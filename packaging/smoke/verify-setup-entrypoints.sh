#!/usr/bin/env bash
# Shared by the hosted candidate, installer smoke and public readback.
prepare_setup_smoke() {
  local scratch=$1
  mkdir -p "$scratch/harness-bin"
  # Setup checks for a harness on PATH even when it only prints the plan.
  printf '#!/bin/sh\nexit 0\n' > "$scratch/harness-bin/claude"
  chmod +x "$scratch/harness-bin/claude"
  export PATH="$scratch/harness-bin:$PATH"

  if [ "$(uname -s)" = Linux ] && ! systemctl --user show-environment >/dev/null 2>&1; then
    if [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then
      echo 'Installer smoke needs an active systemd user manager.' >&2
      return 1
    fi
    sudo systemctl start "user@$(id -u).service"
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    systemctl --user show-environment >/dev/null
  fi
}

assert_setup_plan() {
  local log=$1 base=$2
  grep -F -- '- Start a local-only Tightbeam user service' "$log"
  if grep -Fxq 'Install yes or no' "$log"; then
    echo 'Setup dry-run prompted for installation.' >&2
    return 1
  fi
  test ! -e "$base"
}

verify_brew_setup() {
  local prefix=$1 scratch=$2 node_bin
  node_bin="$(brew --prefix node)/bin"
  PATH="$node_bin:$PATH" node --version
  PATH="$node_bin:$PATH" node -e 'process.exit(Number(process.versions.node.split(".")[0]) < 24 ? 1 : 0)'
  mkdir -p "$scratch/brew-home"
  HOME="$scratch/brew-home" TIGHTBEAM_BASE_DIR="$scratch/brew-state" PATH="$node_bin:$PATH" \
    "$prefix/bin/tightbeam" setup --mode quick --dry-run >"$scratch/brew-setup.log"
  assert_setup_plan "$scratch/brew-setup.log" "$scratch/brew-state"
}

verify_setup_stamp() {
  local payload=$1 tag=$2 commit=$3
  jq -e --arg tag "$tag" --arg commit "$commit" \
    '.tag == $tag and .commit == $commit' "$payload/setup-build.json" >/dev/null
}

verify_npx_setup() {
  local package=$1 scratch=$2 tag=$3 commit=$4 binary
  mkdir -p "$scratch/npm-home"
  HOME="$scratch/npm-home" TIGHTBEAM_BASE_DIR="$scratch/npm-state" \
    npx --yes --package "$package" tightbeam --mode quick --dry-run >"$scratch/npm-setup.log"
  assert_setup_plan "$scratch/npm-setup.log" "$scratch/npm-state"
  binary=$(find "$scratch/npm-home/.local/share/tightbeam-install" -path '*/bin/tightbeam' -type f)
  verify_setup_stamp "$(dirname "$(dirname "$binary")")" "$tag" "$commit"
}

verify_public_setup_entrypoints() (
  set -euo pipefail
  local manifest=$1 commit=$2 scratch version tag formula=clickety-clacks/tap/tightbeam prefix
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  jq -e '.engines.node == ">=24"' "$manifest" >/dev/null
  version=$(jq -er .version "$manifest")
  tag=$(jq -er .tightbeamRelease "$manifest")
  prepare_setup_smoke "$scratch"
  verify_npx_setup "tightbeam@$version" "$scratch" "$tag" "$commit"
  brew install "$formula"
  prefix=$(brew --prefix --installed "$formula")
  verify_setup_stamp "$prefix/libexec" "$tag" "$commit"
  verify_brew_setup "$prefix" "$scratch"
)

verify_staged_setup_entrypoints() (
  set -euo pipefail
  local stage=$1 scratch tag commit tarball prefix tap=local/setup-candidate
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  tag=$(jq -er .tag "$stage/release-provenance.json")
  commit=$(jq -er .commit "$stage/release-provenance.json")
  prepare_setup_smoke "$scratch"
  node packaging/prepare-install-channels.mjs "$tag" "$stage/SHA256SUMS" "$scratch"
  jq -e '.engines.node == ">=24"' "$scratch/npm/package.json" >/dev/null
  tarball=$(npm pack "$scratch/npm" --pack-destination "$scratch" --silent)

  # Serve staged bytes at the installer's expected URLs without a public release.
  # The launcher still parses SHA256SUMS, verifies the archive and runs setup.
  cat >"$scratch/staged-downloads.mjs" <<'JS'
import { openAsBlob } from 'node:fs';
import { join } from 'node:path';
const prefix = 'https://github.com/clickety-clacks/tightbeam/releases/download/' +
  encodeURIComponent(process.env.STAGED_RELEASE_TAG) + '/';
const request = globalThis.fetch;
globalThis.fetch = async (url, ...args) => {
  const address = String(url);
  if (!address.startsWith(prefix)) return request(url, ...args);
  const asset = address.slice(prefix.length);
  if (!/^(SHA256SUMS|tightbeam-[a-z0-9_.-]+\.tgz)$/.test(asset)) {
    throw new Error('Unexpected staged asset: ' + asset);
  }
  return new Response(await openAsBlob(join(process.env.STAGED_RELEASE_DIR, asset)));
};
JS
  STAGED_RELEASE_TAG="$tag" STAGED_RELEASE_DIR="$stage" NODE_OPTIONS="--import=$scratch/staged-downloads.mjs" \
    verify_npx_setup "$scratch/$tarball" "$scratch" "$tag" "$commit"

  # Keep the generated formula and archive hashes, replacing only asset URLs.
  mkdir -p "$scratch/tap/Formula"
  node --input-type=module - "$stage" "$scratch/tightbeam.rb" >"$scratch/tap/Formula/tightbeam.rb" <<'JS'
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [stage, formula] = process.argv.slice(2);
process.stdout.write(readFileSync(formula, 'utf8').replace(
  /https:\/\/github\.com\/clickety-clacks\/tightbeam\/releases\/download\/[^/"]+\/([^/"]+)/g,
  (_, asset) => pathToFileURL(join(stage, asset)).href
));
JS
  git init -q -b main "$scratch/tap"
  git -C "$scratch/tap" add Formula/tightbeam.rb
  git -C "$scratch/tap" -c user.name=CI -c user.email=ci@example.invalid commit -qm 'Stage candidate formula'
  brew tap --custom-remote "$tap" "$scratch/tap"
  brew install "$tap/tightbeam"
  prefix=$(brew --prefix --installed "$tap/tightbeam")
  verify_setup_stamp "$prefix/libexec" "$tag" "$commit"
  verify_brew_setup "$prefix" "$scratch"
)
