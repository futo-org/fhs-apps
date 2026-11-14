#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

failed=0
fail() {
  echo "error: $*" >&2
  failed=1
}

command -v jq > /dev/null || {
  echo "jq is required" >&2
  exit 2
}

ports_dir=$(mktemp -d)
trap 'rm -rf "$ports_dir"' EXIT

report_problems() {
  local at=$1 found problem
  shift
  found=$("$@") || {
    fail "${at:-the store}: couldn't be checked"
    return
  }
  while IFS= read -r problem; do
    [[ -z "$problem" ]] || fail "${at:+$at: }$problem"
  done <<< "$found"
}

validate_links() {
  local apps
  mapfile -t apps < <(app_ids)
  report_problems "" find catalog.json scripts "${apps[@]}" ! -type f ! -type d \
    -printf '%p: only files and folders are allowed in the store\n'
}

app_ids() {
  local manifest
  for manifest in */manifest.json; do
    case $manifest in _* | .*) continue ;; esac
    echo "${manifest%/manifest.json}"
  done
}

unknown_keys() {
  local json=$1
  shift
  jq -r --args '[$ARGS.positional[]] as $allowed | keys - $allowed | .[] | "unknown key \"\(.)\""' "$@" <<< "$json"
}

catalog_problems() {
  jq -r '
    .apps[]? | . as $app | "\($app.id // "?")" as $at |
    ((keys - ["id", "name", "tagline", "description", "icon", "developer", "website", "sourceRepo"])[] | "\($at): unknown key \"\(.)\""),
    (if has("icon") and (($app.icon | type) != "string" or ($app.icon | test("^https://[^\\s/?#]+([/?#]\\S*)?$") | not))
      then "\($at): icon must be an absolute https URL" else empty end)' <<< "$1"
}

validate_catalog() {
  local catalog listed app
  catalog=$(< catalog.json)
  jq -e '.schemaVersion == 1 and (.apps | type == "array")' <<< "$catalog" > /dev/null \
    || fail "catalog.json: schemaVersion must be 1 and apps an array"
  report_problems catalog.json unknown_keys "$catalog" schemaVersion apps
  report_problems catalog.json catalog_problems "$catalog"
  listed=$(jq -r '.apps[]?.id' <<< "$catalog") || {
    fail "catalog.json: couldn't be checked"
    return
  }
  for app in $listed; do
    [[ -f "$app/manifest.json" ]] || fail "catalog.json: lists $app but $app/manifest.json is missing"
  done
  for app in $(app_ids); do
    grep -qxF "$app" <<< "$listed" || fail "$app/manifest.json: $app is not in catalog.json"
  done
}

validate_manifest() {
  local app=$1 manifest count version entry
  manifest=$(< "$app/manifest.json") || {
    fail "$app/manifest.json: unreadable"
    return
  }
  jq -e . <<< "$manifest" > /dev/null 2>&1 || {
    fail "$app/manifest.json: not valid json"
    return
  }

  report_problems "$app/manifest.json" unknown_keys "$manifest" schemaVersion appId appPort releases
  [[ $(jq -r .schemaVersion <<< "$manifest") == 1 ]] || fail "$app/manifest.json: schemaVersion must be 1"
  [[ $(jq -r .appId <<< "$manifest") == "$app" ]] || fail "$app/manifest.json: appId must be \"$app\""
  jq -e '(.appPort | tojson | test("^[1-9][0-9]{0,4}$")) and .appPort <= 65535' <<< "$manifest" > /dev/null \
    || fail "$app/manifest.json: appPort must be an integer 1-65535"
  jq -e '.releases | type == "array"' <<< "$manifest" > /dev/null || {
    fail "$app/manifest.json: releases must be an array"
    return
  }

  count=$(jq '.releases | length' <<< "$manifest")
  for ((version = 1; version <= count; version++)); do
    entry=$(jq -c ".releases[$((version - 1))]" <<< "$manifest")
    report_problems "$app/manifest.json: release $version" unknown_keys "$entry" version appVersion canSkip
    jq -e --argjson v "$version" '.version == $v' <<< "$entry" > /dev/null \
      || fail "$app/manifest.json: release $version must have version $version (consecutive from 1)"
    jq -e '.appVersion | type == "string" and length > 0' <<< "$entry" > /dev/null \
      || fail "$app/manifest.json: release $version needs a non empty appVersion"
    jq -e '.canSkip | type == "boolean"' <<< "$entry" > /dev/null \
      || fail "$app/manifest.json: release $version needs a boolean canSkip"
    if [[ -d "$app/releases/$version" ]]; then
      validate_release_folder "$app" "$app/releases/$version"
      [[ ! -f "$app/releases/$version/release.json" ]] \
        || report_problems "$app/manifest.json" app_version_mismatch "$entry" "$app/releases/$version/release.json"
      ((version == 1)) || validate_kept_paths "$app/releases/$((version - 1))" "$app/releases/$version" "$((version - 1))"
    else
      fail "$app/releases/$version: missing"
    fi
  done

  local dir
  for dir in "$app"/releases/*/; do
    [[ -d "$dir" ]] || continue
    dir=${dir%/}
    version=${dir##*/}
    if ! [[ "$version" =~ ^[1-9][0-9]*$ ]] || ((version > count)); then
      fail "$dir: no manifest entry for this release folder"
    fi
  done

  if [[ -d "$app/latest" ]]; then
    validate_release_folder "$app" "$app/latest"
  else
    fail "$app/latest: missing"
  fi

  if ((count == 0)) || ! diff -r -q "$app/latest" "$app/releases/$count" > /dev/null 2>&1; then
    fail "$app/latest: not released: run \`mise run release $app\`"
  fi
}

