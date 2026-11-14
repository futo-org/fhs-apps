#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

release() {
  BASE_REF=HEAD "$1/scripts/release.sh" whoami > /dev/null
}

released_store() {
  local store
  store=$(new_store)
  release "$store"
  echo "$store"
}

committed_store() {
  local store
  store=$(released_store)
  commit "$store" "release 1"
  echo "$store"
}

problems() {
  { SKIP_RENDER=1 BASE_REF="${2:-}" "$1/scripts/validate-store.sh" > /dev/null; } 2>&1 || true
}

store=$(released_store)
run "$store/scripts/validate-store.sh"
assert_equal "passes a valid store, renders included" "$status" 0

store=$(released_store)
edit_json "$store/catalog.json" '.apps += [{"id": "ghost", "name": "Ghost"}]'
assert_problem "rejects a catalog app without a manifest" "$(problems "$store")" \
  catalog.json "lists ghost but ghost/manifest.json is missing"

store=$(released_store)
edit_json "$store/catalog.json" '.iconBaseUrl = "https://raw.githubusercontent.com/futo-org/fhs-apps/master/"'
assert_problem "rejects iconBaseUrl, icons are absolute" "$(problems "$store")" catalog.json 'unknown key "iconBaseUrl"'

store=$(released_store)
edit_json "$store/catalog.json" '.apps[0].screenshots = []'
assert_problem "rejects an unknown catalog app key" "$(problems "$store")" catalog.json 'whoami: unknown key "screenshots"'

for icon in http://example.com/icon.png icons/whoami.png //example.com/icon.png 'https://example.com/my icon.png'; do
  store=$(released_store)
  edit_json "$store/catalog.json" ".apps[0].icon = \"$icon\""
  assert_problem "rejects the icon $icon, not an absolute https URL" "$(problems "$store")" catalog.json \
    "whoami: icon must be an absolute https URL"
done

store=$(released_store)
edit_json "$store/catalog.json" '.apps[0] += {icon: "https://example.com/whoami.png", tagline: "t", description: "d", developer: "d", website: "https://example.com", sourceRepo: "https://example.com/src"}'
assert_equal "accepts every catalog app field" "$(problems "$store")" ""

store=$(released_store)
edit_json "$store/whoami/manifest.json" '.healthCheckUrl = "/"'
assert_problem "rejects an unknown manifest key" "$(problems "$store")" whoami/manifest.json healthCheckUrl

store=$(released_store)
edit_json "$store/whoami/manifest.json" '.appId = "whoareyou"'
assert_problem "rejects an appId that differs from the folder" "$(problems "$store")" \
  whoami/manifest.json 'appId must be "whoami"'

store=$(released_store)
edit_json "$store/whoami/manifest.json" '.releases[0].version = 2'
assert_problem "rejects release numbers that are not consecutive from 1" "$(problems "$store")" \
  whoami/manifest.json "release 1 must have version 1"

store=$(released_store)
rm -rf "$store/whoami/releases/1"
assert_problem "rejects a manifest entry without its release folder" "$(problems "$store")" \
  whoami/releases/1 missing

for folder in 7 01; do
  store=$(released_store)
  mkdir -p "$store/whoami/releases/$folder"
  echo '{}' > "$store/whoami/releases/$folder/release.json"
  assert_problem "rejects the release folder $folder without a manifest entry" "$(problems "$store")" \
    "whoami/releases/$folder" "no manifest entry"
done

for port in 0 65536 2283.0; do
  store=$(released_store)
  edit_json "$store/whoami/manifest.json" ".appPort = $port"
  assert_problem "rejects appPort $port" "$(problems "$store")" whoami/manifest.json "appPort must be an integer 1-65535"
done

store=$(released_store)
mv "$store/catalog.json" "$store/catalog.real.json"
ln -s catalog.real.json "$store/catalog.json"
assert_problem "rejects a linked catalog.json" "$(problems "$store")" catalog.json "only files and folders are allowed"

store=$(released_store)
ln -s /etc "$store/whoami/latest/data/config/host-etc"
assert_problem "rejects a link in a release folder" "$(problems "$store")" \
  whoami/latest/data/config/host-etc "only files and folders are allowed"

store=$(released_store)
echo 'docker compose up -d' > "$store/whoami/latest/start.sh"
assert_problem "rejects a file that is not part of a release" "$(problems "$store")" \
  whoami/latest/start.sh "not allowed in a release folder"

