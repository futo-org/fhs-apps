#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

base=${BASE_REF:-origin/master}
body=${BODY:-}
previous_body=${PREVIOUS_BODY:-}

is_ticked() {
  grep -qiE "^[*-] \[x\] $1[[:space:]]*$" <<< "$2"
}

is_just_ticked() {
  is_ticked "$1" "$body" && ! is_ticked "$1" "$previous_body"
}

if ! is_just_ticked "Release, can skip" && ! is_just_ticked "Release, required stop"; then
  echo "no release box was just ticked"
  exit 0
fi

if is_ticked "Release, can skip" "$body" && is_ticked "Release, required stop" "$body"; then
  echo "tick one release box, not both" >&2
  exit 1
fi

can_skip=false
if is_ticked "Release, can skip" "$body"; then
  can_skip=true
fi

apps=$(git diff --name-only "$(git merge-base "$base" HEAD)" -- '*/latest/**' ':(exclude)_*' | cut -d/ -f1 | sort -u | paste -sd' ')
if [[ -z $apps || $apps == *" "* ]]; then
  echo "release needs one changed app, got: ${apps:-none}" >&2
  exit 1
fi

app=$apps
errors=$(mktemp)
trap 'rm -f "$errors"' EXIT
if ! output=$(printf '\n' | env -u APP_VERSION CAN_SKIP="$can_skip" BASE_REF="$base" scripts/release.sh "$app" 2> "$errors"); then
  if grep -q 'no answer' "$errors"; then
    echo "$app: no appVersion guess; release it locally: mise run release $app" >&2
    exit 1
  fi

  grep -v '^appVersion\|^canSkip' "$errors" >&2 || true
  echo "$app: release failed; release it locally: mise run release $app" >&2
  exit 1
fi

echo "$output"
