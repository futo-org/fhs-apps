#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

unset APP_VERSION CAN_SKIP

body() {
  printf 'Update whoami.\n\n* [%s] Release, can skip\n* [%s] Release, required stop\n' "$1" "$2"
}

set_image() {
  sed -i -E "s|image: docker.io/traefik/whoami:.*|image: docker.io/traefik/whoami:$2|" "$1/whoami/latest/docker-compose.yml"
}

branch_store() {
  local store
  store=$(new_store)
  write_release "$store/whoami/latest" "${1:-v1.10.1}" false
  release "$store"
  commit "$store" "release 1"
  git -C "$store" branch -q base
  set_image "$store" v1.11.0
  commit "$store" "bump whoami"
  echo "$store"
}

ticked() {
  local store=$1 previous=$2 current=$3
  run env BASE_REF=base PREVIOUS_BODY="$previous" BODY="$current" "$store/scripts/release-pr.sh"
}

released() {
  echo "$(jq -c '.releases[-1]' "$1/whoami/manifest.json")$([[ -d "$1/whoami/releases/2" ]] && echo ' folder')"
}

store=$(branch_store)
ticked "$store" "$(body ' ' ' ')" "$(body x ' ')"
assert_equal "releases with the guessed appVersion as skippable when Release, can skip is ticked" \
  "$status ${output##*$'\n'} $(released "$store")" \
  '0 whoami: release 2 (v1.11.0) {"version":2,"appVersion":"v1.11.0","canSkip":true} folder'

store=$(branch_store)
ticked "$store" "$(body ' ' ' ')" "$(body ' ' X)"
assert_equal "releases as a required stop when Release, required stop is ticked" \
  "$status ${output##*$'\n'} $(released "$store")" \
  '0 whoami: release 2 (v1.11.0) {"version":2,"appVersion":"v1.11.0","canSkip":false} folder'

store=$(branch_store)
ticked "$store" "$(body ' ' ' ' | sed 's/$/\r/')" "$(body x ' ' | sed 's/$/\r/')"
assert_equal "reads a ticked box in a body with Windows line ends, as the browser sends it" \
  "$status ${output##*$'\n'}" "0 whoami: release 2 (v1.11.0)"

store=$(branch_store)
ticked "$store" "$(body x ' ')" "$(body x ' ')"
assert_equal "does nothing when the body changed but no release box was just ticked" \
  "$status $output $(released "$store")" \
  '0 no release box was just ticked {"version":1,"appVersion":"v1.10.1","canSkip":false}'

store=$(branch_store)
ticked "$store" "$(body ' ' ' ')" "$(body x x)"
assert_equal "refuses both release boxes ticked" \
  "$status $output $(released "$store")" \
  '1 tick one release box, not both {"version":1,"appVersion":"v1.10.1","canSkip":false}'

store=$(branch_store "whoami r7")
ticked "$store" "$(body ' ' ' ')" "$(body ' ' x)"
assert_equal "refuses, asking to release locally, when there is no appVersion guess" \
  "$status ${output##*$'\n'} $(released "$store")" \
  '1 whoami: no appVersion guess; release it locally: mise run release whoami {"version":1,"appVersion":"whoami r7","canSkip":false}'

store=$(branch_store)
cp -a "$store/whoami" "$store/other"
commit "$store" "add other"
ticked "$store" "$(body ' ' ' ')" "$(body x ' ')"
assert_equal "refuses a PR that changes more than one app" \
  "$status $output $(released "$store")" \
  '1 release needs one changed app, got: other whoami {"version":1,"appVersion":"v1.10.1","canSkip":false}'

store=$(new_store)
release "$store"
commit "$store" "release 1"
git -C "$store" branch -q base
ticked "$store" "$(body ' ' ' ')" "$(body x ' ')"
assert_equal "refuses a PR that changes no app" "$status $output" "1 release needs one changed app, got: none"

finish_tests
