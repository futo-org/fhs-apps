#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

unset APP_VERSION CAN_SKIP

block() {
  printf '<!-- release -->\n* [%s] Release, can skip\n* [%s] Release, required stop\n<!-- /release -->\n' "$1" "$2"
}

body() {
  printf 'Update whoami.\n\n%s\n' "$(block "$1" "$2")"
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
  '3 tick one release box, not both {"version":1,"appVersion":"v1.10.1","canSkip":false}'

store=$(branch_store "whoami r7")
ticked "$store" "$(body ' ' ' ')" "$(body ' ' x)"
assert_equal "refuses, asking to release locally, when there is no appVersion guess" \
  "$status ${output##*$'\n'} $(released "$store")" \
  '3 whoami: no appVersion guess; release it locally: mise run release whoami {"version":1,"appVersion":"whoami r7","canSkip":false}'

store=$(branch_store)
ticked "$store" "$(body x x)" "$(body x ' ')"
assert_equal "releases when both boxes are corrected to one" \
  "$status ${output##*$'\n'} $(released "$store")" \
  '0 whoami: release 2 (v1.11.0) {"version":2,"appVersion":"v1.11.0","canSkip":true} folder'

store=$(branch_store)
changelog=$(printf '%s\n\n* [x] Release, can skip\n\n~~~\n<!-- release -->\n* [x] Release, required stop\n<!-- /release -->\n~~~\n' "$(body ' ' ' ')")
ticked "$store" "$(body ' ' ' ')" "$changelog"
assert_equal "ignores release lines outside the release block and inside code fences" \
  "$status $output $(released "$store")" \
  '0 no release box was just ticked {"version":1,"appVersion":"v1.10.1","canSkip":false}'

store=$(branch_store)
ticked "$store" "$(body ' ' ' ')" "$(printf '%s\n%s\n' "$(body x ' ')" "$(block x ' ')")"
assert_equal "refuses a body with two release blocks" \
  "$status $output $(released "$store")" \
  '3 keep one release block in the PR body {"version":1,"appVersion":"v1.10.1","canSkip":false}'

store=$(branch_store)
fenced=$(printf '%s\n\n~~~~\n~~~\n<!-- release -->\n* [x] Release, required stop\n<!-- /release -->\n~~~~\n' "$(body ' ' ' ')")
ticked "$store" "$(body ' ' ' ')" "$fenced"
assert_equal "ignores a release block inside a longer fence that holds a shorter one" \
  "$status $output $(released "$store")" \
  '0 no release box was just ticked {"version":1,"appVersion":"v1.10.1","canSkip":false}'

store=$(branch_store)
ticked "$store" "$(body ' ' ' ')" "$(printf '<!-- release -->\n%s\n' "$(body x ' ')")"
assert_equal "refuses a release block nested in another" \
  "$status $output $(released "$store")" \
  '3 keep one release block in the PR body {"version":1,"appVersion":"v1.10.1","canSkip":false}'

store=$(branch_store)
indented=$(printf '%s\n\n   ~~~\n<!-- release -->\n* [x] Release, required stop\n<!-- /release -->\n   ~~~\n' "$(body ' ' ' ')")
ticked "$store" "$(body ' ' ' ')" "$indented"
assert_equal "ignores a release block inside a fence indented by three spaces" \
  "$status $output $(released "$store")" \
  '0 no release box was just ticked {"version":1,"appVersion":"v1.10.1","canSkip":false}'

store=$(branch_store)
printf '#!/usr/bin/env bash\necho "registry: no answer from docker.io" >&2\nexit 1\n' > "$store/scripts/release.sh"
ticked "$store" "$(body ' ' ' ')" "$(body x ' ')"
assert_equal "fails, not refuses, when a release error only mentions no answer" \
  "$status ${output##*$'\n'}" \
  '1 whoami: release failed; release it locally: mise run release whoami'

store=$(branch_store)
touch "$store/whoami/latest/data/config/café.txt"
commit "$store" "add a seed file"
ticked "$store" "$(body ' ' ' ')" "$(body x ' ')"
assert_equal "releases one app whose seed file name is not ASCII" \
  "$status ${output##*$'\n'}" "0 whoami: release 2 (v1.11.0)"

store=$(new_store)
cp -a "$store/whoami" "$store/other"
echo seed > "$store/whoami/latest/data/config/seed.txt"
release "$store"
release "$store" other
commit "$store" "release 1"
git -C "$store" branch -q base
git -C "$store" mv whoami/latest/data/config/seed.txt other/latest/data/config/seed.txt
commit "$store" "move seed"
ticked "$store" "$(body ' ' ' ')" "$(body x ' ')"
assert_equal "refuses a seed file moved between two apps" "$status $output" "3 release needs one changed app, got: other whoami"

store=$(branch_store)
cp -a "$store/whoami" "$store/other"
commit "$store" "add other"
ticked "$store" "$(body ' ' ' ')" "$(body x ' ')"
assert_equal "refuses a PR that changes more than one app" \
  "$status $output $(released "$store")" \
  '3 release needs one changed app, got: other whoami {"version":1,"appVersion":"v1.10.1","canSkip":false}'

store=$(new_store)
release "$store"
commit "$store" "release 1"
git -C "$store" branch -q base
ticked "$store" "$(body ' ' ' ')" "$(body x ' ')"
assert_equal "refuses a PR that changes no app" "$status $output" "3 release needs one changed app, got: none"

finish_tests
