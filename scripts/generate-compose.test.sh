#!/usr/bin/env bash
# Tests for generate-compose.sh (needs jq, docker).
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

store=$(new_store)

# Prints the rendered whoami service as JSON: rendered_service <values json> [app id]
rendered_service() {
  printf '%s' "$1" > "$store/user_settings.json"
  APP_DATA_DIR=/var/home/app-data/whoami APP_SEED=seed APP_PASSWORD=password RENDER_FORMAT=json \
    "$store/scripts/generate-compose.sh" "$store/whoami/latest" "${2:-whoami}" "$store/user_settings.json" | jq -c '.services.whoami'
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

assert_equal "a bool reaches the compose as true or false" \
  "$(rendered_service '{"VERBOSE": false}' | jq -r .environment.VERBOSE) $(jq -r .environment.VERBOSE <<< "$service")" "false true"

assert_equal "picked path replaces the stock bind at the same target" \
  "$(rendered_service '{"EXPORT_DIR": "/var/mnt/external/abc/Export"}' | jq -c '[.volumes[] | {source, target, create_host_path: .bind.create_host_path}]')" \
  '[{"source":"/var/mnt/external/abc/Export","target":"/config","create_host_path":false}]'

# generate <release dir>: runs the script on $store/user_settings.json; sets status and output.
generate() {
  run env APP_DATA_DIR=/var/home/app-data/whoami APP_SEED=seed APP_PASSWORD=password \
    "$store/scripts/generate-compose.sh" "$1" whoami "$store/user_settings.json"
}

for broken in '{"MODE": "gp' '[]' '"gpu"'; do
  printf '%s' "$broken" > "$store/user_settings.json"
  generate "$store/whoami/latest"
  assert_equal "refuses user_settings.json $broken instead of generating the stock compose" \
    "$status $([[ "$output" == *"user_settings.json: not a JSON object"* ]] && echo said)" "1 said"
done

finish_tests
