# E3 corrected-tip review findings F1-F3

Date: 2026-09-02

## Lineage

- Producer assignment: `asg_aa987195-5d9a-42dc-98df-b1aeb94808ff`
- Work item: `wi_2ae33e1d-d798-46c2-9aa6-796b5506754f`
- Reviewed candidate: `032d3b550ab5e16b01d7f30043cf79c9f8bbbf05`
- Corrected-tip verdict recovery: `asg_01111e4e-fe69-419c-af61-5e494da3fc4c`
- Changes-requested verdict: `att_9b8e328b-f233-44f5-8ae4-6ef8c7a8c8a9`
- Canonical review report: `art_f2faac28`
- Review report SHA-256:
  `102911fa5b2ec0165f00ad957b57698a2296ca83b9f4775d2a6f7a0667786233`
- Reviewed specification commit:
  `dbdcf888e5f4948be9a24decc1ef1d9c9f422759`
- Reviewed specification SHA-256:
  `16de5cc246ff0d07883c3a9519c67b19e82cc69d1eb032714f6a0d5fab21aa16`
- Main-landing hold: `att_3e0c0b07-1269-4ce3-8a60-3974e5cf4a88`

## Corrections

1. Every compiled-wrapper failure now becomes synthetic
   `ToolCheckMaterialV1` material with state `rule_runtime_failure`. Invalid
   invocation, session authentication, authenticated context, stdin,
   observation recording, registered-handler, and invalid returned-material
   failures all map through the compiled `rule_runtime_failure` effect. The
   marker uses only projected machine, principal, optional profile, rule name,
   and fallback repair. It does not expose a raw runtime error or trust tool
   JSON or invalid returned material. A real binary invocation exits 2 with the
   named `github-network-auth-required` marker.
2. R15 explicit-selector precedence now includes positional `gh repo`
   selectors. Host-qualified `HOST/owner/repo` and repository-position URLs
   win before `GH_REPO`, current-repository state, `GH_HOST`, and the default.
   Unqualified positional selectors avoid a current-repository lookup and use
   the effective host. Conflicting positional and flag selectors refuse as
   ambiguous. Positional issue and pull-request numbers continue to use the
   current repository.
3. The hand-authored GitHub dialogue fixture is replaced by
   `cli/tests/fixtures/gh-auth-login-2.83.2-device.json`, a sanitized replay of
   the historical installed-`gh` capture. It records Darwin arm64, installed
   path, version, exact argv, capture and terminal times, exact `Y\n` followed
   by EOF, combined-PTY provenance, prompt, device URL, deadline result, exit
   status 1, no banking, and durable source refs. The expired code is replaced
   by `REDACTED-EXPIRED-CODE`; no token or credential is present. The released
   source capture did not hash the installed `gh` binary, so the fixture
   records a deliberate null and forbids an inferred hash. Fixture SHA-256:
   `b79008a54d0056f9328d976f815135af55ff0a1cad01df5109e5936823cf76f6`.

## Fresh gates

- Focused runtime-material tests: 7 tests, 0 failures.
- Focused R15 positional-selector test: 1 test, 0 failures.
- Focused installed-`gh` two-stream replay: 1 test, 0 failures.
- GitHub Rust group: 31 tests, 0 failures.
- Full Rust suite, serial final run: 297 unit tests and four integration tests,
  0 failures. One earlier default-parallel run had one transient failure in the
  pre-existing profile-lock fixture; that exact test passed immediately in
  isolation before the complete serial run passed.
- Focused GitHub, adapter, doctor, credential, projection, and rule Mix suite:
  3 doctests and 191 tests, 0 failures.
- Proportional compatibility, restart, schema/migration, and
  scheduler/supervision Mix suite: 109 tests, 0 failures.
- `cargo build --release`: pass.
- `cargo fmt --check`: pass.
- `mix format --check-formatted`: pass.
- `python3 scripts/verify_shipped_privacy.py`: pass.
- `python3 scripts/verify_public_rule_facts.py`: pass.
- `git diff --check`: pass.
- `packaging/assemble.sh` and `packaging/version-smoke.sh`: pass; manifest,
  CLI, and gateway report `0.2.0`.
- Package: `tightbeam-0.2.0-linux-x86_64.tgz`, SHA-256
  `79874abaa68d2706d2ed7af0b8756163319ef8aa826023c5f3fecf13a9ca74bb`.

The known hosted A17 full-Mix hang remains governed by the main-landing hold;
`scripts/verify_mix.sh` was not repeated. All Mix runs used their isolated
disposable test databases and repository fixture harness. No development build
or migration was booted against the live database. No GitHub command, live
credential, provider secret, identity/configuration mutation, target, main
move, release, or deployment was used.
