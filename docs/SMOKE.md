# Smoke runbook — core user journeys

Run this after any change to prove core functionality is alive. It walks the
operator journeys end-to-end from a real client (the iOS simulator) against a
freshly-booted gateway; steps that are awkward to drive through the simulator
have a CLI fallback (marked ⌥). Every step names its PASS condition — an
observable frame, bubble, or row. The DB checks use
`sqlite3 <base_dir>/state.db`.

`README.md` is the authority for the fresh-org install path. This runbook
follows that path verbatim rather than restating it.

Conventions: GATEWAY = the gateway under test (fresh base_dir unless the run
says otherwise). First device to pair becomes the admin user. `tb` = the
reference CLI with TIGHTBEAM_URL/TIGHTBEAM_TOKEN pointed at GATEWAY (token
from `<base_dir>/gateway.json`).

## Harness parity (normative for every run)

This runbook is a MATRIX, not a list: one full pass PER HARNESS the org
supports (today: claude on `claude-sonnet-5[medium]`, codex on
`gpt-5.6-sol[medium]`), using a
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

## Preflight: harnesses are installed and logged in

The smoke ASSUMES every harness it exercises is already installed and logged in
on every host a leg will place sessions on. Onboarding is a separate activity
with its own runbook: `docs/ONBOARDING.md`. Installing a satellite and its
harness CLIs is `docs/SATELLITE.md`.

Verify it cheaply, then get on with the run. Per `{host, harness}` in scope:

P2. **Credential live — AUTHORITATIVE.** Read it off the gateway's boot summary,
    or `tightbeam list` and check that host's catalog for that harness is
    non-empty. A live credential yields models; a dead one yields none. A
    non-empty catalog is also proof the binary was reachable by whoever needed
    to reach it.
P1. **Binary present — EXPLANATORY, never a verdict on its own.** Its job is to
    explain a P2 failure. The PATH depends on the role: a **satellite** is judged
    on the non-interactive ssh PATH (`ssh <host> <binary> --version`); the
    **gateway host** is judged on the gateway service's own `Environment=PATH`,
    which its adapters inherit. A gateway-host binary absent from the
    non-interactive ssh PATH is not a failure — failing a host on P1 alone
    waives healthy legs.

FAIL FAST on P2. Do not repair auth inside a smoke run, and do not infer
liveness from a login prompt or a file's presence:

- binary missing → `docs/SATELLITE.md`
- credential missing, dead, or kind unrecorded → `docs/ONBOARDING.md`

A `{host, harness}` that fails preflight is either fixed before the run or
carried as a NAMED WAIVER in the scorecard. After a clean preflight, any
downstream auth-shaped failure is a FINDING — something rotated or leaked
mid-run — never noise to shrug at.

## Fresh-org provisioning (what "auth seeded" actually means)

A fresh base_dir is NOT ready after copying files around; each item below is a
seam with its own shape, and every one of these was rediscovered the hard way
on 2026-07-25:

- **Credentials are store rows, not loose files** — three parts per provider,
  and the metadata row's `kind` is what every credential seam dispatches on.
  Copying an org's `auth/` around does not make a host logged in. See
  `docs/ONBOARDING.md` for the layout and the only sanctioned path to create
  it (`tightbeam onboard <provider>`, run on that host).
- **Codex model catalog** needs nothing seeded. It is one HTTPS call the host
  makes with its own grant, filtered by the version of that host's `codex`
  binary — so a working credential and a current `codex` on PATH are the whole
  requirement. An outdated `codex` yields an EMPTY catalog with no error from
  the provider; the refusal names the version and says to upgrade the binary.
- **Default model must match default harness** (`TIGHTBEAM_DEFAULT_HARNESS` /
  `TIGHTBEAM_DEFAULT_MODEL`, or archetype `[defaults]`); the claude default
  against a codex org fails `model_unavailable` at spawn.
- **The identity repo working tree must stay clean.** Anything hand-placed
  under `identity/` (e.g. a rules fixture) must be COMMITTED, or every
  identity verb wedges with "identity working tree is dirty".
- **The effort check-in probe needs a short horizon — but not TOO short**: boot
  the gateway with `TIGHTBEAM_EFFORT_CHECKIN_HORIZON_MS=2500` for smoke runs.
  The default is 30 minutes (the probe waits a real idle horizon), and the
  DEADLINE interval shares this config — at 250ms the deadline rung-rotates the
  request away from the parent before it can rule, which loses the race on the
  slower codex leg every time.
