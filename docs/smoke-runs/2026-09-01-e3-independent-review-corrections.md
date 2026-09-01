# E3 GitHub host-auth independent-review corrections

Date: 2026-09-01

## Lineage

- Producer assignment: `asg_aa987195-5d9a-42dc-98df-b1aeb94808ff`
- Work item: `wi_2ae33e1d-d798-46c2-9aa6-796b5506754f`
- Reviewed candidate: `ed70914c1596896b1f0f6f0b90bb8635897d4627`
- Independent review assignment: `asg_00cfbe76-58ea-46e2-9da5-f8509abe8727`
- Changes-requested verdict: `att_43ee0b3c-ab56-44fe-9398-7ad650f734c8`
- Canonical review report: `art_455675a2`
- Review report SHA-256: `af1868557daffd29a557b83feb68fb9f8a1d73b5745e93e2b3861704a2408a69`
- Reviewed specification commit: `dbdcf888e5f4948be9a24decc1ef1d9c9f422759`
- Reviewed specification SHA-256: `16de5cc246ff0d07883c3a9519c67b19e82cc69d1eb032714f6a0d5fab21aa16`
- Main-landing hold: `att_3e0c0b07-1269-4ce3-8a60-3974e5cf4a88`

## Corrected findings

1. Local adapter launch keeps the elected `TIGHTBEAM_GITHUB_PROFILE` and
   `GH_CONFIG_DIR` while removing ambient token variables. An executed-command
   fixture proves both election variables survive and fixture tokens do not.
2. Adapter projection resolves the GitHub election from the pinned session
   identity revision. The adapter key remains stable across a live manifest
   reload, and coordinator callers carry `identityRevision`.
3. `github-network-auth-v1` returns typed `ToolCheckMaterialV1` facts with
   durable observation ids. The generic executor alone maps the compiled
   effects table. The compatibility command fails closed. Compiled GitHub law
   also arms the existing boot wiring proof, whose named failure is
   `github-rule-unarmed`.
4. The classifier implements R15 selector order, including explicit selectors,
   `GH_REPO`, current-repository `gh-resolved=base` markers and candidates,
   `GH_HOST`, and the `github.com` default.
5. GitHub device login uses the first-class tee, sends exactly `Y\n`, has a
   15-minute process-group deadline, and settles onboarding, rotation, and
   revocation failure branches. Metadata-only authority fingerprints distinguish
   failures before and after a possible provider write. Probes take a
   non-blocking shared profile lock.
6. Both runtimes capture auth status and the API result before classification.
   The API status line owns 401/403. A 200 with inactive auth status is unknown.
   Git probes close stdin, suppress terminal prompts, and use the elected home.
7. Production doctor reports inert legacy residue without reading it. Storage
   validates private modes through the `credential-homes` ancestor.

## Fixture and gate results

- Focused final GitHub, credential, dispatch-rule, doctor, projection, and
  exact wiring-refusal Mix fixtures: 46 tests, 0 failures.
- Focused restart, scheduler, migration, and GitHub compatibility fixtures:
  28 tests, 0 failures.
- Full Rust suite: 294 unit tests and four integration tests, 0 failures.
- `cargo build --release`: pass.
- `mix format --check-formatted`: pass.
- `cargo fmt --check`: pass.
- `python3 scripts/verify_shipped_privacy.py`: pass.
- `python3 scripts/verify_public_rule_facts.py`: pass.
- `git diff --check`: pass.
- `packaging/assemble.sh`: pass; manifest, CLI, and gateway report `0.2.0`.
- Package: `tightbeam-0.2.0-linux-x86_64.tgz`, SHA-256
  `ad7d6281d9f529056eecc1c31a1ef3fe4724d82c6f02ddaaeda0e79113d73beb`.

The authoritative `scripts/verify_mix.sh` run progressed through the broad test
body without a failure report, then emitted no output after 19:32:49Z for more
than 160 seconds. It was stopped without a completion summary. This reproduces
the canonical A17 hosted hang named by the owner hold; it is not recorded as a
pass. Focused A17-adjacent restart and scheduler fixtures passed above.

All feature verification used repository fixtures. It did not invoke GitHub,
inspect a live credential, read a provider secret, alter runtime identity or
configuration, move main, release, or deploy.
