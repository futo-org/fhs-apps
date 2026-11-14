#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

mkdir -p "$test_root/bin"
cat > "$test_root/bin/crane" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

unexpected() {
  echo "fake crane: unexpected call: crane $*" >&2
  exit 99
}

missing() {
  echo "Error: fetching manifest $1: GET https://registry.example/v2/manifests/${1##*:}: MANIFEST_UNKNOWN: manifest unknown" >&2
  exit 1
}

case "${1:-} $#" in
  "digest 2")
    jq -e -r --arg image "$2" '.[$image].digest // empty' "$FAKE_IMAGES" || missing "$2"
    ;;
  "config 4")
    [[ "$2 $3" == "--platform linux/amd64" ]] || unexpected "$@"
    if jq -e --arg image "$4" '.[$image].platforms // ["linux/amd64"] | index("linux/amd64") | not' "$FAKE_IMAGES" > /dev/null; then
      echo "Error: no child with platform linux/amd64 in index $4" >&2
      exit 1
    fi
    jq -e -c --arg image "$4" '.[$image] // empty | {config: {Volumes: (.volumes | map({(.): {}}) | add)}}' "$FAKE_IMAGES" \
      || missing "$4"
    ;;
  *) unexpected "$@" ;;
esac
EOF
chmod +x "$test_root/bin/crane"
export PATH="$test_root/bin:$PATH" FAKE_IMAGES="$test_root/images.json"

whoami_image() {
  sed -i -E "s|image: docker.io/traefik/whoami:.*|image: $2|" "$store/whoami/releases/$1/docker-compose.yml"
}

store=$(new_store)
BASE_REF=HEAD "$store/scripts/release.sh" whoami > /dev/null
commit "$store" "release 1"
write_release "$store/whoami/latest" v1.11.0 true
BASE_REF=HEAD "$store/scripts/release.sh" whoami > /dev/null
whoami_image 2 docker.io/traefik/whoami:v1.11.0
commit "$store" "release 2"

echo '{
  "docker.io/traefik/whoami:v1.10.1": {"digest": "sha256:1010", "volumes": ["/config/"]},
  "docker.io/traefik/whoami:v1.11.0": {"digest": "sha256:1110", "volumes": []}
}' > "$FAKE_IMAGES"
run "$store/scripts/check-images.sh"
assert_equal "passes when every image resolves and every VOLUME is mounted" "$status" 0

edit_json "$FAKE_IMAGES" 'del(.["docker.io/traefik/whoami:v1.11.0"])'
run "$store/scripts/check-images.sh"
assert_equal "fails when an image doesn't resolve" "$status" 1
assert_problem "names the app, the release and the image that doesn't resolve" "$output" "whoami release 2" \
  "docker.io/traefik/whoami:v1.11.0 doesn't resolve"
assert_equal "reports only the release whose image is missing" "$(grep -c '^error:' <<< "$output")" 1
edit_json "$FAKE_IMAGES" '.["docker.io/traefik/whoami:v1.11.0"] = {"digest": "sha256:1110", "volumes": []}'

for setting in "MODE|.compose.gpu|{\"MODE\":\"gpu\"}" "EXPORT_DIR|.compose|{\"EXPORT_DIR\":\"/var/mnt/external/check/EXPORT_DIR\"}"; do
  IFS='|' read -r key fragment values <<< "$setting"
  edit_json "$store/whoami/releases/2/settings.json" \
    "(.fields[] | select(.key == \"$key\") | $fragment.services.whoami.image) = \"docker.io/traefik/whoami:v1.11.0-$key\""
  run "$store/scripts/check-images.sh"
  assert_problem "checks the image the $key setting brings in" "$output" "whoami release 2" \
    "docker.io/traefik/whoami:v1.11.0-$key doesn't resolve (with $values)"
  git -C "$store" checkout -q -- whoami
done

edit_json "$FAKE_IMAGES" '.["docker.io/traefik/whoami:v1.10.1"].volumes += ["/data"]'
run "$store/scripts/check-images.sh"
assert_equal "fails when an image declares a VOLUME the service doesn't mount" "$status" 1
assert_problem "names the app, the release, the image and the VOLUME left unmounted" "$output" "whoami release 1" \
  "docker.io/traefik/whoami:v1.10.1 declares VOLUME /data, which service whoami doesn't mount (with {})"
assert_equal "reports an unmounted VOLUME once per release" "$(grep -c '^error:' <<< "$output")" 1

sed -i '/restart: unless-stopped/a\    tmpfs:\n      - /data:size=64m,mode=1777' "$store/whoami/releases/1/docker-compose.yml"
run "$store/scripts/check-images.sh"
assert_equal "counts a tmpfs mount with options as mounting the VOLUME" "$status" 0
git -C "$store" checkout -q -- whoami
edit_json "$FAKE_IMAGES" '.["docker.io/traefik/whoami:v1.10.1"].volumes -= ["/data"]'

edit_json "$FAKE_IMAGES" '.["docker.io/traefik/whoami:v1.11.0"].platforms = ["linux/arm64"]'
run "$store/scripts/check-images.sh"
assert_problem "fails naming an image that resolves but has no linux/amd64 build" "$output" "whoami release 2" \
  "docker.io/traefik/whoami:v1.11.0 doesn't resolve (with {}): Error: no child with platform linux/amd64"
edit_json "$FAKE_IMAGES" 'del(.["docker.io/traefik/whoami:v1.11.0"].platforms)'

echo 'services: [' > "$store/whoami/releases/2/docker-compose.yml"
run "$store/scripts/check-images.sh"
assert_equal "fails when a release doesn't render" "$status" 1
assert_problem "names the release that doesn't render" "$output" "whoami release 2" "doesn't render (with {})"
git -C "$store" checkout -q -- whoami

echo '{' > "$store/whoami/releases/2/settings.json"
run "$store/scripts/check-images.sh"
assert_equal "fails when a release's settings can't be read" "$status" 1
assert_problem "names the release whose settings can't be read" "$output" "whoami release 2" "settings.json"

finish_tests
