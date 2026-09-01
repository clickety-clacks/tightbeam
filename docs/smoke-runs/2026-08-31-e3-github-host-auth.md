# E3 GitHub host-auth verification

Date: 2026-08-31

## Lineage

- Assignment: `asg_aa987195-5d9a-42dc-98df-b1aeb94808ff`
- Work item: `wi_2ae33e1d-d798-46c2-9aa6-796b5506754f`
- Protected source: `origin/main` at `c50e418384c44137a063e52f9bee22c53001acc3`
- Reviewed PR20 source range: `c57c190..60bda7e`
- Reviewed specification commit: `dbdcf888e5f4948be9a24decc1ef1d9c9f422759`
- Reviewed specification SHA-256: `16de5cc246ff0d07883c3a9519c67b19e82cc69d1eb032714f6a0d5fab21aa16`
- Specification artifact: `art_7e964893`
- Design report: `art_2908a90d`
- Independent design review: `att_f248334b` / `art_e95312db`
- Projection-key ruling: `att_7f8f301b-e31a-497e-a5b8-8a44340bdc60`

## Posture

All verification used repository fixtures. It did not inspect, read, or use a live
credential, GitHub account, GitHub authentication state, runtime service, or live
configuration. Tightbeam stores GitHub credential metadata and observations only.
Provider-owned host storage remains the secret authority. Legacy
`auth/github/gh` content is inert and is not projected into a process environment.

## Results

- Focused GitHub credential, host-auth, dispatch-rule, placement, coordinator,
  gateway, doctor, and malformed-input fixtures: pass.
- `scripts/verify_mix.sh`: 9 doctests, 2,102 tests, 0 failures, 11 skipped.
- `cargo test --manifest-path cli/Cargo.toml --no-fail-fast`: 286 unit tests and
  four integration tests, 0 failures.
- `cargo build --release --manifest-path cli/Cargo.toml`: pass.
- `mix format --check-formatted`: pass.
- `cargo fmt --manifest-path cli/Cargo.toml --check`: pass.
- `python3 scripts/verify_shipped_privacy.py`: pass.
- `python3 scripts/verify_public_rule_facts.py`: pass.
- `git diff --check`: pass.
- `packaging/assemble.sh`: pass on Linux x86-64; manifest, CLI, and gateway all
  report version 0.2.0.
- Package: `tightbeam-0.2.0-linux-x86_64.tgz`, SHA-256
  `10e9cb7a4b666f712f86fdac8190ee65c2fe55e0b6b1f3e72d2ad15b82e941e5`.

The candidate exact commit and remote branch are recorded in the assignment
artifacts after the commit is created and pushed. No release, deployment, tag,
main movement, or live-state mutation is part of this verification.
