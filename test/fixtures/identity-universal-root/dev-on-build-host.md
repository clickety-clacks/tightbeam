# Dev runs on build-host (mike, 2026-08-22; org-local)

Development and verification work runs on **build-host**. It has the full toolchain:
elixir 1.19.5 and mix on OTP 28 via mise, pinned by the repo's own `.tool-versions`,
plus cargo for the release CLI, and 32 cores. The tools are absent from a bare
non-interactive PATH, which is why they can look missing: use `mise exec -- mix ...`
or prepend `$HOME/.local/share/mise/shims` (and `$HOME/.cargo/bin`) to PATH.

Two mechanics that make a gate run honest here. The suite REFUSES to run without
`cli/target/release/tightbeam`, so build it first:
`cargo build --release --manifest-path cli/Cargo.toml`. And never run a gate in the
shared checkout at `~/src/tightbeam` — it carries other agents' uncommitted work and
drifts behind origin. Run in a throwaway `git worktree` at the tip you are gating,
and record baseline+after counts from that run.

Any older guidance saying build-host lacks elixir/mix, or that gates must run on mac-runner,
is superseded by this section.