store=$(released_store)
rm "$store/whoami/latest/health-check.sh"
assert_problem "rejects a release without its health check" "$(problems "$store")" \
  whoami/latest/health-check.sh missing

store=$(released_store)
echo 'docker compose ps --status running | grep -q whoami' > "$store/whoami/latest/health-check.sh"
assert_problem "rejects a health check that uses docker" "$(problems "$store")" \
  whoami/latest/health-check.sh "can't use docker"

store=$(released_store)
printf '# unlike docker compose ps, this sees the app serve\ncurl -fsS http://127.0.0.1:8080/\n' > "$store/whoami/latest/health-check.sh"
release "$store"
assert_equal "accepts docker in a health check comment" "$(problems "$store")" ""

store=$(released_store)
edit_json "$store/whoami/latest/release.json" '.notes = "new"'
assert_problem "rejects an unknown release.json key" "$(problems "$store")" whoami/latest/release.json notes

for minutes in 361 0 -5 1.5 30.0 '"30"' null; do
  store=$(released_store)
  edit_json "$store/whoami/latest/release.json" ".healthTimeoutMinutes = $minutes"
  assert_problem "rejects healthTimeoutMinutes $minutes" "$(problems "$store")" whoami/latest/release.json \
    "healthTimeoutMinutes must be a whole number of minutes, 1 to 360"
done

store=$(released_store)
edit_json "$store/whoami/latest/release.json" '.healthTimeoutMinutes = 360'
release "$store"
assert_equal "accepts healthTimeoutMinutes 360" "$(problems "$store")" ""

settings_problems() {
  local store
  store=$(released_store)
  edit_json "$store/whoami/latest/settings.json" "$1"
  problems "$store"
}

settings=whoami/latest/settings.json
assert_problem "rejects a reserved key prefix" "$(settings_problems '.fields[1].key = "APP_MODE"')" \
  "$settings" "APP_, FHS_ and COMPOSE_ prefixes are reserved"
assert_problem "rejects a key that is not UPPER_SNAKE" "$(settings_problems '.fields[1].key = "mode"')" \
  "$settings" "key must be UPPER_SNAKE"
assert_problem "rejects an enum default that is not an option" "$(settings_problems '.fields[1].default = "turbo"')" \
  "$settings" "default must be one of the option values"
assert_problem "rejects an enum compose case that is not an option" "$(settings_problems '.fields[1].compose.turbo = {}')" \
  "$settings" 'compose case "turbo" is not an option value'
assert_problem "rejects a bool compose case other than true or false" "$(settings_problems '.fields[2].compose.on = {}')" \
  "$settings" 'compose cases must be "true" or "false"'
# shellcheck disable=SC2016 # ${EXPORT_DIR} is compose syntax, not bash
assert_problem "rejects a path bind in short syntax" \
  "$(settings_problems '.fields[0].compose.services.whoami.volumes = ["${EXPORT_DIR}:/config"]')" \
  "$settings" "path binds must use long syntax"
assert_problem "rejects a duplicate key" "$(settings_problems '.fields += [.fields[1]]')" \
  "$settings" "duplicate key MODE"
assert_problem "rejects a generated setting, a secret is \${APP_SEED} or \${APP_PASSWORD}" \
  "$(settings_problems '.fields += [{key: "TOKEN", type: "generated"}]')" \
  "$settings" "field TOKEN: type must be path, enum or bool"

found=$(settings_problems '.fields[1].default = "turbo" | .fields[2].default = "yes"')
assert_problem "reports each broken field: the enum" "$found" "$settings" "field MODE: default must be one of the option values"
assert_problem "reports each broken field: the bool" "$found" "$settings" "field VERBOSE: default must be a boolean"

not_released="not released: run \`mise run release whoami\`"

store=$(new_store)
assert_problem "rejects an app with no release" "$(problems "$store")" whoami/latest "$not_released"

store=$(released_store)
echo 'exit 0' > "$store/whoami/latest/health-check.sh"
assert_problem "rejects latest/ that differs from the newest release" "$(problems "$store")" \
  whoami/latest "$not_released"

compose=whoami/latest/docker-compose.yml
gpu_fragment=whoami/latest/settings.json

assert_rendered_problem() {
  local case=$1 says=$2 edit=$3 store
  store=$(released_store)
  (cd "$store" && eval "$edit")
  assert_problem "$case" "$({ "$store/scripts/validate-store.sh" > /dev/null; } 2>&1 || true)" whoami/latest "$says"
}

