#!/bin/sh
# Assemble the per-platform npm tarball. Run ON the target platform (no cross-compiling):
#   sh packaging/assemble.sh
# Produces tightbeam-<version>-<os>-<arch>.tgz installable via `npm install <file>`.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(grep -oE '^version = "[^"]+"' cli/Cargo.toml | cut -d'"' -f2)
OS=$(uname -s | tr 'A-Z' 'a-z'); ARCH=$(uname -m); [ "$ARCH" = arm64 ] && ARCH=aarch64
OUT="_build/npm/tightbeam"
rm -rf _build/npm && mkdir -p "$OUT/bin"
MIX_ENV=prod mix release tightbeam_gateway --overwrite --quiet
cargo build --release --manifest-path cli/Cargo.toml
cp cli/target/release/tightbeam "$OUT/bin/tightbeam"
cp packaging/tightbeam-gateway "$OUT/bin/tightbeam-gateway"
cp -R _build/prod/rel/tightbeam_gateway "$OUT/release"
sed "s/\"name\": \"tightbeam\"/\"name\": \"tightbeam\",\n  \"version\": \"$VERSION\",\n  \"os\": [\"$OS\"],\n  \"cpu\": [\"$([ $ARCH = aarch64 ] && echo arm64 || echo x64)\"]/" packaging/package.json > "$OUT/package.json"
(cd _build/npm && tar czf "tightbeam-$VERSION-$OS-$ARCH.tgz" tightbeam)
echo "artifact: _build/npm/tightbeam-$VERSION-$OS-$ARCH.tgz"
