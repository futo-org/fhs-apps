#!/usr/bin/env bash
set -euo pipefail

declare -A restarts_at_start

clean_up() {
  docker compose down --volumes --remove-orphans > /dev/null 2>&1 || true
  docker run --rm -v "$work:/work" alpine:3 rm -rf /work/data > /dev/null 2>&1 || true
  rm -rf "$work"
}

render_release() {
  local dir=$1 target=${2:-$COMPOSE_FILE}
  echo "== render $dir"
  scripts/generate-compose.sh "$dir" "$app" > "$target"
}

seed_data() {
  local dir=$1
  mkdir -p "$APP_DATA_DIR"
  if [[ -d "$dir/data" ]]; then
    cp -a "$dir/data/." "$APP_DATA_DIR/"
  fi
  find "$APP_DATA_DIR" -type f -name .gitkeep -delete
}

start_release() {
  local dir=$1
  echo "== pull"
  docker compose pull --quiet
  echo "== up"
  docker compose up -d
  require_no_anonymous_volumes || return 1
  wait_healthy "$dir"
}

require_no_anonymous_volumes() {
  local containers services service
  containers=$(docker compose ps -a --format json) || return 1
  services=$(jq -r 'select(.LocalVolumes != "0") | .Service' <<< "$containers") || return 1
  [[ -n "$services" ]] || return 0

  for service in $services; do
    echo "$service: anonymous volume, bind every VOLUME of its image under \${APP_DATA_DIR}" >&2
  done
  return 1
}

container_restarts() {
  local ids
  mapfile -t ids < <(docker compose ps -a -q)
  ((${#ids[@]})) || return 0
  docker inspect -f '{{.ID}} {{.RestartCount}}' "${ids[@]}"
}

count_restarts() {
  local id count
  restarts=0
  while read -r id count; do
    [[ -v "restarts_at_start[$id]" ]] || restarts_at_start[$id]=$count
    if ((count - restarts_at_start[$id] > restarts)); then
      restarts=$((count - restarts_at_start[$id]))
    fi
  done < <(container_restarts)
}

run_health_check() {
  said=$(cd "$1" && timeout -s KILL 5 env -i PATH=/usr/bin:/usr/sbin HOME=/var/roothome LANG=C.UTF-8 \
    APP_ID="$APP_ID" APP_DATA_DIR="$APP_DATA_DIR" APP_TZ="$APP_TZ" \
    bash -euo pipefail ./health-check.sh < /dev/null 2>&1)
}

fail_gate() {
  docker compose logs --tail 50 >&2 || true
  echo "$1, the health check said:" >&2
  echo "  ${said//$'\n'/$'\n'  }" >&2
}

wait_healthy() {
  local dir=$1 started elapsed timeout_minutes restarts said
  timeout_minutes=$(jq '.healthTimeoutMinutes // 30' "$dir/release.json")
  started=$(date +%s)
  restarts_at_start=()
  count_restarts
  echo "== health gate ($dir/health-check.sh, $timeout_minutes min)"
  while true; do
    if run_health_check "$dir"; then
      if [[ -n "$said" ]]; then
        fail_gate "a passing health check must print nothing"
        return 1
      fi
      echo "healthy after $(($(date +%s) - started)) s"
      return 0
    fi
    if [[ -z "$said" ]]; then
      echo "the health check failed without saying why: print what it asked and what it got" >&2
      return 1
    fi
    count_restarts
    if ((restarts >= 5)); then
      fail_gate "a container restarted $restarts times since the gate started"
      return 1
    fi
    elapsed=$(($(date +%s) - started))
    if ((elapsed >= timeout_minutes * 60)); then
      fail_gate "not healthy after $timeout_minutes min"
      return 1
    fi
    sleep 5
  done
}

main() {
  if (($# != 2)) || [[ "$1" != install && "$1" != update ]]; then
    echo "usage: $0 install|update <app-id>" >&2
    exit 2
  fi

  local mode=$1 last from to
  app=$2

  work=$(mktemp -d)
  export APP_ID=$app
  export APP_DATA_DIR="$work/data"
  export APP_SEED=ci-seed
  export APP_PASSWORD="ci-$RANDOM$RANDOM"
  export APP_TZ=America/Chicago
  export COMPOSE_PROJECT_NAME=$app
  export COMPOSE_FILE="$work/docker-compose.yml"
  trap clean_up EXIT

  case $mode in
    install)
      seed_data "$app/latest"
      render_release "$app/latest"
      start_release "$app/latest"
      ;;
    update)
      last=$(jq '.releases | length' "$app/manifest.json")
      if ((last < 2)); then
        echo "$app: one release, nothing to update from"
        exit 0
      fi
      from="$app/releases/$((last - 1))"
      to="$app/releases/$last"
      seed_data "$from"
      render_release "$from"
      start_release "$from"
      render_release "$to" "$work/next.yml"
      echo "== down (release $((last - 1)))"
      docker compose down --remove-orphans
      mv "$work/next.yml" "$COMPOSE_FILE"
      start_release "$to"
      ;;
  esac

  echo "$app: $mode passed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cd "$(dirname "$0")/.."
  main "$@"
fi
