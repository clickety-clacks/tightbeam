# E3 dispatch normalizer reconciliation

Date: 2026-09-01

## Finding

The reviewed `pretooluse-normalize-v1` ABI requires `ToolCallInputV1` to retain
the typed `tool: Bash` field. Candidate `7ff95955b140af1f02dd16a4b664c51e15e0ae1b`
validated the native `/tool_name` value but passed only the decoded command to
the compiled GitHub guard.

The correction retains `{abi, tool, command}` as the typed normalizer output
and passes that complete value to the compiled guard. The guard refuses an
invalid internal ABI or tool value. A fixture proves that different Claude and
Codex metadata produces the same typed normalizer output for the same command.

## Verification

- Current `origin/main`: `c50e418384c44137a063e52f9bee22c53001acc3`.
- Focused normalizer tests: 3 passed, 0 failed.
- Focused GitHub auth tests: 26 passed, 0 failed.
- Full Rust gate: 287 unit tests and four integration tests passed, 0 failed.
- Rust development build: passed.
- Elixir gateway compilation with the pinned BEAM toolchain: passed.
- Rust format and `git diff --check`: passed.

All tests used repository fixtures. This reconciliation did not read or use a
live credential, GitHub authentication state, runtime service, or live
configuration. It did not move main, merge, release, or deploy.
