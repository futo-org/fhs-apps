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

if ((kept > 0)) && diff -r -q "$latest" "$app/releases/$kept" > /dev/null; then
  if ((kept < last)); then
    rm -rf "${app:?}/releases/$next"
    mv "$staged/manifest.json" "$manifest"
  fi
  echo "$app: nothing to release"
  exit 0
fi

if ((kept == last)) && [[ -e "$app/releases/$next" ]]; then
  echo "$app/releases/$next: already exists" >&2
  exit 1
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
