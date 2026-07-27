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

## Running it as a service

Nothing here is tightbeam-specific policy — it is the ordinary way to run a
long-lived process on each platform. Pick your init system and keep three
properties: **start on boot**, **restart on failure**, and **a stable
environment**.

### The environment that matters

| variable | why |
|---|---|
| `TIGHTBEAM_LOCAL_HOST_NAME` | **Set this. It is the one that bites.** The homes tree is keyed `homes/<machine>/<harness>`, and the machine name defaults to the OS hostname. If the hostname is unstable — a container that gets a new id per start, a renamed machine — every restart projects a NEW home tree and silently orphans the durable harness state (codex `sessions/`, claude `projects/`) under the old name. It does not fail; it just quietly stops finding the old conversations. Pin it to a name you choose and never change it. |
| `TIGHTBEAM_BASE_DIR` | The org: `auth/`, `identity/`, `homes/`, `state.db`, `work/`. Defaults to `TIGHTBEAM_HOME`, else `~/.tightbeam`. |
| `TIGHTBEAM_PORT` | Rewritten into `gateway.json` at every boot. |
| `TIGHTBEAM_ADVERTISED_URL` | The URL clients are told to connect back on. `mix tightbeam.doctor` fails without it. |
| `TIGHTBEAM_DEFAULT_MODEL` | Must be a live ref for the default harness. It is a single global, so on a two-harness host one harness will report its default as unselectable — that is expected, not a fault. |
| `CODEX_PATH` | Pin the codex binary. Harness CLIs auto-update underneath you; an unpinned one changes behaviour without warning. |

Run the service as an ordinary user, not root. It needs write access to
`TIGHTBEAM_BASE_DIR` and read access to the harness CLIs on `PATH`.

### macOS — launchd

`~/Library/LaunchAgents/com.tightbeam.gateway.plist`, loaded with
`launchctl bootstrap gui/$(id -u) <path>` and started at login. Use a LaunchAgent
(per-user) rather than a LaunchDaemon: the harness CLIs keep credentials in the
user's keychain and home directory, so a root daemon cannot see them.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.tightbeam.gateway</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/mix</string>
    <string>run</string>
    <string>--no-halt</string>
  </array>
  <key>WorkingDirectory</key><string>/Users/you/src/tightbeam_ex</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TIGHTBEAM_LOCAL_HOST_NAME</key><string>gibson</string>
    <key>TIGHTBEAM_BASE_DIR</key><string>/Users/you/.tightbeam</string>
    <key>TIGHTBEAM_PORT</key><string>11373</string>
    <key>TIGHTBEAM_ADVERTISED_URL</key><string>ws://gibson.local:11373</string>
    <key>MIX_ENV</key><string>dev</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>/Users/you/.tightbeam/gateway.log</string>
  <key>StandardErrorPath</key><string>/Users/you/.tightbeam/gateway.err.log</string>
</dict>
</plist>
```

`KeepAlive`/`SuccessfulExit=false` restarts on crash but respects a deliberate
clean stop. launchd does not rotate logs — point them at a path you rotate, or
`newsyslog.conf` will not do it for you.

### Linux — systemd

`~/.config/systemd/user/tightbeam.service`, enabled with
`systemctl --user enable --now tightbeam`. Use a **user** unit for the same
credential-visibility reason as above, and run `loginctl enable-linger <user>`
or the service will stop when you log out.

```ini
[Unit]
Description=Tightbeam gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
WorkingDirectory=%h/src/tightbeam_ex
ExecStart=/usr/local/bin/mix run --no-halt
Environment=MIX_ENV=dev
Environment=TIGHTBEAM_LOCAL_HOST_NAME=gibson
Environment=TIGHTBEAM_BASE_DIR=%h/.tightbeam
Environment=TIGHTBEAM_PORT=11373
Environment=TIGHTBEAM_ADVERTISED_URL=ws://gibson.local:11373
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s

[Install]
WantedBy=default.target
```

`Restart=on-failure` rather than `always`, so a deliberate stop stays stopped.
Logs go to the journal — `journalctl --user -u tightbeam -f`. Give
`TimeoutStopSec` room: shutdown drains in-flight turns.

### Confirming it actually came up

A clean start is not a working install. Read the **last** lines of the log, not
the `Running … (http)` line above them: boot ends with a readiness summary that
says either `READY: <harness> can run turns.` or `NOT READY` followed by each
gap and the command that closes it. That summary is the check — `systemctl
is-active` and a listening port will both look healthy on an instance that
cannot run a single turn.

## Operating

- `docs/SMOKE.md` — the manual acceptance runbook, and the authority on
  fresh-org provisioning.
- `docs/ARCHITECTURE.md` — the substrate's shape.
- `docs/SATELLITE.md` — adding a machine to an existing org.
