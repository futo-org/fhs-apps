#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

unset APP_VERSION CAN_SKIP

set_image() {
  sed -i -E "s|image: docker.io/traefik/whoami:.*|image: docker.io/traefik/whoami:$2|" "$1/whoami/latest/docker-compose.yml"
}

released_store() {
  local store
  store=$(new_store)
  write_release "$store/whoami/latest" "$1" "${3:-false}"
  set_image "$store" "$2"
  release "$store"
  commit "$store" "release 1"
  echo "$store"
}

add_service() {
  sed -i "s|^  whoami:|  $2:\n    image: $3\n  whoami:|" "$1/whoami/latest/docker-compose.yml"
}

answer() {
  local store=$1 answers=$2
  run env BASE_REF=HEAD "$store/scripts/release.sh" whoami <<< "$answers"
}

released() {
  echo "$(jq -c '.releases[1:]' "$1/whoami/manifest.json") $(jq -c . "$1/whoami/latest/release.json")"
}

shown() {
  [[ $output == *"$1"* ]] && echo shown || echo "missing in: $output"
}

store=$(new_store)
run env BASE_REF=HEAD APP_VERSION=v1.10.1 CAN_SKIP=false "$store/scripts/release.sh" whoami
assert_equal "freezes latest/ as release 1" "$status $output" "0 whoami: release 1 (v1.10.1)"
assert_equal "appends the release 1 manifest entry" "$(jq -c .releases "$store/whoami/manifest.json")" \
  '[{"version":1,"appVersion":"v1.10.1","canSkip":false}]'
assert_equal "release 1 is a full copy of latest/" \
  "$(diff -r "$store/whoami/latest" "$store/whoami/releases/1" && echo same)" same
commit "$store" "release 1"

run env BASE_REF=HEAD "$store/scripts/release.sh" whoami < /dev/null
assert_equal "releases nothing, without asking, when latest/ is the newest release" \
  "$status $output $(jq '.releases | length' "$store/whoami/manifest.json")" "0 whoami: nothing to release 1"
assert_equal "makes no release folder when nothing changed" "$([[ -e "$store/whoami/releases/2" ]] || echo absent)" absent

base=$(git -C "$store" rev-parse HEAD)
set_image "$store" v1.11.0
run env BASE_REF="$base" APP_VERSION=v1.11.0 CAN_SKIP=false "$store/scripts/release.sh" whoami < /dev/null
assert_equal "adds the release after the base's newest, without asking when APP_VERSION and CAN_SKIP are set" \
  "$status $output" "0 whoami: release 2 (v1.11.0)"
commit "$store" "release 2"

run env BASE_REF="$base" APP_VERSION=v1.11.1 CAN_SKIP=true "$store/scripts/release.sh" whoami < /dev/null
assert_equal "rebuilds the release this branch added instead of adding another" \
  "$status $(jq -c '.releases[1:]' "$store/whoami/manifest.json") $(jq -r .appVersion "$store/whoami/releases/2/release.json")" \
  '0 [{"version":2,"appVersion":"v1.11.1","canSkip":true}] v1.11.1'

git -C "$store" checkout -q "$base" -- whoami/latest
run env BASE_REF="$base" "$store/scripts/release.sh" whoami < /dev/null
assert_equal "drops the release this branch added when latest/ is back to the base's" \
  "$status $output $(jq '.releases | length' "$store/whoami/manifest.json") $([[ -e "$store/whoami/releases/2" ]] || echo absent)" \
  "0 whoami: nothing to release 1 absent"

run env BASE_REF=nope "$store/scripts/release.sh" whoami
assert_equal "refuses a base that doesn't exist" "$status $output" \
  "1 nope: not found; set BASE_REF to the branch the PR merges into"

store=$(released_store v1.10.1 v1.10.1)
set_image "$store" v1.11.0
answer "$store" $'\ny'
assert_equal "guesses appVersion from the changed image tag" "$status $(shown 'appVersion [v1.11.0]: ')" "0 shown"
assert_equal "shows the image change and the last canSkip" \
  "$(shown 'whoami: docker.io/traefik/whoami v1.10.1 → v1.11.0') $(shown 'canSkip (last: no) [y/n]: ')" "shown shown"
