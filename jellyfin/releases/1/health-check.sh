# Healthy once /health says "Healthy". While migrating (first start, updates)
# the startup server answers 200 "Degraded", so the body is checked too.
status=$(curl -fsS --max-time 4 http://127.0.0.1:8096/health)
[[ $status == Healthy ]]
