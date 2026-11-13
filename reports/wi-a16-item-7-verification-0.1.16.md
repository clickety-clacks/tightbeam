# WIa16 item 7 verification — 0.1.16 carry

Date: 2026-11-13
Work item: `wi_a16dbf9d-d3bc-4ff1-9af9-401ed04f10de`
Assignment: `asg_c2a7f186-6043-42fb-b301-19f97e5752e9`

## Change and evidence mapping

The carry starts from the exact 0.1.16 base `894aa988865742ed72ad39e1449bbe10821851ca` and applies the first-parent change from the 0.1.15 merge `b8c5f88f1760de67c043eec795e85dd965ee98f0`. The resulting source commit before this report was `fd09f245b82815204a4279dbabf88c4f949c931f`. Its five-file carry is limited to the evidence validator, three regression test files, and the preserved 0.1.15 verification report. The earlier report remains unchanged at SHA-256 `776ed4895b7435a5ff32b90f515d4f928769105417e5358d6b44e00c68488574`.

When no operational-evidence policy is selected, a captured artifact and its SHA-256 can substantiate a verified non-code assignment. The artifact/hash pair is still validated and recorded on the verdict. The integration regression proves the captured report remains attached and that the verified evidence allows completion through the existing rules. The artifact-only code-card case remains rejected with `invalid_commit_refs`; the code-card path still requires reviewed commit refs.

This covers the same source-level evidence shape as the preserved specimens: WI652 on WI4bcb, with artifact `art_5914de5a` (SHA-256 prefix `9f377db8939f`) and historical completion, artifact-backed verification, and note-only verification refusals (`req_sgPGGy`, `req_UemxNkY`, `req_RgITvK`); and Surf Ace WI4c078a67-cee8-4e07-8d08-db6bba81fd7f, with artifact `art_db5a69d7` and its preserved artifact-bearing verified refusal. These historical records were not retried, relabeled, replaced, or modified. The tests exercise the behavior those records request; they do not change those records.

## Commands and results

The canonical wrapper was not modified. Its SHA-256 is `fa1db1b48840850528ffc2eec92556fbcc49c19455472f28de0f9a398e77c699`.

The first unchanged-wrapper attempt used a unique temporary directory and exited 1 during dependency preflight, before running tests, because these lockfile dependencies were not yet present: `websock_adapter`, `toml`, `exqlite`, `bandit`, and `tz`.

```sh
mise exec -- mix deps.get
```

Result: exit 0. Dependencies were resolved from the existing lockfile; `mix.lock` remained unchanged.

The second unchanged-wrapper attempt exited 1 before running tests because the checkout-local CLI binary was missing. The test helper identified the declared prerequisite below; no test was skipped or substituted.

```sh
cargo build --release --manifest-path cli/Cargo.toml
```

Result: exit 0. Built the local CLI package at version `0.1.15`, as declared by `cli/Cargo.toml`.

The final unchanged-wrapper invocation used fresh temporary scratch `/tmp/tightbeam-wia16-item7-0.1.16.7QfeRK2O` for `RUNNER_TEMP` and `TMPDIR`:

```sh
RUNNER_TEMP=/tmp/tightbeam-wia16-item7-0.1.16.7QfeRK2O TMPDIR=/tmp/tightbeam-wia16-item7-0.1.16.7QfeRK2O scripts/verify_mix.sh test/file_effect_validation_port_test.exs:386 test/file_effect_validation_port_test.exs:452 test/assignments_test.exs:6577 test/verification_papertrail_test.exs:263
```

Result: exit 0; **4 tests, 0 failures (156 excluded)**. The selected regressions cover a no-policy artifact-bearing non-code verdict, retained artifact ID/hash, the code-card commit-ref requirement, and completion after captured-report verification.

```sh
mise exec -- mix format --check-formatted
git diff 894aa988865742ed72ad39e1449bbe10821851ca...HEAD --check
```

Result: both exited 0. Dependency setup did not change either lockfile: `mix.lock` SHA-256 `a9452239b0b5b285f76c57d9ac997fab6861d1586f077db4b3af02440fe2fb74`; `cli/Cargo.lock` SHA-256 `0efdff24303ae81f9da68647435d92e6416333d48bf72b370b05f707c3632581`.

## Versions and pinned inputs

- OS: macOS `27.0.1`, build `26A434`, Darwin kernel `27.0.0`, architecture `arm64`.
- `.tool-versions` SHA-256: `bad70134e7aa0fecd1ef6ae4313f3f958d6a65e54cd7c32100336fee9b0b8499`; it pins Erlang/OTP `28.5` and Elixir `1.19.5-otp-28`.
- The wrapper selected Erlang/OTP `28` (ERTS `16.4`), Elixir `1.19.5`, and Mix `1.19.5` compiled with OTP 28. Direct system Erlang was `28.3.2`; the wrapper selected the repository-pinned runtime instead.
- Rust: `rustc 1.99.1 (58cf8f9c3 2026-10-13)`; Cargo `1.99.1 (5f94df478 2026-08-27)`; `rust-toolchain.toml` selects stable.
- Git: `2.54.0` (Apple Git-157).
- CLI package: `0.1.15`.
- `scripts/verify_mix.sh`: SHA-256 `fa1db1b48840850528ffc2eec92556fbcc49c19455472f28de0f9a398e77c699`.

## Limits

All build and test work used an isolated checkout and unique scratch runtime/test directories off the restricted live host. The wrapper was used unchanged. The selected tests are targeted source-level regressions; 156 tests were excluded. They do not prove that a tagged 0.1.16 release is published, installed, or serving the behavior. The preserved Surf Ace refusal therefore remains historical evidence, and a future served verification of that artifact shape still depends on a separately authorized tagged, installed, hash-verified release. This assignment authorizes no release, install, main port, or live-state change.
