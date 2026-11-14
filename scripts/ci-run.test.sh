#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"
# shellcheck source=ci-run.sh
source "$(dirname "$0")/ci-run.sh"

device_env=(APP_ID=whoami APP_DATA_DIR=/var/home/app-data/whoami APP_TZ=America/Chicago)
now=0
sleeps=()
restarts_before=0
restarts_after=0
# shellcheck disable=SC2329 # fakes for what ci-run.sh calls
{
  sleep() {
    sleeps+=("$1")
    now=$((now + $1))
  }
  date() { echo "$now"; }
  container_restarts() {
    if ((now == 0)); then
      echo "c1 $restarts_before"
    else
      echo "c1 $restarts_after"
    fi
  }
}
compose_ps=()
compose_ps_status=0
docker() {
  if [[ "$*" == "compose ps -a --format json" ]]; then
    printf '%s\n' "${compose_ps[@]}"
    return "$compose_ps_status"
  fi
}
with_device_env() {
  local "${device_env[@]}"
  export APP_ID APP_DATA_DIR APP_TZ
  "$@"
}

failing_says="answered 502"
passing_says=
gate() {
  local dir release='{}'
  (($# < 4)) || release=$4
  now=0 sleeps=() restarts_before=$2 restarts_after=$3
  dir=$(mktemp -d "$test_root/gate.XXXXXX")
  echo "$1" > "$dir/pass_at"
  printf '%s' "$failing_says" > "$dir/failing_says"
  printf '%s' "$passing_says" > "$dir/passing_says"
  echo "$release" > "$dir/release.json"
  cat > "$dir/health-check.sh" << 'EOF'
echo check >> checks
pass_at=$(< pass_at)
if ((pass_at > 0 && $(wc -l < checks) >= pass_at)); then
  cat passing_says
  exit 0
fi
[[ ! -s failing_says ]] || echo "check $(wc -l < checks): $(< failing_says)"
exit 1
EOF
  status=0
  with_device_env wait_healthy "$dir" > "$dir/output" 2>&1 || status=$?
  output=$(grep -v '^== ' "$dir/output" | paste -sd '|')
  checks=$(wc -l < "$dir/checks")
}

gate 3 0 0
assert_equal "is healthy as soon as the check passes, checking every interval" \
  "$status $checks ${sleeps[*]} | $output" "0 3 5 5 | healthy after 10 s"

gate 0 0 5
assert_equal "fails without waiting for the timeout once a container restarted 5 times" \
  "$status $checks ${sleeps[*]} | $output" "1 2 5 | a container restarted 5 times since the gate started, the health check said:|  check 2: answered 502"

gate 3 7 7
assert_equal "passes for a container that had 7 restarts before the gate and doesn't restart again" \
  "$status $checks | $output" "0 3 | healthy after 10 s"

gate 0 2 6 '{"healthTimeoutMinutes": 1}'
assert_equal "counts restarts from each container's first read" \
  "$status $checks | $output" "1 13 | not healthy after 1 min, the health check said:|  check 13: answered 502"

gate 0 0 0 '{"healthTimeoutMinutes": 2}'
assert_equal "fails when the app is still unhealthy at the release's healthTimeoutMinutes" \
  "$status $checks | $output" "1 25 | not healthy after 2 min, the health check said:|  check 25: answered 502"

gate 0 0 0
assert_equal "fails when the app is still unhealthy at 30 minutes without healthTimeoutMinutes" \
  "$status $checks | $output" "1 361 | not healthy after 30 min, the health check said:|  check 361: answered 502"

failing_says=
gate 3 0 0
failing_says="answered 502"
assert_equal "fails at the first failing check that prints nothing" \
  "$status $checks | $output" "1 1 | the health check failed without saying why: print what it asked and what it got"

passing_says="all good"
gate 1 0 0
passing_says=
assert_equal "fails when a passing check prints" \
  "$status $checks | $output" "1 1 | a passing health check must print nothing, the health check said:|  all good"

check_env=$(mktemp -d "$test_root/env.XXXXXX")
echo '{}' > "$check_env/release.json"
echo 'env | sort > env' > "$check_env/health-check.sh"
now=0
SECRET=leak with_device_env wait_healthy "$check_env" > /dev/null
assert_equal "runs the health check with only the device's environment" \
  "$(grep -v -e '^PWD=' -e '^SHLVL=' -e '^_=' "$check_env/env" | tr '\n' ' ')" \
  "APP_DATA_DIR=/var/home/app-data/whoami APP_ID=whoami APP_TZ=America/Chicago HOME=/var/roothome LANG=C.UTF-8 PATH=/usr/bin:/usr/sbin "

start() {
  local dir
  dir=$(mktemp -d "$test_root/start.XXXXXX")
  echo '{}' > "$dir/release.json"
  echo 'echo ran > checked' > "$dir/health-check.sh"
  compose_ps=("$@")
  now=0 status=0
  output=$(with_device_env start_release "$dir" 2>&1) || status=$?
  output=$(tail -1 <<< "$output")
  checked=$([[ -f "$dir/checked" ]] && echo checked || echo unchecked)
  compose_ps=()
}

start '{"Service":"server","LocalVolumes":"0"}' '{"Service":"redis","LocalVolumes":"1"}'
assert_equal "fails before the health gate when a container has an anonymous volume, naming its service" \
  "$status $checked | $output" "1 unchecked | redis: anonymous volume, bind every VOLUME of its image under \${APP_DATA_DIR}"

start '{"Service":"server","LocalVolumes":"0"}' '{"Service":"redis","LocalVolumes":"0"}'
assert_equal "starts when every container binds its volumes" "$status $checked | $output" "0 checked | healthy after 0 s"

compose_ps_status=1
start
compose_ps_status=0
assert_equal "fails before the health gate when the containers can't be listed" "$status $checked" "1 unchecked"

start 'not json'
assert_equal "fails before the health gate when the container list isn't json" "$status $checked" "1 unchecked"

seed=$(mktemp -d "$test_root/seed.XXXXXX")
mkdir -p "$seed/release/data/postgres" "$seed/release/data/config"
touch "$seed/release/data/postgres/.gitkeep" "$seed/release/data/config/app.conf"
APP_DATA_DIR="$seed/app-data" seed_data "$seed/release"
assert_equal "seeding drops git placeholders and keeps folders and files" \
  "$(cd "$seed/app-data" && find . | sort | tr '\n' ' ')" ". ./config ./config/app.conf ./postgres "

update_steps() {
  local store n
  store=$(new_store)
  for ((n = 1; n <= $1; n++)); do
    write_release "$store/whoami/releases/$n" "v1.$n.0"
  done
  edit_json "$store/whoami/manifest.json" ".releases = [range(1; $1 + 1) | {version: ., appVersion: \"v1.\\(.).0\", canSkip: false}]"
  status=0
  output=$(
    cd "$store"
    seed_data() { echo "seed $1"; }
    start_release() { echo "start $1"; }
    main update whoami 2>&1
  ) || status=$?
  output=${output//$'\n'/|}
}

update_steps 3
assert_equal "updates from the release before the newest to the newest" "$status $output" \
  "0 seed whoami/releases/2|== render whoami/releases/2|start whoami/releases/2|== render whoami/releases/3|== down (release 2)|start whoami/releases/3|whoami: update passed"

update_steps 1
assert_equal "skips the update with a single release" "$status $output" \
  "0 whoami: one release, nothing to update from"

finish_tests