- **"Copy the org" means two DIFFERENT things depending on which harness you
  are driving.** `ClientE2E.LegGateway.provision!/2` copies `auth/`, `homes/`
  and `identity/` and deliberately OMITS `state.db`, because a client-e2e leg
  must have no history and bootstraps its first user through the app's own J0
  pairing. `feature_smoke.exs` needs the opposite: a fully provisioned org
  whose `state.db` already holds the owner as an ADMIN, because it drives
  admin-only verbs (`identity-status`, `config`) as `--as-user` over HTTP with
  no pairing step. Provisioning a feature-smoke org with `provision!/2` boots
  fine and then fails several checks in with `admin required`, which looks
  nothing like its cause. For feature smoke, copy the whole template org
  including `state.db` (minus logs and `work/`) and let `TIGHTBEAM_PORT`
  rewrite `gateway.json` at boot.
- **`feature_smoke.exs` is a LOCAL-HOST HERMETIC driver, and only that.** It
  runs one leg per registry harness, every one of them on
  `Placement.local_host_name()` — there is no host dimension. It also spawns
  into the `reviewer` archetype and commits a rule fixture into the identity
  repo as a side effect, so it wants an org it may mutate. **The satellite
  host×harness matrix is agent-driven through the journeys below, and
  deliberately has no script**: real-host e2e is a runbook plus a flexible
  agent, and a host-blind script cannot reach a satellite at all.
- **`feature_smoke.exs` runs with `mix run --no-start`.** A plain `mix run`
  boots a second gateway that OVERWRITES `gateway.json` and silently redirects
  the smoke away from the gateway under test. The script enumerates
  `Tightbeam.Harness.all/0`, runs one complete leg per registry entry, and adds
  that leg's `harness`, `model`, and `effort` to every spawn explicitly. A model
  is named by FIELDS, never one packed string: supply the model per leg through
  `TIGHTBEAM_SMOKE_MODEL_<UPPERCASE_WIRE_NAME>`, its reasoning level through
  `TIGHTBEAM_SMOKE_EFFORT_<…>`, and a vendor context-window variant, if the leg
  needs one, through `TIGHTBEAM_SMOKE_CONTEXT_<…>`. Missing model configuration
  refuses the run before the first leg. For the current registry:

  ```sh
  TIGHTBEAM_BASE_DIR=~/.tightbeam-beam \
  TIGHTBEAM_SMOKE_MODEL_CLAUDE='claude-sonnet-5' TIGHTBEAM_SMOKE_EFFORT_CLAUDE='medium' \
  TIGHTBEAM_SMOKE_MODEL_CODEX='gpt-5.6-sol' TIGHTBEAM_SMOKE_EFFORT_CODEX='medium' \
  mix run --no-start scripts/feature_smoke.exs
  ```

  The claude model must be one the ADAPTER accepts, which is a narrower set than the
  derived catalog — `fable` and `claude-fable-5` are both refused, and a refusal fails
  the model apply on every `session/new` and `session/load`. The recipe above used to
  say `fable`; every real run on record used `claude-sonnet-5` at effort `medium`
  instead, which is why the stale value was never caught. The accepted list and how to
  re-probe it live in the note above `@adapter_selectable_models` in
  `lib/tightbeam/harness/claude.ex`.

  Each registered harness must have its credential preflight and catalog
  bootstrap complete first. The gateway
  still needs `TIGHTBEAM_EFFORT_CHECKIN_HORIZON_MS=2500`. Success is reported
  separately as `feature-smoke leg <wire>: <n> checks PASS`; absence of any
  registered leg is not a pass.

## 0. Boot + pair

1. [auto: J0] Boot the gateway (fresh base_dir; auth seeded for the claude harness).
   PASS: `GET /version` returns `{"protocolVersion":1,...}`.
2. [auto: J0] In the client: set the server URL, pair with a claimed name.
   PASS: pair succeeds instantly (first user bootstrap), catalog shows one
   "Main" stream, `sync_complete` arrives (app leaves the connecting state).
   DB: one `allowlisted` device; one `users` row with `isAdmin=1`.

## 1. Converse (the fundamental loop)

