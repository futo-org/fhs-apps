# Healthy once Nextcloud is installed, out of maintenance mode and has no
# pending database upgrade. While the entrypoint installs or runs `occ
# upgrade`, apache is not started yet, so curl fails.
status=$(curl -fsS --max-time 4 http://127.0.0.1:8081/status.php)
jq -e '.installed == true and .maintenance == false and .needsDbUpgrade == false' <<< "$status" > /dev/null
