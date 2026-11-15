#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

registry_pids=()
trap 'kill "${registry_pids[@]}" 2> /dev/null; rm -rf "$test_root"' EXIT

start_registry() {
  local output line
  output=$(mktemp -u "$test_root/registry.XXXXXX")
  mkfifo "$output"
  crane registry serve --address 127.0.0.1:0 > "$output" 2>&1 &
  registry_pids+=($!)
  exec {registry_output}< "$output"
  while IFS= read -r -t 10 line <&"$registry_output"; do
    [[ "$line" =~ serving\ on\ port\ ([0-9]+)$ ]] || continue
    registry="localhost:${BASH_REMATCH[1]}/fhs-apps/store"
    cat <&"$registry_output" > /dev/null &
    return
  done
  echo "the test registry didn't start" >&2
  return 1
}

publish() {
  run env STORE_REPOSITORIES="$1" "$store/scripts/publish-store.sh" "${@:2}"
}

digest_of() {
  crane digest "$1" 2> /dev/null || echo missing
}

channel_digests() {
  local repository channel
  for repository in "$ghcr" "$futo"; do
    for channel in nightly alpha; do
      digest_of "$repository:$channel"
    done
  done | paste -sd' '
}

signatures() {
  local repository
  for repository in "$@"; do
    if cosign verify --key "$test_root/cosign.pub" --insecure-ignore-tlog=true "$repository" > /dev/null 2>&1; then
      echo signed
    else
      echo unsigned
    fi
  done | paste -sd' '
}

release_whoami() {
  write_release "$store/whoami/latest" "$1" true
  BASE_REF=HEAD "$store/scripts/release.sh" whoami > /dev/null
  commit "$store" "$1"
}

push_tag_without_store() {
  echo junk > "$test_root/junk"
  (cd "$test_root" && oras push "$1" "${@:2}" junk > /dev/null)
}

start_registry
ghcr=$registry
start_registry
futo=$registry
both="$ghcr $futo"
(cd "$test_root" && COSIGN_PASSWORD='' cosign generate-key-pair > /dev/null 2>&1)
export COSIGN_KEY="$test_root/cosign.key" COSIGN_PASSWORD=''

store=$(new_store)
release_whoami v1.10.1
first=$(git -C "$store" rev-parse HEAD)

publish "$both" commit
first_digest=$(digest_of "$ghcr:$first")
assert_equal "publishes the first store" "$status" 0
assert_equal "pushes store:<commit> with one digest to both registries" "$(digest_of "$futo:$first")" "$first_digest"
assert_equal "points every channel on both registries at it when they don't exist yet" "$(channel_digests)" \
  "$first_digest $first_digest $first_digest $first_digest"
assert_equal "signs it on both registries" "$(signatures "$ghcr@$first_digest" "$futo@$first_digest")" "signed signed"
"$store/scripts/pack-store.sh" "$test_root/first.tar.gz" > /dev/null
assert_equal "pushes the packed store as the agent's single layer, named for the commit" \
  "$(crane manifest "$futo:nightly" | jq -c '{artifactType, config: .config.mediaType, layers: [.layers[] | {mediaType, digest, title: .annotations["org.opencontainers.image.title"]}], revision: .annotations["org.opencontainers.image.revision"]}')" \
  "{\"artifactType\":\"application/vnd.futo.fhs-apps.store.v1\",\"config\":\"application/vnd.oci.empty.v1+json\",\"layers\":[{\"mediaType\":\"application/vnd.futo.fhs-apps.store.v1.tar+gzip\",\"digest\":\"sha256:$(sha256sum "$test_root/first.tar.gz" | cut -d' ' -f1)\",\"title\":\"store.tar.gz\"}],\"revision\":\"$first\"}"

release_whoami v1.11.0
second=$(git -C "$store" rev-parse HEAD)
publish "$both" commit
second_digest=$(digest_of "$ghcr:$second")
assert_equal "moves every channel on both registries to a newer commit's store" "$status $(channel_digests)" \
  "0 $second_digest $second_digest $second_digest $second_digest"

echo docs >> "$store/README.md"
commit "$store" docs
docs=$(git -C "$store" rev-parse HEAD)
publish "$both" commit
assert_equal "gives a newer commit that kept the store the same digest, so the channels stay" \
  "$status $(digest_of "$ghcr:$docs") $(channel_digests)" \
  "0 $second_digest $second_digest $second_digest $second_digest $second_digest"

git -C "$store" checkout -q "$first"
publish "$both" commit
assert_equal "leaves the channels when an older commit runs again" "$status $(channel_digests)" \
  "0 $second_digest $second_digest $second_digest $second_digest"
git -C "$store" checkout -q -

release_whoami v1.11.1
third=$(git -C "$store" rev-parse HEAD)
publish "$ghcr localhost:1/fhs-apps/store" commit
assert_equal "moves no channel when the second registry can't be reached" "$((status > 0)) $(channel_digests)" \
  "1 $second_digest $second_digest $second_digest $second_digest"