3. [auto: J1] Post "hello, who are you?" in Main.
   PASS: echo bubble immediately; typing indicator ON; assistant bubble
   arrives; indicator clears WITHOUT lingering. DB: turn row `delivered`.
   The indicator's ON/OFF is the INVARIANT — its absence, or a lingering
   indicator, is a failure. Its LABEL is not: the substrate relays labels the
   harness reports (`agent_thought_chunk` → "Thinking…", `tool_call*` → its
   title) and fabricates none, so a plain conversational turn can legitimately
   run with an unlabeled indicator. A label is REQUIRED only where an event
   backs it — step 4, which is also the proof CAP-012 cites. Measured on the
   claude leg at `claude-sonnet-5[medium]` (client-e2e run 0e40b93): a plain
   turn and an explicitly reasoning-provoking turn each produced the full
   frame sequence with ZERO `agent_progress` frames, claude-agent-acp having
   sent no thought chunk. The user-visible consequence — an unlabeled
   indicator during ordinary conversation — is a CLIENT presentation concern
   (clawline `docs/notes/typing-label-local-fallback.md`), not a substrate
   defect and not a driver assertion.
4. [auto: J1] Post a message that provokes tool use ("run `uname -a` and tell me what
   it says").
   PASS: progress label shows a tool title during the turn; assistant bubble
   reports the output; indicator clears.

## 2. Session lifecycle

5. [auto: J2] Create a second session (client stream UI; ⌥ `tb spawn --display
   "Smoke" --as-user <admin>`).
   PASS: `stream_created` lands live — the new stream appears in the catalog
   WITHOUT reconnecting. Post in it; assistant replies. DB: sessions row,
   `origin` = the creator.
6. [auto: J2] Rename it (client stream UI; ⌥ `tb`/PATCH via session sheet).
   PASS: `stream_updated` — name changes in the catalog live.
7. [auto: J2] Delete it (client stream UI; ⌥ `tb retire <key> --as-user <admin>`).
   PASS: `stream_deleted` — gone from the catalog live. DB: sessions row
   `state='retired'` (soft — the row and its messages REMAIN).

## 3. Cancel

8. [auto: J3] Post a long task in Main ("count to 200 slowly, one line per number").
   While the indicator is live, hit the client's stop control (⌥ `tb`
   /api/session-control `cancel_current_run`).
   PASS: turn-state `canceled` arrives (terminalState true); indicator and
   progress label clear; NO assistant bubble for that turn afterward.
   DB: turn row `canceled`. Post again — next turn runs normally (lane
   drained on).

## 4. Queueing — one lane, strict order

9. [auto: J4] Post three messages back-to-back in Main without waiting: "say ONE",
   "say TWO", "say THREE".
   PASS: three echoes immediately; exactly one turn runs at a time (DB:
   never more than one `running` for the session); three assistant bubbles
   arrive IN ORDER; all three turn rows `delivered`. The indicator stays
   sane throughout (on while running, cleared at the end).

## 5. Concurrency — multiple chats in parallel

10. [auto: J5] Create session "Smoke B". Post a slow prompt in Main ("write a haiku
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

11. [auto: J6] `/new` — PASS: completes as above (model replies conversationally; no
    session rotation occurs — that mechanism is future `tune` work).
12. [auto: J6] `/compact` — PASS: completes as above.
13. [auto: J6] `/model` — PASS: completes as above. Then change the model for real via
    the client's picker (session-status → set_model; ⌥ POST
    /api/session-control `set_model`). PASS: `GET /api/session-status`
    shows the new ref; next turn still completes; AND the client's model
    FOOTER populates (this asserts the Swift decode contract, which raw
    JSON checks miss — a missing required field like sessionKey fails the
    whole decode and the footer silently never fills).

## 7. Restart resilience (deploy semantics)

14. [auto: J7] Post a slow prompt; while the indicator is live, SIGTERM the gateway
    (plain `kill <pid>`), wait for exit, restart it.
    PASS: the gateway drains — either the turn completes before exit
    (assistant bubble, then restart is invisible beyond a reconnect blip)
    or, past the drain deadline, the client shows the turn FAILED with
    "interrupted: outcome unknown" after restart — never a silent stuck
    indicator. Client reconnects by itself; replay shows full history; a
    fresh post works and the model still has its context (same harness
    session re-adopted — pointer chain shows `loaded`, not `fallback`).
15. [auto: J7] Queue two messages, SIGTERM before the first completes, restart.
    PASS: queued (not-yet-running) turns survive and run to `delivered`
    after the restart without re-sending.

## 8. Wakes (agent comms surface)

