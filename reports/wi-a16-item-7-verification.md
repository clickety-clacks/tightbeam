# WIa16 item 7 verification — 0.1.15

Date: 2026-11-12
Work item: `wi_a16dbf9d-d3bc-4ff1-9af9-401ed04f10de`
Assignment: `asg_a4eaa0fc-ff84-4083-a6fd-4fe4f6cdbe6a`

## Change exercised

Based on `8c8fae4fb66505461291ca943dc7c3c053eae177`. The source and test patch exercised by the gate had SHA-256 `d4479b17769304c2c28b445d3df15f60a329ab4eab6aa4abc884acc07b56030a` (`git diff --binary`, before adding this report).

When no operational-evidence policy is selected, an attached artifact can now support a non-code verified verdict. The existing artifact and hash pair validation still checks attribution and captured bytes. Code effects remain outside this fallback and still require commit refs. Completion coverage uses the shipped verification and results-artifact rules with an attached report and no commit refs. Tests also cover the code-card artifact-only refusal.

No historical refusal was retried or relabeled. No main port, policy, identity, guidance, service, release, install, or live-state change was made.

## Commands and results

The canonical wrapper was unchanged: SHA-256 `fa1db1b48840850528ffc2eec92556fbcc49c19455472f28de0f9a398e77c699`.

The wrapper run used a fresh scratch directory for `HOME`, `TMPDIR`, `CARGO_HOME`, `ERL_CRASH_DUMP`, and a `TIGHTBEAM_BASE_DIR` sentinel. Toolchain and package caches (`MIX_HOME`, `HEX_HOME`, `MISE_DATA_DIR`, `RUSTUP_HOME`) were preserved so the pinned tools and already-resolved dependencies were available. The wrapper clears inherited `TIGHTBEAM_*` and `RELEASE_*` variables before starting tests. Test state and the wrapper's gate marker therefore stayed in scratch, separate from live Tightbeam state.

Commands run from the checkout:

```sh
cargo build --release --manifest-path cli/Cargo.toml
```

Result: exit 0; built the repository CLI, which reports version `0.1.15`. This satisfied the wrapper's local CLI prerequisite.

```sh
mix format test/verification_papertrail_test.exs
mix format --check-formatted
```

Result: the formatter exited 0 and the final format check exited 0. An earlier format check identified one overlong call in the new test; it was formatted before the successful check.

```sh
scripts/verify_mix.sh test/file_effect_validation_port_test.exs test/assignments_test.exs:6490 test/verification_papertrail_test.exs:263
```

Result: exit 0; **14 tests, 0 failures (146 excluded)**. This covers the no-policy non-code artifact verdict and retained ID/hash, completion through the shipped rules, and the artifact-only code-card refusal. The run was off-host in isolated scratch, using the unchanged canonical wrapper.

Additional read-only checks:

```sh
git diff --check
shasum -a 256 scripts/verify_mix.sh mix.lock cli/Cargo.lock
```

Result: `git diff --check` exited 0. The wrapper and lockfile hashes are listed below; dependency resolution did not change either lockfile.

## Versions and pinned inputs

- OS: macOS `27.0.1`, build `26A434`; kernel `Darwin 27.0.0`, architecture `arm64`.
- `.tool-versions`: Erlang `28.5`; Elixir `1.19.5-otp-28`.
- Runtime: Erlang/OTP `28`, ERTS `16.2.1`; Elixir `1.19.5`; Mix `1.19.5` compiled with OTP 28.
- Rust: `rustc 1.99.1 (58cf8f9c3 2026-10-13)`; Cargo `1.99.1 (5f94df478 2026-08-27)`; `rust-toolchain.toml` selects stable.
- Tightbeam CLI: `0.1.15`.
- `scripts/verify_mix.sh`: `fa1db1b48840850528ffc2eec92556fbcc49c19455472f28de0f9a398e77c699`.
- `mix.lock`: `a9452239b0b5b285f76c57d9ac997fab6861d1586f077db4b3af02440fe2fb74`.
- `cli/Cargo.lock`: `0efdff24303ae81f9da68647435d92e6416333d48bf72b370b05f707c3632581`.

## Limits

The wrapper selected the file-effect test module, the existing code completion test at line 6490, and the new shipped-completion integration test at line 263; 146 tests were excluded. This is targeted regression evidence, not a full-suite or live-gateway result. No live state was read or changed for this run.

The latest work-item readback records that the installed gateway still refuses artifact-bearing verdicts. No separate `verified` verdict was submitted through that runtime because it would evaluate a different revision from the branch under test; a commit-refs-only verdict was not used as a substitute. The successful source-level verification above is recorded, while a formal producer `verified` verdict remains unfiled pending an evaluation path for the target behavior.
