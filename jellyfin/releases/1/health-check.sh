url=http://127.0.0.1:8096/health
if ! status=$(curl -fsS --max-time 4 "$url"); then
  echo "Jellyfin isn't ready: GET $url failed"
  exit 1
fi
if [[ $status != Healthy ]]; then
  echo "Jellyfin isn't ready: $url says $status"
  exit 1
fi
