#!/usr/bin/env bash
# Freezes <app>/latest/ into the app's next release, in the author's PR: copies it
# to <app>/releases/<n>/ and appends {version, appVersion, canSkip} to the
# manifest. A release newer than the base branch's was added by this branch and
# is rebuilt, so a PR adds one release however often this runs.
#
# usage: release.sh <app-id>
# env: BASE_REF  the branch the PR merges into (default origin/master)
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

if ((last > published)); then
  rm -rf "${app:?}/releases/$last"
  tmp=$(mktemp)
  jq '.releases |= .[:-1]' "$manifest" > "$tmp"
  mv "$tmp" "$manifest"
  last=$((last - 1))
fi

if ((last > 0)) && diff -r -q "$latest" "$app/releases/$last" > /dev/null; then
  echo "$app: nothing to release"
  exit 0
fi

next=$((last + 1))
if [[ -e "$app/releases/$next" ]]; then
  echo "$app/releases/$next: already exists" >&2
  exit 1
fi

mkdir -p "$app/releases"
cp -a "$latest" "$app/releases/$next"
tmp=$(mktemp)
jq --argjson version "$next" --slurpfile release "$latest/release.json" \
  '.releases += [{version: $version, appVersion: $release[0].appVersion, canSkip: $release[0].canSkip}]' \
  "$manifest" > "$tmp"
mv "$tmp" "$manifest"

echo "$app: release $next ($(jq -r .appVersion "$latest/release.json"))"
