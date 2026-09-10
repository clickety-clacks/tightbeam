#!/bin/sh
set -eu

refuse_preflight() {
  printf 'tightbeam-gate-preflight: {"schema":"tightbeam-gate-preflight-refusal/v1","cause":"%s"}\n' "$1" >&2
  exit 78
}

command -v cargo >/dev/null 2>&1 || refuse_preflight cargo-unavailable
cargo --version >/dev/null 2>&1 || refuse_preflight cargo-unavailable

charmap=$(locale charmap 2>/dev/null) || refuse_preflight utf8-locale-unavailable
case "$charmap" in
  UTF-8 | UTF8) ;;
  *) refuse_preflight utf8-locale-unavailable ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tool_versions="$script_dir/../.tool-versions"
[ -r "$tool_versions" ] || refuse_preflight pinned-beam-unavailable
pinned_erlang=$(awk '$1 == "erlang" { print $2 }' "$tool_versions")
pinned_elixir_spec=$(awk '$1 == "elixir" { print $2 }' "$tool_versions")
[ -n "$pinned_erlang" ] && [ -n "$pinned_elixir_spec" ] ||
  refuse_preflight pinned-beam-unavailable
pinned_elixir=${pinned_elixir_spec%%-otp-*}
pinned_elixir_otp=${pinned_elixir_spec##*-otp-}

# The pin names an OTP release line the way source installs stamp OTP_VERSION
# (mise/asdf build 28.5 and stamp exactly "28.5"), while erlef/setup-beam on CI
# installs Erlang/OTP's binary patch releases, whose OTP_VERSION reads
# "28.5.0.5". Both are the pinned release. Nothing else is: the allowed
# boundary is the exact pin, or the pin extended by dot-separated NUMERIC
# components only — 28.4, 28.50, 28.5., 28.5.foo, 28.5..1, 28.5.1a all refuse.
erlang_matches_pin() {
  [ "$1" = "$pinned_erlang" ] && return 0
  case "$1" in
    "$pinned_erlang".*) ;;
    *) return 1 ;;
  esac
  suffix=${1#"$pinned_erlang".}
  case "$suffix" in
    '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
  esac
  return 0
}

beam_matches() {
  erlang_version=$("$@" erl -noshell -eval \
    'Root = code:root_dir(), Release = erlang:system_info(otp_release), {ok, Version} = file:read_file(filename:join([Root, "releases", Release, "OTP_VERSION"])), io:format("~s", [Version]), halt().' \
    2>/dev/null) || return 1
  elixir_output=$("$@" elixir --version 2>/dev/null) || return 1
  elixir_version=$(printf '%s\n' "$elixir_output" |
    sed -n 's/^Elixir \([^ ]*\) .*/\1/p')
  elixir_otp=$(printf '%s\n' "$elixir_output" |
    sed -n 's/^Elixir [^ ]* (compiled with Erlang\/OTP \([^)]*\)).*/\1/p')
  "$@" mix --version >/dev/null 2>&1 || return 1
  erlang_matches_pin "$erlang_version" &&
    [ "$elixir_version" = "$pinned_elixir" ] &&
    [ "$elixir_otp" = "$pinned_elixir_otp" ]
}

beam_runner=direct
if ! command -v erl >/dev/null 2>&1 ||
  ! command -v elixir >/dev/null 2>&1 ||
  ! command -v mix >/dev/null 2>&1 ||
  ! beam_matches; then
  command -v mise >/dev/null 2>&1 || refuse_preflight pinned-beam-unavailable
  beam_matches mise exec -- || refuse_preflight pinned-beam-unavailable
  beam_runner=mise
fi

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

# Every authoritative gate records the exact BEAM toolchain that executes it.
if [ "$beam_runner" = mise ]; then
  mise exec -- elixir --version
else
  elixir --version
fi

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
if [ "$beam_runner" = mise ]; then
  mise exec -- elixir --sname "$gate_node" -S mix test "$@"
else
  elixir --sname "$gate_node" -S mix test "$@"
fi