assert_equal "Enter takes the guess, y sets canSkip, in the manifest and latest/release.json" "$(released "$store")" \
  '[{"version":2,"appVersion":"v1.11.0","canSkip":true}] {"appVersion":"v1.11.0","canSkip":true}'
assert_equal "the new release is a full copy of latest/" \
  "$(diff -r "$store/whoami/latest" "$store/whoami/releases/2" && echo same)" same

store=$(released_store v1.10.1 v1.10.1 true)
set_image "$store" v1.11.0
answer "$store" $'v1.11.0-rc1\nn'
assert_equal "a typed appVersion replaces the guess, n clears canSkip" "$status $(released "$store")" \
  '0 [{"version":2,"appVersion":"v1.11.0-rc1","canSkip":false}] {"appVersion":"v1.11.0-rc1","canSkip":false}'

while read -r previous old new want; do
  store=$(released_store "$previous" "$old")
  set_image "$store" "$new"
  answer "$store" $'\ny'
  assert_equal "guesses $want from $old → $new when the last appVersion is $previous" \
    "$status $(jq -r .appVersion "$store/whoami/latest/release.json")" "0 $want"
done << 'EOF'
1.37.4 1.37.4 1.37.5 1.37.5
v12.2 12.2.20261005-225228 12.3.20261101-120000 v12.3
v34.0.4 34.0.4-apache 34.0.5-apache v34.0.5
v3.3.1 3.3.1 3.4.0 v3.4.0
v3.3.1 v3.3.1 v3.4.0@sha256:abc v3.4.0
v1.2.3-rc1 v1.2.3-rc1 v1.2.3-rc2 v1.2.3-rc2
v1.2.3-rc1 v1.2.3-rc1 v1.2.3 v1.2.3
EOF

store=$(new_store)
add_service "$store" db docker.io/library/postgres:17.11-alpine
release "$store"
commit "$store" "release 1"
sed -i 's|postgres:17.11-alpine|postgres:17.12-alpine|' "$store/whoami/latest/docker-compose.yml"
set_image "$store" v1.11.0
answer "$store" $'\nn'
assert_equal "guesses from the app's image when a sidecar listed first also changed" \
  "$status $(jq -r .appVersion "$store/whoami/latest/release.json")" "0 v1.11.0"

store=$(new_store)
add_service "$store" cron docker.io/traefik/whoami:v1.10.1
release "$store"
commit "$store" "release 1"
sed -i 's|whoami:v1.10.1|whoami:v1.11.0|' "$store/whoami/latest/docker-compose.yml"
answer "$store" $'\nn'
assert_equal "shows an image change once when two services share the image" \
  "$(grep -c 'whoami v1.10.1 → v1.11.0' <<< "$output")" 1

store=$(new_store)
add_service "$store" ml docker.io/traefik/whoami-ml:v1.10.1
release "$store"
commit "$store" "release 1"
set_image "$store" v1.11.0
sed -i 's|whoami-ml:v1.10.1|whoami-ml:v1.10.2|' "$store/whoami/latest/docker-compose.yml"
answer "$store" $'\nv1.11.0\nn'
assert_equal "offers no appVersion when the app images disagree" \
  "$status $(shown 'appVersion: ') $(jq -r .appVersion "$store/whoami/latest/release.json")" "0 shown v1.11.0"

store=$(new_store)
write_release "$store/whoami/latest" "whoami 1.10" false
add_service "$store" db docker.io/library/postgres:17.11-alpine
release "$store"
commit "$store" "release 1"
set_image "$store" v1.11.0
answer "$store" $'v1.11.0-rc1\nn'
sed -i 's|postgres:17.11-alpine|postgres:17.12-alpine|' "$store/whoami/latest/docker-compose.yml"
answer "$store" $'\nn'
assert_equal "keeps a typed appVersion matching the app image when only a sidecar moved and the last appVersion matches no image" \
  "$status $(jq -r .appVersion "$store/whoami/releases/2/release.json")" "0 v1.11.0-rc1"

