#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if (($# != 1)); then
  echo "usage: $0 <app-id>" >&2
  exit 2
fi

app=$1
manifest="$app/manifest.json"
latest="$app/latest"
base=${BASE_REF:-origin/master}

images() {
  sed -n -E "s/^[[:space:]]*image:[[:space:]]*[\"']?([^\"'@[:space:]]+).*/\1/p" "$1/docker-compose.yml" \
    | sed -E 's/:([^:/]+)$/ \1/'
}

image_changes() {
  awk 'NR == FNR { old[$1] = $2; next } ($1 in old) && old[$1] != $2 && !seen[$0]++ { print $1, old[$1], $2 }' \
    <(images "$1") <(images "$2")
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

guess_version() {
  local previous=$1 current=$2 changes=$3 moved_since_answer=$4 old new

  if [[ $current != "$previous" && -z $moved_since_answer ]]; then
    echo "$current"
    return
  fi

  if [[ -z $changes ]]; then
    echo "$previous"
    return
  fi

  while read -r _ old new; do
    if [[ $(shaped_like "$previous" "$old") == "$previous" ]]; then
      shaped_like "$previous" "$new"
      return
    fi
  done <<< "$changes"
}

ask() {
  printf '%s' "$1" >&2
  if ! IFS= read -r REPLY; then
    echo >&2
    echo "$app: no answer; run it in a terminal or set APP_VERSION and CAN_SKIP" >&2
    exit 1
  fi
}

ask_release() {
  local previous_dir="$app/releases/$kept" previous="" last_can_skip="" changes="" moved_since_answer="" guess answered
  local version=${APP_VERSION:-} can_skip=${CAN_SKIP:-}

  case $can_skip in
    "" | true | false) ;;
    *)
      echo "CAN_SKIP: want true or false, got $can_skip" >&2
      exit 1
      ;;
  esac

  if ((kept > 0)); then
    previous=$(jq -r .appVersion "$previous_dir/release.json")
    last_can_skip=$(jq -r 'if .canSkip then "yes" else "no" end' "$previous_dir/release.json")
    changes=$(image_changes "$previous_dir" "$latest")
  fi

  if ((kept < last)); then
    moved_since_answer=$(image_changes "$app/releases/$next" "$latest")
  fi

  if [[ -z $version || -z $can_skip ]] && [[ -n $changes ]]; then
    awk -v app="$app" '{ print app ": " $1 " " $2 " → " $3 }' <<< "$changes" >&2
  fi

  if [[ -z $version ]]; then
    guess=$(guess_version "$previous" "$(jq -r .appVersion "$latest/release.json")" "$changes" "$moved_since_answer")
    while [[ -z $version ]]; do
      ask "appVersion${guess:+ [$guess]}: "
      version=${REPLY:-$guess}
    done
  fi

  while [[ -z $can_skip ]]; do
    ask "canSkip${last_can_skip:+ (last: $last_can_skip)} [y/n]: "
    case $REPLY in
      y | yes) can_skip=true ;;
      n | no) can_skip=false ;;
    esac
  done

  answered=$(jq --arg version "$version" --argjson canSkip "$can_skip" \
    '.appVersion = $version | .canSkip = $canSkip' "$latest/release.json")
  printf '%s\n' "$answered" > "$latest/release.json"
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
trap 'rm -rf "$staged"' EXIT
jq --argjson kept "$kept" '.releases |= .[:$kept]' "$manifest" > "$staged/manifest.json"

if is_unchanged; then
  release_nothing
fi

if ((kept == last)) && [[ -e "$app/releases/$next" ]]; then
  echo "$app/releases/$next: already exists" >&2
  exit 1
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
