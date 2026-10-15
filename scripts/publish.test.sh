#!/usr/bin/env bash
# Tests for publish.sh.
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

store=$(new_store)
run "$store/scripts/publish.sh" whoami
assert_equal "freezes latest/ as release 1" "$status $output" "0 whoami: published release 1 (v1.10.1)"
assert_equal "appends the release 1 manifest entry" "$(jq -c .releases "$store/whoami/manifest.json")" \
  '[{"version":1,"appVersion":"v1.10.1","canSkip":false}]'
assert_equal "release 1 is a full copy of latest/" \
  "$(diff -r "$store/whoami/latest" "$store/whoami/releases/1" && echo same)" same
commit "$store" publish

run "$store/scripts/publish.sh" whoami
assert_equal "publishes nothing when every merge of latest/ is released" \
  "$status $output $(jq '.releases | length' "$store/whoami/manifest.json")" "0 whoami: nothing to publish 1"
assert_equal "makes no release folder when nothing changed" "$([[ -e "$store/whoami/releases/2" ]] || echo absent)" absent

write_release "$store/whoami/latest" v1.11.0 false
commit "$store" "required stop"
write_release "$store/whoami/latest" v2.0.0 true
commit "$store" "skippable"
run "$store/scripts/publish.sh" whoami
assert_equal "publishes each unreleased merge of latest/ as its own release, oldest first" \
  "$status $(jq -c '.releases[1:]' "$store/whoami/manifest.json")" \
  '0 [{"version":2,"appVersion":"v1.11.0","canSkip":false},{"version":3,"appVersion":"v2.0.0","canSkip":true}]'
assert_equal "freezes each release from its own merge" "$(jq -r .appVersion "$store/whoami/releases/2/release.json")" v1.11.0
assert_equal "leaves latest/ as merged" "$(git -C "$store" status --porcelain -- whoami/latest)" ""
commit "$store" publish

write_release "$store/whoami/latest" v2.1.0 true
commit "$store" bump
write_release "$store/whoami/latest" v2.0.0 true
commit "$store" revert
run "$store/scripts/publish.sh" whoami
assert_equal "skips a merge reverted before it was released" "$status $output" "0 whoami: nothing to publish"

store=$(new_store)
write_release "$store/whoami/latest" v1.11.0 true
commit "$store" bump
run "$store/scripts/publish.sh" whoami
assert_equal "publishes only the newest merge when nothing is released yet" \
  "$status $(jq -c .releases "$store/whoami/manifest.json")" '0 [{"version":1,"appVersion":"v1.11.0","canSkip":true}]'

store=$(new_store)
write_release "$store/whoami/releases/1" v1.0.0 false
edit_json "$store/whoami/manifest.json" '.releases = [{version: 1, appVersion: "v1.0.0", canSkip: false}]'
commit "$store" seed
write_release "$store/whoami/latest" v1.11.0 true
commit "$store" bump
run "$store/scripts/publish.sh" whoami
assert_equal "publishes only the newest merge when no merge matches a release seeded by hand" \
  "$status $(jq -c '.releases[1:]' "$store/whoami/manifest.json")" '0 [{"version":2,"appVersion":"v1.11.0","canSkip":true}]'

store=$(new_store)
mkdir -p "$store/whoami/releases/1"
run "$store/scripts/publish.sh" whoami
assert_equal "refuses when the next release folder already exists" "$status $output" \
  "1 whoami/releases/1: already exists"

finish_tests
