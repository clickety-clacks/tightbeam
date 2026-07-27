# Smoke scorecard — 2026-07-27 @ a0fcde2 (linux gateway)

Client build: sim-client (driver) · Operator: claude (sat-e2e-linux) ·
Scope: the LINUX-GATEWAY half of the {gateway, satellite} x {linux, macOS} matrix.

RUN VERDICT: **FAIL** — both registered harness legs failed their credential
preflight on the gateway host and were never booted (SMOKE P3). No journey step
(1–16) and no rails/roles step (17–33) reached a verdict on either harness.
Satellite placement was never exercised.

## Topology actually used

Neither SMOKE.md nor SATELLITE.md names hosts; this run's hosts were:

| role | host | OS / kernel | toolchain | outcome |
|---|---|---|---|---|
| gateway under test | shrdlu (`clu@shrdlu`, tailnet 100.98.120.22) | Ubuntu, `Linux shrdlu 6.8.0-134-generic x86_64` | Erlang/OTP 28 (erts-16.4) + Elixir 1.19.5-otp-28 (host asdf installs, read-only); node v22.22.2 (`/usr/bin/node`); codex-cli 0.145.0 (`~/.local/bin/codex`); **no claude CLI** | booted, both legs credential-BLOCKED |
| linux satellite (intended) | eurisko (tailnet 100.78.200.74) | Linux | node via asdf shims | reachable 07:28Z, ssh-dark from 07:33–07:35Z onward — **BLOCKED** |
| macOS satellite (intended) | eezo (tailnet 100.71.19.27) | macOS | n/a | gateway cannot ssh to it — **BLOCKED** |
| — | tars | — | — | not used (restricted) |

`eliza` was reached once for inventory only (Linux, no node/claude/codex) and
was not used as a satellite.

**Run install root:** `/home/clu/tb-smoke-lnx-20260727-a0fcde2` — repo clone,
`MIX_HOME`, `HEX_HOME`, `CARGO_HOME`/`CARGO_TARGET_DIR`, both template orgs, and
the boot-check org all live inside it. Nothing was installed outside it. The
host-global Erlang/Elixir were used READ-ONLY; no apt and no asdf plugin
install was performed.

**Tree transport (no git remote exists):** `git bundle create` on eezo → `scp`
to shrdlu `/tmp` → `git clone` into the run root → `git remote remove origin`.
The driver's own `Provenance.stamp/1` reported a CLEAN worktree and stamped the
scorecard `a0fcde2` with no DIRTY marker.

**Toolchain deviation from the brief:** the brief's proven recipe was an
`elixir-otp-26.zip` unzipped into the run root against asdf Erlang 26.2.5. The
host already had asdf `erlang/28.5` and `elixir/1.19.5-otp-28` installed
(install logs dated Jul 23), which satisfy `mix.exs ~> 1.19` while installing
nothing. Those were used instead. `mix deps.get` + `mix compile` completed clean
including the exqlite NIF, so the deviation cost nothing; recorded for
reproducibility.

## Scorecard — driver output (`scripts/client_e2e.exs`, both harnesses)

Emitted at `/home/clu/tb-smoke-lnx-20260727-a0fcde2/scorecard-emptyauth.md`.

| Step | claude@shrdlu | codex@shrdlu | notes |
|---|---|---|---|
| P-claude auth | FAIL | N/A | "the harness reports its credential store is not ready" |
| P-codex auth | N/A | FAIL | "the harness reports its credential store is not ready"; with the host's own codex store seeded (second run below) the same row is `FAIL — credential rejected: {:http_status, 401}` |
| 1 boot [J0] | INCOMPLETE | INCOMPLETE | preflight-blocked: leg not booted (SMOKE P3) |
| 2 pair [J0] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 3 converse [J1] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 4 tool use [J1] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 5 create stream [J2] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 6 rename stream [J2] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 7 retire stream [J2] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 8 cancel [J3] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 9 queueing [J4] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 10 concurrency [J5] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 11 /new [J6] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 12 /compact [J6] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 13a /model [J6] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 13b model change [J6] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 13c model footer | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 14 restart resilience [J7] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 15 restart queue survival [J7] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 16 wakes [J8] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 16b scheduled wake [J8] | INCOMPLETE | INCOMPLETE | preflight-blocked |
| 17–23 rails | INCOMPLETE | INCOMPLETE | not attempted: no bootable leg |
| 24 satellite propagation | BLOCKED | BLOCKED | see F3/F4 — no satellite was usable |
| 25–33 roles | INCOMPLETE | INCOMPLETE | not attempted: no bootable leg |