publish "$ghcr" commit
third_digest=$(digest_of "$ghcr:$third")
publish "$both" commit
assert_equal "brings the second registry level with the first when a run stopped between them" \
  "$status $(digest_of "$ghcr:$third") $(channel_digests) $(signatures "$futo@$third_digest")" \
  "0 $third_digest $third_digest $third_digest $third_digest $third_digest signed"

release_whoami v1.12.0
unknown_commit=0123456789abcdef0123456789abcdef01234567
for case in "an unknown commit|--annotation=org.opencontainers.image.revision=$unknown_commit|points at $unknown_commit, a commit this clone doesn't have" "no revision||has no"; do
  IFS='|' read -r label annotation problem <<< "$case"
  push_tag_without_store "$futo:alpha" ${annotation:+"$annotation"}
  stray=$(digest_of "$futo:alpha")
  publish "$both" commit
  assert_equal "fails and moves no channel when a channel points at $label" \
    "$((status > 0)) $(channel_digests)" "1 $third_digest $third_digest $third_digest $stray"
  assert_problem "names the channel that points at $label" "$output" "$futo:alpha" "$problem"
done
oras tag "$futo@$third_digest" alpha > /dev/null

release_whoami v1.13.0
head=$(git -C "$store" rev-parse HEAD)
publish "$both" pr 12
pr_digest=$(digest_of "$ghcr:pr-12")
assert_equal "pushes a PR's store to the first registry only, unsigned, named for its commit" \
  "$status $(crane manifest "$ghcr:pr-12" | jq -r '.annotations["org.opencontainers.image.revision"]') $(digest_of "$futo:pr-12") $(signatures "$ghcr@$pr_digest")" \
  "0 $head missing unsigned"
assert_equal "moves no channel for a PR" "$(channel_digests)" "$third_digest $third_digest $third_digest $third_digest"

publish "$both" pr twelve
assert_equal "refuses a PR number that isn't one" "$status" 2

publish "$ghcr" commit
cut_off_digest=$(digest_of "$ghcr:$head")
echo more docs >> "$store/README.md"
commit "$store" "more docs"
more_docs=$(git -C "$store" rev-parse HEAD)
publish "$both" commit
assert_equal "brings both registries to one digest when a commit that kept the store follows a run that stopped between them" \
  "$status $(digest_of "$futo:$more_docs") $(channel_digests)" \
  "0 $cut_off_digest $cut_off_digest $cut_off_digest $cut_off_digest $cut_off_digest"

echo '{}' > "$store/_template/manifest.json"
commit "$store" "template"
template=$(git -C "$store" rev-parse HEAD)
publish "$both" commit
assert_equal "gives a commit that only changes the template the same digest" "$status $(digest_of "$ghcr:$template")" \
  "0 $cut_off_digest"

sed -i 's/--mtime=@0/--mtime=@1/' "$store/scripts/pack-store.sh"
commit "$store" "pack differently"
repacked=$(git -C "$store" rev-parse HEAD)
publish "$both" commit
repacked_digest=$(digest_of "$ghcr:$repacked")
assert_equal "moves the channels when a commit changes how the store is packed" \
  "$status $([[ "$repacked_digest" != "$cut_off_digest" ]] && echo new) $(channel_digests)" \
  "0 new $repacked_digest $repacked_digest $repacked_digest $repacked_digest"

git -C "$store" checkout -q -b side HEAD~1
git -C "$store" -c user.name=t -c user.email=t@t cherry-pick "$repacked" > /dev/null
edit_json "$store/catalog.json" '.apps[0].name = "Who am I"'
commit "$store" "rename on a branch that started before the published commit"
git -C "$store" checkout -q -
git -C "$store" -c user.name=t -c user.email=t@t merge -q --no-ff -X theirs -m "merge side" side
merged=$(git -C "$store" rev-parse HEAD)
publish "$both" commit
merged_digest=$(digest_of "$ghcr:$merged")
assert_equal "moves the channels to a store merged from a branch that started before the published commit" \
  "$status $(crane manifest "$ghcr:$merged" | jq -r '.annotations["org.opencontainers.image.revision"]') $(channel_digests)" \
  "0 $merged $merged_digest $merged_digest $merged_digest $merged_digest"

for change in "an edited manifest|whoami/manifest.json" "an edited release file|whoami/releases/1/health-check.sh" "a new release file|whoami/releases/1/stray"; do
  IFS='|' read -r label path <<< "$change"
  echo changed >> "$store/$path"
  publish "$both" commit
  assert_equal "refuses to publish a store with $label" "$status $(channel_digests)" \
    "1 $merged_digest $merged_digest $merged_digest $merged_digest"
  git -C "$store" checkout -q -- whoami
  git -C "$store" clean -qfd -- whoami
done

finish_tests
