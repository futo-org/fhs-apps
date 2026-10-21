#!/usr/bin/env bash
# Renders a release's compose: the stock compose plus the fragments the chosen
# values select, merged by `docker compose config` with the values baked in.
# Prints the rendered compose. The agent runs this script on the device, CI runs
# it to validate; it is the only renderer.
#
# usage: generate-compose.sh <release-dir> <app-id> [user_settings.json]
#   user_settings.json: {"KEY": value}; unset keys take the release default.
# The caller provides APP_DATA_DIR, APP_SEED and APP_PASSWORD in the environment.
# RENDER_FORMAT=json prints JSON instead of YAML.
set -euo pipefail

if (($# < 2)); then
  echo "usage: $0 <release-dir> <app-id> [user_settings.json]" >&2
  exit 2
fi

release_dir=$1
app_id=$2
values_file=${3:-}

values='{}'
if [[ -n "$values_file" ]]; then
  values=$(< "$values_file")
fi
# A broken file must not quietly render the defaults: a picked folder would fall
# back to app data.
jq -e 'type == "object"' <<< "$values" > /dev/null 2>&1 || {
  echo "${values_file:-values}: not a JSON object" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# One line per field: {key, type, value, fragment}. A fragment applies when its
# case matches: enum option value, bool true/false, path picked (non empty).
# Default only when unset: jq's `//` would also replace a chosen false.
resolved_fields() {
  jq -c --argjson values "$values" '
    .fields[]
    | . as $f
    | (if $values[$f.key] == null then $f.default else $values[$f.key] end) as $v
    | {
        key: $f.key,
        type: $f.type,
        value: $v,
        fragment: (
          if $f.type == "enum" then ($f.compose // {})[$v]
          elif $f.type == "bool" then ($f.compose // {})[($v | tostring)]
          elif $f.type == "path" and ($v // "") != "" then $f.compose
          else null end
        )
      }' "$release_dir/settings.json"
}

env_args=(APP_ID="$app_id")
compose_args=(-p "$app_id" -f "$release_dir/docker-compose.yml")
index=0

# Collected first: a jq error inside `< <(...)` would get past set -e.
fields=$(resolved_fields)
while IFS= read -r field; do
  [[ -n "$field" ]] || continue
  key=$(jq -r .key <<< "$field")
  env_args+=("$key=$(jq -r 'if .value == null then "" else .value | tostring end' <<< "$field")")

  if jq -e '.fragment != null' <<< "$field" > /dev/null; then
    index=$((index + 1))
    jq .fragment <<< "$field" > "$work/fragment-$index.json"
    compose_args+=(-f "$work/fragment-$index.json")
  fi
done <<< "$fields"

env "${env_args[@]}" docker compose "${compose_args[@]}" config ${RENDER_FORMAT:+--format "$RENDER_FORMAT"}
