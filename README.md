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
- **A registered harness CLI** — `claude` and/or `codex` — installed and on
  PATH before you clone or build Tightbeam. Boot refuses by name when it cannot
  find a usable registered harness. `mix tightbeam.doctor` reports each as
  `harness_binary:<harness>`.
- **node + npm.** The ACP adapters are npm packages, and the gateway installs
  them into `<base_dir>/adapters` itself on first spawn. Without npm that
  install fails and no turn can start.
- **git**, for the identity repository.
- **A C toolchain** (`gcc`/`clang` + `make`) — `exqlite` builds a native NIF.
- **Hex and rebar3**, Elixir's package and build tools. They do NOT ship with
  Elixir. Without them `mix deps.get` cannot fetch anything, and on a machine
  that has never had them it stops on an interactive prompt — `Shall I install
  Hex? [Yn]` — which fails outright under any non-interactive install. Install
  them explicitly with the first two commands below rather than answering that
  prompt; `--if-missing` makes both a no-op when you already have them.

## Install

Install at least one harness first. These are the vendors' install commands;
install both if you want both harnesses:

```sh
npm install -g @anthropic-ai/claude-code
claude --version
```

and/or:

```sh
npm install -g @openai/codex
codex --version
```

Only after a harness is on PATH, install Tightbeam:

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

Set `TIGHTBEAM_BASE_DIR` to choose `base_dir`; the gateway otherwise uses
`TIGHTBEAM_HOME`, then `~/.tightbeam`. The CLI uses the same fallback order. The
CLI finds the gateway through `<base_dir>/gateway.json`. `TIGHTBEAM_PORT`
overrides the port. Whatever you set for the service, set for the shell you run
the CLI from: if they disagree, the CLI looks for its gateway in a directory
that does not have one.

With at least one usable harness through preflight, the first boot creates the
base dir and serves, but **cannot run a turn yet**: it has no credentials, so it
prints a NOT READY summary naming every gap. Harness homes are projected per
machine and harness during reconciliation or launch, not necessarily at boot.
Leave this process running and complete the remaining steps from another
terminal.

### Connect your first client — do this BEFORE onboarding

A fresh org has no users. **The first client to connect is auto-approved and its
user becomes the admin**: point your client at `TIGHTBEAM_ADVERTISED_URL`, pair
with a claimed name, and it succeeds instantly — no approval step, because
there is nobody yet to approve it.

Do this first. Onboarding is admin-only, so running it before any client has
paired fails with `forbidden: admin required` and there is no other way to
create that first admin.

Every client after this one pairs as `pending` and must be approved by the admin.

### Then onboard a credential, per provider

An existing vendor CLI login is invisible to Tightbeam; Tightbeam keeps its own
credential. This command is the only supported credential path — running the
vendor's own `login` does not onboard Tightbeam:

```sh
<base_dir>/bin/tightbeam onboard <provider> --as-user <userId>
```

`<provider>` is the credential provider — **`anthropic`** or **`openai`** — not
the harness name. `<userId>` is the admin created by that first pairing.

### Then learn the working identity

```sh
<base_dir>/bin/tightbeam learn agentic-engineering --as-user <userId>
```

`<base_dir>/bin/tightbeam unlearn agentic-engineering --as-user <userId>` is its
inverse. Credentials are per provider/harness per machine, while harness homes
are per machine and harness; learning or unlearning changes neither, so it
never requires onboarding again.

### Then run a real turn

In the connected client, open Main and send `hello, who are you?`. Installation
has reached its end only when the assistant reply arrives and the typing
indicator clears.

You do not install the ACP adapters by hand. `<base_dir>/adapters` stays empty
until the first session spawns, at which point the gateway installs both
adapters at their pinned versions. A first boot reporting them missing is
expected, not a failed install.

## Reading the boot summary

Boot ends with a readiness verdict, because serving is not the same as being
able to run a turn. A ready install says so in one line. An install with gaps
says `NOT READY` and then names each one per harness, with the command that
closes it:

```
NOT READY: no harness on this instance can run a turn. The gateway is
serving, so clients can connect, but every turn will fail until the
gaps below are closed.

  claude:
    ACP adapter missing at <base_dir>/adapters/node_modules/.bin/claude-agent-acp
      — no turn can start.
    Tightbeam has no credential for anthropic on <host>. It does not use or
      import your normal claude CLI login; Tightbeam keeps its own credential
      under <base_dir>/auth. Run on <host>:
      tightbeam onboard anthropic --as-user <userId>
```

A row saying UNKNOWN is not a claim that the credential is bad. Use
`mix tightbeam.doctor` for additional diagnostics; check credential liveness in
the boot summary or the running gateway's catalog.

## Installing as a service

**This is how Tight Beam is meant to run, and it is part of installation — not an
optional extra afterwards.** `mix run --no-halt` is a foreground process bound to
your terminal: it dies when you log out and does not come back after a reboot.
An install that leaves you with a foreground process is not finished.

The service must **start with no interactive login**, **survive logout**,
**survive reboot**, and **restart on failure**.

### The environment that matters