for edits in 's|whoami:v1.10.1|whoami:v1.11.0|;s|postgres:17.11-alpine|postgres:17.12-alpine|' \
  's|postgres:17.11-alpine|postgres:17.12-alpine|;s|whoami:v1.10.1|whoami:v1.11.0|'; do
  store=$(new_store)
  write_release "$store/whoami/latest" "whoami 1.10" false
  add_service "$store" db docker.io/library/postgres:17.11-alpine
  release "$store"
  commit "$store" "release 1"
  sed -i "${edits%%;*}" "$store/whoami/latest/docker-compose.yml"
  answer "$store" $'whoami 1.11 RC1\nn'
  sed -i "${edits#*;}" "$store/whoami/latest/docker-compose.yml"
  answer "$store" $'\nr9\nn'
  assert_equal "offers no appVersion when neither version matches an image and an image moved after this branch's release: $edits" \
    "$status $(shown 'appVersion: ') $(jq -r .appVersion "$store/whoami/releases/2/release.json")" "0 shown r9"
done

store=$(new_store)
write_release "$store/whoami/latest" r7 false
add_service "$store" db docker.io/library/postgres:17.11-alpine
release "$store"
commit "$store" "release 1"
set_image "$store" v1.11.0
answer "$store" $'r8\nn'
set_image "$store" v1.12.0
answer "$store" $'\nr9\nn'
assert_equal "offers no appVersion when the app image moved and neither version matches an image" \
  "$status $(shown 'appVersion: ') $(jq -r .appVersion "$store/whoami/releases/2/release.json")" "0 shown r9"

for moved in 's|postgres:17.12-alpine|postgres:17.13-alpine|' 's|whoami:v1.11.0|whoami:v1.12.0|'; do
  store=$(new_store)
  write_release "$store/whoami/latest" r7 false
  add_service "$store" db docker.io/library/postgres:17.11-alpine
  release "$store"
  commit "$store" "release 1"
  set_image "$store" v1.11.0
  sed -i 's|postgres:17.11-alpine|postgres:17.12-alpine|' "$store/whoami/latest/docker-compose.yml"
  answer "$store" $'r8\nn'
  sed -i "$moved" "$store/whoami/latest/docker-compose.yml"
  answer "$store" $'\nr8\nn'
  assert_equal "offers no appVersion when neither version matches an image, the branch moved several images, then $moved" \
    "$status $(shown 'appVersion: ') $(jq -r .appVersion "$store/whoami/releases/2/release.json")" "0 shown r8"
done

store=$(new_store)
write_release "$store/whoami/latest" r7 false
add_service "$store" db docker.io/library/postgres:17.11-alpine
release "$store"
commit "$store" "release 1"
set_image "$store" v1.11.0
sed -i 's|postgres:17.11-alpine|postgres:17.12-alpine|' "$store/whoami/latest/docker-compose.yml"
answer "$store" $'v1.11.0-rc1\nn'
sed -i 's|postgres:17.12-alpine|postgres:17.13-alpine|' "$store/whoami/latest/docker-compose.yml"
answer "$store" $'\nn'
assert_equal "keeps a typed appVersion matching the app image when the branch moved several images and a sidecar moves" \
  "$status $(jq -r .appVersion "$store/whoami/releases/2/release.json")" "0 v1.11.0-rc1"

store=$(new_store)
write_release "$store/whoami/latest" "whoami 1.10" false
add_service "$store" db docker.io/library/postgres:17.11-alpine
release "$store"
commit "$store" "release 1"
set_image "$store" v1.11.0
answer "$store" $'v1.11.0-rc1\nn'
set_image "$store" v1.12.0
answer "$store" $'\nv1.12.0\nn'
assert_equal "offers no appVersion when the app image moved and the last appVersion matches no image" \
  "$status $(shown 'appVersion: ') $(jq -r .appVersion "$store/whoami/releases/2/release.json")" "0 shown v1.12.0"

store=$(new_store)
add_service "$store" db docker.io/library/postgres:17.11-alpine
release "$store"
commit "$store" "release 1"
set_image "$store" v1.11.0
answer "$store" $'v1.11.0-rc1\nn'
sed -i 's|postgres:17.11-alpine|postgres:17.12-alpine|' "$store/whoami/latest/docker-compose.yml"
answer "$store" $'\nn'
assert_equal "keeps a typed appVersion when only a sidecar moved after this branch's release" \
  "$status $(jq -r .appVersion "$store/whoami/releases/2/release.json")" "0 v1.11.0-rc1"