# shellcheck disable=SC2016 # edits run in the store, compose syntax kept literal
{
  assert_rendered_problem "rejects a service without a restart policy, in every render" "whoami: needs restart: always or unless-stopped" \
    "sed -i '/restart: unless-stopped/d' $compose"
  assert_rendered_problem "rejects a named volume" "whoami: /cache is a docker volume, bind a folder under \${APP_DATA_DIR}" \
    "sed -i 's#- .*/config:/config#&\n      - cache:/cache#' $compose && printf 'volumes:\n  cache: {}\n' >> $compose"
  assert_rendered_problem "rejects an anonymous volume" "whoami: /cache is a docker volume, bind a folder under \${APP_DATA_DIR}" \
    "sed -i 's#- .*/config:/config#&\n      - /cache#' $compose"
  assert_rendered_problem "rejects an image without a tag" "whoami: image docker.io/traefik/whoami must be pinned to a tag" \
    "sed -i 's#whoami:v1.10.1#whoami#' $compose"
  assert_rendered_problem "rejects a floating image tag, quoted too" "whoami: image docker.io/traefik/whoami:latest has a floating tag" \
    "sed -i 's#image: .*#image: \"docker.io/traefik/whoami:latest\"#' $compose"
  assert_rendered_problem "rejects a floating image tag in a fragment, naming the settings" "whoami: image docker.io/traefik/whoami:release has a floating tag (with {\"MODE\":\"gpu\"" \
    "edit_json $gpu_fragment '.fields[1].compose.gpu.services.whoami.image = \"docker.io/traefik/whoami:release\"'"
  assert_rendered_problem "rejects SELinux relabel options" "whoami: SELinux relabel options are not allowed" \
    "sed -i 's#:/config\$#:/config:Z#' $compose"
  assert_rendered_problem "rejects SELinux relabel options in a fragment" "whoami: SELinux relabel options are not allowed" \
    "edit_json $gpu_fragment '.fields[1].compose.gpu.services.whoami.volumes = [\"/srv:/srv:z\"]'"
  assert_rendered_problem "rejects container_name" "whoami: container_name is not allowed" \
    "sed -i 's#^  whoami:\$#&\n    container_name: whoami#' $compose"
  assert_rendered_problem "rejects container_name in a fragment" "whoami: container_name is not allowed" \
    "edit_json $gpu_fragment '.fields[1].compose.gpu.services.whoami.container_name = \"whoami\"'"
  assert_rendered_problem "rejects a relative bind in the stock compose" "whoami: binds a relative path (./config)" \
    "sed -i 's#- .*/config:/config#- ./config:/config#' $compose"
  assert_rendered_problem "rejects a relative bind in a fragment" "whoami: binds a relative path (../shared)" \
    "edit_json $gpu_fragment '.fields[1].compose.gpu.services.whoami.volumes = [\"../shared:/shared\"]'"
  assert_rendered_problem "rejects a relative bind that leaves the store" "whoami: binds a relative path (../../../../../escape)" \
    "sed -i 's#- .*/config:/config#- ../../../../../escape:/config#' $compose"
  assert_rendered_problem "rejects a bind in the home folder" "whoami: binds a relative path (~/config)" \
    "sed -i 's#- .*/config:/config#- ~/config:/config#' $compose"
  assert_rendered_problem "rejects switching off a service another one may start without, in every render" "the rendered compose doesn't load" \
    "printf '    depends_on:\n      sidecar: {condition: service_started, required: false}\n  sidecar:\n    image: docker.io/traefik/whoami:v1.10.1\n    restart: unless-stopped\n' >> $compose && edit_json $gpu_fragment '.fields += [{key: \"SIDECAR\", type: \"bool\", label: \"Sidecar\", default: true, compose: {\"false\": {services: {sidecar: {profiles: [\"off\"]}}}}}]'"
}

store=$(released_store)
sed -i 's#^    restart: unless-stopped$#&\n    env_file: whoami.env#' "$store/$compose"
assert_problem "rejects env_file" "$(problems "$store")" "$compose" "env_file is not allowed"

store=$(released_store)
edit_json "$store/$gpu_fragment" '.fields[1].compose.gpu.services.whoami.env_file = "whoami.env"'
assert_problem "rejects env_file in a fragment" "$(problems "$store")" "$gpu_fragment" "env_file is not allowed"

