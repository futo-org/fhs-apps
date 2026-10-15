#!/usr/bin/env bash
# Publishes every merge of <app>/latest/ not yet released, oldest first: each
# is frozen into <app>/releases/<n+1>/ and appended to the manifest as
# {version, appVersion, canSkip}. Reads the merges from git history, never the
# working copy, so merges that land faster than the publish workflow runs still
# get a release each. The publish workflow runs this on a clean checkout of
# master after every merge; never run it in a PR.
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
merges=$(git log --first-parent --format=%H -- "$latest")

# Pending: the merges after the newest one whose latest/ is the last release.
# Without one (nothing published yet, or releases seeded by hand) only the
# newest merge is pending: no device can be on anything in between.
pending=${merges%%$'\n'*}
if ((last > 0)); then
  released=$(git rev-parse "HEAD:$app/releases/$last")
  for commit in $merges; do
    if [[ "$(git rev-parse -q --verify "$commit:$latest")" == "$released" ]]; then
      pending=$(git log --first-parent --reverse --format=%H "$commit..HEAD" -- "$latest")
      break
    fi
  done
fi

if [[ -z "$pending" ]]; then
  echo "$app: nothing to publish"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$app/releases"
for commit in $pending; do
  next=$((last + 1))
  if [[ -e "$app/releases/$next" ]]; then
    echo "$app/releases/$next: already exists" >&2
    exit 1
  fi

  rm -rf "${work:?}/$app"
  git archive "$commit" "$latest" | tar -x -C "$work"
  cp -a "$work/$latest" "$app/releases/$next"

  tmp=$(mktemp)
  jq --argjson version "$next" --slurpfile release "$work/$latest/release.json" \
    '.releases += [{version: $version, appVersion: $release[0].appVersion, canSkip: $release[0].canSkip}]' \
    "$manifest" > "$tmp"
  mv "$tmp" "$manifest"

  echo "$app: published release $next ($(jq -r .appVersion "$work/$latest/release.json"))"
  last=$next
done
