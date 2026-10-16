#!/usr/bin/env bash
# Tests for ci-run.sh: the health gate on a fake clock, seeding, and the update steps.
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"
# shellcheck source=ci-run.sh
source "$(dirname "$0")/ci-run.sh"

# Fakes: sleeping advances the clock; restarts come from the case; logs print nothing.
# Not named restarts: wait_healthy has a local of that name, which bash would show the fake.
now=0
sleeps=()
fake_restarts=0
sleep() {
  sleeps+=("$1")
  now=$((now + $1))
}
date() { echo "$now"; }
max_restarts() { echo "$fake_restarts"; }
docker() { :; }

# gate <check that passes, 0 = never> [restarts] [timeout s]: runs wait_healthy on a fresh
# clock against a health check that counts its runs; sets status, output and checks.
gate() {
  local dir
  now=0 sleeps=() fake_restarts=${2:-0} health_timeout=${3:-1800}
  dir=$(mktemp -d "$test_root/gate.XXXXXX")
  echo "$1" > "$dir/pass_at"
  cat > "$dir/health-check.sh" << 'EOF'
echo check >> checks
pass_at=$(< pass_at)
((pass_at > 0 && $(wc -l < checks) >= pass_at))
EOF
  status=0
  wait_healthy "$dir" > "$dir/output" 2>&1 || status=$?
  output=$(tail -1 "$dir/output")
  checks=$(wc -l < "$dir/checks")
}

gate 3
assert_equal "is healthy as soon as the check passes, checking every interval" \
  "$status $checks ${sleeps[*]} | $output" "0 3 5 5 | healthy after 10 s"

gate 0 5
assert_equal "fails without waiting for the timeout once a service restarted 5 times" \
  "$status $checks ${sleeps[*]} | $output" "1 1  | a service restarted 5 times"

gate 0 0 30
assert_equal "fails when the app is still unhealthy at the timeout" \
  "$status $checks | $output" "1 7 | not healthy after 30 s"

seed=$(mktemp -d "$test_root/seed.XXXXXX")
mkdir -p "$seed/release/data/postgres" "$seed/release/data/config"
touch "$seed/release/data/postgres/.gitkeep" "$seed/release/data/config/app.conf"
APP_DATA_DIR="$seed/app-data" seed_data "$seed/release"
assert_equal "seeding drops git placeholders and keeps folders and files" \
  "$(cd "$seed/app-data" && find . | sort | tr '\n' ' ')" ". ./config ./config/app.conf ./postgres "

# update_steps <releases>: runs `main update` on a store whoami with that many releases,
# the release steps faked; sets status and output (the steps, one per "|").
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
    render_release() {
      echo "render $1"
      : > "${2:-$COMPOSE_FILE}"
    }
    start_release() { echo "start $1"; }
    main update whoami 2>&1
  ) || status=$?
  output=${output//$'\n'/|}
}

update_steps 3
assert_equal "updates from the release before the newest to the newest" "$status $output" \
  "0 seed whoami/releases/2|render whoami/releases/2|start whoami/releases/2|render whoami/releases/3|== down (release 2)|start whoami/releases/3|whoami: update passed"

update_steps 1
assert_equal "skips the update with a single release" "$status $output" \
  "0 whoami: one release, nothing to update from"

finish_tests