app_version_mismatch() {
  jq -rn --argjson entry "$1" --arg path "$2" --rawfile release "$2" '
    ($release | fromjson? // null) as $release |
    if ($release | type) != "object" or $release.appVersion == $entry.appVersion then empty
    else "release \($entry.version) appVersion \($entry.appVersion | tojson) differs from \($path) (\($release.appVersion | tojson))" end'
}

validate_release_folder() {
  local app=$1 dir=$2 name release
  for name in "$dir"/* "$dir"/.[!.]*; do
    [[ -e "$name" ]] || continue
    case ${name##*/} in
      release.json | docker-compose.yml | settings.json | health-check.sh) ;;
      data) [[ -d "$name" ]] || fail "$name: must be a directory of seed folders" ;;
      *) fail "$name: not allowed in a release folder (allowed: release.json, docker-compose.yml, settings.json, health-check.sh, data/)" ;;
    esac
  done

  for name in release.json docker-compose.yml settings.json health-check.sh; do
    [[ -f "$dir/$name" ]] || fail "$dir/$name: missing"
  done
  [[ -f "$dir/release.json" && -f "$dir/settings.json" && -f "$dir/docker-compose.yml" ]] || return 0

  release=$(< "$dir/release.json")
  if jq -e . <<< "$release" > /dev/null 2>&1; then
    report_problems "$dir/release.json" unknown_keys "$release" appVersion canSkip healthTimeoutMinutes
    jq -e '(.appVersion | type == "string" and length > 0) and (.canSkip | type == "boolean")' <<< "$release" > /dev/null \
      || fail "$dir/release.json: needs a non empty appVersion and a boolean canSkip"
    jq -e '(has("healthTimeoutMinutes") | not) or ((.healthTimeoutMinutes | tojson | test("^[1-9][0-9]{0,2}$")) and .healthTimeoutMinutes <= 360)' <<< "$release" > /dev/null \
      || fail "$dir/release.json: healthTimeoutMinutes must be a whole number of minutes, 1 to 360"
  else
    fail "$dir/release.json: not valid json"
  fi

  validate_no_upstream_defaults "$dir/docker-compose.yml"
  if validate_settings "$dir/settings.json"; then
    validate_no_upstream_defaults "$dir/settings.json"
    validate_variables "$dir"
  fi

  if command -v shellcheck > /dev/null && [[ -f "$dir/health-check.sh" ]]; then
    shellcheck -s bash "$dir/health-check.sh" >&2 || fail "$dir/health-check.sh: shellcheck failed"
  fi
  if [[ -f "$dir/health-check.sh" ]] && grep -qP '^(?!\s*#).*\bdocker\b' "$dir/health-check.sh"; then
    fail "$dir/health-check.sh: health checks can't use docker"
  fi

  if [[ "${SKIP_RENDER:-}" != 1 ]]; then
    render_combinations "$app" "$dir"
  fi
}

