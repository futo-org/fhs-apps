#!/usr/bin/env bash
# Runs an app the way a device does, for CI: render with default settings, pull,
# up, then the health gate (health-check.sh every 5 s, fail after 5 restarts of
# any service or 30 min). Mirrors the agent's install and update steps in bash.
#
# usage: ci-run.sh install <app-id>   fresh install of latest/
#        ci-run.sh update <app-id>    the release before the newest, then update to the newest
set -euo pipefail

health_timeout=1800
restart_limit=5

cleanup() {
  docker compose down --remove-orphans > /dev/null 2>&1 || true
  # Containers write app data as other users; delete it from inside a container.
  docker run --rm -v "$work:/work" alpine:3 rm -rf /work/data > /dev/null 2>&1 || true
  rm -rf "$work"
}

render_release() {
  local dir=$1 target=${2:-$COMPOSE_FILE}
  echo "== render $dir"
  scripts/render.sh "$dir" "$app" > "$target"
}

seed_data() {
  local dir=$1
  mkdir -p "$APP_DATA_DIR"
  if [[ -d "$dir/data" ]]; then
    cp -a "$dir/data/." "$APP_DATA_DIR/"
  fi
  # Like the agent: .gitkeep only lets git hold empty folders, and some images
  # refuse a folder that isn't empty (postgres initdb).
  find "$APP_DATA_DIR" -type f -name .gitkeep -delete
}

start_release() {
  local dir=$1
  echo "== pull"
  docker compose pull --quiet
  echo "== up"
  docker compose up -d
  wait_healthy "$dir"
}

# Prints the highest restart count of any of the project's containers.
max_restarts() {
  local ids
  ids=$(docker compose ps -a -q)
  [[ -n "$ids" ]] || {
    echo 0
    return
  }
  # shellcheck disable=SC2086
  docker inspect -f '{{.RestartCount}}' $ids | sort -n | tail -1
}

wait_healthy() {
  local dir=$1 started elapsed restarts
  started=$(date +%s)
  echo "== health gate ($dir/health-check.sh)"
  while true; do
    if (cd "$dir" && timeout -s KILL 5 bash -euo pipefail ./health-check.sh < /dev/null > /dev/null 2>&1); then
      echo "healthy after $(($(date +%s) - started)) s"
      return 0
    fi
    restarts=$(max_restarts)
    if ((restarts >= restart_limit)); then
      echo "a service restarted $restarts times" >&2
      docker compose logs --tail 50 >&2 || true
      return 1
    fi
    elapsed=$(($(date +%s) - started))
    if ((elapsed >= health_timeout)); then
      echo "not healthy after $health_timeout s" >&2
      docker compose logs --tail 50 >&2 || true
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
  export COMPOSE_PROJECT_NAME=$app
  export COMPOSE_FILE="$work/docker-compose.yml"
  trap cleanup EXIT

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
      # Like the agent: render next to the running file, stop, then swap.
      render_release "$to" "$work/next.yml"
      echo "== down (release $((last - 1)))"
      docker compose down --remove-orphans
      mv "$work/next.yml" "$COMPOSE_FILE"
      start_release "$to"
      ;;
  esac

  echo "$app: $mode passed"
}

# Tests source this file for its functions; run as a command otherwise.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cd "$(dirname "$0")/.."
  main "$@"
fi
