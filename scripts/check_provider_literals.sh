#!/bin/sh
set -eu

root=${TIGHTBEAM_PROVIDER_SCAN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
expected="$root/priv/provider_literal_sites.txt"
temporary=$(mktemp "${TMPDIR:-/tmp}/tightbeam-provider-sites.XXXXXX")
trap 'rm -f "$temporary"' EXIT

cd "$root"

# Harness modules are the provider declaration zone. The companion integration
# bundle is every consumer outside that zone; file paths are stable edit sites.
grep -RlE '(:openai|:anthropic|"openai"|"anthropic"|'\''openai'\''|'\''anthropic'\'')' \
  lib config cli/src scripts/feature_smoke.exs docs/SMOKE.md \
  --exclude-dir=harness \
  --include='*.ex' \
  --include='*.exs' \
  --include='*.rs' \
  --include='*.md' |
  LC_ALL=C sort -u >"$temporary"

if [ "${1:-}" = "--print" ]; then
  cat "$temporary"
  exit 0
fi

if ! cmp -s "$expected" "$temporary"; then
  echo "provider-literal consumer inventory changed" >&2
  diff -u "$expected" "$temporary" >&2 || true
  exit 1
fi
