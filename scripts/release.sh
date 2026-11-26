#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if (($# > 1)); then
  echo "usage: $0 [app-id]" >&2
  exit 2
fi

app=${1:-}
base=${BASE_REF:-origin/master}
pending=""

images() {
  docker compose -p release -f "$1/docker-compose.yml" config --no-interpolate --no-path-resolution --no-env-resolution --format json \
    | jq -r '.services | to_entries[] | select(.value.image) | .key as $service | .value.image | sub("@.*"; "")
      | (capture("^(?<repo>.*):(?<tag>[^:/]+)$") // {repo: ., tag: "-"}) | "\($service) \(.repo) \(.tag)"'
}

image_changes() {
  awk '
    NR == FNR && NF { old[$1] = $2 " " $3; repo[$1] = $2; order[++count] = $1; next }
    NR == FNR { next }
    NF { kept[$1] }
    $1 in old { if (old[$1] != $2 " " $3) print $1, old[$1], $2, $3; next }
    NF { added[$2]++; added_tag[$2] = $3 }
    END {
      for (i = 1; i <= count; i++) if (!(order[i] in kept)) removed[repo[order[i]]]++
      for (i = 1; i <= count; i++) {
        service = order[i]; image = repo[service]
        if (service in kept) continue
        if (removed[image] != 1 || added[image] != 1) print service, old[service], "-", "-"
        else if (old[service] != image " " added_tag[image]) print service, old[service], image, added_tag[image]
      }
    }
  ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

of_services() {
  local changes=$1 services=$2
  if [[ -z $changes || -z $services ]]; then
    echo "$changes"
    return
  fi

  awk 'NR == FNR { keep[$1]; next } $1 in keep' <(echo "$services") <(echo "$changes")
}

show_changes() {
  awk -v app="$app" '!seen[$2, $3, $4, $5]++ {
    if ($4 == "-") print app ": " $2 ":" $3 " removed"
    else if ($2 == $4) print app ": " $2 " " $3 " → " $5
    else print app ": " $2 ":" $3 " → " $4 ":" $5
  }' <<< "$1" >&2
}

shaped_like() {
  local previous=$1 tag=${2#v} parts count shaped
  IFS=. read -ra parts <<< "${previous#v}"
  count=${#parts[@]}
  IFS=. read -ra parts <<< "${tag%%-*}"
  shaped=$(
    IFS=.
    echo "${parts[*]:0:count}"
  )
  [[ $previous == v* ]] && shaped="v$shaped"
  echo "$shaped"
}

version_from() {
  local previous=$1 tag=${2#v}
  if [[ ${previous#v} == *-* && $tag == *-* ]]; then
    echo "$(shaped_like "$previous" "$tag")-${tag#*-}"
    return
  fi

  shaped_like "$previous" "$tag"
}

app_services() {
  local images=$1 previous=$2 service tag version
  version=$(shaped_like "$previous" "$previous")
  while read -r service _ tag; do
    if [[ -n $service && $(shaped_like "$previous" "$tag") == "$version" ]]; then
      echo "$service"
    fi
  done <<< "$images"
}

moved_since_draft() {
  local kept_images=$1 draft_images=$2 latest_images=$3 services=$4 current=$5

  if [[ -z $services ]]; then
    of_services "$(image_changes "$draft_images" "$latest_images")" "$(app_services "$draft_images" "$current")"
    return
  fi

  if [[ $(of_services "$(image_changes "$kept_images" "$latest_images")" "$services" | sort) != "$(of_services "$(image_changes "$kept_images" "$draft_images")" "$services" | sort)" ]]; then
    echo moved
  fi
}

guess_version() {
  local previous=$1 current=$2 changes=$3 kept_images=$4 draft_images=$5 latest_images=$6
  local services app_changes candidates moved=""

  if [[ -z $previous ]]; then
    echo "$current"
    return
  fi

  services=$(app_services "$kept_images" "$previous")
  app_changes=$(of_services "$changes" "$services" | sort)
  if [[ -n $draft_images ]]; then
    moved=$(moved_since_draft "$kept_images" "$draft_images" "$latest_images" "$services" "$current")
  fi

  if [[ -n $current && $current != "$previous" && -z $moved ]]; then
    echo "$current"
    return
  fi

  if [[ -z $changes ]]; then
    echo "$previous"
    return
  fi

  if [[ -z $services ]]; then
    return
  fi

  if [[ -z $app_changes ]]; then
    echo "$previous"
    return
  fi

  if awk '$4 == "-" { removed = 1 } END { exit !removed }' <<< "$app_changes"; then
    return
  fi

  candidates=$(while read -r _ _ _ _ tag; do version_from "$previous" "$tag"; done <<< "$app_changes" | sort -u)
  if [[ $(wc -l <<< "$candidates") == 1 ]]; then
    echo "$candidates"
  fi
}

ask() {
  local prompt=$1 no_answer=$2
  printf '%s' "$prompt" >&2
  if ! IFS= read -r REPLY; then
    echo >&2
    echo "$no_answer" >&2
    exit 1
  fi
}

release_state() {
  local count status=0
  count=$(jq '.releases | length' "$1/manifest.json")
  if ((count == 0)); then
    echo changed
    return
  fi

  diff -r -q "$1/latest" "$1/releases/$count" > /dev/null 2>&1 || status=$?
  case $status in
    0) ;;
    1) echo changed ;;
    *) echo "releases/$count unreadable" ;;
  esac
}

pick_app() {
  local apps=() changed=() dir id index default="" state
  for dir in */manifest.json; do
    id=${dir%/manifest.json}
    [[ $id == _* ]] || apps+=("$id")
  done

  for index in "${!apps[@]}"; do
    state=$(release_state "${apps[index]}")
    if [[ $state == changed ]]; then
      changed+=("${apps[index]}")
    fi
    printf '%d) %s%s\n' $((index + 1)) "${apps[index]}" "${state:+  $state}" >&2
  done

  if ((${#changed[@]} == 1)); then
    default=${changed[0]}
  fi

  while [[ -z $app ]]; do
    ask "app${default:+ [$default]}: " "no app picked; run it in a terminal or pass one: mise run release <app-id>"
    if [[ -z $REPLY ]]; then
      app=$default
      continue
    fi

    for index in "${!apps[@]}"; do
      if [[ $REPLY == "$((index + 1))" ]]; then
        app=${apps[index]}
      fi
    done
    for index in "${!apps[@]}"; do
      if [[ -z $app && $REPLY == "${apps[index]}" ]]; then
        app=$REPLY
      fi
    done
  done
}

require_release_object() {
  if ! jq -s -e 'length == 1 and (.[0] | type == "object")' "$latest/release.json" > /dev/null; then
    echo "$latest/release.json: want one JSON object" >&2
    exit 1
  fi
}

write_release_answers() {
  local version=$1 can_skip=$2 answered
  if jq -e --arg version "$version" --argjson canSkip "$can_skip" \
    '.appVersion == $version and .canSkip == $canSkip' "$latest/release.json" > /dev/null; then
    return
  fi

  answered=$(jq --arg version "$version" --argjson canSkip "$can_skip" \
    '.appVersion = $version | .canSkip = $canSkip' "$latest/release.json")
  pending=$(mktemp "$latest/.release.json.XXXXXX")
  cp -p "$latest/release.json" "$pending"
  printf '%s\n' "$answered" > "$pending"
  mv "$pending" "$latest/release.json"
}

ask_release() {
  local previous_dir="$app/releases/$kept" previous="" last_can_skip="" changes="" kept_images="" draft_images=""
  local current latest_images guess
  local version=${APP_VERSION:-} can_skip=${CAN_SKIP:-}

  case $can_skip in
    "" | true | false) ;;
    *)
      echo "CAN_SKIP: want true or false, got $can_skip" >&2
      exit 1
      ;;
  esac

  require_release_object
  current=$(jq -r '.appVersion | strings' "$latest/release.json")
  latest_images=$(images "$latest")

  if ((kept > 0)); then
    previous=$(jq -r '.appVersion | strings' "$previous_dir/release.json")
    last_can_skip=$(jq -r --argjson kept "$kept" 'if .releases[$kept - 1].canSkip then "yes" else "no" end' "$manifest")
    kept_images=$(images "$previous_dir")
    changes=$(image_changes "$kept_images" "$latest_images")
  fi

  if ((kept < last)); then
    draft_images=$(images "$app/releases/$next")
  fi

  if [[ -z $version || -z $can_skip ]] && [[ -n $changes ]]; then
    show_changes "$changes"
  fi

  if [[ -z $version ]]; then
    guess=$(guess_version "$previous" "$current" "$changes" "$kept_images" "$draft_images" "$latest_images")
    while [[ -z $version ]]; do
      ask "appVersion${guess:+ [$guess]}: " "$app: no answer; run it in a terminal or set APP_VERSION and CAN_SKIP"
      version=${REPLY:-$guess}
    done
  fi

  while [[ -z $can_skip ]]; do
    ask "canSkip${last_can_skip:+ (last: $last_can_skip)} [y/n]: " "$app: no answer; run it in a terminal or set APP_VERSION and CAN_SKIP"
    case $REPLY in
      y | yes) can_skip=true ;;
      n | no) can_skip=false ;;
    esac
  done

  write_release_answers "$version" "$can_skip"
}

is_unchanged() {
  ((kept > 0)) && diff -r -q "$latest" "$app/releases/$kept" > /dev/null
}

release_nothing() {
  if ((kept < last)); then
    rm -rf "${app:?}/releases/$next"
    mv "$staged/manifest.json" "$manifest"
  fi
  echo "$app: nothing to release"
  exit 0
}

if [[ -z $app ]]; then
  pick_app
fi

manifest="$app/manifest.json"
latest="$app/latest"

[[ -f "$manifest" ]] || {
  echo "$manifest: missing" >&2
  exit 1
}
[[ -d "$latest" ]] || {
  echo "$latest: missing" >&2
  exit 1
}
git rev-parse -q --verify "$base^{commit}" > /dev/null || {
  echo "$base: not found; set BASE_REF to the branch the PR merges into" >&2
  exit 1
}

last=$(jq '.releases | length' "$manifest")
published=$(git show "$base:$manifest" 2> /dev/null | jq '.releases | length') || published=0
kept=$((last > published ? last - 1 : last))
next=$((kept + 1))

staged=$(mktemp -d)
trap 'rm -rf "$staged" ${pending:+"$pending"}' EXIT
jq --argjson kept "$kept" '.releases |= .[:$kept]' "$manifest" > "$staged/manifest.json"

if is_unchanged && [[ -z ${APP_VERSION:-}${CAN_SKIP:-} ]]; then
  release_nothing
fi

if ((kept == last)) && [[ -e "$app/releases/$next" || -L "$app/releases/$next" ]]; then
  if ! leftover=$(find "$app/releases/$next" ! -type d -print -quit 2> /dev/null); then
    echo "$app/releases/$next: can't be read" >&2
    exit 1
  fi

  if [[ -n $leftover ]]; then
    echo "$app/releases/$next: already exists" >&2
    exit 1
  fi
fi

ask_release

if is_unchanged; then
  release_nothing
fi

cp -a "$latest" "$staged/release"
jq --argjson version "$next" --slurpfile release "$latest/release.json" \
  '.releases += [{version: $version, appVersion: $release[0].appVersion, canSkip: $release[0].canSkip}]' \
  "$staged/manifest.json" > "$staged/manifest.next.json"

mkdir -p "$app/releases"
rm -rf "${app:?}/releases/$next"
mv "$staged/release" "$app/releases/$next"
mv "$staged/manifest.next.json" "$manifest"

echo "$app: release $next ($(jq -r .appVersion "$latest/release.json"))"