store=$(released_store v1.10.1 v1.10.1)
sed -i 's|docker.io/traefik/whoami:v1.10.1|ghcr.io/traefik/whoami:v1.11.0|' "$store/whoami/latest/docker-compose.yml"
answer "$store" $'\nn'
assert_equal "follows the app's image when its repository is replaced" \
  "$status $(shown 'whoami: docker.io/traefik/whoami:v1.10.1 → ghcr.io/traefik/whoami:v1.11.0') $(jq -r .appVersion "$store/whoami/latest/release.json")" \
  "0 shown v1.11.0"

store=$(released_store v1.10.1 v1.10.1)
sed -i 's|^services:$|services: # app services|' "$store/whoami/latest/docker-compose.yml"
set_image "$store" v1.11.0
answer "$store" $'\nn'
assert_equal "follows the app's image when the services header has a comment" \
  "$status $(shown 'whoami: docker.io/traefik/whoami v1.10.1 → v1.11.0') $(jq -r .appVersion "$store/whoami/latest/release.json")" \
  "0 shown v1.11.0"

store=$(released_store v1.10.1 v1.10.1)
sed -i 's|^  whoami:$|  web:|' "$store/whoami/latest/docker-compose.yml"
set_image "$store" v1.11.0
answer "$store" $'\nn'
assert_equal "follows the app's image when its service is renamed" \
  "$status $(shown 'whoami: docker.io/traefik/whoami v1.10.1 → v1.11.0') $(jq -r .appVersion "$store/whoami/latest/release.json")" \
  "0 shown v1.11.0"

store=$(new_store)
add_service "$store" cron docker.io/traefik/whoami:v1.10.1
release "$store"
commit "$store" "release 1"
sed -i 's|^  whoami:$|  web:|; s|^  cron:$|  jobs:|; s|whoami:v1.10.1|whoami:v1.11.0|' "$store/whoami/latest/docker-compose.yml"
answer "$store" $'\nv1.11.0\nn'
assert_equal "offers no appVersion when renamed services share one image" \
  "$status $(shown 'whoami: docker.io/traefik/whoami:v1.10.1 removed') $(shown 'appVersion: ') $(jq -r .appVersion "$store/whoami/latest/release.json")" \
  "0 shown shown v1.11.0"

store=$(new_store)
add_service "$store" cron docker.io/traefik/whoami:v1.10.1
release "$store"
commit "$store" "release 1"
sed -i 's|whoami:v1.10.1|whoami:v1.11.0|' "$store/whoami/latest/docker-compose.yml"
answer "$store" $'v1.11.0-rc1\nn'
sed -i 's|^  cron:$|  jobs:|' "$store/whoami/latest/docker-compose.yml"
answer "$store" $'\nn'
assert_equal "keeps a typed appVersion when a service sharing the app image is only renamed" \
  "$status $(jq -r .appVersion "$store/whoami/releases/2/release.json")" "0 v1.11.0-rc1"

store=$(released_store v1.10.1 v1.10.1)
sed -i 's|^  whoami:$|  web:|' "$store/whoami/latest/docker-compose.yml"
set_image "$store" v1.11.0
answer "$store" $'v1.11.0-rc1\nn'
set_image "$store" v1.12.0
answer "$store" $'\nn'
assert_equal "drops a typed appVersion when a renamed app image moves after this branch's release" \
  "$status $(jq -r .appVersion "$store/whoami/releases/2/release.json")" "0 v1.12.0"

store=$(released_store v1.10.1 v1.10.1)
set_image "$store" v1.11.0
echo 'services: [' >> "$store/whoami/latest/docker-compose.yml"
run env BASE_REF=HEAD APP_VERSION=v1.11.0 CAN_SKIP=false "$store/scripts/release.sh" whoami < /dev/null
assert_equal "refuses a compose it cannot read and writes no release" \
  "$status $(shown "$store/whoami/latest/docker-compose.yml") $(jq -c '.releases | length' "$store/whoami/manifest.json") $([[ -e "$store/whoami/releases/2" ]] || echo absent)" \
  "1 shown 1 absent"

store=$(new_store)
add_service "$store" cache docker.io/library/redis:7.4
release "$store"
commit "$store" "release 1"
sed -i 's|docker.io/library/redis:7.4|docker.io/valkey/valkey:8.1|' "$store/whoami/latest/docker-compose.yml"
answer "$store" $'\nn'
assert_equal "keeps the last appVersion when only a sidecar's repository is replaced" \
  "$status $(shown 'appVersion [v1.10.1]: ')" "0 shown"

