# Tightbeam

A gateway that coordinates agent sessions across machines: durable turns, work
items, assignments, and gate statutes over a closed verb set.

You RUN tightbeam; you do not depend on it. There is no Hex package.

## Prerequisites

None of these are installed for you, and a missing one is not always obvious
from the failure — see `mix tightbeam.doctor` and the notes below.

- **Elixir + OTP.** Built against Elixir 1.19 / OTP 28. With no Elixir on PATH
  every command below fails as `mix: command not found`; nothing in this
  repository can report that for you.
- **Rust toolchain**, to build the `tightbeam` CLI (`cargo build --release
  --manifest-path cli/Cargo.toml`). If you skip this, gateway boot still
  succeeds and installs a `bin/tightbeam` that refuses to run, naming what is
  missing.
- **A harness CLI per harness you intend to use** — `claude` and/or `codex` — on
  PATH. `mix tightbeam.doctor` reports each as `harness_binary:<harness>`.
- **git**, for the identity repository.

## Install

```sh
mix deps.get
mix compile
cargo build --release --manifest-path cli/Cargo.toml
mix tightbeam.init                 # creates <base_dir>/identity
mix run --no-halt                  # boots the gateway; creates state.db, homes, bin/
```

`base_dir` is `TIGHTBEAM_HOME`, else `~/.tightbeam`. `TIGHTBEAM_BASE_DIR`
selects it for a single run, and `TIGHTBEAM_PORT` overrides the port.

Then, per harness, onboard a credential:

```sh
<base_dir>/bin/tightbeam onboard <provider> --as-user <userId>
```

## Read this before trusting a green boot

Boot prints `Running Tightbeam.Wire.Router ... (http)` as its last line **even
when the gateway cannot run a single turn** — with no credentials it logs two
`model catalog ... degraded` warnings above that line and then serves anyway.
A successful boot is not a working installation.

`mix tightbeam.doctor` is the closest thing to a readiness check, with one
documented limitation: it runs as a bare mix task, where the Credentials server
is not running, so **it cannot determine credential state at all**. Those rows
say so rather than guessing. To check credentials for real, use
`Tightbeam.ClientE2E.preflight/2` or read the running gateway's catalog.

## Operating

- `docs/SMOKE.md` — the manual acceptance runbook, and the authority on
  fresh-org provisioning.
- `docs/ARCHITECTURE.md` — the substrate's shape.
- `docs/SATELLITE.md` — adding a machine to an existing org.
