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
TAR_METADATA_FLAGS=
if [ "$OS" = darwin ]; then
  # BSD tar records host metadata unless every class is disabled explicitly.
  TAR_METADATA_FLAGS="--no-mac-metadata --no-xattrs --no-acls --no-fflags"
fi

case "$ARCH" in aarch64) NPM_CPU=arm64 ;; x86_64) NPM_CPU=x64 ;; esac
OUT="_build/npm/tightbeam"
rm -rf _build/npm && mkdir -p "$OUT/bin"
# cli/Cargo.toml is the release version authority, but it is outside Mix's
# compiler inputs. Without an explicit project clean, changing only that file
# can leave _build/prod/lib/tightbeam-<old> in place and `mix release
# --overwrite` will faithfully repackage the stale application. Clean only the
# application (dependencies remain cached), then build the release whose
# version was read above.
MIX_ENV=prod mix clean
MIX_ENV=prod mix release tightbeam_gateway --overwrite --quiet
cargo build --release --manifest-path cli/Cargo.toml
cp cli/target/release/tightbeam "$OUT/bin/tightbeam"
cp packaging/tightbeam-gateway "$OUT/bin/tightbeam-gateway"
cp packaging/tightbeam-select "$OUT/bin/tightbeam-select"
cp -R _build/prod/rel/tightbeam_gateway "$OUT/release"

# Only a tagged GitHub release carries automatic live-base adoption authority.
# Branch/work-tree packages intentionally omit this file, so their unmarked-base
# boot still takes the existing explicit-transition refusal path. The runtime
# validates this exact provenance beside the published release payload; version,
# MIX_ENV, package layout, and operator flags cannot substitute for it.
if [ "${GITHUB_REF_TYPE:-}" = "tag" ] || case "${GITHUB_REF:-}" in refs/tags/v*) true ;; *) false ;; esac; then
  provenance_tag="${GITHUB_REF_NAME:-}"
  provenance_commit="${CI_SOURCE_SHA:-${GITHUB_SHA:-}}"
  provenance_repository="${GITHUB_REPOSITORY:-}"

  case "$provenance_tag" in v*) ;; *) echo "packaging: tagged release is missing GITHUB_REF_NAME." >&2; exit 1 ;; esac
  if ! printf '%s' "$provenance_commit" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "packaging: tagged release requires a full lower-case CI source SHA." >&2
    exit 1
  fi
  if [ "$provenance_repository" != "clickety-clacks/tightbeam" ]; then
    echo "packaging: tagged release provenance repository is not clickety-clacks/tightbeam." >&2
    exit 1
  fi

  jq -n -S \
    --arg format "tightbeam-release-provenance/v1" \
    --arg repository "$provenance_repository" \
    --arg tag "$provenance_tag" \
    --arg commit "$provenance_commit" \
    '{commit: $commit, format: $format, repository: $repository, tag: $tag}' \
    > "$OUT/release-provenance.json"
fi
sed "s/\"name\": \"tightbeam\"/\"name\": \"tightbeam\",\n  \"version\": \"$VERSION\",\n  \"os\": [\"$OS\"],\n  \"cpu\": [\"$NPM_CPU\"]/" packaging/package.json > "$OUT/package.json"
ARTIFACT="_build/npm/tightbeam-$VERSION-$OS-$ARCH.tgz"
elixir packaging/payload-manifest.exs generate "$OUT"
TEMP_ARTIFACT="$ARTIFACT.tmp.$$"
trap 'rm -f "$TEMP_ARTIFACT"' EXIT HUP INT TERM
(cd _build/npm && tar $TAR_METADATA_FLAGS -czf "$(basename "$TEMP_ARTIFACT")" tightbeam)
sh packaging/finalize-artifact.sh "$TEMP_ARTIFACT" "$ARTIFACT" "$VERSION"
echo "artifact: $ARTIFACT"
