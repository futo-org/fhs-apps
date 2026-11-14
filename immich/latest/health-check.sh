url=http://127.0.0.1:2283/api/server/ping
if ! curl -fsS --max-time 4 -o /dev/null "$url"; then
  echo "Immich isn't ready: GET $url failed"
  exit 1
fi
