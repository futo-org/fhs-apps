#!/usr/bin/env bash
# Tests for render.sh (needs jq, docker).
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

store=$(new_store)

# Prints the rendered whoami service as JSON: rendered_service <values json> [app id]
rendered_service() {
  printf '%s' "$1" > "$store/values.json"
  APP_DATA_DIR=/var/home/app-data/whoami APP_SEED=seed APP_PASSWORD=password RENDER_FORMAT=json \
    "$store/scripts/render.sh" "$store/whoami/latest" "${2:-whoami}" "$store/values.json" | jq -c '.services.whoami'
}

service=$(rendered_service '{}')
assert_equal "defaults keep the stock bind" \
  "$(jq -c '[.volumes[] | {source, target}]' <<< "$service")" \
  '[{"source":"/var/home/app-data/whoami/config","target":"/config"}]'
assert_equal "defaults add no devices" "$(jq -c .devices <<< "$service")" null
assert_equal "defaults apply the bool default" "$(jq -r .environment.WHOAMI_VERBOSE <<< "$service")" yes

assert_equal "chosen enum option applies its fragment" \
  "$(rendered_service '{"MODE": "gpu"}' | jq -c '[.devices[] | "\(.source):\(.target)"]')" \
  '["/dev/dri:/dev/dri"]'

assert_equal "false beats a true default" \
  "$(rendered_service '{"VERBOSE": false}' | jq -r .environment.WHOAMI_VERBOSE)" no

assert_equal "picked path replaces the stock bind at the same target" \
  "$(rendered_service '{"EXPORT_DIR": "/var/mnt/external/abc/Export"}' | jq -c '[.volumes[] | {source, target, create_host_path: .bind.create_host_path}]')" \
  '[{"source":"/var/mnt/external/abc/Export","target":"/config","create_host_path":false}]'

secret=$(jq -r .environment.SECRET <<< "$service")
assert_equal "generated secret is 32 hex chars" "$([[ "$secret" =~ ^[0-9a-f]{32}$ ]] && echo yes)" yes
assert_equal "generated secret is stable per app" "$(rendered_service '{}' | jq -r .environment.SECRET)" "$secret"
assert_equal "generated secret differs between apps" \
  "$(rendered_service '{}' other | jq -r --arg secret "$secret" '.environment.SECRET != $secret')" true

finish_tests
