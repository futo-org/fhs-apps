#!/usr/bin/env bash
set -euo pipefail

if (($# < 2)); then
  echo "usage: $0 <release-dir> <app-id> [user_settings.json]" >&2
  exit 2
fi

release_dir=$1
app_id=$2
values_file=${3:-}
settings="$release_dir/settings.json"

for name in APP_DATA_DIR APP_SEED APP_PASSWORD APP_TZ; do
  [[ -n "${!name:-}" ]] || {
    echo "$name: missing from the environment" >&2
    exit 1
  }
done

unknown_types=$(jq -r '.fields[] | select(.type | IN("path", "enum", "bool") | not) | "\(.key): unknown setting type \(.type)"' "$settings")
if [[ -n "$unknown_types" ]]; then
  echo "$unknown_types" >&2
  exit 1
fi

values='{}'
if [[ -n "$values_file" ]]; then
  values=$(< "$values_file")
fi
jq -e 'type == "object"' <<< "$values" > /dev/null 2>&1 || {
  echo "${values_file:-values}: not a JSON object" >&2
  exit 1
}

rejected=$(jq -r --argjson values "$values" '
  (.fields | map({(.key): .}) | add // {}) as $fields
  | $values | to_entries[] | .key as $key | .value as $value | $fields[$key] as $field
  | if $field == null then "\($key)\tthe release has no such setting"
    elif $field.type == "enum" and ($field.options | any(.value == $value) | not) then "\($key)\t\($value | tojson) is not one of the options"
    elif $field.type == "bool" and ($value | type) != "boolean" then "\($key)\tmust be true or false"
    elif $field.type == "path" and (($value | type) != "string" or ($value | startswith("/") | not)) then "\($key)\tmust be an absolute path"
    else empty end' "$settings")
if [[ -n "$rejected" ]]; then
  cut -f1 <<< "$rejected"
  echo "${rejected//$'\t'/: }" >&2
  exit 10
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

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
      }' "$settings"
}

env_args=(APP_ID="$app_id")
compose_args=(-p "$app_id" -f "$release_dir/docker-compose.yml")
index=0

fields=$(resolved_fields)
while IFS= read -r field; do
  [[ -n "$field" ]] || continue
  key=$(jq -r .key <<< "$field")
  env_args+=("$key=$(jq -r 'if .value == null then "" else .value | tostring end' <<< "$field")")

  fragment=$(jq -c .fragment <<< "$field")
  if [[ "$fragment" != null ]]; then
    index=$((index + 1))
    printf '%s\n' "$fragment" > "$work/fragment-$index.json"
    compose_args+=(-f "$work/fragment-$index.json")
  fi
done <<< "$fields"

env "${env_args[@]}" docker compose "${compose_args[@]}" config --no-path-resolution --no-env-resolution ${RENDER_FORMAT:+--format "$RENDER_FORMAT"}
