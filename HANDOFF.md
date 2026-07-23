# CLI lane handoffs

## Clause 11 — direct dependency limit

`cli/Cargo.toml` is outside the CLI lane's owned paths and still declares
`libc = "0.2"`. The dependency is used directly by `cli/src/contain.rs` for
process-group and signal operations, which is also outside this lane. A
Cargo/containment owner must either replace those calls using only the two
dependencies permitted by `cli-rust-v1.md` and remove `libc`, or obtain and
record a governing-spec amendment that permits `libc`.

## Clauses 1, 57, and 66 — executable-level `rail-exec` command

`cli/src/main.rs` is outside this lane's owned paths and intercepts `rail-exec`
before `args::parse`, so the parser cannot make that command produce the
TypeScript reference's canonical unknown-command error. The executable owner
must remove the `rail-exec` interception from `main.rs` (and adjudicate the
resulting `contain` module reachability), then add a real-binary test that runs
`tightbeam rail-exec` and asserts the exact canonical unknown-command stderr
and exit status 1.

## Mandatory clippy gate — unreachable legacy `init` and `probe` modules

`cli/src/main.rs`, `cli/src/ceremonies.rs`, and `cli/src/probe.rs` are outside
this lane's owned paths. The v1 command surface intentionally does not expose
the later `init` and `probe` commands, but `main.rs` still compiles both legacy
modules. Removing the rejected discarded-function-pointer suppression from
`dispatch::run` exposes dead-code errors throughout those modules under
`cargo clippy -- -D warnings`. The executable/module owner must stop compiling
the non-v1 modules (while preserving the v1 `setup` and `assimilate` ceremony
paths), or obtain a governing-spec amendment that makes their behavior
reachable; lint suppression or unused function-pointer references are not an
acceptable close.

## Tagged CLI integration suite versus clauses 1, 10, 14, 19, 36, 57, and 66

`test/cli_integration_test.exs` is outside this lane and requires
`.tightbeam-session` identity discovery plus assignment, producer, and work-item
verbs. Those expectations directly conflict with the governing v1 spec's
TypeScript-normative discovery, exactly-one explicit identity, canonical command
set, and no-new-verbs requirements. The spec/test owner must adjudicate the
source of truth and then either update the tagged integration suite to the v1
CLI surface or amend `cli-rust-v1.md` before those tests can be made compatible.
