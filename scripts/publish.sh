#!/usr/bin/env bash
# Publishes an app's working copy: freezes <app>/latest/ into
# <app>/releases/<n+1>/ and appends {version, appVersion, canSkip} to its
# manifest. Does nothing when latest/ equals the last published release.
# The publish workflow runs this after every merge; never run it in a PR.
#
# usage: publish.sh <app-id>
set -euo pipefail

cd "$(dirname "$0")/.."

if (($# != 1)); then
  echo "usage: $0 <app-id>" >&2
  exit 2
fi

app=$1
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

last=$(jq '.releases | length' "$manifest")
next=$((last + 1))

if ((last > 0)) && diff -r -q "$latest" "$app/releases/$last" > /dev/null; then
  echo "$app: latest/ matches release $last, nothing to publish"
  exit 0
fi

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

echo "$app: published release $next ($(jq -r .appVersion "$latest/release.json"))"