16. [auto: J8] ⌥ `tb wake --session <mainKey> --prompt "reply with exactly: WAKE OK" --as-user
    <admin>`.
    PASS: the prompt appears in Main as a sender-tagged message, the turn row
    carries the dispatched wakeId, an assistant reply correlates to that
    message, and the turn reaches `delivered`. The reply's CONTENT is not
    asserted — instruction compliance is agent effectiveness, which evals own.
    Then `--after 15s` variant: fires after the delay (row visible in
    `tb list` until it fires).

## Automation index (client-e2e driver)

Every numbered step above carries `[auto: J<n>]` or `[manual]`; silence would
be a step nobody owns. `[auto: …]` names the journey in
`Tightbeam.ClientE2E.Journeys` that walks it with the sim client against a
real gateway (`mix run --no-start scripts/client_e2e.exs`). `[manual]` steps
stay this runbook's, run by a human, and appear in the scorecard as
verdict-neutral MANUAL rows.

Steps 14-16 are driven: J7 restarts the gateway for real (SIGTERM the captured
pid, await exit AND the port going unreachable, restart on the same port and
base_dir, confirm a NEW pid) and J8 drives wakes through `/agent/dispatch`,
the same facade `tb wake` posts. Step 16b is J8's scheduled variant.

## Recording results — the scorecard

Every run produces a SCORECARD. Run records live outside the repo, in
`~/shared-workspace/tightbeam_ex/smoke-runs/`: copy `TEMPLATE.md` there to
`<date>-<short-sha>.md` and fill it in — one column per
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

17. [manual] Install law: copy `docs/statutes.toml.example` to
    `<base_dir>/identity/rails/statutes.toml`; restart the gateway.
    PASS [divergent]: gateway boots. After adapter boot, the claude home's
    `settings.json` decodes with one `hooks.PreToolUse` entry per statute
    (matcher "Bash"). The codex home's `hooks.json` decodes with one entry
    per statute plus `tightbeam-probe` LAST; the codex home still has NO
    `settings.json`. Existing sessions are not refreshed automatically.
    **Count every statute the org has, not just the ones you copied.**
    `mix tightbeam.init` seeds `identity/rails/engineering.toml` (5 statutes),
    so a real org shows those plus the example's — the assertion is a 1:1
    correspondence with the total, and reading it as "one per copied statute"
    manufactures a discrepancy that isn't there.
18. [manual] The invariant: assert neither shared home contains `CLAUDE.md`,
    `AGENTS.md`, nor archetype skill directories. Run `tightbeam identity
    status <archetype>` and inspect both composed instruction channels.
    PASS: statute names/text are absent from the composed guidance; guidance
    arrives only through the Codex developer message / Claude system prompt.
19. [manual] Live refusal [divergent]: in a scratch git repo, tell a real session to
    run exactly `git reset --hard HEAD`, then `git status`, and report what
    happened. The claude fallback is `claude -p
    --dangerously-skip-permissions` inside the projected home.
    PASS: the reset is refused BEFORE execution. Claude's reply quotes
    `[gate: no-history-rewrites]`; codex quotes `Command blocked by
    PreToolUse hook: [gate: no-history-rewrites] …`. In both, the agent must
    report that the runtime refused it, not that it declined; `git status`
    runs normally and the repo is untouched. Repeat with `git push origin
    main` → `[gate: no-push-main]` refusal.
20. [manual] Boot wiring-check evidence [codex-only]: confirm the codex adapter boot
    log contains `gate wiring-check PASS [gate: tightbeam-probe]`. Delete the
    projected home's `hooks.json` and restart the adapter.
    PASS: the adapter REFUSES to boot with `gate_attestation_failed`, and no
    codex session is served. Restore by changing MANIFEST BYTES: edit a
    statute, or delete the home's `.tightbeam/manifest` stamp, then **spawn a
    session** — regeneration is ownership-scoped to projection, which happens at
    SPAWN, not at gateway restart. A restart alone does not rewrite `hooks.json`,
    and waiting for one to leaves the adapter looping on `wiring-check FAIL`.
    Then confirm regeneration is real rather than cached: the rewritten
    `hooks.json` must carry the edited statute's current text.
    This demonstrates silent-misconfig detection, NOT tamper resistance.

    Do NOT assert that `sessions/`, history, transcripts and memory stay
    byte-identical while the gateway is up. A failed attestation is a RETRY
    LOOP, and every failed boot writes durable state — rollouts accumulate and
    the sqlite files change, so the comparison is unevaluable, not failing. If
    you want it, stop the gateway first and compare against a snapshot taken
    while it was already stopped.