# shellcheck disable=SC2016 # ${...} here is compose syntax, kept literal on purpose
{
  store=$(released_store)
  sed -i 's|VERBOSE: ${VERBOSE}|VERBOSE: ${VERBOSE:-true}|' "$store/$compose"
  assert_problem "rejects an unresolved upstream variable" "$(problems "$store")" "$compose" "unresolved upstream variable"

  store=$(released_store)
  edit_json "$store/$gpu_fragment" '.fields[1].compose.gpu.services.whoami.environment = {GPU: "${GPU_NAME:-any}"}'
  assert_problem "rejects an unresolved upstream variable in a fragment" "$(problems "$store")" "$gpu_fragment" "unresolved upstream variable"
}

# shellcheck disable=SC2016 # ${...} here is compose syntax, kept literal on purpose
{
  store=$(released_store)
  edit_json "$store/whoami/latest/settings.json" '.fields[0].compose.services.whoami.volumes[0].source = "${EXPORT_DIRR}"'
  assert_problem "rejects a fragment variable that is no setting key or platform variable" "$(problems "$store")" \
    whoami/latest/settings.json '${EXPORT_DIRR} is not a setting key or platform variable'

  store=$(released_store)
  sed -i 's|VERBOSE: ${VERBOSE}|VERBOSE: ${VERBOSE}\n      WHO: ${USER}|' "$store/whoami/latest/docker-compose.yml"
  assert_problem "rejects a compose variable that is no setting key or platform variable" "$(problems "$store")" \
    whoami/latest/docker-compose.yml '${USER} is not a setting key or platform variable'

  store=$(released_store)
  sed -i 's|VERBOSE: ${VERBOSE}|VERBOSE: ${VERBOSE}\n      LITERAL: $${HOME}|' "$store/whoami/latest/docker-compose.yml"
  release "$store"
  assert_equal "accepts an escaped dollar" "$(problems "$store")" ""

  store=$(released_store)
  sed -i 's|VERBOSE: ${VERBOSE}|VERBOSE: ${VERBOSE}\n      TZ: ${APP_TZ}|' "$store/whoami/latest/docker-compose.yml"
  release "$store"
  run "$store/scripts/validate-store.sh"
  assert_equal "accepts the platform variable \${APP_TZ}, renders included" "$status" 0
}

store=$(committed_store)
edit_json "$store/whoami/manifest.json" '.releases[0].canSkip = true'
assert_equal "accepts flipping canSkip from false to true" "$(problems "$store" HEAD)" ""

store=$(committed_store)
edit_json "$store/whoami/manifest.json" '.releases[0].canSkip = true'
commit "$store" skip
edit_json "$store/whoami/manifest.json" '.releases[0].canSkip = false'
assert_problem "rejects flipping canSkip from true to false" "$(problems "$store" HEAD)" \
  whoami/manifest.json "canSkip may only change from false to true"

store=$(committed_store)
echo 'exit 0' > "$store/whoami/releases/1/health-check.sh"
assert_problem "rejects editing a published release folder" "$(problems "$store" HEAD)" \
  whoami/releases/1 "published release folders never change"

store=$(committed_store)
edit_json "$store/whoami/manifest.json" '.releases |= .[:-1]'
rm -rf "$store/whoami/releases/1"
assert_problem "rejects removing a published release" "$(problems "$store" HEAD)" \
  whoami/manifest.json "published release 1 was removed"

store=$(committed_store)
rm -rf "$store/whoami"
edit_json "$store/catalog.json" '.apps = []'
assert_problem "rejects removing a published app" "$(problems "$store" HEAD)" \
  whoami/manifest.json "a published app can't be removed"

store=$(committed_store)
edit_json "$store/whoami/latest/release.json" '.appVersion = "v1.11.0"'
release "$store"
assert_equal "accepts a PR that changes latest/ and adds its release" "$(problems "$store" HEAD)" ""

store=$(committed_store)
base=$(git -C "$store" rev-parse HEAD)
edit_json "$store/whoami/latest/release.json" '.appVersion = "v1.11.0"'
release "$store"
commit "$store" "release 2"
edit_json "$store/whoami/latest/release.json" '.appVersion = "v1.12.0"'
release "$store"
assert_problem "rejects a PR that adds more than one release" "$(problems "$store" "$base")" \
  whoami/manifest.json "a PR adds one release at most, this one adds 2"

