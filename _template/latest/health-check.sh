url=http://127.0.0.1:8080/
if ! curl -fsS --max-time 4 -o /dev/null "$url"; then
  echo "The app isn't ready: GET $url failed"
  exit 1
fi
