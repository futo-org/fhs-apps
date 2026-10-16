#!/usr/bin/env bash
# Tests for validate-store.sh (the render cases need docker).
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

# release <store>: releases the store's latest/, like an author before opening the PR.
release() {
  BASE_REF=HEAD "$1/scripts/release.sh" whoami > /dev/null
}

# Prints a new store with latest/ released as release 1.
released_store() {
  local store
  store=$(new_store)
  release "$store"
  echo "$store"
}

# Prints a released store with the release committed, the base for history checks.
committed_store() {
  local store
  store=$(released_store)
  commit "$store" "release 1"
  echo "$store"
}

# Prints the problems validate reports, renders skipped: problems <store> [base ref]
problems() {
  { SKIP_RENDER=1 BASE_REF="${2:-}" "$1/scripts/validate-store.sh" > /dev/null; } 2>&1 || true
}

store=$(released_store)
run "$store/scripts/validate-store.sh"
assert_equal "passes a valid store, renders included" "$status" 0

# Catalog and manifest.

store=$(released_store)
edit_json "$store/catalog.json" '.apps += [{"id": "ghost", "name": "Ghost"}]'
assert_problem "rejects a catalog app without a manifest" "$(problems "$store")" \
  catalog.json "lists ghost but ghost/manifest.json is missing"

store=$(released_store)
edit_json "$store/whoami/manifest.json" '.healthCheckUrl = "/"'
assert_problem "rejects an unknown manifest key" "$(problems "$store")" whoami/manifest.json healthCheckUrl

store=$(released_store)
edit_json "$store/whoami/manifest.json" '.appId = "whoareyou"'
assert_problem "rejects an appId that differs from the folder" "$(problems "$store")" \
  whoami/manifest.json 'appId must be "whoami"'

store=$(released_store)
edit_json "$store/whoami/manifest.json" '.releases[0].version = 2'
assert_problem "rejects release numbers that are not consecutive from 1" "$(problems "$store")" \
  whoami/manifest.json "release 1 must have version 1"

store=$(released_store)
rm -rf "$store/whoami/releases/1"
assert_problem "rejects a manifest entry without its release folder" "$(problems "$store")" \
  whoami/releases/1 missing

store=$(released_store)
mkdir -p "$store/whoami/releases/7"
echo '{}' > "$store/whoami/releases/7/release.json"
assert_problem "rejects a release folder without a manifest entry" "$(problems "$store")" \
  whoami/releases/7 "no manifest entry"

# Release folder.

store=$(released_store)
echo 'docker compose up -d' > "$store/whoami/latest/start.sh"
assert_problem "rejects a file that is not part of a release" "$(problems "$store")" \
  whoami/latest/start.sh "not allowed in a release folder"

store=$(released_store)
rm "$store/whoami/latest/health-check.sh"
assert_problem "rejects a release without its health check" "$(problems "$store")" \
  whoami/latest/health-check.sh missing

store=$(released_store)
echo 'docker compose ps --status running | grep -q whoami' > "$store/whoami/latest/health-check.sh"
assert_problem "rejects a health check that uses docker" "$(problems "$store")" \
  whoami/latest/health-check.sh "can't use docker"

store=$(released_store)
printf '# unlike docker compose ps, this sees the app serve\ncurl -fsS http://127.0.0.1:8080/\n' > "$store/whoami/latest/health-check.sh"
release "$store"
assert_equal "accepts docker in a health check comment" "$(problems "$store")" ""

store=$(released_store)
edit_json "$store/whoami/latest/release.json" '.notes = "new"'
assert_problem "rejects an unknown release.json key" "$(problems "$store")" whoami/latest/release.json notes

# Settings.

# Prints the problems after editing latest/settings.json: settings_problems <jq filter>
settings_problems() {
  local store
  store=$(released_store)
  edit_json "$store/whoami/latest/settings.json" "$1"
  problems "$store"
}

settings=whoami/latest/settings.json
assert_problem "rejects a reserved key prefix" "$(settings_problems '.fields[1].key = "APP_MODE"')" \
  "$settings" "APP_, FHS_ and COMPOSE_ prefixes are reserved"
assert_problem "rejects a key that is not UPPER_SNAKE" "$(settings_problems '.fields[1].key = "mode"')" \
  "$settings" "key must be UPPER_SNAKE"
assert_problem "rejects an enum default that is not an option" "$(settings_problems '.fields[1].default = "turbo"')" \
  "$settings" "default must be one of the option values"
