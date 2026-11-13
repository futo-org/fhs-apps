# Healthy once the server answers its ping endpoint.
curl -fsS --max-time 4 http://127.0.0.1:2283/api/server/ping >/dev/null