store=$(new_store)
edit_json "$store/whoami/latest/release.json" 'del(.appVersion)'
run env BASE_REF=HEAD "$store/scripts/release.sh" whoami <<< $'\nv1.0.0\nn'
assert_equal "offers no appVersion when latest/ has none" \
  "$status $(shown 'appVersion: ') $(jq -r .appVersion "$store/whoami/latest/release.json")" "0 shown v1.0.0"

for content in '' '   '; do
  store=$(new_store)
  printf '%s' "$content" > "$store/whoami/latest/release.json"
  run env BASE_REF=HEAD APP_VERSION=v1.10.1 CAN_SKIP=false "$store/scripts/release.sh" whoami < /dev/null
  assert_equal "refuses a release.json of \"$content\" and writes no release" \
    "$status ${output##*$'\n'} $(jq -c .releases "$store/whoami/manifest.json") $([[ -e "$store/whoami/releases" ]] || echo absent)" \
    "1 whoami/latest/release.json: want one JSON object [] absent"
done

if ((EUID == 0)); then
  echo "skip: leaves latest/release.json as it was when the new one can't be written (root ignores a read only folder)"
else
  store=$(released_store v1.10.1 v1.10.1)
  set_image "$store" v1.11.0
  before=$(cat "$store/whoami/latest/release.json")
  chmod a-w "$store/whoami/latest"
  answer "$store" $'\ny'
  chmod u+w "$store/whoami/latest"
  assert_equal "leaves latest/release.json as it was when the new one can't be written" \
    "$((status != 0)) $(cat "$store/whoami/latest/release.json") $(jq '.releases | length' "$store/whoami/manifest.json")" \
    "1 $before 1"
fi

store=$(released_store v1.10.1 v1.10.1)
edit_json "$store/whoami/manifest.json" '.releases[0].canSkip = true'
commit "$store" "relax release 1"
set_image "$store" v1.11.0
answer "$store" $'\ny'
assert_equal "shows the last canSkip from the manifest, which may have been relaxed" "$(shown 'canSkip (last: yes) [y/n]: ')" shown

store=$(released_store v1.10.1 v1.10.1)
run env BASE_REF=HEAD APP_VERSION=v1.10.1 CAN_SKIP=false "$store/scripts/release.sh" whoami < /dev/null
assert_equal "releases nothing when APP_VERSION and CAN_SKIP match an unchanged latest/" "$status $output" "0 whoami: nothing to release"
run env BASE_REF=HEAD APP_VERSION=v1.10.1 CAN_SKIP=true "$store/scripts/release.sh" whoami < /dev/null
assert_equal "applies APP_VERSION and CAN_SKIP to an unchanged latest/ as a new release" \
  "$status $output $(jq -c '.releases[1]' "$store/whoami/manifest.json")" \
  '0 whoami: release 2 (v1.10.1) {"version":2,"appVersion":"v1.10.1","canSkip":true}'

store=$(released_store v1.10.1 v1.10.1)
echo 'exit 0' > "$store/whoami/latest/health-check.sh"
answer "$store" $'\nn'
assert_equal "guesses the last appVersion when no image changed" \
  "$status $(shown 'appVersion [v1.10.1]: ') $(jq -r .appVersion "$store/whoami/latest/release.json")" "0 shown v1.10.1"

store=$(released_store v1.10.1 v1.10.1)
set_image "$store" v1.11.0
edit_json "$store/whoami/latest/release.json" '.appVersion = "v1.11.0-beta"'
answer "$store" $'\nn'
assert_equal "offers the appVersion already set in latest/ over the guess" \
  "$status $(jq -r .appVersion "$store/whoami/latest/release.json")" "0 v1.11.0-beta"

store=$(released_store v1.10.1 v1.10.1)
set_image "$store" v1.11.0
answer "$store" $'\nn'
set_image "$store" v1.12.0
answer "$store" $'\nn'
assert_equal "guesses from the image again when it moved after this branch's release" \
  "$status $(released "$store")" \
  '0 [{"version":2,"appVersion":"v1.12.0","canSkip":false}] {"appVersion":"v1.12.0","canSkip":false}'

