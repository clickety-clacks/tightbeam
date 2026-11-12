# Proof-of-done r4 verification

## Result and exact subject

This report describes the proof-of-done r4 implementation and its scoped verification.

The implementation follows the proof-of-done behavior and adds local-file artifact capture. Exact source identities and complete run records are kept with the private verification evidence.

## Implemented

- Added domain-blind proof facts and r4 verification rules, with effect-based completion and results requirements in the engineering kungfu rules.
- Kept completion behavior aligned with the bound proof-of-done rules; the focused completion coverage exercises the worker and opener paths.
- Added `artifact-record --content-file <local-path>`. The CLI reads ordinary bytes locally and places their standard Base64 encoding in the existing `contentBase64` request field. `--content-file` and `--content-base64` are mutually exclusive; empty paths and unreadable files are refused before a request is sent. Payload bytes are not placed in argv.
- Added coverage for the fact/rule behavior, the worker-versus-opener completion case, and file capture including non-UTF-8 bytes, empty and missing files, conflicting inputs, digest refusal, and retrieval after the source file changes.

The source delta from the requested base is limited to `cli/src/args.rs`, `cli/src/dispatch.rs`, `lib/tightbeam/assignments.ex`, `lib/tightbeam/rules.ex`, the two affected engineering kungfu rule files, and their tests. The test-only fixture adjustment is in `test/refix_requires_diagnosis_test.exs`.

## Producer verification

All test commands below ran in an isolated scratch checkout with the repository's canonical Mix wrapper where applicable. The checked-in tool pins are Erlang/OTP `28.5` and Elixir `1.19.5-otp-28`.

| Subject and command | Result |
| --- | --- |
| Focused rules and assignment tests using the canonical wrapper | 227 tests, 0 failures. The affected source files were unchanged by later CLI-only edits. |
| Focused CLI file-capture test using the canonical wrapper | 1 test, 0 failures (37 excluded). It exercises ordinary file capture through the CLI with a large binary input containing NUL and non-UTF-8 bytes. |
| CLI release build on the implementation source | Succeeded. Rust/Cargo: `rustc 1.99.1`, `cargo 1.99.1`; build emitted 15 warnings, including an unused `catalog` function. |
| Draft policy test using the canonical wrapper | 1 test, 1 failure before reaching policy assertions: the fixture lacked required metadata. The fixture was corrected in the final test source; this draft result is not a product-rule failure. |
| Final policy test using the canonical wrapper | 1 test, 0 failures (78 excluded). Three file-producing policy assignments without declared files covered commit refs without an artifact, a captured artifact with its matching digest, and refusal of a metadata-only artifact because its saved bytes were missing. The commit-reference command is stubbed, so this establishes policy-rule admission after a successful ref check, not real repository/ref validation. |
| CLI release build on the final policy-test source | Succeeded. Only tests and this report changed after the earlier implementation source; the CLI source is unchanged. |
| Rust unit-test attempt | 540 passed, 1 ignored, 1 failed. `args::tests::requires_exactly_one_wake_target_and_session_only_retire` expected usage text for `retire --session`, but received `retire does not accept --role`. The exact base was not successfully tested for comparison, so this is not classified as pre-existing. No Rust unit-test pass is claimed. |

Tool versions used for the isolated build and tests: Rust `1.99.1 (58cf8f9c3 2026-10-13)`, Cargo `1.99.1 (5f94df478 2026-08-27)`, Erlang/OTP `28.5`, ERTS `16.4`, Elixir `1.19.5`, Mix `1.19.5`, and CLI `0.1.15`.

Source-integrity checks on the local source:

- `git diff --check` — passed.
- The selected source target remained an ancestor of the local source.

## Policy verification when files are undeclared

The file-producing `policy` assignment case works without a declared file list. A successful commit-reference check or a saved artifact can support verification; a metadata-only artifact is refused because its bytes were not saved.

The focused test at `test/rules_test.exs:1692` omits `files` on all three policy assignments. It exercises the shipped rules and asserts: (1) commit refs without an artifact are admitted; (2) a report artifact whose bytes were captured and whose matching SHA-256 is cited is admitted; and (3) a metadata-only report artifact with a supplied digest is refused because its bytes were not saved. The saved-copy cases exercise captured-content facts through the test helper; they do not exercise the CLI's `--content-file` intake. That local-byte route is covered separately by the CLI integration test.

The commit-ref branch stubs only the external commit-reference command to represent a successful ref check. It therefore tests policy-rule admission, not whether the referenced repository or commit exists. The `mix format --check-formatted test/rules_test.exs` check still reports formatter differences in other legacy parts of the file; the final added test block itself has no formatter diff.

The focused rules test logged best-effort `ConnRegistry` `noproc` warnings while dispatch published work-state events in the isolated test process. Dispatch continued and the policy assertions passed; this run does not verify delivery to a running gateway.

This policy test is distinct from previously recorded desktop and no-files evidence cases. It does not retry or reclassify those cases, select a policy, or alter any operational-evidence rule. No desktop integration source was touched.

## Limits and remaining acceptance

- `mix format --check-formatted test/rules_test.exs` reports formatting differences in legacy portions of that file. The final policy test block has no formatter diff; no repository-wide formatter rewrite was applied.
- `cargo fmt --manifest-path cli/Cargo.toml --all -- --check` reports one formatting difference at `cli/src/cursor_execution_identity.rs:78`; that file is unchanged from the requested base.
- The scoped passing tests do not establish a full suite pass, broad behavior equivalence, or independent acceptance. The Rust unit-test failure above remains unresolved and lacks an exact-base comparison.
- This is a local source candidate, not a release. Additional evidence and independent review of the combined source remain required before delivery.
- This report is a repository file. Its presence does not establish that its bytes were captured through the CLI's local-file intake.
