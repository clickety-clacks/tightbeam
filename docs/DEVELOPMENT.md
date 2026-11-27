# Developing Tightbeam

Use a checkout only for development, outside any service-selected installation.
Development builds and local packages are not verified releases.

Needed to build **from source only** — a release package has all of these
already compiled into it:

- **Elixir + OTP.** Built against Elixir 1.19 / OTP 28. With no Elixir on PATH
  every command below fails as `mix: command not found`; nothing in this
  repository can report that for you.
- **Rust >= 1.85**, to build the `tightbeam` CLI (`cargo build --release
  --manifest-path cli/Cargo.toml`). The CLI is edition 2024, so older toolchains
  cannot build it at all. **Install via [rustup](https://rustup.rs), not your
  distro** — Ubuntu 24.04 LTS packages 1.75, which looks like a satisfied
  prerequisite and then fails the build. `cargo --version` must report 1.85 or
  newer before you start.

  Do not skip this step and continue. Gateway boot still succeeds without the
  CLI and installs a `bin/tightbeam` that refuses to run — but the very next
  documented step, onboarding a credential, *is* that binary. You would get a
  gateway that looks healthy, cannot be onboarded, cannot run a turn, and
  reports its problem as missing credentials rather than a missing CLI.
- **A C toolchain** (`gcc`/`clang` + `make`) — `exqlite` builds a native NIF.
- **Hex and rebar3**, Elixir's package and build tools. They do NOT ship with
  Elixir. Without them `mix deps.get` cannot fetch anything, and on a machine
  that has never had them it stops on an interactive prompt — `Shall I install
  Hex? [Yn]` — which fails outright under any non-interactive install. Install
  them explicitly with the first two commands below rather than answering that
  prompt; `--if-missing` makes both a no-op when you already have them.

## From source

Only after a harness is on PATH, build and run a development checkout:

```sh
git clone https://github.com/clickety-clacks/tightbeam.git
cd tightbeam

mix local.hex --force --if-missing      # Hex; no-op if already installed
mix local.rebar --force --if-missing    # rebar3, to build Erlang deps

mix deps.get
mix compile
cargo build --release --manifest-path cli/Cargo.toml

mix tightbeam.init                 # creates <base_dir>/identity
mix run --no-halt                  # boots the gateway; creates state.db and bin/
```

## Cutting a release

`main` is the only long-lived development branch. Prepare release source through
reviewed pull requests to `main`; do not use a version branch. Set the version
in `cli/Cargo.toml` in the reviewed change. In the same change, re-check each
external-agent skill that `tightbeam skill install` ships (listed in
`cli/src/skills.rs`) against the new `tightbeam --help`, and update its
`Written for Tightbeam <version>.` line. CI checks
`scripts/verify_external_skills.py` on pull requests and retains push checks
for existing `0.1.*` branches.

For each release, manually dispatch `.github/workflows/release-candidate.yml`
from `main` to build the final unpublished candidate from the exact release
commit. Supply `candidate_branch=main` and the full SHA of the exact current
`main` tip. The workflow refuses a different SHA, runs the full Linux and macOS
test gates, builds both native packages, and uploads a proof artifact with the
canonical manifest, package bytes and `SHA256SUMS`. For a main candidate it
also uploads `release-candidate-stage-<sha>` with selector-ready package names,
the same package bytes, candidate manifest, candidate provenance and
`SHA256SUMS`. The top-level `workflow` field binds the candidate run; the
planned release tag in that provenance is metadata only. Neither a Git tag nor
a GitHub Release is created before the soak.

Staging and publication verify that the exact candidate is still in the
fetched canonical `main` history.
The release tag must be exactly `v<major>.<minor>.<patch>+<build>`: the version
must match `cli/Cargo.toml`, and the build number is `git rev-list --count`
for the candidate commit. If a candidate check or soak fails, prepare a new
candidate from the current `main` tip.

After the user separately approves installing that exact candidate SHA, install
those bytes and complete the soak on the maintainers' production deployment.
Every candidate or release installation requires the user's exact approval.
The soak is the final check; other testing stays in CI and isolated
environments. If the soak is `healthy`, manually dispatch
`.github/workflows/publish-release.yml` from `main` with the candidate run ID
and SHA, release tag, the matching install-approval SHA, `healthy` soak
outcome, and the matching soaked SHA. The publisher rechecks the successful
candidate run, manifest, and checksums, then publishes the downloaded package
bytes from the selector-ready stage artifact without rebuilding them. It
checks those bytes against the proof artifact, then records the candidate,
approval, soak, checksums, and publication workflow at top level in the release
provenance. A failed candidate or unhealthy soak remains unpublished; fix the
source through a reviewed change to `main` and build a fresh candidate.
Release tags are immutable and must not be reused or moved.

Retain a broken published release. Put a do-not-install warning at the top of
its notes naming the failure and safe replacement, and mark it prerelease so
it cannot be latest. Delete it only for a leaked secret or legal problem.
