# Healthy once the frontend answers: HA opens its HTTP server only after the
# frontend and its dependencies (api, auth, onboarding) are set up.
curl -fsS --max-time 4 http://127.0.0.1:8123/manifest.json | jq -e '.name == "Home Assistant"' >/dev/null