store=$(released_store v1.10.1 v1.10.1)
set_image "$store" v1.11.0
answer "$store" $'v1.11.0-beta\nn'
echo 'exit 0' > "$store/whoami/latest/health-check.sh"
answer "$store" $'\nn'
assert_equal "keeps a typed appVersion when rebuilding with the same images" \
  "$status $(jq -r .appVersion "$store/whoami/releases/2/release.json")" "0 v1.11.0-beta"

store=$(released_store r7 v1.10.1)
set_image "$store" v1.11.0
answer "$store" $'\nr8\nn'
assert_equal "asks again, with no guess, when no changed image matches the last appVersion" \
  "$status $(shown 'appVersion: ') $(jq -r .appVersion "$store/whoami/latest/release.json")" "0 shown r8"

store=$(released_store v1.10.1 v1.10.1)
set_image "$store" v1.11.0
edit_json "$store/whoami/latest/release.json" '.healthTimeoutMinutes = 10'
answer "$store" $'\ny'
assert_equal "keeps the other release.json keys" "$status $(jq -c . "$store/whoami/releases/2/release.json")" \
  '0 {"appVersion":"v1.11.0","canSkip":true,"healthTimeoutMinutes":10}'

store=$(released_store v1.10.1 v1.10.1)
set_image "$store" v1.11.0
answer "$store" $'\n\nmaybe\ny'
assert_equal "asks canSkip again until it is y or n" "$status $(jq .canSkip "$store/whoami/latest/release.json")" "0 true"

store=$(released_store v1.10.1 v1.10.1)
set_image "$store" v1.11.0
answer "$store" ''
assert_equal "fails without a canSkip answer and writes no release" \
  "$status ${output##*$'\n'} $(jq '.releases | length' "$store/whoami/manifest.json") $([[ -e "$store/whoami/releases/2" ]] || echo absent)" \
  "1 whoami: no answer; run it in a terminal or set APP_VERSION and CAN_SKIP 1 absent"

run env BASE_REF=HEAD "$store/scripts/release.sh" whoami < /dev/null
assert_equal "fails with no input and no APP_VERSION or CAN_SKIP" \
  "$status ${output##*$'\n'} $(jq '.releases | length' "$store/whoami/manifest.json")" \
  "1 whoami: no answer; run it in a terminal or set APP_VERSION and CAN_SKIP 1"

run env BASE_REF=HEAD APP_VERSION=v1.11.0 CAN_SKIP=yes "$store/scripts/release.sh" whoami < /dev/null
assert_equal "refuses a CAN_SKIP that isn't true or false" "$status $output" "1 CAN_SKIP: want true or false, got yes"

store=$(new_store)
echo '{"appVersion": "v1.10.1",' > "$store/whoami/latest/release.json"
run env BASE_REF=HEAD APP_VERSION=v1.10.1 CAN_SKIP=false "$store/scripts/release.sh" whoami
assert_equal "an invalid release.json leaves no release behind" \
  "$((status != 0)) $(jq -c .releases "$store/whoami/manifest.json") $([[ -e "$store/whoami/releases" ]] || echo absent)" \
  "1 [] absent"
write_release "$store/whoami/latest"
run env BASE_REF=HEAD APP_VERSION=v1.10.1 CAN_SKIP=false "$store/scripts/release.sh" whoami
assert_equal "releases after the invalid release.json is fixed, with no cleanup" "$status $output" "0 whoami: release 1 (v1.10.1)"

store=$(new_store)
release_base=$(git -C "$store" rev-parse HEAD)
set_image "$store" v1.11.0
BASE_REF="$release_base" APP_VERSION=v1.11.0 CAN_SKIP=false "$store/scripts/release.sh" whoami > /dev/null
echo '{"appVersion": "v1.11.1",' > "$store/whoami/latest/release.json"
run env BASE_REF="$release_base" APP_VERSION=v1.11.1 CAN_SKIP=false "$store/scripts/release.sh" whoami
assert_equal "an invalid release.json keeps the release this branch added" \
  "$((status != 0)) $(jq -c .releases "$store/whoami/manifest.json") $(jq -r .appVersion "$store/whoami/releases/1/release.json")" \
  '1 [{"version":1,"appVersion":"v1.11.0","canSkip":false}] v1.11.0'
