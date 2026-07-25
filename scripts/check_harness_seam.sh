#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

mechanics='CODEX_HOME|CLAUDE_CONFIG_DIR|codex-acp|claude-agent-acp|auth\.json|oauth-token|settings\.json|hooks\.json|CLAUDE_CODE_OAUTH_TOKEN|CODEX_CONFIG'
identity='==[[:space:]]*:(claude|codex)|case[[:space:]]+([[:alnum:]_]+\.)?harness[[:space:]]+do|\[:claude,[[:space:]]*:codex\]|\[:codex,[[:space:]]*:claude\]|\["claude",[[:space:]]*"codex"\]|\["codex",[[:space:]]*"claude"\]'

# Portable: grep -E / perl only — the test harness's System.cmd PATH carries no rg.
if grep -RnE "$mechanics" lib \
  --exclude-dir=harness \
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

if grep -RnE "$identity" lib config \
  --exclude-dir=harness
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
