#!/usr/bin/env bash
# Tests for new-app.sh.
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

store=$(new_store)
run "$store/scripts/new-app.sh" jellyfin 8096
assert_equal "copies the template" "$status $(jq -c . "$store/jellyfin/latest/release.json")" \
  '0 {"appVersion":"","canSkip":false}'
assert_equal "sets the app id and port in the manifest" "$(jq -c . "$store/jellyfin/manifest.json")" \
  '{"schemaVersion":1,"appId":"jellyfin","appPort":8096,"releases":[]}'

for app in Jellyfin -jelly jelly_fin ''; do
  run "$store/scripts/new-app.sh" "$app" 8096
  assert_equal "rejects the app id \"$app\"" "$status $output" \
    "1 app id must be lowercase letters, digits and dashes"
done

for port in 0 65536 80.5; do
  run "$store/scripts/new-app.sh" plex "$port"
  assert_equal "rejects the port $port" "$status $output" "1 app port must be 1-65535"
done

run "$store/scripts/new-app.sh" jellyfin 8096
assert_equal "refuses to overwrite an existing app" "$status $output" "1 jellyfin: already exists"

finish_tests