21. [manual] Negative control: an adjacent, allowed command of the same tool
    (`git log`, `git diff`) runs without any refusal text appearing.
    PASS: normal output, no `[gate: ...]` anywhere.
22. [manual] Bad law stops the boot: append a statute with `mode = "remind"` to
    the statutes file and restart.
    PASS: the gateway REFUSES to start; the log names the law error
    verbatim ("rails never add guidance; put prose in guidance or a
    skill"). Same check with `pattern = "("` → "invalid gate pattern".
    Restore the file; gateway boots.
23. [manual] Law removal: delete the statutes file, restart, re-run step 19's
    forbidden command.
    PASS: no refusal (the gate is gone, not lingering in the shared home);
    step 18 still passes and durable harness state survives.
24. [manual] ⌥ Satellite propagation — **run `docs/ASSIMILATION-E2E.md` §5**, which
    supersedes the single line this step used to be. It carries the commands,
    the expected rows, and the same PASS conditions: identical enforcement on
    the satellite's projected home, `settings.json`/`hooks.json` in the shared
    home with elected archetype skills materialized separately at the exact
    remote session cwd, and no credential bytes in any captured ssh/rsync
    command. Agent-to-agent delivery across hosts is `docs/INTER-NODE-COMMS.md`.
    Score this step from that run: PASS / BLOCKED(no assimilated satellite).

## 10. Roles (offices: typed targets, binding, fallback, late binding)

Roles are substrate-level — run once per harness leg (bind to that leg's
session where a binding is called for). ⌥ all steps are CLI/dispatch.

Note on the `role create` / `role bind` / `role rm` spellings below: those are
gateway verbs (`role-create`, `role-bind`, `role-rm`, `role-list`) dispatched
through the ⌥ CLI/dispatch annotation. **The CLI exposes no `role` command**, so
the literal syntax will not run as written — reach the verbs through dispatch.

25. [manual] Typed target seam: `wake --user <admin>` lands in the admin's Main;
    `wake --role <admin-id>` FAILS with "unknown role" (the field is the
    type — a user id in the role field is a role lookup, period);
    `wake --session agent:garbage` fails "unknown sessionKey"; sending
    BOTH --role and --user fails "exactly one of"; the retired single
    `target` param fails naming the three fields.
    PASS: all five behave exactly so.
26. [manual] Unstaffed office: `role create probe-office`, then `wake --role probe-office`.
    PASS: message lands in the role OWNER's Main; the turn row has
    roleRef='probe-office' AND roleFallback=1. DB is the check — fallback
    is recorded, never disguised.
27. [manual] Staffed office: `role bind probe-office <sessionKey of this leg's
    smoke session>`, wake again.
    PASS: delivered to the bound session; turn row roleFallback=0.
28. [manual] Late binding: `wake probe-office --after 30s`, then IMMEDIATELY
    `role bind probe-office <a different session>`. Wait for fire.
    PASS: delivered to the NEW binding (the one at fire time, not at
    schedule time); turn row records the role and the new key.
29. [manual] Reply spelling round trip: from the bound session, have the agent
    reply to a role-stamped message per its Comms guidance.
    PASS: for `[from agent:X]` the agent runs `wake --role X`; for
    `[from user:Y]` it runs `wake --user Y` — typed flags, no 404s.
30. [manual] Deleted office: `role rm probe-office`, then `wake --role probe-office`.
    PASS: named error ("unknown role: probe-office") — the name errors by
    name, never silently reroutes. A wake SCHEDULED before the rm and
    firing after it produces a `wake_unresolved` lifecycle row and no
    delivery.
31. [manual] Permanence of Mains: attempt `retire <admin's Main key>`.
    PASS: refused with "main sessions are permanent" — the fallback
    target cannot be destroyed; Main remains active.
32. [manual] Spawn sugar atomicity: `spawn --display X --name probe-office` while
    that role still exists.
    PASS: the spawn FAILS with role_exists and NO session row was
    created. Then with a fresh name: session + role both exist, role
    bound to the new session.
33. [manual] Acting-as requires the office: `wake <target> --as probe-office` from
    a context where the role is unbound.
    PASS: refused ("unknown or unbound role"); after binding, the same
    call succeeds and the delivered stamp reads `[from agent:probe-office]`.
