# shellcheck shell=bash
# Test helpers, sourced by scripts/*.test.sh: assertions and throwaway stores.

scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
failed=0

# run <command...>: sets output (stdout and stderr) and status; never fails.
run() {
  # shellcheck disable=SC2034 # read by the tests
  status=0
  # shellcheck disable=SC2034 # read by the tests
  output=$("$@" 2>&1) || status=$?
}

# assert_equal <case> <actual> <expected>
assert_equal() {
  if [[ "$2" == "$3" ]]; then
    echo "ok: $1"
    return
  fi

  echo "FAIL: $1: got $2, want $3"
  failed=1
}

# assert_problem <case> <validate output> <file> <says>: needs a line "error: <file>: ...<says>...".
assert_problem() {
  local line
  while IFS= read -r line; do
    if [[ "$line" == "error: $3: "*"$4"* ]]; then
      echo "ok: $1"
      return
    fi
  done <<< "$2"

  echo "FAIL: $1: no problem in $3 saying \"$4\"; got:"
  while IFS= read -r line; do
    echo "  $line"
  done <<< "$2"
  failed=1
}

finish_tests() {
  exit "$failed"
}

# edit_json <file> <jq filter>
edit_json() {
  local edited
  edited=$(jq "$2" "$1")
  printf '%s\n' "$edited" > "$1"
}

# write_release <dir> [app version] [can skip]: a complete whoami release with one setting of each type.
write_release() {
  local dir=$1
  mkdir -p "$dir/data/config"
  touch "$dir/data/config/.gitkeep"
  jq -n --arg appVersion "${2:-v1.10.1}" --argjson canSkip "${3:-false}" \
    '{appVersion: $appVersion, canSkip: $canSkip}' > "$dir/release.json"
  echo 'curl -fsS --max-time 4 http://127.0.0.1:8080/ > /dev/null' > "$dir/health-check.sh"
  cat > "$dir/docker-compose.yml" << 'EOF'
name: whoami

services:
  whoami:
    image: docker.io/traefik/whoami:v1.10.1
    volumes:
      - ${APP_DATA_DIR}/config:/config
    environment:
      SECRET: ${SECRET}
      VERBOSE: ${VERBOSE}
    ports:
      - "8080:80"
    restart: unless-stopped
EOF
  cat > "$dir/settings.json" << 'EOF'
{
  "fields": [
    {
      "key": "EXPORT_DIR",
      "type": "path",
      "label": "Export folder",
      "compose": {
        "services": {
          "whoami": {
            "volumes": [{"type": "bind", "source": "${EXPORT_DIR}", "target": "/config", "bind": {"create_host_path": false}}]
          }
        }
      }
    },
    {
      "key": "MODE",
      "type": "enum",
      "label": "Mode",
      "default": "plain",
      "options": [{"value": "plain", "label": "Plain"}, {"value": "gpu", "label": "GPU"}],
      "compose": {"gpu": {"services": {"whoami": {"devices": ["/dev/dri:/dev/dri"]}}}}
    },
    {
      "key": "VERBOSE",
      "type": "bool",
      "label": "Verbose",
      "default": true,
      "compose": {
        "true": {"services": {"whoami": {"environment": {"WHOAMI_VERBOSE": "yes"}}}},
        "false": {"services": {"whoami": {"environment": {"WHOAMI_VERBOSE": "no"}}}}
      }
    },
    {"key": "SECRET", "type": "generated"}
  ]
}
EOF
}

# commit <store> <message>: commits every change, like a merge to master.
commit() {
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$2"
}

# Prints the path of a new git store: the whoami app merged with nothing published, _template/ and the tooling.
new_store() {
  local store
  store=$(mktemp -d "$test_root/store.XXXXXX")
  mkdir -p "$store/scripts"
  cp "$scripts_dir"/{validate-store,render,publish,new-app}.sh "$store/scripts/"
  cp -a "$scripts_dir/../_template" "$store/_template"
  echo '{"schemaVersion": 1, "apps": [{"id": "whoami", "name": "Whoami"}]}' > "$store/catalog.json"
  mkdir -p "$store/whoami"
  echo '{"schemaVersion": 1, "appId": "whoami", "appPort": 8080, "releases": []}' > "$store/whoami/manifest.json"
  write_release "$store/whoami/latest"
  git -C "$store" init -q
  commit "$store" base
  echo "$store"
}
