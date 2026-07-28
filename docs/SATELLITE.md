# Installing a satellite (work) host

> **This page explains what a satellite is and what its operator must do by hand.
> To bring one up and prove it, run `docs/ASSIMILATION-E2E.md`** — that is the
> golden path and the scored one. `tightbeam assimilate` is the only way to register
> a host; there is no manual declaration.

A satellite is a machine where agent *harnesses* run while the substrate,
ledger, and stores stay on the gateway host (spec §Placement). There is no
satellite daemon: sshd is the transport, rsync materializes non-secret
session identity, and the gateway does the rest. Prerequisite: the gateway host can ssh to the
satellite non-interactively (shared keys — you bring these).
The gateway host also needs at least one registered harness CLI installed and on PATH.
It needs a credential only for the harnesses it runs ITSELF. A model catalog is
derived on the host that owns the credential, so a harness that only ever runs on
satellites needs a grant only on those satellites — the gateway holds nothing for
it and demands nothing.

## On the satellite (one-time, by the operator)

1. **Base dir** — `mkdir -p ~/.tightbeam/auth/<harness>` for each harness
   that will run here (`claude`, `codex`). `homes/` is created by delivery.
2. **Credentials** — run Tight Beam onboarding independently on this
   machine: `tightbeam onboard openai` for Codex device-code, and
   `tightbeam onboard anthropic` for Claude setup-token. Never copy,
   harvest, scp, or rsync credentials between machines. No operator env is
   needed: step 5's provisioned file supplies both the gateway endpoint and
   this host's registered name. `TIGHTBEAM_MACHINE` still overrides the name
   if you need it to, and a satellite provisioned by a gateway too old to have
   written the name says so and tells you to set it.
3. **Runtime + adapters** — install node and the ACP adapter packages
   (`@agentclientprotocol/claude-agent-acp`, `codex-acp`) at a path of your
   choosing. Also install `rsync` (standard on macOS/Linux).
4. **The harness CLIs themselves** — `claude` and/or `codex`, on a PATH a
   **non-login ssh shell** can see. These are a prerequisite, like node and
   rsync: Tight Beam installs Tight Beam's plumbing on a satellite, not the
   vendors' software. Onboarding and turns invoke these binaries **directly**
   (`claude setup-token`, `codex login --device-auth`) — the ACP adapters wrap
   them and cannot stand in for them. A host without them assimilates fine and
   then cannot run anything, failing at the onboarding ceremony with a bare
   `command not found`. Assimilate does not yet check for them (#76).
5. **Agent CLI** — `assimilate` ships the `tightbeam` binary into
   `<base_dir>/bin`. Agents on this host reach the gateway through the
   TIGHTBEAM_URL / TIGHTBEAM_TOKEN env the gateway injects into every adapter
   launch, carrying that session's own token; they need nothing on disk. An
   **operator** shell has no session and no injected env, so the gateway writes
   `<base_dir>/gateway.json` here — `{"url": "<advertised url>", "cliToken":
   "<org token>", "machine": "<this host's registered name>"}`, mode 0600 — and
   that file is what makes step 2's
   `tightbeam onboard` work on this machine. It names the advertised url; the
   gateway host's own gateway.json carries a port instead, and 127.0.0.1 is
   correct only there. It is written at `register-host` (assimilation's last
   step) and re-written for every registered host at gateway boot, so a rotated
   org token or a host assimilated by an older build heals with a restart, not a
   ceremony. Note what it holds: the ORG token, which is broader than the
   per-session token the gateway injects into agents here.

## On the gateway host (config)

One variable, and it is required before any remote host is registered:

```sh
export TIGHTBEAM_ADVERTISED_URL="http://<gateway-tailnet-addr>:<port>"
```

It must be reachable **from the satellite** — never `127.0.0.1`. A satellite's
adapters and its operator CLI both reach the gateway by this address, so
registering a remote host without it fails at registration rather than at first
turn.

Hosts are **not** declared by hand. `tightbeam assimilate <ssh-dest> --name <name>`
probes the machine, installs Tight Beam's plumbing, and records the host in
`<base_dir>/hosts.json` — the one registry. The name is yours; `local` is
reserved, and the gateway's own machine is always present under its real hostname.
Run `docs/ASSIMILATION-E2E.md` for the full procedure.

A `TIGHTBEAM_HOSTS` env var used to be the way to declare a host. It was **removed**
in `8c0dfa0`: it layered a second store over the registry and won on collision, so
a stale entry silently overrode what assimilate had just written and the gateway
dialled a destination it had never installed to. Nothing reads it now.

## Allow and use it

Placement is law, not suggestion: a host is usable only where an archetype's
`where` admits it. In YOUR identity dir on the gateway host
(`<base_dir>/identity/archetypes/`, instance config — never this repo):

```toml
# coder.toml
where = ["work-1"]
[defaults]
harness = "codex"
```

Then `tightbeam spawn --display "Coder" --archetype coder ...` places the
session on work-1; `tune set_host` moves sessions among the archetype's
allowed hosts (fresh model context; chat history is substrate-side and
unaffected). Spawning outside `where` is denied, citing the check.

The shared home is `<base_dir>/homes/<machine>/<harness>`. Elected skills
are copied only to the exact session cwd under `.codex/skills/tightbeam__*`
or `.claude/skills/tightbeam__*`; guidance arrives in the harness instruction
channel. Credentials remain in this machine's local auth store.

## What failure looks like

An unreachable satellite degrades exactly like a dead adapter: backoff,
circuit-open after repeated failures, visible in `/version`, turns fail fast
with a reason. Fix connectivity; the circuit closes on the next successful
start. Nothing on the satellite supervises anything — the gateway owns all
lifecycle.

A spawn refused `catalog_unavailable` names the host whose catalog is missing,
which is the host the session would have run on. The message names the harness,
that host, the provider, and the repair (`tightbeam onboard <provider>` on that
host). Onboard where the message says: the gateway's grant does not stand in for
a satellite's, and a satellite's does not stand in for the gateway's.
