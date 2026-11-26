#!/usr/bin/env bash
set -euo pipefail

channel_dir=$1
tap_dir=$2
version=$(jq -er .version "$channel_dir/npm/package.json")
pack=$(cd "$channel_dir" && npm pack ./npm --json)
integrity=$(jq -er '.[0].integrity' <<< "$pack")
tarball=$(jq -er '.[0].filename' <<< "$pack")
registry=https://registry.npmjs.org
metadata="$channel_dir/registry.json"

status=$(curl -sS --retry 3 -o "$metadata" -w '%{http_code}' "$registry/tightbeam/$version")
case "$status" in
  404) npm publish "$channel_dir/$tarball" --registry "$registry" --access public --tag latest ;;
  200) jq -e --arg integrity "$integrity" '.dist.integrity == $integrity' "$metadata" >/dev/null ;;
  *) echo "npm release lookup failed (HTTP $status)" >&2; exit 1 ;;
esac

mkdir -p "$tap_dir/Formula"
cp "$channel_dir/tightbeam.rb" "$tap_dir/Formula/tightbeam.rb"
git -C "$tap_dir" add Formula/tightbeam.rb
if ! git -C "$tap_dir" diff --cached --quiet; then
  git -C "$tap_dir" -c user.name='github-actions[bot]' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m "Update Tightbeam to $version"
  git -C "$tap_dir" push origin HEAD:main
fi

# Read both public channels back. Compare the npm tarball integrity and the
# whole formula, including both platform URLs and digests.
curl -fsS --retry 6 --retry-all-errors "$registry/tightbeam/latest" |
  jq -e --arg version "$version" --arg integrity "$integrity" \
    '.version == $version and .dist.integrity == $integrity' >/dev/null
git -C "$tap_dir" fetch origin main
git -C "$tap_dir" show FETCH_HEAD:Formula/tightbeam.rb | cmp "$channel_dir/tightbeam.rb" -
