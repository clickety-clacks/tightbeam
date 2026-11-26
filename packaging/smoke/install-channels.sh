#!/usr/bin/env bash
set -euo pipefail

repo=clickety-clacks/tightbeam
target=${TARGET_TAG:-$(gh api "repos/$repo/releases/latest" --jq .tag_name)}
previous=${PREVIOUS_TAG:?Set PREVIOUS_TAG to a published predecessor}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

for tag in "$previous" "$target"; do
  gh release download "$tag" --repo "$repo" --dir "$scratch/$tag" --pattern SHA256SUMS
  node packaging/prepare-install-channels.mjs "$tag" "$scratch/$tag/SHA256SUMS" "$scratch/$tag"
  ruby -c "$scratch/$tag/tightbeam.rb"
done

mkdir "$scratch/home"
tarball=$(npm pack "$scratch/$target/npm" --pack-destination "$scratch" --silent)
export TIGHTBEAM_BASE_DIR="$scratch/state"
if HOME="$scratch/home" npx --yes --package "$scratch/$tarball" tightbeam --mode quick --dry-run >"$scratch/npx.log" 2>&1; then
  cat "$scratch/npx.log"
else
  cat "$scratch/npx.log"
  # Published releases predating setup can prove install and invocation only.
  case "$target" in
    v0.1.15+*|v0.1.16+*|v0.1.17+*) grep -F 'unknown command: setup' "$scratch/npx.log" ;;
    *) exit 1 ;;
  esac
fi
binary=$(find "$scratch/home/.local/share/tightbeam-install" -path '*/bin/tightbeam' -type f)
npm_source="$(dirname "$binary")/../tightbeam-install-source.json"
jq -e --arg tag "$target" '.tag == $tag' "$npm_source"
release_version=${target#v}
"$binary" --version | grep -F "${release_version%%+*}"

cat > "$scratch/corrupt.mjs" <<'JS'
const request = globalThis.fetch;
globalThis.fetch = async (url, ...args) => {
  const response = await request(url, ...args);
  if (!String(url).endsWith('/SHA256SUMS') || !response.ok) return response;
  return new Response((await response.text()).replace(/^[a-f0-9]{64}/gm, '0'.repeat(64)));
};
JS
mkdir "$scratch/mismatch-home"
if HOME="$scratch/mismatch-home" NODE_OPTIONS="--import=$scratch/corrupt.mjs" \
    npx --yes --package "$scratch/$tarball" tightbeam --mode quick --dry-run >"$scratch/mismatch.log" 2>&1; then
  echo "npx accepted mismatched bytes" >&2
  exit 1
fi
cat "$scratch/mismatch.log"
grep -F 'SHA-256 mismatch' "$scratch/mismatch.log"
test -z "$(find "$scratch/mismatch-home/.local/share/tightbeam-install" -mindepth 1 -print -quit)"

tap=local/install-smoke
formula="$tap/tightbeam"
git init -q -b main "$scratch/tap"
mkdir "$scratch/tap/Formula"
update_tap() {
  cp "$scratch/$1/tightbeam.rb" "$scratch/tap/Formula/tightbeam.rb"
  git -C "$scratch/tap" add Formula/tightbeam.rb
  git -C "$scratch/tap" -c user.name=CI -c user.email=ci@example.invalid commit -qm "$1"
}
update_tap "$previous"
brew tap --custom-remote "$tap" "$scratch/tap"
brew install "$formula"
brew test "$formula"
old_prefix=$(brew --prefix --installed "$formula")
update_tap "$target"
git -C "$(brew --repo "$tap")" pull --ff-only
brew upgrade "$formula"
brew test "$formula"
new_prefix=$(brew --prefix --installed "$formula")
test "$old_prefix" != "$new_prefix"
jq -e --slurpfile npm "$npm_source" '. == $npm[0]' "$new_prefix/libexec/tightbeam-install-source.json"
"$new_prefix/bin/tightbeam" --version | grep -F "${release_version%%+*}"

ruby -pi -e 'gsub(/sha256 "[a-f0-9]{64}"/, "sha256 \"" + "0" * 64 + "\"")' \
  "$(brew --repo "$tap")/Formula/tightbeam.rb"
if brew fetch --force "$formula" >"$scratch/brew-mismatch.log" 2>&1; then
  echo "Homebrew accepted mismatched bytes" >&2
  exit 1
fi
cat "$scratch/brew-mismatch.log"
grep -Ei 'SHA256 mismatch|checksum mismatch' "$scratch/brew-mismatch.log"
