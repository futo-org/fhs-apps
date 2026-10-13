#!/usr/bin/env bash
# Tests for publish.sh.
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

store=$(new_store)
run "$store/scripts/publish.sh" whoami
assert_equal "freezes latest/ as release 1" "$status $output" "0 whoami: published release 1 (v1.10.1)"
assert_equal "appends the release 1 manifest entry" "$(jq -c .releases "$store/whoami/manifest.json")" \
  '[{"version":1,"appVersion":"v1.10.1","canSkip":false}]'
assert_equal "release 1 is a full copy of latest/" \
  "$(diff -r "$store/whoami/latest" "$store/whoami/releases/1" && echo same)" same

run "$store/scripts/publish.sh" whoami
assert_equal "publishes nothing when latest/ equals the last release" "$status $output $(jq '.releases | length' "$store/whoami/manifest.json")" \
  "0 whoami: latest/ matches release 1, nothing to publish 1"
assert_equal "makes no release folder when nothing changed" "$([[ -e "$store/whoami/releases/2" ]] || echo absent)" absent

write_release "$store/whoami/latest" v1.11.0 true
run "$store/scripts/publish.sh" whoami
assert_equal "appends the next release number with latest/ release.json values" \
  "$status $(jq -c .releases "$store/whoami/manifest.json")" \
  '0 [{"version":1,"appVersion":"v1.10.1","canSkip":false},{"version":2,"appVersion":"v1.11.0","canSkip":true}]'

store=$(new_store)
mkdir -p "$store/whoami/releases/1"
run "$store/scripts/publish.sh" whoami
assert_equal "refuses when the next release folder already exists" "$status $output" \
  "1 whoami/releases/1: already exists"

finish_tests
