#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

base=${BASE_REF:-origin/master}
body=${BODY:-}
previous_body=${PREVIOUS_BODY:-}
refused=3

refuse() {
  echo "$1" >&2
  exit "$refused"
}

selection() {
  tr -d '\r' <<< "$1" | awk '
    { line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line) }
    !fence && match($0, /^(   |  | )?(```+|~~~+)/) { fence = substr($0, RSTART, RLENGTH); sub(/^ +/, "", fence); next }
    fence {
      if ($0 ~ /^(   |  | )?(`+|~+)[ \t]*$/ && substr(line, 1, 1) == substr(fence, 1, 1) && length(line) >= length(fence)) fence = ""
      next
    }
    line == "<!-- release -->" { nested = nested || inside; inside = 1; skip = 0; stop = 0; next }
    line == "<!-- /release -->" && inside { inside = 0; blocks++; picked = (skip && stop) ? "both" : skip ? "can skip" : stop ? "required stop" : ""; next }
    inside && tolower(line) ~ /^[*-] \[x\] release, can skip$/ { skip = 1 }
    inside && tolower(line) ~ /^[*-] \[x\] release, required stop$/ { stop = 1 }
    END { print (blocks > 1 || nested) ? "duplicate" : picked }
  '
}

current=$(selection "$body")
previous=$(selection "$previous_body")

if [[ $current == duplicate ]]; then
  refuse "keep one release block in the PR body"
fi

if [[ -z $current || $current == "$previous" ]]; then
  echo "no release box was just ticked"
  exit 0
fi

if [[ $current == both ]]; then
  refuse "tick one release box, not both"
fi

can_skip=false
if [[ $current == "can skip" ]]; then
  can_skip=true
fi

paths=$(mktemp)
errors=$(mktemp)
trap 'rm -f "$paths" "$errors"' EXIT
git diff --no-renames --name-only -z "$(git merge-base "$base" HEAD)" -- '*/latest/**' ':(exclude)_*' > "$paths"
apps=$(while IFS= read -r -d '' path; do echo "${path%%/*}"; done < "$paths" | sort -u | paste -sd' ')
if [[ -z $apps || $apps == *" "* ]]; then
  refuse "release needs one changed app, got: ${apps:-none}"
fi

app=$apps
if ! output=$(printf '\n' | env -u APP_VERSION CAN_SKIP="$can_skip" BASE_REF="$base" scripts/release.sh "$app" 2> "$errors"); then
  if grep -qxF "$app: no answer; run it in a terminal or set APP_VERSION and CAN_SKIP" "$errors"; then
    refuse "$app: no appVersion guess; release it locally: mise run release $app"
  fi

  grep -v '^appVersion\|^canSkip' "$errors" >&2 || true
  echo "$app: release failed; release it locally: mise run release $app" >&2
  exit 1
fi

echo "$output"
