# Smoke runbook — core user journeys

Run this after any change to prove core functionality is alive. It walks the
operator journeys end-to-end from a real client (the iOS simulator) against a
freshly-booted gateway; steps that are awkward to drive through the simulator
have a CLI fallback (marked ⌥). Every step names its PASS condition — an
observable frame, bubble, or row. The DB checks use
`sqlite3 <base_dir>/state.db`.

Conventions: GATEWAY = the gateway under test (fresh base_dir unless the run
says otherwise). First device to pair becomes the admin user. `tb` = the
reference CLI with TIGHTBEAM_URL/TIGHTBEAM_TOKEN pointed at GATEWAY (token
from `<base_dir>/gateway.json`).

## Harness parity (normative for every run)

This runbook is a MATRIX, not a list: one full pass PER HARNESS the org
supports (today: claude on `fable`, codex on `gpt-5.6-sol[medium]`), using a
session of that harness for every step. A smoke run's verdict is
INCOMPLETE — not passed — until every harness leg has run or been WAIVED by
name with the blocker stated (e.g. "codex leg waived: no codex grant in the
org's auth store"). A silent single-harness run is not a smoke run.

Steps behave identically across harnesses unless annotated:
- **[claude-only]** — the mechanism exists only on claude per
  `shared/specs/tightbeam/harness-support.md` (the canonical matrix). On
  codex the step becomes its NEGATIVE check where one is stated.
- **[codex-only]** — the mechanism exists only on codex; claude does not run
  that step.
- **[divergent]** — both harnesses run it, PASS conditions differ as noted.

Every `codex exec` invocation redirects `</dev/null`; an open stdin hangs it.

The matrix document is the authority on which rows diverge; a smoke step
verifying a matrix row cites it, and a matrix claim with no verifying smoke
step or test is marked unverified there. Discovering un-annotated divergence
during a run is itself a FINDING: record it, amend the matrix and this
runbook in the same change.

Per-harness annotations for the existing sections:
- §1 step 4 (tool use): [divergent] — codex tool titles/progress vocabulary
  differ; PASS is still "progress label during turn, output reported".
- §6 step 13 (model picker/footer): [divergent] — codex refs are
  `gpt-5.6-sol[low..xhigh]`, `gpt-5.6-luna[medium]`.
- §9 rails (17–24): [divergent]. Claude asserts hooks in `settings.json`;
  codex asserts `hooks.json` with the org entries plus the trailing
  `tightbeam-probe` entry, still NO `settings.json` in the codex home.
  Neither home contains archetype guidance.
- Skills verification (when a step exercises one): [divergent] — claude
  invokes via its native Skill tool; codex must READ the skill file by the
  path the Operations pointer names. PASS for codex is the agent quoting
  skill content it read on demand, not a claim of native discovery.

## Preflight: credential validity (FIRST, before anything boots)

Dead OAuth does not fail as "auth" downstream — it masquerades (an expired
claude grant surfaces as "Invalid value for config option model: <ref>",
because no auth → no model catalog → every value invalid; this cost a
diagnostic hour on 2026-07-18). So the run starts by proving every grant
in scope is LIVE, per {harness × host}: the gateway machine and every
satellite a leg will place sessions on.

P1. claude, per host (run ON the host; ssh for satellites):
    `env CLAUDE_CONFIG_DIR=<scratch dir> CLAUDE_CODE_OAUTH_TOKEN=$(cat
    <base_dir>/auth/claude/oauth-token) claude -p "reply with exactly: OK"`
    PASS: the reply "OK". FAIL signatures: "OAuth session expired and
    could not be refreshed" or persistent invalid-token 401s. Repair with
    `tightbeam onboard anthropic` ON that host; never harvest or copy a
    rotating Claude login.
P2. codex, per host: `env CODEX_HOME=<base_dir>/auth/codex codex login
    status`. PASS: reports logged in. (If the codex leg is waived for a
    missing grant, say so here — the waiver is named at preflight, not
    discovered mid-run.)
P3. Rule: a preflight FAIL blocks that {harness × host} leg until fixed or
    waived by name. After a clean preflight, any downstream auth-shaped
    failure is a FINDING (something rotated or leaked mid-run), never
    noise to shrug at.

## Fresh-org provisioning (what "auth seeded" actually means)

A fresh base_dir is NOT ready after copying files around; each item below is a
seam with its own shape, and every one of these was rediscovered the hard way
on 2026-07-25:

- **Credentials are store rows, not loose files.** Each provider needs all
  three: the store backing file (`auth/codex/auth.json`; claude
  `auth/claude/oauth-token` — a full 108-char `sk-ant-oat…` setup token), the
  home symlink (`homes/<machine>/<harness>/…` → store file), and the metadata
  row (`auth/<harness>/.tightbeam/credential.json` with `"onboarded": true`).
  The sanctioned path is `tightbeam onboard <provider>` on the host; the
  manual recipe above is for smoke orgs only.
- **Codex model catalog** reads `homes/<machine>/codex/models_cache.json` —
  seed it (copy from a live `~/.codex/models_cache.json`) or every spawn dies
  `catalog_unavailable`.
- **Default model must match default harness** (`TIGHTBEAM_DEFAULT_HARNESS` /
  `TIGHTBEAM_DEFAULT_MODEL`, or archetype `[defaults]`); the claude default
  against a codex org fails `model_unavailable` at spawn.
- **The identity repo working tree must stay clean.** Anything hand-placed
  under `identity/` (e.g. a rules fixture) must be COMMITTED, or every
  identity verb wedges with "identity working tree is dirty".
- **`feature_smoke.exs` runs with `mix run --no-start`.** A plain `mix run`
  boots a second gateway that OVERWRITES `gateway.json` and silently redirects
  the smoke away from the gateway under test.

## 0. Boot + pair

1. Boot the gateway (fresh base_dir; auth seeded for the claude harness).
   PASS: `GET /version` returns `{"protocolVersion":1,...}`.
2. In the client: set the server URL, pair with a claimed name.
   PASS: pair succeeds instantly (first user bootstrap), catalog shows one
   "Main" stream, `sync_complete` arrives (app leaves the connecting state).
   DB: one `allowlisted` device; one `users` row with `isAdmin=1`.

## 1. Converse (the fundamental loop)

3. Post "hello, who are you?" in Main.
   PASS: echo bubble immediately; typing indicator ON with live progress
   text (at minimum "Thinking…" flickers); assistant bubble arrives;
   indicator clears WITHOUT lingering. DB: turn row `delivered`.
4. Post a message that provokes tool use ("run `uname -a` and tell me what
   it says").
   PASS: progress label shows a tool title during the turn; assistant bubble
   reports the output; indicator clears.

## 2. Session lifecycle

5. Create a second session (client stream UI; ⌥ `tb spawn --display
   "Smoke" --as-user <admin>`).
   PASS: `stream_created` lands live — the new stream appears in the catalog
   WITHOUT reconnecting. Post in it; assistant replies. DB: sessions row,
   `origin` = the creator.
6. Rename it (client stream UI; ⌥ `tb`/PATCH via session sheet).
   PASS: `stream_updated` — name changes in the catalog live.
7. Delete it (client stream UI; ⌥ `tb retire <key> --as-user <admin>`).
   PASS: `stream_deleted` — gone from the catalog live. DB: sessions row
   `state='retired'` (soft — the row and its messages REMAIN).

## 3. Cancel

8. Post a long task in Main ("count to 200 slowly, one line per number").
   While the indicator is live, hit the client's stop control (⌥ `tb`
   /api/session-control `cancel_current_run`).
   PASS: turn-state `canceled` arrives (terminalState true); indicator and
   progress label clear; NO assistant bubble for that turn afterward.
   DB: turn row `canceled`. Post again — next turn runs normally (lane
   drained on).

## 4. Queueing — one lane, strict order

9. Post three messages back-to-back in Main without waiting: "say ONE",
   "say TWO", "say THREE".
   PASS: three echoes immediately; exactly one turn runs at a time (DB:
   never more than one `running` for the session); three assistant bubbles
   arrive IN ORDER; all three turn rows `delivered`. The indicator stays
   sane throughout (on while running, cleared at the end).

## 5. Concurrency — multiple chats in parallel

10. Create session "Smoke B". Post a slow prompt in Main ("write a haiku
    about each of 10 planets"), then IMMEDIATELY post in Smoke B ("what is
    2+2?"), then a third in Main ("now say DONE").
    PASS: Smoke B's reply arrives while Main's first turn is still running
    (different lanes run in parallel); Main's two turns complete in order;
    ALL turns reach `delivered` with assistant bubbles; no cross-talk
    (each reply in its own stream). DB: at peak, two `running` rows with
    DIFFERENT sessionKeys.

## 6. Slash commands (current contract)

The substrate interprets no message content: slash commands are delivered to
the model as ordinary text. The PASS condition is therefore: the turn
COMPLETES — assistant bubble, indicator clears, `delivered` row. A stuck
indicator on any slash command is a regression (this exact class shipped
once: a `/new` that died pre-model with `Session not found`).

11. `/new` — PASS: completes as above (model replies conversationally; no
    session rotation occurs — that mechanism is future `tune` work).
12. `/compact` — PASS: completes as above.
13. `/model` — PASS: completes as above. Then change the model for real via
    the client's picker (session-status → set_model; ⌥ POST
    /api/session-control `set_model`). PASS: `GET /api/session-status`
    shows the new ref; next turn still completes; AND the client's model
    FOOTER populates (this asserts the Swift decode contract, which raw
    JSON checks miss — a missing required field like sessionKey fails the
    whole decode and the footer silently never fills).

## 7. Restart resilience (deploy semantics)

14. Post a slow prompt; while the indicator is live, SIGTERM the gateway
    (plain `kill <pid>`), wait for exit, restart it.
    PASS: the gateway drains — either the turn completes before exit
    (assistant bubble, then restart is invisible beyond a reconnect blip)
    or, past the drain deadline, the client shows the turn FAILED with
    "interrupted: outcome unknown" after restart — never a silent stuck
    indicator. Client reconnects by itself; replay shows full history; a
    fresh post works and the model still has its context (same harness
    session re-adopted — pointer chain shows `loaded`, not `fallback`).
15. Queue two messages, SIGTERM before the first completes, restart.
    PASS: queued (not-yet-running) turns survive and run to `delivered`
    after the restart without re-sending.

## 8. Wakes (agent comms surface)

16. ⌥ `tb wake --session <mainKey> --prompt "reply with exactly: WAKE OK" --as-user
    <admin>`.
    PASS: the prompt appears in Main as a sender-tagged message; assistant
    replies "WAKE OK". Then `--after 15s` variant: fires after the delay
    (row visible in `tb list` until it fires).

## Recording results — the scorecard

Every run produces a SCORECARD: copy `docs/smoke-runs/TEMPLATE.md` to
`docs/smoke-runs/<date>-<short-sha>.md` and fill it in — one column per
{harness x host} leg, one row per step (P1..P3, 1..33), each cell
PASS / FAIL(note) / WAIVED(blocker) / N/A[harness-only]. The scorecard also
carries a copy of the harness-support matrix's rows with a verified?
column — a run is how matrix claims EARN their checkmarks, and a filled
scorecard is the evidence the matrix cites. Gateway commit hash, client
build, and date go in the header; deviations get a line each. A FAIL on
any step blocks deploy of whatever changed; an incomplete leg without a
named waiver blocks calling the run a pass at all.

## 9. Rails (gate statutes — deterministic tool refusal)

The invariant under test (bible §rails): rails never add guidance — zero
statute bytes in any model's context; enforcement is the runtime refusing
the tool call, with the statute text delivered only as the denial reason.

17. Install law: copy `docs/statutes.toml.example` to
    `<base_dir>/identity/rails/statutes.toml`; restart the gateway.
    PASS [divergent]: gateway boots. After adapter boot, the claude home's
    `settings.json` decodes with one `hooks.PreToolUse` entry per statute
    (matcher "Bash"). The codex home's `hooks.json` decodes with one entry
    per statute plus `tightbeam-probe` LAST; the codex home still has NO
    `settings.json`. Existing sessions are not refreshed automatically.
18. The invariant: assert neither shared home contains `CLAUDE.md`,
    `AGENTS.md`, nor archetype skill directories. Run `tightbeam identity
    status <archetype>` and inspect both composed instruction channels.
    PASS: statute names/text are absent from the composed guidance; guidance
    arrives only through the Codex developer message / Claude system prompt.
19. Live refusal [divergent]: in a scratch git repo, tell a real session to
    run exactly `git reset --hard HEAD`, then `git status`, and report what
    happened. The claude fallback is `claude -p
    --dangerously-skip-permissions` inside the projected home.
    PASS: the reset is refused BEFORE execution. Claude's reply quotes
    `[gate: no-history-rewrites]`; codex quotes `Command blocked by
    PreToolUse hook: [gate: no-history-rewrites] …`. In both, the agent must
    report that the runtime refused it, not that it declined; `git status`
    runs normally and the repo is untouched. Repeat with `git push origin
    main` → `[gate: no-push-main]` refusal.
20. Boot wiring-check evidence [codex-only]: confirm the codex adapter boot
    log contains `gate wiring-check PASS [gate: tightbeam-probe]`. Delete the
    projected home's `hooks.json` and restart the adapter.
    PASS: the adapter REFUSES to boot with `gate_attestation_failed`, and no
    codex session is served. Restore by changing MANIFEST BYTES: edit a
    statute, or delete the home's `.tightbeam/manifest` stamp, then restart
    so ownership-scoped regeneration rewrites `hooks.json`. Confirm the
    home's `sessions/`, history, transcripts, and memory remain byte-identical.
    This demonstrates silent-misconfig detection, NOT tamper resistance.
21. Negative control: an adjacent, allowed command of the same tool
    (`git log`, `git diff`) runs without any refusal text appearing.
    PASS: normal output, no `[gate: ...]` anywhere.
22. Bad law stops the boot: append a statute with `mode = "remind"` to
    the statutes file and restart.
    PASS: the gateway REFUSES to start; the log names the law error
    verbatim ("rails never add guidance; put prose in guidance or a
    skill"). Same check with `pattern = "("` → "invalid gate pattern".
    Restore the file; gateway boots.
23. Law removal: delete the statutes file, restart, re-run step 19's
    forbidden command.
    PASS: no refusal (the gate is gone, not lingering in the shared home);
    step 18 still passes and durable harness state survives.
24. ⌥ Satellite propagation (needs an assimilated host with credentials for
    the harness leg): after step 17, deliver a home to the satellite (adapter
    boot there) and repeat steps 18–20 on the satellite's projected home.
    PASS [divergent]: identical enforcement behavior; the generic shared
    home received `settings.json`/`hooks.json`, while elected archetype skills
    were materialized separately at the exact remote session cwd. No
    credential bytes appear in captured ssh/rsync commands.

## 10. Roles (offices: typed targets, binding, fallback, late binding)

Roles are substrate-level — run once per harness leg (bind to that leg's
session where a binding is called for). ⌥ all steps are CLI/dispatch.

25. Typed target seam: `wake --user <admin>` lands in the admin's Main;
    `wake --role <admin-id>` FAILS with "unknown role" (the field is the
    type — a user id in the role field is a role lookup, period);
    `wake --session agent:garbage` fails "unknown sessionKey"; sending
    BOTH --role and --user fails "exactly one of"; the retired single
    `target` param fails naming the three fields.
    PASS: all five behave exactly so.
26. Unstaffed office: `role create probe-office`, then `wake --role probe-office`.
    PASS: message lands in the role OWNER's Main; the turn row has
    roleRef='probe-office' AND roleFallback=1. DB is the check — fallback
    is recorded, never disguised.
27. Staffed office: `role bind probe-office <sessionKey of this leg's
    smoke session>`, wake again.
    PASS: delivered to the bound session; turn row roleFallback=0.
28. Late binding: `wake probe-office --after 30s`, then IMMEDIATELY
    `role bind probe-office <a different session>`. Wait for fire.
    PASS: delivered to the NEW binding (the one at fire time, not at
    schedule time); turn row records the role and the new key.
29. Reply spelling round trip: from the bound session, have the agent
    reply to a role-stamped message per its Comms guidance.
    PASS: for `[from agent:X]` the agent runs `wake --role X`; for
    `[from user:Y]` it runs `wake --user Y` — typed flags, no 404s.
30. Deleted office: `role rm probe-office`, then `wake --role probe-office`.
    PASS: named error ("unknown role: probe-office") — the name errors by
    name, never silently reroutes. A wake SCHEDULED before the rm and
    firing after it produces a `wake_unresolved` lifecycle row and no
    delivery.
31. Permanence of Mains: attempt `retire <admin's Main key>`.
    PASS: refused with "main sessions are permanent" — the fallback
    target cannot be destroyed; Main remains active.
32. Spawn sugar atomicity: `spawn --display X --name probe-office` while
    that role still exists.
    PASS: the spawn FAILS with role_exists and NO session row was
    created. Then with a fresh name: session + role both exist, role
    bound to the new session.
33. Acting-as requires the office: `wake <target> --as probe-office` from
    a context where the role is unbound.
    PASS: refused ("unknown or unbound role"); after binding, the same
    call succeeds and the delivered stamp reads `[from agent:probe-office]`.