Second driver run, codex leg only, with shrdlu's OWN `~/.codex/auth.json`
seeded into the org store (host-local; nothing copied between machines) —
`/home/clu/tb-smoke-lnx-20260727-a0fcde2/scorecard-codexseed.md`:

```
| P-codex auth codex | FAIL | codex: credential rejected: {:http_status, 401} |
```

## Leg verdicts

- claude@shrdlu: **FAIL** (preflight FAIL — credential store absent; leg not booted)
- codex@shrdlu: **FAIL** (preflight FAIL — credential present but DEAD, 401 `token_expired`; leg not booted)
- any-harness@eurisko (linux satellite): **BLOCKED** — host went ssh-dark mid-run
- any-harness@eezo (macOS satellite): **BLOCKED** — gateway cannot ssh to it

## Matrix rows exercised this run

| harness-support.md row | leg | verdict |
|---|---|---|
| (none) | — | no harness session ran on any host; no matrix claim earned a checkmark |

## Findings

**F1 — the linux gateway has no usable harness credential, for either harness.
This is what blocked the run.**
- claude: no credential store at all. `~/.tightbeam-beam/auth/claude/` is empty,
  there is no `~/.claude`, and `find / -name oauth-token` over the whole host
  returns zero hits. Product preflight: `FAIL — the harness reports its
  credential store is not ready`.
- codex: a store exists (`~/.codex/auth.json`, `last_refresh
  2026-04-30T18:57:11Z`) and is dead three ways:
  (a) direct probe of `GET https://chatgpt.com/backend-api/wham/accounts/check`
  with that grant → HTTP 401 `"code": "token_expired"`;
  (b) `codex exec` refresh attempt → `Failed to refresh token: Your access token
  could not be refreshed because your refresh token was already used. Please log
  out and sign in again.` (repeated, then `401 Unauthorized` on the responses
  websocket) — the refresh token is spent, so this is not self-healing;
  (c) product preflight against that store → `FAIL — credential rejected:
  {:http_status, 401}`.
- Repair for both is interactive onboarding (`tightbeam onboard anthropic`
  setup-token / `tightbeam onboard openai` device code) on shrdlu itself.
  SATELLITE.md forbids copying a grant in from another machine, so this cannot
  be completed non-interactively. **BLOCKED: claude@shrdlu and codex@shrdlu,
  blocker = no live grant on the gateway host, needs Flynn at a browser.**
- The one thing this DID verify on real hardware: SMOKE's P1–P3 contract behaved
  exactly as written. The dead grant surfaced as an explicit credential
  rejection BEFORE anything booted, and the leg was refused rather than booted
  into a downstream `model_unavailable` masquerade.

**F2 — no claude CLI on the gateway host.** `mix tightbeam.doctor` on shrdlu:
`harness_binary:claude WARN :not_found`, `harness_binary:codex PASS codex-cli
0.145.0`. Even with a grant, a claude leg on shrdlu needs the CLI installed
first. Not fixed (verification run).

**F3 — macOS satellite unreachable from the gateway: SATELLITE.md's stated
prerequisite is not met.** From shrdlu, `ssh -o BatchMode=yes clu@eezo` and
`ssh -o BatchMode=yes mike@eezo` both return `Permission denied
(publickey,password,keyboard-interactive)`. eezo is up and `active` on the
tailnet (100.71.19.27), so this is key trust, not connectivity. No key was
installed — that is an operator ceremony, not a verification step.
**BLOCKED: macOS satellite coverage, blocker = no gateway→eezo ssh trust.**

**F4 — the linux satellite went ssh-dark mid-run.**
- 07:28Z: `ssh -o BatchMode=yes eurisko` succeeded; the host reported
  `eurisko / Linux`, node on PATH via asdf shims, and both credential shapes
  present: `~/.tightbeam/auth/claude/oauth-token` and `~/.codex/auth.json`.
  Its codex grant probed **LIVE** (`accounts/check` → 200) — so the satellite
  side of the codex story was healthy at that moment.
- 07:33Z: an `scp` from shrdlu to eurisko failed `scp: Connection closed`.
- 07:35Z onward: `ssh` to port 22 times out — three sequential retries via the
  ssh-config name, and once by tailnet IP with `-F /dev/null`. `tailscale
  status` still lists eurisko, as `idle`.
- Consequences, recorded as NOT verified rather than assumed: eurisko's **claude**
  grant liveness (the probe never ran); eurisko's `rsync`/`scp`/sftp-server
  availability, which SATELLITE.md requires — the 07:33Z `scp: Connection
  closed` is ambiguous between a missing sftp-server and the onset of the
  outage, and it stayed ambiguous because the host went away.
