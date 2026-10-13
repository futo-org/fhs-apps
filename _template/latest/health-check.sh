# Exit 0 when the app serves requests, anything else when not. Run as
# `bash -euo pipefail`, cwd = this release folder, 5 s limit per run.
# Tools: bash, coreutils, grep, sed, gawk, jq, curl, docker compose.
curl -fsS --max-time 4 http://127.0.0.1:8080/ >/dev/null
