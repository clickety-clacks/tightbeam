#!/bin/sh
set -eu

# The authoritative Mix gate can run inside a Tightbeam session, whose process
# environment belongs to the live release.  A source test run must not inherit
# that release's base directory, endpoint, node identity, or ERTS paths.
for name in $(
  env | sed -n \
    -e 's/^\(TIGHTBEAM_[A-Za-z0-9_]*\)=.*/\1/p' \
    -e 's/^\(RELEASE_[A-Za-z0-9_]*\)=.*/\1/p'
); do
  unset "$name"
done
unset ROOTDIR BINDIR

# mktemp owns uniqueness across concurrent invocations.  The directory lives
# for the whole run, so another gate cannot reuse this node name while it is
# active.  `--sname` is an argv option on this VM only; exporting ERL_FLAGS or
# ELIXIR_ERL_OPTIONS would leak the name into child BEAMs spawned by tests.
gate_marker=$(mktemp -d "${TMPDIR:-/tmp}/tightbeam-mix-gate.XXXXXXXX")
trap 'rmdir "$gate_marker" 2>/dev/null || :' EXIT HUP INT TERM
gate_node="tightbeam_mix_gate_${gate_marker##*.}"

export TIGHTBEAM_AUTHORITATIVE_GATE=1
export TIGHTBEAM_GATE_NODE="$gate_node"
export TIGHTBEAM_PORT=0

printf 'Authoritative Mix gate: node=%s port=0\n' "$gate_node"
elixir --sname "$gate_node" -S mix test "$@"