- **BLOCKED: linux satellite coverage, blocker = eurisko sshd unreachable from
  07:33Z.** Note this would have been blocked anyway by F1: SATELLITE.md
  §"What failure looks like" says a spawn is refused `catalog_unavailable` when
  the GATEWAY cannot derive the harness catalog, and shrdlu cannot.

**F5 — adapters and `bin/` must be hand-provisioned, and the driver does not
carry them.** Confirms the brief's #46 note. `LegGateway.provision!/2` copies
only `auth homes identity` (`@copied`), while both harnesses resolve their
adapter at `<base_dir>/adapters/node_modules/.bin/<adapter>` and boot preflight
requires a harness CLI under `<base_dir>/bin`. On main a gateway host cannot
self-provision the local adapter (the local path refuses by policy), so a leg
base_dir produced by the driver has neither. For this run they were placed by
hand from the host's existing `~/src/openclaw/node_modules`
(`@zed-industries/codex-acp 0.15.0`, `@agentclientprotocol/claude-agent-acp`)
plus a `bin/codex` shim. **This gap was not exercised end-to-end** — no leg
booted — so it is recorded as a provisioning-shape observation, not a proven
adapter failure.

**F6 — a pre-existing org's identity repo does not boot on a0fcde2.** Booting
against a copy of the host's Jul-23 org identity (`~/.tightbeam-beam/identity`,
HEAD 4df8a65) aborts application start:

```
** (ArgumentError) identity repository is missing required refs: main, tightbeam/upstream, tightbeam/live.
   Repair with: restore main from a known-good identity backup; git -C .../identity branch tightbeam/upstream main; ...
       (tightbeam 0.1.0) lib/tightbeam/identity.ex:63: Tightbeam.Identity.verify_required_refs!/1
       (tightbeam 0.1.0) lib/tightbeam/gateway.ex:396: Tightbeam.Gateway.preflight!/1
```

Cause, verified on the SOURCE repo (not a copy artifact): that identity repo's
only branch is `master` (`git symbolic-ref HEAD` → `refs/heads/master`), while
`Identity.init!/1` now creates `main` + `tightbeam/upstream` + `tightbeam/live`
and `verify_required_refs!/1` demands all three. A fresh identity created by the
gateway at boot has all three and boots fine. So orgs created before the
required-refs rule need the documented repair; the failure is loud and the
message names the exact commands, which is good failure semantics, but nothing
in `docs/UPGRADE.md` mentions it.

## Supplementary evidence (NOT step verdicts)

SMOKE P3 blocks the legs, so none of the following is scored as a PASS on any
step. They are recorded because nothing on real hardware had been verified
tonight and these were observed directly:

- **a0fcde2 builds clean on Linux/OTP 28.** `mix deps.get` then `mix compile` in
  the run root: `==> tightbeam / Compiling 73 files (.ex) / Generated tightbeam
  app`, exqlite NIF built.
- **A gateway from that tree boots on shrdlu and answers `/version`.** Fresh org
  (`bootcheck-org`, no credentials), port 12200:
  `{"adapters":{},"protocolVersion":1,"server":"tightbeam"}`; listener owned by
  `beam.smp` pid 4115421. This is step 1's stated PASS condition, observed —
  but on a credential-less org outside any leg, so step 1 remains INCOMPLETE
  in the scorecard.
- **The boot log states the credential gap per harness with its repair**
  (`no credential (:missing) — the model catalog is empty, so no model can be
  selected. Onboard it with: tightbeam onboard <harness> --as-user <userId>`).
- **`mix tightbeam.doctor` refuses verdicts it cannot back**: `harness_auth:*`
  and `default_model` come back INFO/"not verified here … UNKNOWN" with an
  explicit "do not re-onboard on the strength of this row", pointing at
  `ClientE2E.preflight/2` instead. `base_dir_identity PASS`, `advertised_url
  PASS`, `hosts_registered PASS (local host shrdlu resolves)`.

## Process notes

- Nothing was fixed. Every defect above is recorded with its evidence and left
  in place.
- Process safety: the gateway this run started (pid 4115421) was matched by full
  command line before being signalled, `kill`ed plainly, confirmed gone, and
  port 12200 confirmed released. shrdlu's own long-running gateway (pid 2635655,
  port 11373, base_dir `~/.tightbeam-beam`) was left untouched. pids 7822 and
  20088 were never signalled anywhere.
- Artifacts left on shrdlu under the run root: the two scorecards, the repo
  clone at a0fcde2, `gateway-boot.log` (identity-refs failure) and
  `gateway-boot2.log` (successful boot).
