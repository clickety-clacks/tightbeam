#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

mechanics='CODEX_HOME|CLAUDE_CONFIG_DIR|codex-acp|claude-agent-acp|auth\.json|\.credentials\.json|settings\.json|hooks\.json|CLAUDE_CODE_OAUTH_TOKEN|CODEX_CONFIG'
# A bare harness NAME in executable code is a seam break on its own, not only
# in pairs: a default like `Keyword.get(opts, :harness, "claude")` silently
# pins one harness and survives a registry change (found by cross-review of
# the client-e2e driver). Quoted or atom form, anywhere outside the registry.
identity='==[[:space:]]*:(claude|codex)|case[[:space:]]+([[:alnum:]_]+\.)?harness[[:space:]]+do|\[:claude,[[:space:]]*:codex\]|\[:codex,[[:space:]]*:claude\]|\["claude",[[:space:]]*"codex"\]|\["codex",[[:space:]]*"claude"\]|"(claude|codex)"|(^|[^[:alnum:]_:]):(claude|codex)([^[:alnum:]_]|$)'

# Portable: grep -E / perl only — the test harness's System.cmd PATH carries no rg.
if grep -RnE "$mechanics" lib \
  --exclude-dir=harness \
  --exclude-dir=pi_provider \
  --exclude=credentials.ex \
  --exclude=rails.ex
then
  echo "harness mechanic literal escaped Tightbeam.Harness.*" >&2
  exit 1
fi

# rails.ex carries parity-pinned historical mechanics in its documentation.
# Strip documentation and scan the executable remainder so the documentation
# carve-out cannot hide an implementation literal.
if perl -0777 -pe 's/\@(moduledoc|doc)\s+""".*?"""//sg' lib/tightbeam/rails.ex |
  grep -nE "$mechanics"
then
  echo "harness mechanic literal escaped into rails implementation" >&2
  exit 1
fi

# credentials.ex owns the provider<->harness naming (same carve-out the
# mechanics scan gives it: it IS the credential store, and the store's paths
# are named per harness by definition).
if grep -RnE "$identity" lib config \
  --exclude-dir=harness \
  --exclude=credentials.ex
then
  echo "harness identity dispatch or list escaped the registry" >&2
  exit 1
fi

if perl -0777 -ne 'exit 0 if /Homes\.home_path\([^)]*\).{0,240}File\.(write!?|ln_s!?|rm)/s; exit 1' \
  lib/tightbeam/credentials.ex
then
  echo "credentials writes a harness home outside reconcile_home/3" >&2
  exit 1
fi

if grep -nE 'case .*harness|if .*harness|unless .*harness|harness[[:space:]]*==' \
  test/harness_conformance_test.exs
then
  echo "shared harness conformance suite contains a harness branch" >&2
  exit 1
fi

"$root/scripts/check_provider_literals.sh"
