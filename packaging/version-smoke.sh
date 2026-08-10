#!/bin/sh
# Refuse a package whose compiled CLI and gateway do not carry the advertised
# release version. This runs against the tarball, not the staging directory, so
# the exact bytes handed to npm are the bytes that prove the handshake.
set -eu

ARTIFACT=${1:?usage: version-smoke.sh <artifact.tgz> <expected-version>}
EXPECTED=${2:?usage: version-smoke.sh <artifact.tgz> <expected-version>}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

tar xzf "$ARTIFACT" -C "$TMP"
ROOT="$TMP/tightbeam"
if [ ! -f "$ROOT/package.json" ]; then
  echo "packaging: extracted artifact has no package.json" >&2
  exit 1
fi

MANIFEST_VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/package.json" | head -n 1)
CLI_VERSION=$("$ROOT/bin/tightbeam" --version)
GATEWAY_VERSION=$(awk 'NF >= 2 { print $2; exit }' "$ROOT/release/releases/start_erl.data")

if [ "$MANIFEST_VERSION" != "$EXPECTED" ]; then
  echo "packaging: manifest version ${MANIFEST_VERSION:-missing} does not match package version $EXPECTED" >&2
  exit 1
fi

if [ "$CLI_VERSION" != "$EXPECTED" ]; then
  echo "packaging: CLI version $CLI_VERSION does not match package version $EXPECTED" >&2
  exit 1
fi

if [ "$GATEWAY_VERSION" != "$EXPECTED" ]; then
  echo "packaging: gateway version $GATEWAY_VERSION does not match package version $EXPECTED" >&2
  exit 1
fi

echo "version smoke: manifest=$MANIFEST_VERSION cli=$CLI_VERSION gateway=$GATEWAY_VERSION"
