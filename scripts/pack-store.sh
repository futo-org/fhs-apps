#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  echo "usage: $0 <out>" >&2
  exit 2
fi

out=$(realpath -m "$1")
cd "$(dirname "$0")/.."

tar --version | grep -q 'GNU tar' || {
  echo "GNU tar is required" >&2
  exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
apps=$(jq -r '.apps[].id' catalog.json)
{
  echo catalog.json
  echo scripts/generate-compose.sh
  for app in $apps; do
    echo "$app/manifest.json"
    find "$app/releases" -type f
  done
} > "$work/list"

files=$(LC_ALL=C sort -u "$work/list")
mapfile -t paths <<< "$files"
unpacked=$((512 * ${#paths[@]} + $(du -cb "${paths[@]}" | tail -1 | cut -f1)))
if ((unpacked > 67108864)); then
  echo "$out: unpacks to $unpacked bytes, over the agent's limit of 67108864 bytes" >&2
  exit 1
fi

packed=$(mktemp "$out.XXXXXX")
trap 'rm -rf "$work" "$packed"' EXIT
tar --create --format=ustar --no-recursion --verbatim-files-from --files-from=- \
  --owner=0 --group=0 --numeric-owner --mtime=@0 --mode=u=rwX,go=rX <<< "$files" \
  | gzip -n > "$packed"

size=$(stat -c %s "$packed")
if ((size > 1048576)); then
  echo "$out: $size bytes, over the agent's limit of 1048576 bytes" >&2
  exit 1
fi

chmod 0644 "$packed"
mv "$packed" "$out"
echo "$out: $size bytes, ${#paths[@]} files, unpacks to $unpacked bytes"
