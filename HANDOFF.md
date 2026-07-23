# CLI lane handoffs

## Clause 11 — direct dependency limit

`cli/Cargo.toml` is outside the CLI lane's owned paths and still declares
`libc = "0.2"`. The dependency is used directly by `cli/src/contain.rs` for
process-group and signal operations, which is also outside this lane. A
Cargo/containment owner must either replace those calls using only the two
dependencies permitted by `cli-rust-v1.md` and remove `libc`, or obtain and
record a governing-spec amendment that permits `libc`.

## Tagged CLI integration suite versus clauses 1, 10, 14, 19, 36, 57, and 66

`test/cli_integration_test.exs` is outside this lane and requires
`.tightbeam-session` identity discovery plus assignment, producer, and work-item
verbs. Those expectations directly conflict with the governing v1 spec's
TypeScript-normative discovery, exactly-one explicit identity, canonical command
set, and no-new-verbs requirements. The spec/test owner must adjudicate the
source of truth and then either update the tagged integration suite to the v1
CLI surface or amend `cli-rust-v1.md` before those tests can be made compatible.
