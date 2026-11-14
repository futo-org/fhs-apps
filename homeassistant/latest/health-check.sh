url=http://127.0.0.1:8123/manifest.json
if ! manifest=$(curl -fsS --max-time 4 "$url"); then
  echo "Home Assistant isn't ready: GET $url failed"
  exit 1
fi
if ! jq -e '.name == "Home Assistant"' <<< "$manifest" > /dev/null 2>&1; then
  echo "Home Assistant isn't ready: $url isn't Home Assistant's manifest"
  exit 1
fi
