#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

revision_key=org.opencontainers.image.revision
channels=(nightly alpha)
store_paths=(catalog.json scripts/generate-compose.sh scripts/pack-store.sh scripts/publish-store.sh '*/manifest.json' '*/releases/*' ':(exclude)_*')
read -r -a repositories <<< "${STORE_REPOSITORIES:-ghcr.io/futo-org/fhs-apps/store oci.futo.org/fhs-apps/store}"
first=${repositories[0]}

usage() {
  echo "usage: $0 commit | pr <number>" >&2
  exit 2
}

fail() {
  echo "error: $*" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
commit=$(git rev-parse HEAD)
revision=$(git rev-list -1 --first-parent HEAD -- "${store_paths[@]}")
[[ -n "$revision" ]] || fail "no commit changed the store"
created=$(git show -s --format=%cI "$revision")

pack() {
  scripts/pack-store.sh "$work/store.tar.gz"
}

push_store() {
  local ref=$1
  echo "== push $ref" >&2
  (cd "$work" && oras push "$ref" \
    --artifact-type application/vnd.futo.fhs-apps.store.v1 \
    --annotation "$revision_key=$revision" \
    --annotation org.opencontainers.image.source=https://github.com/futo-org/fhs-apps \
    --annotation "org.opencontainers.image.created=$created" \
    --format go-template='{{.digest}}' \
    store.tar.gz:application/vnd.futo.fhs-apps.store.v1.tar+gzip)
}

sign() {
  local key_args=()
  [[ -z "${COSIGN_KEY:-}" ]] || key_args=(--key "$COSIGN_KEY" --tlog-upload=false)
  echo "== sign $1"
  cosign sign --yes --new-bundle-format=false --use-signing-config=false "${key_args[@]}" "$1"
}

copy_store() {
  local repository=$1 digest=$2 signature copied
  signature="sha256-${digest#sha256:}.sig"
  echo "== copy to $repository:$commit"
  oras cp "$first:$commit" "$repository:$commit"
  oras cp "$first:$signature" "$repository:$signature"
  copied=$(oras resolve "$repository:$commit")
  [[ "$copied" == "$digest" ]] || fail "$repository:$commit: holds $copied, not $first's $digest"
}

channel_plan() {
  local ref=$1 manifest at ancestry=0
  if ! manifest=$(oras manifest fetch "$ref" 2> "$work/err"); then
    grep -Eqi 'not found|MANIFEST_UNKNOWN|NAME_UNKNOWN' "$work/err" || fail "$ref: $(< "$work/err")"
    echo "move: first publish"
    return
  fi

  at=$(jq -r --arg key "$revision_key" '.annotations[$key] // ""' <<< "$manifest")
  [[ -n "$at" ]] || fail "$ref: has no $revision_key annotation, so it can't be ordered against $revision"
  git cat-file -e "$at^{commit}" 2> /dev/null \
    || fail "$ref: points at $at, a commit this clone doesn't have (fetch the full history)"
  if [[ "$at" == "$revision" ]]; then
    echo "stay: already serves the store from $revision"
    return
  fi

  git merge-base --is-ancestor "$at" "$revision" || ancestry=$?
  case $ancestry in
    0) echo "move: from $at" ;;
    1) echo "stay: at $at, which $revision doesn't descend from" ;;
    *) fail "$ref: couldn't order $at against $revision" ;;
  esac
}

require_committed_store() {
  local changed
  changed=$(git status --porcelain -- "${store_paths[@]}")
  [[ -z "$changed" ]] || fail "the store has uncommitted changes, commit them first:"$'\n'"$changed"
}

publish_commit() {
  local digest repository channel ref plan moves=()
  require_committed_store
  pack
  digest=$(push_store "$first:$commit")
  echo "$digest"
  sign "$first@$digest"
  for repository in "${repositories[@]:1}"; do
    copy_store "$repository" "$digest"
  done

  echo "== channels"
  for repository in "${repositories[@]}"; do
    for channel in "${channels[@]}"; do
      ref="$repository:$channel"
      plan=$(channel_plan "$ref")
      echo "$ref: ${plan#*: }"
      [[ "$plan" != move:* ]] || moves+=("$ref")
    done
  done
  for ref in "${moves[@]}"; do
    oras tag "${ref%:*}@$digest" "${ref##*:}" > /dev/null
    echo "$ref -> $digest"
  done
}

publish_pr() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || usage
  pack
  push_store "$first:pr-$1"
}

case ${1:-} in
  commit)
    (($# == 1)) || usage
    publish_commit
    ;;
  pr)
    (($# == 2)) || usage
    publish_pr "$2"
    ;;
  *) usage ;;
esac