assert_problem "rejects an enum compose case that is not an option" "$(settings_problems '.fields[1].compose.turbo = {}')" \
  "$settings" 'compose case "turbo" is not an option value'
assert_problem "rejects a bool compose case other than true or false" "$(settings_problems '.fields[2].compose.on = {}')" \
  "$settings" 'compose cases must be "true" or "false"'
# shellcheck disable=SC2016 # ${EXPORT_DIR} is compose syntax, not bash
assert_problem "rejects a path bind in short syntax" \
  "$(settings_problems '.fields[0].compose.services.whoami.volumes = ["${EXPORT_DIR}:/config"]')" \
  "$settings" "path binds must use long syntax"
assert_problem "rejects a duplicate key" "$(settings_problems '.fields += [.fields[1]]')" \
  "$settings" "duplicate key MODE"

found=$(settings_problems '.fields[1].default = "turbo" | .fields[2].default = "yes"')
assert_problem "reports each broken field: the enum" "$found" "$settings" "field MODE: default must be one of the option values"
assert_problem "reports each broken field: the bool" "$found" "$settings" "field VERBOSE: default must be a boolean"

# Releases.

not_released="not released: run \`mise run release whoami\`"

store=$(new_store)
assert_problem "rejects an app with no release" "$(problems "$store")" whoami/latest "$not_released"

store=$(released_store)
echo 'exit 0' > "$store/whoami/latest/health-check.sh"
assert_problem "rejects latest/ that differs from the newest release" "$(problems "$store")" \
  whoami/latest "$not_released"

# Compose.

compose=whoami/latest/docker-compose.yml

store=$(released_store)
printf 'volumes:\n  cache: {}\n' >> "$store/$compose"
assert_problem "rejects named volumes" "$(problems "$store")" "$compose" "named volumes are not allowed"

store=$(released_store)
sed -i 's/whoami:v1.10.1/whoami:latest/' "$store/$compose"
assert_problem "rejects a floating image tag" "$(problems "$store")" "$compose" "floating image tag"

store=$(released_store)
sed -i 's#:/config$#:/config:Z#' "$store/$compose"
assert_problem "rejects SELinux relabel options" "$(problems "$store")" "$compose" "SELinux relabel options are not allowed"

store=$(released_store)
sed -i '/restart: unless-stopped/d' "$store/$compose"
assert_problem "rejects a service without a restart policy, in every render" \
  "$({ "$store/scripts/validate-store.sh" > /dev/null; } 2>&1 || true)" whoami/latest "every service needs restart"

# Published history.

store=$(committed_store)
edit_json "$store/whoami/manifest.json" '.releases[0].canSkip = true'
assert_equal "accepts flipping canSkip from false to true" "$(problems "$store" HEAD)" ""

store=$(committed_store)
edit_json "$store/whoami/manifest.json" '.releases[0].canSkip = true'
commit "$store" skip
edit_json "$store/whoami/manifest.json" '.releases[0].canSkip = false'
assert_problem "rejects flipping canSkip from true to false" "$(problems "$store" HEAD)" \
  whoami/manifest.json "canSkip may only change from false to true"

store=$(committed_store)
echo 'exit 0' > "$store/whoami/releases/1/health-check.sh"
assert_problem "rejects editing a published release folder" "$(problems "$store" HEAD)" \
  whoami/releases/1 "published release folders never change"

store=$(committed_store)
edit_json "$store/whoami/manifest.json" '.releases |= .[:-1]'
rm -rf "$store/whoami/releases/1"
assert_problem "rejects removing a published release" "$(problems "$store" HEAD)" \
  whoami/manifest.json "published release 1 was removed"

store=$(committed_store)
edit_json "$store/whoami/latest/release.json" '.appVersion = "v1.11.0"'
release "$store"
assert_equal "accepts a PR that changes latest/ and adds its release" "$(problems "$store" HEAD)" ""

store=$(committed_store)
base=$(git -C "$store" rev-parse HEAD)
edit_json "$store/whoami/latest/release.json" '.appVersion = "v1.11.0"'
release "$store"
commit "$store" "release 2"
edit_json "$store/whoami/latest/release.json" '.appVersion = "v1.12.0"'
release "$store"
assert_problem "rejects a PR that adds more than one release" "$(problems "$store" "$base")" \
  whoami/manifest.json "a PR adds one release at most, this one adds 2"

finish_tests