| variable | why |
|---|---|
| `TIGHTBEAM_LOCAL_HOST_NAME` | **Set this. It is the one that bites.** The homes tree is keyed `homes/<machine>/<harness>`, and the machine name defaults to the OS hostname. If the hostname is unstable — a container that gets a new id per start, a renamed machine — every restart projects a NEW home tree and silently orphans the durable harness state (codex `sessions/`, claude `projects/`) under the old name. It does not fail; it just quietly stops finding the old conversations. Pin it to a name you choose and never change it. |
| `TIGHTBEAM_BASE_DIR` | The org: `auth/`, `identity/`, `homes/`, `state.db`, `work/`. Defaults to `TIGHTBEAM_HOME`, else `~/.tightbeam`. |
| `TIGHTBEAM_PORT` | Rewritten into `gateway.json` at every boot. |
| `TIGHTBEAM_ADVERTISED_URL` | The URL clients are told to connect back on. `mix tightbeam.doctor` fails without it. |
| `TIGHTBEAM_DEFAULT_MODEL` | Must be a live ref for the default harness. It is a single global, so on a two-harness host one harness will report its default as unselectable — that is expected, not a fault. |
| `CODEX_PATH` | Pin the codex binary. Harness CLIs auto-update underneath you; an unpinned one changes behaviour without warning. |

Run the service **as an ordinary user, not root** — set the account explicitly
(`User=` / `UserName=`) rather than letting the init system default to root. It
needs write access to `TIGHTBEAM_BASE_DIR` and read access to the harness CLIs on
`PATH`. No dedicated service account is required: run it as the account that
installed it.

Keep `base_dir` somewhere durable; it holds the org's credentials, identity,
sessions, and work.

### macOS — launchd

`/Library/LaunchDaemons/com.tightbeam.gateway.plist`, owned `root:wheel` mode
`644`, loaded with `sudo launchctl bootstrap system <path>`.

Use a **LaunchDaemon**, not a LaunchAgent. A LaunchAgent is per-user and starts at
*login*, so it dies at logout and does not exist until someone signs in — it cannot
meet the requirements above. `UserName` keeps the process off root.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.tightbeam.gateway</string>
  <key>UserName</key><string>you</string>
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

Verify: `sudo launchctl print system/com.tightbeam.gateway`.

### Linux — systemd

`/etc/systemd/system/tightbeam.service`, enabled with
`sudo systemctl enable --now tightbeam`.

Use a **system** unit. A user unit stops at logout unless you also enable
lingering, and it will not start until that user's manager does — `WantedBy=
multi-user.target` starts at boot with no login at all.

```ini
[Unit]
Description=Tightbeam gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=you
Group=you
WorkingDirectory=/home/you/src/tightbeam_ex
ExecStart=/home/you/.local/bin/mix run --no-halt
Environment=MIX_ENV=dev
Environment=TIGHTBEAM_LOCAL_HOST_NAME=gibson
Environment=TIGHTBEAM_BASE_DIR=/home/you/.tightbeam
Environment=TIGHTBEAM_PORT=11373
Environment=TIGHTBEAM_ADVERTISED_URL=ws://gibson.local:11373
Environment=PATH=/home/you/.local/bin:/usr/local/bin:/usr/bin:/bin
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s

[Install]
WantedBy=multi-user.target
```

`User=`/`Group=` are required in a system unit — without them systemd runs it as
root. `%h` does NOT work here: in a system unit it expands to `/root`, not to the
user's home, so every path is spelled out. Set `PATH` explicitly too — a system
unit inherits almost none of your login environment, and `mix`, `elixir`, `node`
and the harness CLIs must all be findable.

`WantedBy=multi-user.target` is what makes it start at boot with nobody logged in.
`Restart=on-failure` rather than `always`, so a deliberate `systemctl stop` stays
stopped. Logs go to the journal — `journalctl -u tightbeam -f` (no `--user`).
Give `TimeoutStopSec` room: shutdown drains in-flight turns.

Verify: `systemctl is-enabled tightbeam` reports `enabled` (starts at boot) and
`systemctl is-active tightbeam` reports `active`.

### Verifying the service — the four things that define it

A running process proves none of these. Check them explicitly:

| property | Linux | macOS |
|---|---|---|
| starts with no login | `systemctl is-enabled tightbeam` → `enabled` | `sudo launchctl print system/com.tightbeam.gateway` |
| survives logout | log out, then re-check `is-active` | log out, then re-check `print` |
| survives reboot | reboot; `is-active` without intervention | reboot; `print` without intervention |
| restarts on failure | kill the pid; it returns | kill the pid; it returns |

Then confirm it can actually work — read the boot summary below, and run a real
turn. A service that starts perfectly and cannot run a turn is not installed.

### Uninstalling

**NOT YET IMPLEMENTED.** There is no `tightbeam uninstall`. Until there is,
removal is manual, and the order matters — stop the service before removing
anything it holds open:

```sh
# Linux
sudo systemctl disable --now tightbeam
sudo rm /etc/systemd/system/tightbeam.service
sudo systemctl daemon-reload

# macOS
sudo launchctl bootout system/com.tightbeam.gateway
sudo rm /Library/LaunchDaemons/com.tightbeam.gateway.plist
```

Then verify nothing is left: no unit or plist, no process, nothing listening on
your `TIGHTBEAM_PORT`.

`base_dir` is **left alone** by the steps above, and that is deliberate — it holds
your identity repo, sessions, work items, and credentials. Removing the service
does not throw away the org. Delete `base_dir` yourself only when you mean to
destroy that state; it is not recoverable.

### Confirming it actually came up

A clean start is not a working install. Read the **last** lines of the log, not
the `Running … (http)` line above them: boot ends with a readiness summary that
says either `READY: <harness> can run turns.` or `NOT READY` followed by each
gap and the command that closes it. That summary is the check — `systemctl
is-active` and a listening port will both look healthy on an instance that
cannot run a single turn.

## Operating

- `docs/SMOKE.md` — the manual acceptance runbook; it follows this README's
  authoritative fresh-org install path.
- `docs/ARCHITECTURE.md` — the substrate's shape.
- `docs/SATELLITE.md` — adding a machine to an existing org.
