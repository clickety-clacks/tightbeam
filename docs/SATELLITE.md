# Installing a satellite (work) host

> **This page explains what a satellite is and what its operator must do by hand.
> To bring one up and prove it, run `docs/ASSIMILATION-E2E.md`** — that is the
> golden path and the scored one. The manual host declaration below predates the
> `assimilate` verb; see that runbook's Q4 for the open question about which host
> registration route wins when both are used.

A satellite is a machine where agent *harnesses* run while the substrate,
ledger, and stores stay on the gateway host (spec §Placement). There is no
satellite daemon: sshd is the transport, rsync materializes non-secret
session identity, and the gateway does the rest. Prerequisite: the gateway host can ssh to the
satellite non-interactively (shared keys — you bring these).
The gateway host also needs at least one registered harness CLI installed and on PATH.
It ALSO needs its own credential for every harness you intend to spawn, even when
those sessions only ever run on satellites: the gateway derives each harness's model
catalog on its own host, and a spawn is refused when the catalog is missing (see
§What failure looks like). A satellite grant does not cover the gateway.

## On the satellite (one-time, by the operator)

1. **Base dir** — `mkdir -p ~/.tightbeam/auth/<harness>` for each harness
   that will run here (`claude`, `codex`). `homes/` is created by delivery.
2. **Credentials** — run Tight Beam onboarding independently on this
   machine: `tightbeam onboard openai` for Codex device-code, and
   `tightbeam onboard anthropic` for Claude setup-token. Never copy,
   harvest, scp, or rsync credentials between machines. In an operator
   shell, set `TIGHTBEAM_MACHINE` to this host's registered name alongside
   the gateway discovery variables; agent shells receive it automatically.
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
4. **Agent CLI** — put a `tightbeam` executable on a path of your choosing
   (the reference CLI is `node <checkout>/dist/cli/main.js`; a shim script
   suffices). Agents on this host reach the gateway via the TIGHTBEAM_URL /
   TIGHTBEAM_TOKEN env the gateway injects — no gateway.json needed here.

## On the gateway host (config)

Declare the host and how to reach it (name is yours; "local" is reserved):

```sh
export TIGHTBEAM_ADVERTISED_URL="http://<gateway-tailnet-addr>:<port>"
export TIGHTBEAM_HOSTS='{
  "work-1": {
    "ssh": "work-1",
    "base_dir": "/Users/you/.tightbeam",
    "cli_bin": "/Users/you/.tightbeam/bin"
  }
}'
```

`ssh` is anything your ssh config resolves. `advertised_url` must be
reachable FROM the satellite (never 127.0.0.1).

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

A spawn refused `catalog_unavailable` naming a **GATEWAY host** is the
prerequisite above, not a satellite fault: the satellite's own grant is fine and
the gateway simply cannot derive that harness's catalog. The message names the
provider, the gateway host, and the repair (`tightbeam onboard <provider>` on the
gateway). Onboarding the satellite again will not fix it.
