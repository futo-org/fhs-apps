#!/usr/bin/env bash
# Starts a new app from _template/: copies it to <app-id>/ and sets appId and
# appPort in its manifest. Fill in latest/ and add a catalog.json entry next.
#
# usage: new-app.sh <app-id> <app-port>
set -euo pipefail

cd "$(dirname "$0")/.."

if (($# != 2)); then
  echo "usage: $0 <app-id> <app-port>" >&2
  exit 2
fi

app=$1
port=$2

[[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
  echo "app id must be lowercase letters, digits and dashes" >&2
  exit 1
}
if ! [[ "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
  echo "app port must be 1-65535" >&2
  exit 1
fi
[[ ! -e "$app" ]] || {
  echo "$app: already exists" >&2
  exit 1
}

cp -a _template "$app"

tmp=$(mktemp)
jq --arg app "$app" --argjson port "$port" '.appId = $app | .appPort = $port' "$app/manifest.json" > "$tmp"
mv "$tmp" "$app/manifest.json"

echo "$app: created from _template/; fill in $app/latest/, add a catalog.json entry, then run \`mise run release $app\`"
