#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

store=$(new_store)

rendered_service() {
  printf '%s' "$1" > "$store/user_settings.json"
  env "${platform_env[@]}" RENDER_FORMAT=json \
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

generate() {
  local dir=$1 without=${2:-NONE} vars=() var
  for var in "${platform_env[@]}"; do
    [[ "$var" == "$without="* ]] || vars+=("$var")
  done
  status=0
  output=$(env -u "$without" "${vars[@]}" "$store/scripts/generate-compose.sh" "$dir" whoami "$store/user_settings.json" 2> "$store/stderr") || status=$?
  errors=$(< "$store/stderr")
}

for broken in '{"MODE": "gp' '[]' '"gpu"'; do
  printf '%s' "$broken" > "$store/user_settings.json"
  generate "$store/whoami/latest"
  assert_equal "refuses user_settings.json $broken instead of generating the stock compose" \
    "$status $([[ "$errors" == *"user_settings.json: not a JSON object"* ]] && echo said)" "1 said"
done

while IFS='|' read -r case values key; do
  printf '%s' "$values" > "$store/user_settings.json"
  generate "$store/whoami/latest"
  assert_equal "rejects $case with status 10, listing its key and saying why" \
    "$status $output $([[ "$errors" == *"$key: "* ]] && echo said)" "10 $key said"
done << 'CASES'
an enum value that isn't an option|{"MODE": "turbo"}|MODE
a bool that isn't true or false|{"VERBOSE": "yes"}|VERBOSE
a relative path|{"EXPORT_DIR": "exports"}|EXPORT_DIR
a key the release doesn't have|{"GONE": "x"}|GONE
CASES

printf '%s' '{"MODE": "turbo", "VERBOSE": true, "GONE": 1}' > "$store/user_settings.json"
generate "$store/whoami/latest"
assert_equal "lists every rejected key one per line, and only those" "$status ${output//$'\n'/,}" "10 MODE,GONE"

printf '%s' '{"MODE": "gpu", "VERBOSE": false, "EXPORT_DIR": "/var/mnt/external/abc/Export"}' > "$store/user_settings.json"
generate "$store/whoami/latest"
assert_equal "renders values the release accepts" "$status" 0

printf '{}' > "$store/user_settings.json"
for name in APP_DATA_DIR APP_SEED APP_PASSWORD APP_TZ; do
  generate "$store/whoami/latest" "$name"
  assert_equal "fails without the platform variable $name" \
    "$status $([[ "$errors" == *"$name"* ]] && echo named)" "1 named"
done

release=$(mktemp -d "$test_root/release.XXXXXX")
write_release "$release"
edit_json "$release/settings.json" '.fields[1].type = "number"'
generate "$release"
assert_equal "fails on a setting type it doesn't know" \
  "$status $([[ "$errors" == *"MODE: unknown setting type number"* ]] && echo said)" "1 said"

finish_tests