write_release "$store/whoami/latest" v1.11.1 false
set_image "$store" v1.11.1
run env BASE_REF="$release_base" APP_VERSION=v1.11.1 CAN_SKIP=false "$store/scripts/release.sh" whoami
assert_equal "rebuilds the release this branch added once release.json is fixed" "$status $output" "0 whoami: release 1 (v1.11.1)"

store=$(new_store)
mkdir -p "$store/whoami/releases/1"
touch "$store/whoami/releases/1/release.json"
run env BASE_REF=HEAD "$store/scripts/release.sh" whoami < /dev/null
assert_equal "refuses, without asking, when the next release folder already exists" "$status $output" \
  "1 whoami/releases/1: already exists"

store=$(new_store)
mkdir -p "$store/whoami/releases/1/data/config"
run env BASE_REF=HEAD APP_VERSION=v1.10.1 CAN_SKIP=false "$store/scripts/release.sh" whoami < /dev/null
assert_equal "replaces a next release folder left over with no files in it" \
  "$status $output $(diff -r "$store/whoami/latest" "$store/whoami/releases/1" && echo same)" "0 whoami: release 1 (v1.10.1) same"

two_app_store() {
  local store
  store=$(new_store)
  cp -a "$store/whoami" "$store/alpha"
  edit_json "$store/alpha/manifest.json" '.appId = "alpha"'
  release "$store" alpha
  release "$store"
  commit "$store" "release 1 of both"
  echo "$store"
}

pick() {
  run env BASE_REF=HEAD APP_VERSION=v1.11.0 CAN_SKIP=true "$1/scripts/release.sh" <<< "$2"
}

store=$(two_app_store)
set_image "$store" v1.11.0
pick "$store" ''
assert_equal "lists the apps, without _template, and marks the one with unreleased changes" \
  "$(shown $'1) alpha\n2) whoami  changed\n')" shown
assert_equal "offers the only changed app, and Enter releases it" \
  "$status $(shown 'app [whoami]: ') $(shown 'whoami: release 2 (v1.11.0)')" "0 shown shown"

store=$(two_app_store)
cp -a "$store/alpha" "$store/2"
edit_json "$store/2/manifest.json" '.appId = "2"'
commit "$store" "app 2"
echo 'exit 0' > "$store/2/latest/health-check.sh"
run env BASE_REF=HEAD "$store/scripts/release.sh" <<< '2'
assert_equal "a printed row number picks its row even when an app id is that number" "$status $(shown 'alpha: nothing to release')" "0 shown"
pick "$store" ''
assert_equal "Enter takes the offered app even when its id is another row's number" \
  "$status $(shown 'app [2]: ') $(shown '2: release 2 (v1.11.0)')" "0 shown shown"

store=$(two_app_store)
set_image "$store" v1.11.0
pick "$store" 'whoami'
assert_equal "picks an app by its id" "$status $(shown 'whoami: release 2 (v1.11.0)')" "0 shown"

store=$(two_app_store)
set_image "$store" v1.11.0
echo 'exit 0' > "$store/alpha/latest/health-check.sh"
pick "$store" $'\nnope\n../whoami\n3\n08\n010\n18446744073709551618\n1'
assert_equal "offers no app when several changed, asks again until a printed number or id, and picks by number" \
  "$status $(grep -o 'app: ' <<< "$output" | wc -l) $(shown 'alpha: release 2 (v1.11.0)')" "0 8 shown"

store=$(two_app_store)
rm -rf "$store/alpha/releases/1"
set_image "$store" v1.11.0
pick "$store" ''
assert_equal "a release folder that can't be compared is flagged, not counted as changed" \
  "$status $(shown '1) alpha  releases/1 unreadable') $(shown 'app [whoami]: ')" "0 shown shown"

store=$(two_app_store)
set_image "$store" v1.11.0
run env BASE_REF=HEAD "$store/scripts/release.sh" < /dev/null
assert_equal "fails with no input, asking for the app, and writes no release" \
  "$status ${output##*$'\n'} $(jq '.releases | length' "$store/whoami/manifest.json")" \
  "1 no app picked; run it in a terminal or pass one: mise run release <app-id> 1"

run env BASE_REF=HEAD "$store/scripts/release.sh" whoami alpha
assert_equal "refuses more than one app" "$status $output" "2 usage: $store/scripts/release.sh [app-id]"

finish_tests