for change in 'del(.fields[0])' '.fields[0].key = "EXPORT_FOLDER"' '.fields[0] = (.fields[2] | .key = "EXPORT_DIR")'; do
  store=$(committed_store)
  edit_json "$store/whoami/latest/settings.json" "$change"
  release "$store"
  assert_problem "rejects a release whose $change drops, renames or retypes a path setting of the release before it" \
    "$(problems "$store" HEAD)" whoami/releases/2/settings.json "path setting EXPORT_DIR of release 1 is gone or no longer a path"
done

store=$(committed_store)
cp -a "$store/whoami" "$store/second"
rm -rf "$store/second/releases"
edit_json "$store/second/manifest.json" '.appId = "second" | .releases = []'
edit_json "$store/catalog.json" '.apps += [{id: "second", name: "Second"}]'
BASE_REF=HEAD "$store/scripts/release.sh" second > /dev/null
base=$(git -C "$store" rev-parse HEAD)
commit "$store" "second release 1"
edit_json "$store/second/latest/release.json" '.appVersion = "v2.0.0"'
BASE_REF=HEAD "$store/scripts/release.sh" second > /dev/null
assert_problem "rejects a new app's first PR that adds two releases" "$(problems "$store" "$base")" \
  second/manifest.json "a PR adds one release at most, this one adds 2"

store=$(new_store)
git -C "$store" rm -rq scripts
commit "$store" "before the store format"
base=$(git -C "$store" rev-parse HEAD)
git -C "$store" checkout -q HEAD~1 -- scripts
release "$store"
commit "$store" "release 1"
edit_json "$store/whoami/latest/release.json" '.appVersion = "v1.11.0"'
BASE_REF=HEAD "$store/scripts/release.sh" whoami > /dev/null
assert_equal "keeps no history against a base from before the store format" "$(problems "$store" "$base")" ""

store=$(released_store)
edit_json "$store/whoami/manifest.json" '.releases[0].appVersion = "v9.9.9"'
assert_problem "rejects a manifest appVersion that differs from its release.json" "$(problems "$store")" \
  whoami/manifest.json 'release 1 appVersion "v9.9.9" differs from whoami/releases/1/release.json ("v1.10.1")'

store=$(released_store)
for dir in latest releases/1; do
  edit_json "$store/whoami/$dir/settings.json" '.fields[1].options = [1]'
done
run "$store/scripts/validate-store.sh"
assert_problem "fails when the settings check can't run on enum options [1]" "$output" \
  whoami/latest/settings.json "couldn't be checked"

store=$(new_store)
edit_json "$store/whoami/latest/settings.json" '.fields = []'
sed -i '/environment:/d; /VERBOSE/d' "$store/whoami/latest/docker-compose.yml"
release "$store"
commit "$store" "release 1"
fakes="$test_root/fakes"
mkdir -p "$fakes"
for tool in jq find sort; do
  # shellcheck disable=SC2016 # expanded when the fake runs
  printf '#!/usr/bin/env bash\ncount=$(($(cat "$CALLS/%s" 2> /dev/null || echo 0) + 1))\necho "$count" > "$CALLS/%s"\n((count != ${FAIL_AT:-0})) || [[ "$FAIL_TOOL" != %s ]] || exit 3\nexec %q "$@"\n' \
    "$tool" "$tool" "$tool" "$(type -ap "$tool" | grep -v -m1 /shims/)" > "$fakes/$tool"
  chmod +x "$fakes/$tool"
done
injected() {
  local calls
  calls=$(mktemp -d "$test_root/calls.XXXXXX")
  PATH="$fakes:$PATH" CALLS="$calls" FAIL_TOOL=$1 FAIL_AT=$2 BASE_REF=HEAD "$store/scripts/validate-store.sh" > /dev/null 2>&1 \
    && echo passed
  cat "$calls/$1" 2> /dev/null || echo 0
}
passed_with_failure=""
tools_never_called=""
for tool in jq find sort; do
  clean=$(injected "$tool" 0)
  [[ "$clean" == passed* ]] || passed_with_failure+="the run without a failure, "
  calls=$(tail -1 <<< "$clean")
  ((calls > 0)) || tools_never_called+="$tool "
  for ((call = 1; call <= calls; call++)); do
    [[ "$(injected "$tool" "$call")" != passed* ]] || passed_with_failure+="$tool call $call, "
  done
done
assert_equal "fails whenever a jq, find or sort call it makes fails" "$passed_with_failure" ""
assert_equal "the failure injection reaches every tool" "$tools_never_called" ""

finish_tests
