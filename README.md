# Tightbeam

Agent orchestration needs a real machine part—not another layer of ad hoc glue.
Tightbeam coordinates the vendors’ own harnesses rather than repackaging models
in a generic shell: Claude runs in Claude Code; Codex runs in Codex.

It keeps durable, first-party facts about work in one shared source of truth.
At the substrate layer, it turns guidance into deterministic rails: rules
enforced across agents and sessions, not left to each model’s inference.

You RUN tightbeam; you do not depend on it. There is no Hex package.

## External-agent operation skill

Use the [current-line CLI edition](priv/skills/tightbeam-cli/SKILL.md) when an external
agent operates an existing Tightbeam organization through the command line.

Copy the whole `tightbeam-cli` directory to `.codex/skills/tightbeam-cli/` or
`.claude/skills/tightbeam-cli/` in the external agent's project. Keep the directory name
and `SKILL.md` filename unchanged. Start a fresh agent session after the copy so the agent
rediscovers the skill metadata.

The skill does not install Tightbeam, create a session, supply a credential, operate a
kungfu bundle, or change a Tightbeam identity. Provision those prerequisites separately.

## Two ways to install

**From a release package** (below) — a per-platform npm tarball carrying the
gateway *and* the CLI, with Erlang bundled. No Elixir, no Rust, no C toolchain
on the target machine. This is the shorter path and the one to prefer.

**From source** — clone and build. Use this to develop Tightbeam or to produce a
local package from an unreleased commit.

The prerequisites below are split accordingly; everything else in this document
applies to both.

## Prerequisites

None of these are installed for you, and a missing one is not always obvious
from the failure — see `mix tightbeam.doctor` and the notes below.

Needed by **both** paths:

- **A registered harness CLI** — `claude`, `codex`, and/or `pi` — installed and on
  PATH *before* you start. Boot refuses by name when it cannot find a usable
  registered harness. `mix tightbeam.doctor` reports each as
  `harness_binary:<harness>`.
- **node + npm.** The ACP adapters are npm packages, and the gateway installs
  them into `<base_dir>/adapters` itself on first spawn. Without npm that
  install fails and no turn can start. The release package is also an npm
  package, so this is how you install it.
- **git**, for the identity repository.

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

## Linux: unprivileged user namespaces, and the Codex sandbox

**macOS is unaffected.** This section is Linux only.

