#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

store=$(cd "$scripts_dir/.." && pwd)
fake_bin=$(mktemp -d "$test_root/bin.XXXXXX")
cat > "$fake_bin/curl" << 'EOF'
#!/usr/bin/env bash
dir=$(dirname "$0")
if [[ ! -f "$dir/body" ]]; then
  echo "curl: (7) Failed to connect to 127.0.0.1 port 80 after 0 ms: Could not connect to server" >&2
  exit 7
fi
out=/dev/stdout
while (($#)); do
  [[ $1 != -o ]] || out=$2
  shift
done
cat "$dir/body" > "$out"
EOF
chmod +x "$fake_bin/curl"

check() {
  local app=$1
  rm -f "$fake_bin/body"
  (($# < 2)) || printf '%s' "$2" > "$fake_bin/body"
  status=0
  output=$(cd "$store/$app/latest" && env -i PATH="$fake_bin:/usr/bin:/usr/sbin" HOME=/var/roothome LANG=C.UTF-8 \
    bash -euo pipefail ./health-check.sh 2>&1) || status=$?
  output=${output//$'\n'/|}
}

check nextcloud '{"installed":true,"maintenance":false,"needsDbUpgrade":false}'
assert_equal "nextcloud passes silently once installed, out of maintenance, with no upgrade pending" "$status $output" "0 "

check nextcloud
assert_equal "nextcloud says the url it couldn't get" "$status $output" \
  "1 curl: (7) Failed to connect to 127.0.0.1 port 80 after 0 ms: Could not connect to server|Nextcloud isn't ready: GET http://127.0.0.1:8081/status.php failed"

check nextcloud '{"installed":false,"maintenance":false,"needsDbUpgrade":false}'
assert_equal "nextcloud says its first run install was cut off when apache answers uninstalled" "$status $output" \
  "1 Nextcloud's first run install was cut off and won't resume: http://127.0.0.1:8081/status.php says installed false"

check nextcloud '{"installed":true,"maintenance":true,"needsDbUpgrade":true}'
assert_equal "nextcloud says its upgrade was cut off when a database upgrade is pending in maintenance mode" "$status $output" \
  "1 Nextcloud's upgrade was cut off and won't resume: http://127.0.0.1:8081/status.php says a database upgrade is pending (occ upgrade)"

check nextcloud '{"installed":true,"maintenance":true,"needsDbUpgrade":false}'
assert_equal "nextcloud says it is in maintenance mode" "$status $output" \
  "1 Nextcloud is in maintenance mode: http://127.0.0.1:8081/status.php says maintenance true (occ maintenance:mode --off)"

check nextcloud '<html>Bad Gateway</html>'
assert_equal "nextcloud says when the answer isn't its status" "$status $output" \
  "1 Nextcloud isn't ready: http://127.0.0.1:8081/status.php didn't answer Nextcloud's status"

check jellyfin Healthy
assert_equal "jellyfin passes silently once healthy" "$status $output" "0 "

check jellyfin Degraded
assert_equal "jellyfin says what its health endpoint answered while migrating" "$status $output" \
  "1 Jellyfin isn't ready: http://127.0.0.1:8096/health says Degraded"

check homeassistant '{"name":"Home Assistant"}'
assert_equal "home assistant passes silently once its manifest answers" "$status $output" "0 "

check homeassistant '{"name":"Grafana"}'
assert_equal "home assistant says when another app answers its port" "$status $output" \
  "1 Home Assistant isn't ready: http://127.0.0.1:8123/manifest.json isn't Home Assistant's manifest"

finish_tests
