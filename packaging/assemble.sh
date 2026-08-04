#!/bin/sh
# Assemble the per-platform npm tarball. Run ON the target platform (no cross-compiling):
#   sh packaging/assemble.sh
# Produces tightbeam-<version>-<os>-<arch>.tgz installable via `npm install <file>`.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(grep -oE '^version = "[^"]+"' cli/Cargo.toml | cut -d'"' -f2)
OS=$(uname -s | tr 'A-Z' 'a-z'); ARCH=$(uname -m); [ "$ARCH" = arm64 ] && ARCH=aarch64

# REFUSE AN UNSUPPORTED PLATFORM BY NAME. The ruling is darwin-arm64 and linux-x64 only.
# This used to map every non-aarch64 machine to npm's "x64" and build anyway, so a
# linux-arm64 box produced a package labelled x64 — npm would then happily install a
# binary that cannot run there. An unsupported platform is dirt to report, not a default
# to fall back on.
case "$OS-$ARCH" in
  darwin-aarch64|linux-x86_64) ;;
  *)
    echo "packaging: unsupported platform $OS-$ARCH." >&2
    echo "Supported: darwin-aarch64 (Apple silicon) and linux-x86_64." >&2
    echo "The package bundles a compiled runtime and CLI, so it must be built on the" >&2
    echo "platform it will run on. Build this one on a supported machine." >&2
    exit 1
    ;;
esac
case "$ARCH" in aarch64) NPM_CPU=arm64 ;; x86_64) NPM_CPU=x64 ;; esac
OUT="_build/npm/tightbeam"
rm -rf _build/npm && mkdir -p "$OUT/bin"
MIX_ENV=prod mix release tightbeam_gateway --overwrite --quiet
cargo build --release --manifest-path cli/Cargo.toml
cp cli/target/release/tightbeam "$OUT/bin/tightbeam"
cp packaging/tightbeam-gateway "$OUT/bin/tightbeam-gateway"
cp -R _build/prod/rel/tightbeam_gateway "$OUT/release"
sed "s/\"name\": \"tightbeam\"/\"name\": \"tightbeam\",\n  \"version\": \"$VERSION\",\n  \"os\": [\"$OS\"],\n  \"cpu\": [\"$NPM_CPU\"]/" packaging/package.json > "$OUT/package.json"
(cd _build/npm && tar czf "tightbeam-$VERSION-$OS-$ARCH.tgz" tightbeam)
echo "artifact: _build/npm/tightbeam-$VERSION-$OS-$ARCH.tgz"