Codex runs every shell command inside a [bubblewrap](https://github.com/containers/bubblewrap)
sandbox, and bubblewrap needs an **unprivileged user namespace** to build it.
Several distributions restrict exactly that, as hardening. Where they do, no
Codex agent on that host can run any command at all.

The failure is severe and nearly silent, so know the shape of it:

```
bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted
```

It reads like a networking fault. It is not. bubblewrap creates the network
namespace, then tries to bring up `lo` inside it, which needs a capability it
should have inherited from the user namespace it was denied. The loopback line
is simply the first place the missing namespace surfaces.

**Why it is worse than an ordinary broken dependency:** an agent that cannot
start a command cannot run `tightbeam` either. It cannot file an attest, record
a blocker, or schedule a continuation. It fails, stays silent, and its card
looks like ordinary open work. Expect to find it by noticing turns that produce
no attests, not by seeing an error.

### Check before you onboard a Linux host

```sh
bwrap --unshare-net --ro-bind / / /bin/true   # exit 0 = sandbox works
unshare --user --map-root-user true           # exit 0 = userns available
```

If the first command prints the error above, agents on that host will not run.

### Fix: Ubuntu 23.10 and later (including 24.04 LTS)

Ubuntu ships `kernel.apparmor_restrict_unprivileged_userns=1` by default. It
does not forbid the namespace outright — it transitions the process into the
`unprivileged_userns` AppArmor profile, whose first rule is `audit deny
capability`. You get a user namespace with every capability stripped, which is
useless for building a sandbox. Nothing is written to the kernel log, so the
only symptom is the `EPERM` above.

Grant the capability to `bwrap` alone, using the same pattern Ubuntu ships for
Chrome and VS Code. Create `/etc/apparmor.d/bwrap`:

```
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
```

```sh
sudo apparmor_parser -Q /etc/apparmor.d/bwrap   # parse-check first
sudo apparmor_parser -r /etc/apparmor.d/bwrap   # load
bwrap --unshare-net --ro-bind / / /bin/true     # verify
```

Existing sessions recover on their next turn; no gateway or adapter restart is
needed. The profile reloads at boot via the `apparmor` service.

Prefer this to `sysctl kernel.apparmor_restrict_unprivileged_userns=0`. That
one line also works, and it disables the restriction for **every** binary on
the host — unprivileged user namespaces are a well-worn local privilege
escalation route, which is why the restriction exists. The per-binary profile
keeps it in force everywhere else. After the profile is installed,
`unshare --user` still fails for other programs; that is correct, not a partial
fix.

Rollback: `sudo rm /etc/apparmor.d/bwrap && sudo systemctl reload apparmor`.

### What might need doing on other distributions

Not verified here — treat as leads, and use the two check commands above to
confirm before and after.

- **Debian** — some configurations ship `kernel.unprivileged_userns_clone=0`.
  Set it to `1`, persisted in `/etc/sysctl.d/`. Debian has no AppArmor
  userns-transition profile to add, so the sysctl is the lever.
- **RHEL, CentOS Stream, Rocky, Alma** — older releases capped
  `user.max_user_namespaces` at `0`. Raise it in `/etc/sysctl.d/`. Current
  releases generally ship a usable default.
- **Arch and derivatives** — stock kernels are fine; `linux-hardened` restricts
  userns and needs `kernel.unprivileged_userns_clone=1`.
- **SELinux hosts** — a denial appears in the audit log rather than as silent
  capability stripping, so `ausearch -m avc` is the place to look.
- **Containers and unprivileged LXC** — nested user namespaces may be
  unavailable regardless of sysctl, and the runtime may need
  `--security-opt seccomp=unconfined` or an equivalent. A host that cannot
  provide the namespace at all cannot run Codex agents.

If a host cannot be fixed, it can still run `claude` or `pi` harness sessions,
which do not use bubblewrap.

## Install

Install at least one harness first. These are the vendors' install commands;
install every harness you intend to use:

```sh
npm install -g @anthropic-ai/claude-code
claude --version
```

and/or:

```sh
npm install -g @openai/codex
codex --version
```

and/or:

```sh
npm install -g @earendil-works/pi-coding-agent
pi --version
```

### From a release package

Download the package for your platform from the
[GitHub Releases](https://github.com/clickety-clacks/tightbeam/releases) page.
Each release contains packages for `darwin-aarch64` and `linux-x86_64`, a
`SHA256SUMS` file, and `release-provenance.json` naming the exact tagged commit
and workflow run that produced them. (Exception: `v0.1.8+1325` was published
manually from the e2e-proven packages; its SHA-256 hashes are in the release
notes instead of a `SHA256SUMS` asset.) Verify the downloaded package before
installing it:

```sh
# Linux
sha256sum -c SHA256SUMS --ignore-missing

# macOS
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Install the verified package:

```sh
npm install -g ./tightbeam-<version>-<os>-<arch>-build<N>.tgz
tightbeam --version
tightbeam-gateway                  # boots the gateway in the foreground
```

For a service-managed installation, `npm install -g` replaces the executable on
disk but does not restart the running gateway. Restart the service after every
upgrade, then verify it is active:

```sh
# Linux
sudo systemctl restart tightbeam.service
systemctl is-active tightbeam.service
```

On macOS, restart the installed Tightbeam launchd service, then verify it with
`sudo launchctl print system/com.tightbeam.gateway`.

`tightbeam-gateway` is the release equivalent of `mix run --no-halt`: same
foreground process, same environment contract, same first-boot behaviour. It
creates the base dir, seeds the identity repository, creates `state.db` and
`bin/`, and prints the NOT READY summary described below. Continue from
**Connect your first client**; everything after this point is identical for
both install paths.

The CLI and the gateway ship in one package on purpose, so their version
handshake holds by construction — you cannot end up with a CLI that its gateway
refuses. `npm install -g` installs both in npm's global bin directory. If you
want easy access to the Tightbeam CLI, make sure npm's global bin directory is
in your `PATH`. Tightbeam does not change your `PATH` for you. Nothing else is
added to the machine, and neither Elixir nor Rust is needed to run either one.

### Cutting a release

Releases are version tags on canonical `main`, not release branches. First set
the version in `cli/Cargo.toml`, land it on `main`, and wait for the ordinary
`main` CI run to pass. Then create and push the matching annotated tag:

```sh
git fetch origin
git merge --ff-only origin/main
git tag -a v<version> -m "Tightbeam v<version>"
git push origin v<version>
```

The tag must be exactly `v<major>.<minor>.<patch>`, must match the Cargo package
version, and must point to the current `origin/main` tip. The tag workflow reruns
the unchanged macOS and Linux test gates, builds both packages from that tagged
commit, and creates one GitHub Release containing the packages, checksums, and
provenance record. If any gate or either platform build fails, no GitHub Release
is created.

### From source

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

### More than one gateway on one machine

Supported. Give each instance its own `TIGHTBEAM_BASE_DIR` and its own
`TIGHTBEAM_PORT` and you are done.

A release build also runs a named Erlang node, and two nodes on one machine
cannot share a name. `tightbeam-gateway` derives the name from the port, so
distinct ports already give distinct names and there is nothing extra to set.
`TIGHTBEAM_NODE` names it yourself if you want to; the only way to collide is to
give two instances the same port, or to pin them to the same name by hand.

That name is also how `tightbeam-gateway stop`, `remote` and `pid` FIND a running
gateway — so **run them the same way you started it**. Same port (or same
`TIGHTBEAM_NODE`), same machine name. When they disagree you do not get a clear
message; you get a connection failure like

```
--rpc-eval : RPC failed with reason :noconnection
```

about a gateway that is running perfectly well. It means the name they looked for
is not the name it started under. Same discipline as the CLI, for the same
reason.

With at least one usable harness through preflight, the first boot creates the
base dir and serves, but **cannot run a turn yet**: it has no credentials, so it
prints a NOT READY summary naming every gap. Harness homes are projected per
machine and harness during reconciliation or launch, not necessarily at boot.
Leave this process running and complete the remaining steps from another
terminal.

### Connect your first client — do this BEFORE onboarding

A fresh org has no users. The first user becomes the admin through either of
these bootstrap paths:

- For an agent-driven install on the box, create the user locally:

  ```sh
  <base_dir>/bin/tightbeam add-user <userId>
  ```

  This empty-org exception is local to the box. After the first user exists,
  the same command uses ordinary admin authentication, for example
  `tightbeam add-user <userId> --as-user <adminUserId>`; pass `--admin` when the
  new user should also be an admin.
- For a human with a client, point it at `TIGHTBEAM_ADVERTISED_URL` and pair
  with a claimed name. The first client is auto-approved and its user becomes
  the admin immediately, with no approval step because nobody exists to
  approve it yet.

Do one of these first. Onboarding is admin-only, so it fails with
`forbidden: admin required` until the first admin exists.

Every client after this one pairs as `pending` and must be approved by the admin.

### Then onboard a credential, per provider

An existing vendor CLI login is invisible to Tightbeam; Tightbeam keeps its own
credential. This command is the only supported credential path — running the
vendor's own `login` does not onboard Tightbeam:

```sh
<base_dir>/bin/tightbeam onboard <provider> --as-user <userId>
```

`<provider>` is the credential provider — **`anthropic`**, **`openai`**, or
**`opencode-go`** — not the harness name. OpenCode Go is API-key-only:

```sh
printenv OPENCODE_API_KEY | <base_dir>/bin/tightbeam onboard opencode-go --api-key
```

`<userId>` is the admin created by that first pairing. From a
release install `tightbeam` is already on PATH, so the `<base_dir>/bin/` prefix
is only needed on a source install.

**RUN IT ONCE PER HARNESS YOU INTEND TO USE.** A credential is per provider, and
onboarding one leaves the other unusable — a session placed on an un-onboarded
harness fails naming the credential it lacks. The boot summary already lists
exactly what is missing, one line per provider, with the command for each: if it
named two, run two. With both installed and nothing chosen, a fresh org defaults
to the first registered harness; with only one installed, that one is the
default and its own model comes with it, so a single-harness box needs no model
configuration at all.

### Then learn the working identity

```sh
<base_dir>/bin/tightbeam learn agentic-engineering --as-user <userId>
```

`<base_dir>/bin/tightbeam unlearn agentic-engineering --as-user <userId>` is its
inverse. Credentials are per provider/harness per machine, while harness homes
are per machine and harness; learning or unlearning changes neither, so it
never requires onboarding again.

### Then run a real turn

In the connected client, open Main and send `hello, who are you?`. The turn
loop works when the assistant reply arrives and the typing indicator clears.

**This is not the end of the install.** One required step remains — installing
the service (below). Until that is done you have a gateway that dies with your
terminal and does not come back after a reboot.

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

## Installing as a service — REQUIRED, and the install is not complete without it

**This is the last required step of installation, not an optional extra
afterwards.** A foreground gateway — `tightbeam-gateway` in a terminal, in tmux,
under `mix run --no-halt` — dies when you log out and does not come back after a
reboot. An install that leaves you with a foreground process is not finished.

**THIS STEP NEEDS ROOT, AND A HUMAN.** Both unit files below are installed with
`sudo`. An agent performing this install on someone's behalf must STOP HERE and
hand the remaining commands to a person; it cannot complete the install alone.
Say so plainly rather than substituting a foreground workaround.

**What skipping it actually costs**, measured on a production host that ran
foreground in tmux for a day (2026-08-05):

- the machine rebooted and the gateway did not come back — every client sat
  timing out until someone noticed and started it by hand;
- the log was gone. A foreground launcher usually redirects with `tee`, which
  TRUNCATES on restart, so the run you need after a crash is destroyed by the
  restart. Under a service manager the log is the journal (linux) or the
  `StandardOutPath` files (macOS), and the previous boot is still readable —
  `journalctl -u tightbeam -b -1`. That difference is the whole post-mortem.

The service must **start with no interactive login**, **survive logout**,
**survive reboot**, and **restart on failure**.

The service must **start with no interactive login**, **survive logout**,
**survive reboot**, and **restart on failure**.

### The environment that matters

| variable | why |
|---|---|
| `TIGHTBEAM_LOCAL_HOST_NAME` | **Set this. It is the one that bites.** The homes tree is keyed `homes/<machine>/<harness>`, and the machine name defaults to the OS hostname. If the hostname is unstable — a container that gets a new id per start, a renamed machine — every restart projects a NEW home tree and silently orphans the durable harness state (codex `sessions/`, claude `projects/`) under the old name. It does not fail; it just quietly stops finding the old conversations. Pin it to a name you choose and never change it. |
| `TIGHTBEAM_BASE_DIR` | The org: `auth/`, `identity/`, `homes/`, `state.db`, `work/`. Defaults to `TIGHTBEAM_HOME`, else `~/.tightbeam`. |
| `TIGHTBEAM_PORT` | Rewritten into `gateway.json` at every boot. |
| `TIGHTBEAM_NODE` | The release's Erlang node name. Defaults to `tightbeam_gateway_<port>`, which is already unique per instance — set it only if you want to choose the name. |
| `TIGHTBEAM_ADVERTISED_URL` | The URL clients are told to connect back on. `mix tightbeam.doctor` fails without it. |
| `TIGHTBEAM_DEFAULT_MODEL` | The default model itself, undecorated (`claude-sonnet-5`). Must be live for the default harness. It is a single global, so on a two-harness host one harness will report its default as unselectable — that is expected, not a fault. |
| `TIGHTBEAM_DEFAULT_EFFORT` | The default reasoning level (`low`…`max`). Required when the default model offers effort tiers — a model is selected by FIELDS, never one packed string. |
| `TIGHTBEAM_DEFAULT_CONTEXT` | The vendor's context-window variant, when it offers more than one (`1m`). Omit for the model's default window. |
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
    <!-- npm decides where -g bins land; ask it: `command -v tightbeam-gateway` -->
    <string>/Users/you/.local/bin/tightbeam-gateway</string>
  </array>
  <key>WorkingDirectory</key><string>/Users/you</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TIGHTBEAM_LOCAL_HOST_NAME</key><string>gibson</string>
    <key>TIGHTBEAM_BASE_DIR</key><string>/Users/you/.tightbeam</string>
    <key>TIGHTBEAM_PORT</key><string>11373</string>
    <key>TIGHTBEAM_ADVERTISED_URL</key><string>ws://gibson.local:11373</string>
    <key>PATH</key><string>/Users/you/.local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
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
WorkingDirectory=/home/you
# npm decides where -g bins land; use the output of: command -v tightbeam-gateway
ExecStart=/home/you/.local/bin/tightbeam-gateway
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
