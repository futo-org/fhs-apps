#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

failed=0
releases=0
declare -A resolution volumes reported
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

report() {
  local problem=$1 values=$2 detail=${3:-}
  [[ ! -v "reported[$problem]" ]] || return 0
  reported[$problem]=1
  echo "error: $problem (with $values)${detail:+: $detail}" >&2
  failed=1
}

look_up() {
  local image=$1 config
  [[ ! -v "resolution[$image]" ]] || return 0
  if ! crane digest "$image" > /dev/null 2> "$work/err" \
    || ! config=$(crane config --platform linux/amd64 "$image" 2> "$work/err"); then
    resolution[$image]=$(tail -1 "$work/err")
    return
  fi
  resolution[$image]=
  volumes[$image]=$(jq -c '.config.Volumes // {} | keys | map(rtrimstr("/"))' <<< "$config")
}

render_values() {
  jq -c '{}, (.fields[] | {(.key): (
    if .type == "enum" then .options[].value
    elif .type == "bool" then true, false
    else "/var/mnt/external/check/\(.key)" end)})' "$1" | awk '!seen[$0]++'
}

check_render() {
  local at=$1 values=$2 rendered=$3 services service image unmounted volume
  services=$(jq -r '.services | to_entries[] | [.key, .value.image] | @tsv' <<< "$rendered")
  while IFS=$'\t' read -r service image; do
    look_up "$image"
    if [[ -n "${resolution[$image]}" ]]; then
      report "$at: $image doesn't resolve" "$values" "${resolution[$image]}"
      continue
    fi
    unmounted=$(jq -r --arg service "$service" --argjson volumes "${volumes[$image]}" \
      '.services[$service] | $volumes - ([.volumes[]?.target, (.tmpfs[]? | split(":")[0])] | map(rtrimstr("/"))) | .[]' <<< "$rendered")
    while IFS= read -r volume; do
      [[ -z "$volume" ]] || report "$at: $image declares VOLUME $volume, which service $service doesn't mount" "$values"
    done <<< "$unmounted"
  done <<< "$services"
}

check_release() {
  local app=$1 version=$2 dir="$1/releases/$2" renders values rendered
  if ! renders=$(render_values "$dir/settings.json" 2> "$work/err"); then
    report "$app release $version: settings.json can't be read" "{}" "$(< "$work/err")"
    return
  fi
  while IFS= read -r values; do
    printf '%s' "$values" > "$work/user_settings.json"
    if ! rendered=$(APP_DATA_DIR="/var/home/app-data/$app" APP_SEED=check APP_PASSWORD=check APP_TZ=Etc/UTC \
      RENDER_FORMAT=json scripts/generate-compose.sh "$dir" "$app" "$work/user_settings.json" 2> "$work/err"); then
      report "$app release $version: doesn't render" "$values" "$(< "$work/err")"
      continue
    fi
    check_render "$app release $version" "$values" "$rendered"
  done <<< "$renders"
  releases=$((releases + 1))
}

apps=$(jq -r '.apps[].id' catalog.json)
for app in $apps; do
  versions=$(jq -r '.releases[].version' "$app/manifest.json")
  for version in $versions; do
    check_release "$app" "$version"
  done
done

if ((failed)); then
  echo "image check failed" >&2
  exit 1
fi
echo "image check passed: ${#resolution[@]} images in $releases releases"