settings_problems() {
  jq -r '
    def known_keys:
      {
        path: ["key", "type", "label", "help", "editable", "compose"],
        enum: ["key", "type", "label", "help", "editable", "compose", "default", "options"],
        bool: ["key", "type", "label", "help", "editable", "compose", "default"]
      };
    ((keys - ["fields"])[] | "unknown key \"\(.)\""),
    (if (.fields | type) != "array" then "fields must be an array" else
      ([.fields[].key] | group_by(.) | map(select(length > 1) | .[0])[] | "duplicate key \(.)"),
      (.fields[] | . as $f | "field \($f.key // "?")" as $at |
        if (known_keys | has($f.type // "")) | not then "\($at): type must be path, enum or bool" else
          ((keys - known_keys[$f.type])[] | "\($at): unknown key \"\(.)\" for type \($f.type)"),
          (if ($f.key | type) != "string" or ($f.key | test("^[A-Z][A-Z0-9_]*$") | not) then "\($at): key must be UPPER_SNAKE" else empty end),
          (if ($f.key // "" | test("^(APP_|FHS_|COMPOSE_)")) then "\($at): APP_, FHS_ and COMPOSE_ prefixes are reserved" else empty end),
          (if ($f.label | type) != "string" or ($f.label | length) == 0 then "\($at): needs a label" else empty end),
          (if has("help") and ($f.help | type) != "string" then "\($at): help must be a string" else empty end),
          (if has("editable") and ($f.editable | type) != "boolean" then "\($at): editable must be a boolean" else empty end),
          (if has("compose") and ($f.compose | type) != "object" then "\($at): compose must be an object" else empty end),
          (if $f.type == "enum" then
            ([$f.options[]?.value]) as $values |
            (if ($f.options | type) != "array" or ($f.options | length) == 0 then "\($at): options must be a non empty array" else empty end),
            ($f.options[]? | select((keys - ["value", "label"]) != [] or (.value | type) != "string" or (.label | type) != "string") | "\($at): every option needs only a string value and label"),
            ($values | group_by(.) | map(select(length > 1) | .[0])[] | "\($at): duplicate option \(.)"),
            (if ($values | index($f.default)) == null then "\($at): default must be one of the option values" else empty end),
            ((($f.compose // {}) | keys) - $values | .[] | "\($at): compose case \"\(.)\" is not an option value")
          elif $f.type == "bool" then
            (if ($f.default | type) != "boolean" then "\($at): default must be a boolean" else empty end),
            ((($f.compose // {}) | keys) - ["true", "false"] | .[] | "\($at): compose cases must be \"true\" or \"false\"")
          elif $f.type == "path" then
            ($f.compose.services // {} | to_entries[] | .value.volumes // [] | .[]
              | select((type != "object") or .type != "bind" or .bind.create_host_path != false)
              | "\($at): path binds must use long syntax with bind.create_host_path: false")
          else empty end)
        end)
    end)' "$1"
}

validate_settings() {
  local file=$1
  jq -e . "$file" > /dev/null 2>&1 || {
    fail "$file: not valid json"
    return 1
  }
  report_problems "$file" settings_problems "$file"
}

platform_variables=(APP_ID APP_DATA_DIR APP_SEED APP_PASSWORD APP_TZ)

unknown_variables() {
  local known lines names name
  local -A seen=()
  known=$(printf '%s\n' "$1" "${platform_variables[@]}")
  lines=$(sed '/^[[:space:]]*#/d' <<< "$2") || return
  names=$(grep -oP '(?<!\$)\$\{?\K[A-Za-z_][A-Za-z0-9_]*' <<< "$lines") || (($? == 1)) || return
  for name in $names; do
    [[ -z "${seen[$name]:-}" ]] || continue
    seen[$name]=1
    grep -qxF "$name" <<< "$known" || echo "\${$name} is not a setting key or platform variable"
  done
}

validate_variables() {
  local dir=$1 keys fragments compose
  if ! keys=$(jq -r '.fields[]?.key' "$dir/settings.json") \
    || ! fragments=$(jq '[.fields[]?.compose // empty]' "$dir/settings.json") \
    || ! compose=$(< "$dir/docker-compose.yml"); then
    fail "$dir: couldn't check its variables"
    return
  fi
  report_problems "$dir/docker-compose.yml" unknown_variables "$keys" "$compose"
  report_problems "$dir/settings.json" unknown_variables "$keys" "$fragments"
}

kept_path_problems() {
  jq -rn --arg number "$1" --slurpfile before "$2" --slurpfile after "$3" '
    $before[0].fields[]? | select(.type == "path") | .key as $key |
    if any($after[0].fields[]?; .key == $key and .type == "path") then empty
    else "path setting \($key) of release \($number) is gone or no longer a path" end'
}

validate_kept_paths() {
  local before=$1 after=$2 number=$3
  [[ -f "$before/settings.json" && -f "$after/settings.json" ]] || return 0
  report_problems "$after/settings.json" kept_path_problems "$number" "$before/settings.json" "$after/settings.json"
}

validate_no_upstream_defaults() {
  if grep -qE '\$\{[A-Z_]+:-' "$1"; then fail "$1: unresolved upstream variable"; fi
}

published_ports='def published_ports: .published // empty | tostring | split("-") | map(tonumber)
  | if length == 2 then range(.[0]; .[1] + 1) else .[0] end;'

compose_problems() {
  jq -r --arg values "$2" --argjson port "$3" "$published_ports"'
    (if any(.services[]; .network_mode == "host") or any(.services[].ports[]? | select((.protocol // "tcp") == "tcp") | published_ports; . == $port) then empty
      else "appPort \($port) isn'"'"'t published" end),
    (.services | to_entries[] | .key as $service | .value |
      (if (.restart // "" | IN("always", "unless-stopped")) | not then "\($service): needs restart: always or unless-stopped" else empty end),
      (if has("container_name") then "\($service): container_name is not allowed, container names are global on the host" else empty end),
      (if has("env_file") then "\($service): env_file is not allowed" else empty end),
      ((.image // "") as $image |
        if ($image | test(":[^/]+$") | not) then "\($service): image \($image) must be pinned to a tag"
        elif ($image | test(":(latest|release)(@|$)")) then "\($service): image \($image) has a floating tag"
        else empty end),
      (.volumes[]? |
        if .type == "volume" then "\($service): \(.target) is a docker volume, bind a folder under ${APP_DATA_DIR} instead"
        elif .type == "bind" and (.source | startswith("/") | not) then "\($service): binds a relative path (\(.source))"
        else empty end),
      (if any(.volumes[]?; .bind.selinux != null) then "\($service): SELinux relabel options are not allowed" else empty end))
    | "\(.)\t\($values)"' <<< "$1"
}

host_ports() {
  jq -r --argjson port "$2" "$published_ports"'
    .services[] | if .network_mode == "host" then "\($port)/tcp" else (.ports[]? | "\(published_ports)/\(.protocol // "tcp")") end' <<< "$1"
}

value_combinations() {
  jq -c '
    def choices:
      if .type == "enum" then [.options[].value]
      elif .type == "bool" then [true, false]
      elif .type == "path" then [null, "/var/mnt/external/validate/\(.key)"]
      else [null] end;
    reduce .fields[] as $f ([{}];
      [.[] as $acc | ($f | choices)[] as $c | $acc + (if $c == null then {} else {($f.key): $c} end)])
    | .[]' "$1"
}

render_combinations() {
  local app=$1 dir=$2 app_port combinations values rendered work found ports problem
  command -v docker > /dev/null || {
    fail "docker is required to render (set SKIP_RENDER=1 to skip)"
    return
  }
  if ! app_port=$(jq .appPort "$app/manifest.json") || ! combinations=$(value_combinations "$dir/settings.json"); then
    fail "$dir: couldn't list the settings combinations to render"
    return
  fi
  [[ -n "$combinations" ]] || fail "$dir/settings.json: no settings combination to render"
  work=$(mktemp -d)
  : > "$work/problems"
  while IFS= read -r values; do
    [[ -n "$values" ]] || continue
    printf '%s' "$values" > "$work/user_settings.json"
    if ! rendered=$(APP_DATA_DIR="/var/home/app-data/$app" APP_SEED=validate APP_PASSWORD=validate APP_TZ=Etc/UTC \
      RENDER_FORMAT=json scripts/generate-compose.sh "$dir" "$app" "$work/user_settings.json" 2> "$work/err"); then
      fail "$dir: render failed for $values: $(< "$work/err")"
      continue
    fi
    if ! found=$(compose_problems "$rendered" "$values" "$app_port") || ! ports=$(host_ports "$rendered" "$app_port"); then
      fail "$dir: couldn't check the render for $values"
      continue
    fi
    printf '%s\n' "$found" >> "$work/problems"
    printf '%s\n' "$ports" >> "$ports_dir/$app"
    printf '%s' "$rendered" > "$work/rendered.json"
    docker compose -f "$work/rendered.json" config -q 2> "$work/err" \
      || fail "$dir: the rendered compose doesn't load for $values: $(< "$work/err")"
  done <<< "$combinations"
  if found=$(sort -s -u -t $'\t' -k1,1 "$work/problems"); then
    while IFS=$'\t' read -r problem values; do
      [[ -z "$problem" ]] || fail "$dir: $problem (with $values)"
    done <<< "$found"
  else
    fail "$dir: couldn't sort the render problems"
  fi
  rm -rf "$work"
}

validate_ports() {
  local app port first
  local -A taken=() reported=()
  for app in $(app_ids); do
    [[ -f "$ports_dir/$app" ]] || continue
    while IFS= read -r port; do
      [[ -n "$port" ]] || continue
      first=${taken[$port]:-}
      if [[ -z "$first" ]]; then
        taken[$port]=$app
      elif [[ "$first" != "$app" && -z "${reported["$app $port"]:-}" ]]; then
        reported["$app $port"]=1
        fail "$app: host port $port is also published by $first"
      fi
    done < "$ports_dir/$app"
  done
}

history_problems() {
  jq -rn --argjson base "$1" --slurpfile now "$2" '
    $now[0] as $now |
    (if $base.appId != $now.appId then "appId must not change" else empty end),
    (if $base.schemaVersion != $now.schemaVersion then "schemaVersion must not change here" else empty end),
    ($base.releases | to_entries[] | .key as $i | .value as $old | $now.releases[$i] as $new |
      if $new == null then "published release \($old.version) was removed"
      elif $new.version != $old.version or $new.appVersion != $old.appVersion then "published release \($old.version) changed"
      elif $new.canSkip != $old.canSkip and ($old.canSkip or ($new.canSkip | not)) then "release \($old.version): canSkip may only change from false to true"
      else empty end)'
}

validate_history() {
  local app=$1 base_manifest count base_count=0 version
  [[ -n "${BASE_REF:-}" ]] || return 0

  if base_manifest=$(git show "$BASE_REF:$app/manifest.json" 2> /dev/null); then
    report_problems "$app/manifest.json" history_problems "$base_manifest" "$app/manifest.json"
    base_count=$(jq '.releases | length' <<< "$base_manifest")
  fi

  count=$(jq '.releases | length' "$app/manifest.json")
  for ((version = 1; version <= base_count; version++)); do
    git diff --quiet "$BASE_REF" -- "$app/releases/$version" \
      || fail "$app/releases/$version: published release folders never change"
  done
  if ((count > base_count + 1)); then
    fail "$app/manifest.json: a PR adds one release at most, this one adds $((count - base_count))"
  fi
}

validate_removed_apps() {
  local published path
  [[ -n "${BASE_REF:-}" ]] || return 0
  published=$(git ls-tree -r --name-only "$BASE_REF") || {
    fail "$BASE_REF: couldn't list its apps"
    return
  }
  while IFS= read -r path; do
    [[ "$path" =~ ^[^_./][^/]*/manifest\.json$ ]] || continue
    [[ -f "$path" ]] || fail "$path: a published app can't be removed"
  done <<< "$published"
}

if [[ -n "${BASE_REF:-}" ]] && ! git rev-parse --verify -q "$BASE_REF^{commit}" > /dev/null; then
  echo "warning: BASE_REF $BASE_REF not found, skipping history checks" >&2
  BASE_REF=
fi
if [[ -n "${BASE_REF:-}" ]] && ! git cat-file -e "$BASE_REF:scripts/validate-store.sh" 2> /dev/null; then
  echo "BASE_REF $BASE_REF predates the store format, skipping history checks"
  BASE_REF=
fi

validate_catalog
validate_links
validate_removed_apps
for app in $(app_ids); do
  validate_manifest "$app"
  validate_history "$app"
done
validate_ports

if ((failed)); then
  echo "store validation failed" >&2
  exit 1
fi
echo "store validation passed"
