#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

store=$(new_store)
run env BASE_REF=HEAD "$store/scripts/release.sh" whoami
assert_equal "freezes latest/ as release 1" "$status $output" "0 whoami: release 1 (v1.10.1)"
assert_equal "appends the release 1 manifest entry" "$(jq -c .releases "$store/whoami/manifest.json")" \
  '[{"version":1,"appVersion":"v1.10.1","canSkip":false}]'
assert_equal "release 1 is a full copy of latest/" \
  "$(diff -r "$store/whoami/latest" "$store/whoami/releases/1" && echo same)" same
commit "$store" "release 1"

run env BASE_REF=HEAD "$store/scripts/release.sh" whoami
assert_equal "releases nothing when latest/ is the newest release" \
  "$status $output $(jq '.releases | length' "$store/whoami/manifest.json")" "0 whoami: nothing to release 1"
assert_equal "makes no release folder when nothing changed" "$([[ -e "$store/whoami/releases/2" ]] || echo absent)" absent

base=$(git -C "$store" rev-parse HEAD)
write_release "$store/whoami/latest" v1.11.0 false
run env BASE_REF="$base" "$store/scripts/release.sh" whoami
assert_equal "adds the release after the base's newest" "$status $output" "0 whoami: release 2 (v1.11.0)"
commit "$store" "release 2"

write_release "$store/whoami/latest" v1.11.1 true
run env BASE_REF="$base" "$store/scripts/release.sh" whoami
assert_equal "rebuilds the release this branch added instead of adding another" \
  "$status $(jq -c '.releases[1:]' "$store/whoami/manifest.json") $(jq -r .appVersion "$store/whoami/releases/2/release.json")" \
  '0 [{"version":2,"appVersion":"v1.11.1","canSkip":true}] v1.11.1'

git -C "$store" checkout -q "$base" -- whoami/latest
run env BASE_REF="$base" "$store/scripts/release.sh" whoami
assert_equal "drops the release this branch added when latest/ is back to the base's" \
  "$status $output $(jq '.releases | length' "$store/whoami/manifest.json") $([[ -e "$store/whoami/releases/2" ]] || echo absent)" \
  "0 whoami: nothing to release 1 absent"

run env BASE_REF=nope "$store/scripts/release.sh" whoami
assert_equal "refuses a base that doesn't exist" "$status $output" \
  "1 nope: not found; set BASE_REF to the branch the PR merges into"

store=$(new_store)
echo '{"appVersion": "v1.10.1",' > "$store/whoami/latest/release.json"
run env BASE_REF=HEAD "$store/scripts/release.sh" whoami
assert_equal "an invalid release.json leaves no release behind" \
  "$((status != 0)) $(jq -c .releases "$store/whoami/manifest.json") $([[ -e "$store/whoami/releases" ]] || echo absent)" \
  "1 [] absent"
write_release "$store/whoami/latest"
run env BASE_REF=HEAD "$store/scripts/release.sh" whoami
assert_equal "releases after the invalid release.json is fixed, with no cleanup" "$status $output" "0 whoami: release 1 (v1.10.1)"

store=$(new_store)
release_base=$(git -C "$store" rev-parse HEAD)
write_release "$store/whoami/latest" v1.11.0 false
BASE_REF="$release_base" "$store/scripts/release.sh" whoami > /dev/null
echo '{"appVersion": "v1.11.1",' > "$store/whoami/latest/release.json"
run env BASE_REF="$release_base" "$store/scripts/release.sh" whoami
assert_equal "an invalid release.json keeps the release this branch added" \
  "$((status != 0)) $(jq -c .releases "$store/whoami/manifest.json") $(jq -r .appVersion "$store/whoami/releases/1/release.json")" \
  '1 [{"version":1,"appVersion":"v1.11.0","canSkip":false}] v1.11.0'
write_release "$store/whoami/latest" v1.11.1 false
run env BASE_REF="$release_base" "$store/scripts/release.sh" whoami
assert_equal "rebuilds the release this branch added once release.json is fixed" "$status $output" "0 whoami: release 1 (v1.11.1)"

store=$(new_store)
mkdir -p "$store/whoami/releases/1"
run env BASE_REF=HEAD "$store/scripts/release.sh" whoami
assert_equal "refuses when the next release folder already exists" "$status $output" \
  "1 whoami/releases/1: already exists"

finish_tests
