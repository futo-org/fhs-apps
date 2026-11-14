url=http://127.0.0.1:8081/status.php
if ! status=$(curl -fsS --max-time 4 "$url"); then
  echo "Nextcloud isn't ready: GET $url failed"
  exit 1
fi
state=$(jq -r 'if .installed != true then "not installed" elif .needsDbUpgrade != false then "upgrade pending" elif .maintenance != false then "maintenance" else "ready" end' <<< "$status" 2> /dev/null) || state="not nextcloud"
case $state in
  ready) ;;
  "not installed")
    echo "Nextcloud's first run install was cut off and won't resume: $url says installed false"
    exit 1
    ;;
  "upgrade pending")
    echo "Nextcloud's upgrade was cut off and won't resume: $url says a database upgrade is pending (occ upgrade)"
    exit 1
    ;;
  maintenance)
    echo "Nextcloud is in maintenance mode: $url says maintenance true (occ maintenance:mode --off)"
    exit 1
    ;;
  *)
    echo "Nextcloud isn't ready: $url didn't answer Nextcloud's status"
    exit 1
    ;;
esac
