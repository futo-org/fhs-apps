#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=testing.sh
source "$(dirname "$0")/testing.sh"

entry_attributes() {
  tar --numeric-owner --utc -tvzf "$1" | awk '{print $1, $2, $4, $5}' | sort -u
}

store=$(new_store)
BASE_REF=HEAD "$store/scripts/release.sh" whoami > /dev/null
cp "$scripts_dir/pack-store.test.sh" "$store/scripts/"
commit "$store" "release 1"

run "$store/scripts/pack-store.sh" "$test_root/first.tar.gz"
assert_equal "packs the store" "$status" 0
assert_equal "packs the catalog, each manifest and release and the renderer, by path from the store root" \
  "$(tar -tzf "$test_root/first.tar.gz")" \
  "catalog.json
scripts/generate-compose.sh
whoami/manifest.json
whoami/releases/1/data/config/.gitkeep
whoami/releases/1/docker-compose.yml
whoami/releases/1/health-check.sh
whoami/releases/1/release.json
whoami/releases/1/settings.json"
assert_equal "packs regular files owned by root at a fixed time" "$(entry_attributes "$test_root/first.tar.gz")" \
  "-rw-r--r-- 0/0 1970-01-01 00:00
-rwxr-xr-x 0/0 1970-01-01 00:00"

copy=$(mktemp -d "$test_root/copy.XXXXXX")
cp -r "$store/." "$copy"
find "$copy" -exec touch -d 2001-02-03T04:05:06 {} +
chmod -R g+w "$copy"
"$copy/scripts/pack-store.sh" "$test_root/copy.tar.gz" > /dev/null
assert_equal "packs the same store into the same bytes, whatever the file times and group bits" \
  "$(cmp "$test_root/first.tar.gz" "$test_root/copy.tar.gz" && echo same)" same

edit_json "$store/catalog.json" '.apps += .apps'
"$store/scripts/pack-store.sh" "$test_root/twice.tar.gz" > /dev/null
assert_equal "packs each path once when the catalog lists an app twice" \
  "$(tar -tzf "$test_root/twice.tar.gz" | sort | uniq -d)$(entry_attributes "$test_root/twice.tar.gz" | cut -c1 | sort -u)" "-"
git -C "$store" checkout -q -- catalog.json

openssl enc -aes-128-ctr -nosalt -K 00000000000000000000000000000000 -iv 00000000000000000000000000000000 \
  -in <(head -c 1100000 /dev/zero) -out "$store/whoami/releases/1/data/config/noise"
run "$store/scripts/pack-store.sh" "$test_root/big.tar.gz"
assert_equal "refuses a store over the agent's download limit, naming both sizes" \
  "$status $(sed -E 's/ [0-9]{7} bytes,/ N bytes,/' <<< "$output")" \
  "1 $test_root/big.tar.gz: N bytes, over the agent's limit of 1048576 bytes"
assert_equal "leaves no store behind when it's too big" "$([[ -e "$test_root/big.tar.gz" ]] || echo absent)" absent
rm "$store/whoami/releases/1/data/config/noise"

for broken in "catalog.json|{" "whoami/releases|"; do
  IFS='|' read -r path content <<< "$broken"
  rm -rf "${store:?}/$path"
  [[ -z "$content" ]] || printf '%s' "$content" > "$store/$path"
  rm -f "$test_root/broken.tar.gz"
  run "$store/scripts/pack-store.sh" "$test_root/broken.tar.gz"
  assert_equal "fails and leaves no store behind when $path can't be read" \
    "$((status > 0)) $([[ -e "$test_root/broken.tar.gz" ]] || echo absent)" "1 absent"
  git -C "$store" checkout -q -- "$path"
done

truncate -s 64M "$store/whoami/releases/1/data/config/zeros"
run "$store/scripts/pack-store.sh" "$test_root/huge.tar.gz"
assert_equal "refuses a store that unpacks past the agent's limit, naming both sizes" \
  "$status $(sed -E 's/ [0-9]{8} bytes,/ N bytes,/' <<< "$output")" \
  "1 $test_root/huge.tar.gz: unpacks to N bytes, over the agent's limit of 67108864 bytes"
rm "$store/whoami/releases/1/data/config/zeros"

finish_tests
