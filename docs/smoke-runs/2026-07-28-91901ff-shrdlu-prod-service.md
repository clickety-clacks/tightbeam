# Smoke scorecard — 2026-07-28 @ 91901ff

Gateway commit: `91901ffc5822f410c2752407850e8a86b5014a7d` (`91901ff`)
Host: **shrdlu** (Ubuntu 24.04.4, kernel 6.8.0-136-generic, 12 cores)
Operator account: **clu** (uid 1001) — the real operator account, per `docs/TEST-HOSTS.md`
base_dir: `/home/clu/.tightbeam-prodgate` · clone: `/home/clu/src/tightbeam-prodgate` · port **11373**
Client build: none — headless host; client ceremony driven by `Tightbeam.ClientE2E.SimClient`
Adapters: `claude-agent-acp` 1.1.4 · `codex-acp` 0.59.0 · CLIs: claude 2.1.220 · codex-cli 0.145.0
Scope: {claude × shrdlu}, {codex × shrdlu}
Date: 2026-07-28 (UTC) · **Install RETAINED at time of writing** (`enabled`/`active`, MainPID 21781)

Aggregate: **67 turns — claude 39 delivered / 2 canceled; codex 24 delivered / 1 canceled / 1 failed.**
The single `failed` is the intentional gate-attestation test (step 20). 137 messages, 9 sessions, 69 wakes, 2 roles.

## Row schema (v1 — client-e2e-v1 §Architecture)

Cell values per TEMPLATE.md, plus two this run needed:

| value | meaning |
|---|---|
| `PASS` | both oracle columns held |
| `PASS (divergence <row id>)` | leg diverges, divergence NEGATIVE PROVED, matrix row cited |
| `FAIL(note)` | an oracle did not hold |
| `INCOMPLETE(blocker)` | could not be driven to a verdict; blocker required |
| `MANUAL(reason)` | outside v1 automation, run by hand — VERDICT-NEUTRAL |
| `N/A[harness-only]` | step does not exist on this harness |
| `NOT VERIFIED(reason)` | the assertion as written was **unevaluable**, distinct from failing |
| `PARTIAL(reason)` | substrate oracle held; a non-substrate oracle did not |

Every row below was run **by hand** against a real gateway (no client-e2e driver on this
host), so all rows are MANUAL in the template's automation sense. They are recorded with
their substantive verdicts rather than blanket `MANUAL`, because a scorecard of 33
verdict-neutral cells would be a vacuous pass. The leg verdicts below account for this.

| Step | claude@shrdlu | codex@shrdlu | notes |
|---|---|---|---|
| P-claude auth | PASS | N/A | catalog populated, 11 selectable refs; 28 withheld as not adapter-selectable |
| P-codex auth | N/A | PASS | `codex login status` exit 0 "Logged in using ChatGPT"; catalog 37 refs after cache seed |
| 1 boot [J0] | PASS | PASS | `GET /version` → `{"adapters":{},"protocolVersion":1,"server":"tightbeam"}`; boot summary `READY: claude can run turns.` |
| 2 pair [J0] | PASS | PASS | `{:ok, %{user_id: "flynn"}}`; DB `users flynn isAdmin=1`, device `allowlisted`. Main stream seeded only by `SimClient.connect` — see the §3a headless-connect note under Findings |
| 3 converse [J1] | PASS | PASS | claude 5995ms "I'm Claude Code, an AI coding assistant built by Anthropic."; codex 13702ms "I'm Codex, your AI coding and problem-solving partner." |
| 4 tool use [J1] | PASS | PASS | both executed `uname -a` and returned real host output `Linux shrdlu 6.8.0-136-generic … x86_64` |
| 5 create stream [J2] | PASS | PASS | claude `Lifecycle` / codex `Codex Life`; both `active`, `origin=user:flynn`, both accepted a turn |
| 6 rename stream [J2] | PASS | PASS | `PATCH /api/streams/:key`; `Main`→`Main Renamed`, `Codex Life`→`Codex Renamed` |
| 7 retire stream [J2] | PASS | PASS | `state='retired'`, row and messages REMAIN (claude 2, codex 2) — soft delete confirmed |
| 8 cancel [J3] | PASS | PASS | turn `canceled`; assistant-message count unchanged across the cancel (claude 10→10, codex 58→58); run state `idle`, queueDepth 0; lane drained (`RECOVERED2` / `CODEX RECOVERED`) |
| 9 queueing [J4] | PASS | PASS | peak concurrent `running` per session = **1** both legs. Codex FIFO proven by timestamps: submission `createdAt` 459474/459475/459476 → completion `endedAt` in the same order, each `startedAt` == prior `endedAt` exactly (459475→462276→464425→466790), zero overlap |
| 10 concurrency [J5] | PASS | PASS | claude: peak 2 distinct sessionKeys running (`s_2cd5c792`,`s_022def3a`), Smoke B answered `4` mid-haiku, no cross-talk. Cross-harness: peak **2 distinct harnesses** running simultaneously (claude 5725ms ‖ codex 3742ms) |
| 11 /new [J6] | PASS | PASS | delivered both legs (substrate passes slash text through unchanged) |
| 12 /compact [J6] | PASS | PASS | delivered both legs |
| 13a /model [J6] | PASS | PASS | delivered both legs |
| 13b model change [J6] | PASS | PASS | claude `claude-sonnet-5[medium]`→`claude-haiku-4-5-20251001`; codex `gpt-5.6-sol[medium]`→`gpt-5.6-sol[high]`; new ref recorded on the next turn row both legs |
| 13c model footer | NOT VERIFIED(no client) | NOT VERIFIED(no client) | rendered-footer assertion is app-side; headless host has no Swift client. `GET /api/session-status` `display.model` did reflect the change, which is the substrate half only |
| 14 restart resilience [J7] | PASS | PASS | SIGTERM mid-turn → **drain branch**: turn `delivered` before exit, no error, never stuck. Unit correctly stayed `inactive` after a clean TERM (`Restart=on-failure`). Restarted to a new pid |
| 15 restart queue survival [J7] | PASS | PASS | before kill `running=1 queued=1`; after restart both `delivered`, survivor reply present, no re-send |
| — pointer chain (part of J7) | PASS | PASS | claude `created`→`loaded`,`loaded` on `e23c9504`; codex `created`→`loaded` on `019fa673`. Never `fallback`. Claude context retained across two restarts ("You asked me to count to 400.") |
| 16 wakes [J8] | PASS | PASS | turn row carries the dispatched wakeId; prompt sender-tagged `[from user:flynn]`; reply correlates via `replyToMessageId`; wake `fired` |
| 16b scheduled wake [J8] | PASS | PASS | `--after 15s`: `pending`, visible in `tb list`, then `fired` → `SCHEDULED OK` / `CODEX SCHEDULED` |
| 17 install law | PASS | PASS | 7 statutes → **exactly 7** `PreToolUse` entries, matcher `Bash`. NOTE: `tightbeam.init` seeds `identity/rails/engineering.toml` (5 statutes) alongside the copied `statutes.toml` (2); step 17's wording implies the copied file is the only source |
| 18 zero-guidance invariant | PASS | PASS | `identity status default` = 7708 chars with **zero** occurrences of `no-history-rewrites`, `no-push-main`, `no-git-stash`, `History-rewriting`, `Pushing to main is forbidden`, or the string `gate:`. No `CLAUDE.md`/`AGENTS.md` in either home. `skills/` holds only substrate `tightbeam-*` skills, not archetype skills |
| 19 live refusal | PASS (divergence CAP-007) | PASS (divergence CAP-007) | claude: bare `[gate: no-history-rewrites] History-rewriting git commands are forbidden here…`. codex: `Command blocked by PreToolUse hook: [gate: no-git-reset-hard] …`. Both refused BEFORE execution; both agents reported the runtime refused. Repo provably untouched (claude HEAD `f33e90a`, codex HEAD `133985e`, both still dirty, `file.txt` = `baseline modified`) |
| 19b push refusal | PASS | N/A[not re-run] | claude `[gate: no-push-main] Pushing to main is forbidden: work lands on branches; the operator merges.` Not repeated on codex; codex refusal mechanism already proven by 19 |
| 20 boot wiring-check | N/A[harness-only] | PASS | codex-only. Healthy boot: `gate wiring-check PASS [gate: tightbeam-probe] output="…Command blocked by PreToolUse hook: [gate: tightbeam-probe] Spawn wiring-check probe command; always refused by design.. Command: tightbeam-gate-probe ."` Deleted `hooks.json` → `gate wiring-check FAIL detail=no_marker` (probe ran unblocked: `tightbeam-gate-probe: command not found`), `** (stop) {:gate_attestation_failed, :no_marker}`, codex turn 38 `failed` with `{:adapter_unavailable, "{:gate_attestation_failed, :no_marker}"}` — **no codex session served**. Restored: 6 entries, `tightbeam-probe` LAST, still no `settings.json`, regenerated from CURRENT statutes (carried the `smoke-edit` text). Claude adapter log has 0 wiring-check lines — correctly codex-only |
| 20b durable state byte-identical | N/A[harness-only] | NOT VERIFIED(failure state is not quiescent) | While `hooks.json` was absent the adapter **retry-looped**; each failed boot wrote durable state. Session rollouts 2 → 9; `goals_1`, `logs_2`, `memories_1`, `state_5` sqlite all changed; even one baseline rollout changed (`0675fe29…`→`edf9a60e…`) mid-snapshot. Only `…835d.jsonl` (`316f2257266adf27`) was byte-identical throughout. The assertion presumes a quiet failure state; recommend stopping the gateway before comparing |
| 20c restore trigger | N/A[harness-only] | PASS(trigger differs from doc) | SMOKE.md says stamp-delete **or** statute-edit then **restart**. Both restart-only attempts did NOT regenerate (absence persisted across two full restart cycles while the adapter logged `wiring-check FAIL` + `gate_attestation_failed`, which only happens if the file is genuinely gone). A **new session spawn** regenerated it at 02:00:03Z. Runbook should read "then spawn a session" |
| 21 negative control | PASS | PASS | claude `git log --oneline -1`→`f33e90a base`, `git diff --stat`→`file.txt | 1 +`. codex `133985e base` + same diffstat. **Zero** `[gate:]` occurrences either leg |
| 22 bad law stops boot | PASS | N/A[gateway-wide] | `mode = "remind"` → `** (ArgumentError) rails never add guidance; put prose in guidance or a skill` at `lib/tightbeam/rails.ex:172`. Gateway refused to start (unit `activating`, restart-looping). Law validation is gateway-wide, not per-harness |
| 22b invalid pattern | PASS | N/A[gateway-wide] | `pattern = "("` → `** (ArgumentError) invalid gate pattern: "("`. Restored → `READY` |
| 23 law removal | PASS | N/A[not re-run] | Removed `statutes.toml`; push reached **real git** (`error: src refspec main does not match any`) with **zero** `no-push-main` occurrences. Gate gone, not lingering in the shared home. Durable harness state survived (`projects/` 3→3) |
| 24 satellite propagation | BLOCKED(no assimilated satellite) | BLOCKED(no assimilated satellite) | Requires an assimilated host with credentials for the leg. No satellite was assimilated this run. **The only untested rails surface** |
| 25 typed target seam | PASS | PASS | all five: `--user flynn` works; `--role flynn` → `not_found: unknown role: flynn`; `--session agent:garbage` → `not_found: unknown sessionKey: agent:garbage`; both flags → `usage: … exactly one of --session <key>, --role <name>, --user <id>`; retired `--target` → same usage error naming the three fields. Codex leg spot-checked the two `not_found` forms |
| 26 unstaffed office | PASS | N/A[substrate-level, run once] | delivered to the OWNER's Main; turn row `roleRef='probe-office'`, **`roleFallback=1`**. Initially queued ~8 min because the Main was unmaterialized — see Finding #68; delivered immediately once seeded |
| 27 staffed office | PASS | PASS | claude bound `s_022def3a` → `roleFallback=0`; codex bound `s_1a90c28e` → turn 66 `harness=codex`, `roleFallback=0`, delivered |
| 28 late binding | PASS | N/A[substrate-level, run once] | scheduled while bound to `s_022def3a`, rebound mid-flight to `s_1e406ad1`, **delivered to `s_1e406ad1`** — the binding at FIRE time, not schedule time. Reply `LATE BOUND` |
| 29 reply spelling round trip | PARTIAL(agent declined; substrate held) | N/A[substrate-level, run once] | Substrate PASS: the agent invoked the CLI and produced turn 36 — `origin=agent:probe-office`, delivered into `flynn:main`, stamped `[from agent:probe-office]`. The agent then declined to continue, reading the request as a manipulation probe. Per SMOKE.md convention instruction compliance is agent effectiveness (evals' domain), so not scored as a substrate failure. Note: composed guidance has **0** matches for `wake --user`/`wake --role`/`[from …]`; that guidance lives in the `tightbeam-dispatching` SKILL |
| 30 deleted office | PASS | N/A[substrate-level, run once] | immediate wake → `not_found: unknown role: probe-office`. Wake SCHEDULED before the `rm` and firing after → **`wake_unresolved`** lifecycle row and **zero** turns carrying that wakeId |
| 31 permanence of Mains | PASS | N/A[substrate-level, run once] | `denied: main sessions are permanent — they are the fallback for roles and user references`; Main remained `active` |
| 32 spawn sugar atomicity | PASS | N/A[substrate-level, run once] | `config_denied: role already exists: probe-office`, sessions **3→3** (no row created). Fresh name → session + role both created and bound |
| 33 acting-as requires the office | PASS | PASS | role removed → `invalid_message: unknown or unbound role: probe-office`. After binding: claude stamp `[from agent:probe-office]`; codex leg turn 67 `origin=agent:probe-office` delivered into `flynn:main` |

## Service-mode properties

The template predates service-mode install; these are the four properties from README's
"Verifying the service" table and `service-mode-install-v1.md`, added as their own section
rather than dropped. Host-level, not per-harness.

| property | verdict | evidence |
|---|---|---|
| starts with no interactive login | PASS | `systemctl is-enabled tightbeam` → `enabled`; `WantedBy=multi-user.target`; **system** unit at `/etc/systemd/system/tightbeam.service`; `User=clu` |
| survives logout of the operator account | PASS | opened a real pty login session (`XDG_SESSION_ID=7044`, `/dev/pts/0`), closed it; MainPID unchanged, `NRestarts` unchanged, still serving. Structurally `Slice=system.slice`, not `user-1001.slice` |
| survives reboot | PASS | boot_id `f28b2048-5def-45ba-b69a-5d010750428a` → `7b105a3b-e12f-4c42-b96e-3889b2e4e2b8`. Came up `active` with **no intervention**, MainPID 1262, `ActiveEnterTimestamp Tue 2026-07-28 01:08:50 UTC`; boot summary `READY: claude can run turns.`; post-reboot turn `POST REBOOT OK` (5446ms) |
| restarts on failure | PASS | SIGKILL of MainPID (deliberately not TERM, which exits clean and would NOT trip `Restart=on-failure`) → returned with a new pid, `NRestarts=1`, `/version` answering |
| runs a real turn against its own credentials | PASS | 63 delivered turns across both harnesses against credentials in `base_dir/auth/` |

Documented uninstall + residue verification: **PASS**, exercised verbatim earlier in this run
(`disable --now` 0, `rm` unit 0, `daemon-reload` 0; then no unit file, no `multi-user.target.wants`
symlink, `is-active`=inactive, `is-enabled`=not-found, no process, nothing on 11373, `base_dir`
correctly left alone). Not re-run at end of run: per the amended `docs/TEST-HOSTS.md` §5 the
installation STAYS.

## Matrix rows exercised this run

First linux evidence for several of these; previously proof references were unit tests or macOS.

| harness-support.md row | leg | verdict |
|---|---|---|
| CAP-001 Sessions, turns, cancel, load | claude, codex | PASS — steps 3,5,8,14,15 both legs; pointer chain `created`→`loaded` |
| CAP-002 Model selection + effort | claude, codex | PASS — step 13b both legs. Claude's environment-dependent offered set observed directly: 28 API models withheld as not adapter-selectable |
| CAP-003 Slash-command passthrough | claude, codex | PASS — steps 11,12,13a both legs |
| CAP-004 Projected identity | claude, codex | PASS — composed guidance identical in shape; step 18 |
| CAP-005 Skills — native discovery | claude, codex | PASS — both homes carry `skills/` with `tightbeam-*` entries only |
| CAP-007 Rails — gate statutes | claude, codex | **PASS — first linux end-to-end proof.** claude `settings.json`, codex `hooks.json` + fail-closed boot probe; steps 17,18,19,21,22,23 and codex step 20 |
| CAP-008 Rails — future block/check tiers | claude, codex | PASS (negative) — `mode = "remind"` rejected at boot, step 22 |
| CAP-009 Credentials — file lifecycle | claude, codex | PASS — provider stores project into each home; per-harness isolation verified (claude home links only `oauth-token`, codex only `auth.json`, **zero** cross-visibility) |
| CAP-010 Credentials — token environment | claude, codex | PASS — noninteractive token mechanisms both legs; 63 delivered turns |
| CAP-011 Onboarding login flow | claude, codex | **NOT VERIFIED — the run's single waiver.** Both ceremonies reached the provider (claude OAuth URL issued; codex device code `URH9-A394A` issued at `https://auth.openai.com/codex/device`) but neither was completed; credentials were placed directly instead |
| CAP-012 Typing-indicator progress | claude, codex | PASS — step 4 both legs, tool titles surfaced during turns |
| CAP-015 Hash-gated home regeneration | codex | PASS — step 20c: ownership-scoped regeneration rewrote `hooks.json` from current statutes; non-owned bytes (`sessions/`, sqlite) not reset by the regeneration itself |
| CAP-016 Harness switch on a session | claude↔codex | PASS — live `set_harness` claude→codex→claude, turns delivered on each side, model recorded per turn |
| CAP-017 Auth-event classification | — | NOT EXERCISED — no auth-failure envelope observed; deliberately not induced (forbidden per the matrix's own rule) |

Error-shape catalog contribution: **none**. No `unclassified_harness_error` was produced;
the one `model_unavailable`-shaped codex envelope observed was
`catalog_unavailable: cannot validate model "…" for codex: {:unavailable, :missing_cache}`,
which is a Tightbeam-side refusal before the harness, not a vendor envelope, so it does
**not** fill the catalog's pending codex `model_unavailable` cell.

## Leg verdicts

- **claude@shrdlu: INCOMPLETE** — every applicable step PASS except: step 29 `PARTIAL`
  (agent declined; substrate held), step 13c `NOT VERIFIED` (no client), step 24 `BLOCKED`
  (no satellite), and CAP-011 waived. No `FAIL` on any row.
- **codex@shrdlu: INCOMPLETE** — every applicable step PASS, including the codex-only
  step 20. Step 20b `NOT VERIFIED` (unevaluable), step 13c `NOT VERIFIED` (no client),
  step 24 `BLOCKED`, CAP-011 waived. No `FAIL` on any row.

**RUN VERDICT: INCOMPLETE** — one named waiver, below. **Zero FAIL cells on either leg.**

## The single named waiver

**Normal onboarding is UNPROVEN for BOTH providers.** `tightbeam onboard <provider>` was
bypassed by the same smoke expedient on both legs: credentials were placed directly into
`base_dir/auth/` from the operator account's existing logins rather than produced by the
onboarding ceremony.

This bounds the run precisely: the turns prove **runtime, adapter, rails, roles, gateway and
service-mode behaviour against real credentials**. They prove **nothing about credential
installation**, which was not under test. Both ceremonies were driven far enough to confirm
they reach their providers (claude issued a real OAuth URL with valid 43-char PKCE params;
codex issued device code `URH9-A394A`), so the *unproven* part is completion, not reachability.

Importing an existing credential is **not** a supported or desired Tight Beam workflow; the
absence of an import verb is intended design, not a gap.

## Deviations

- **Credential placement (both providers).** claude: `auth/claude/oauth-token` (108-byte
  `sk-ant-oat0…`, mode 0600) + metadata with the **honest** `expires_at=1785213584`
  (`2026-07-28T04:39:44Z`), the real OAuth access-token expiry converted ms→s — deliberately
  NOT the `now+365d` a genuine setup-token onboard stamps. codex: `auth/codex/auth.json`
  (**plain `cp`, never a symlink** — codex rotates `auth.json` and a symlink would write
  through into the operator's live login) + metadata with `expires_at: null`, which is
  **byte-for-byte what a real codex onboard writes**, so the codex substitution is narrower
  than the claude one. Both sources read-only throughout.
- **Process-scoped git identity.** `clu` has no global git identity, and `mix test` correctly
  refuses to report an unearned verdict without one. Satisfied with `GIT_COMMITTER_*` /
  `GIT_AUTHOR_*` for the run only rather than writing `git config --global`, because clu's git
  identity is shared with the live subspace/openclaw workloads. Global config verified still
  empty afterwards. This is an environmental prerequisite of *running the suite*, distinct
  from the prerequisites of *installing* Tight Beam. Related: #61.
- **Seeded `models_cache.json` at 01:51:09Z.** Copied from `/home/clu/.codex/` (read-only
  source, distinct inode) into `homes/shrdlu/codex/`. Native fresh-org behaviour was observed
  first and recorded as #67 before intervening. **Any healthy codex catalog after 01:51:09Z
  is healthy because of this seed**; the window 01:49:24Z → 01:51:09Z is the only period
  showing native fresh-org behaviour with a valid credential and no cache.
- **Hex/rebar3 prerequisite not exercised.** `hex-2.5.1` and rebar3 for `1-19-otp-28` were
  installed on clu at 09:24 by an earlier run, and `~/.mix` is shared with the live
  subspace workload, so they were preserved. `mix local.hex/local.rebar --if-missing`
  therefore no-op'd. Prerequisite *discovery* coverage comes from the earlier
  disposable-account run on this same commit lineage, which is where the Rust 1.75 /
  edition-2024 gap was found.
- **Elixir via direct asdf install paths.** clu's `~/.tool-versions` pins 1.16.3-otp-26 (too
  old for `mix.exs`'s `~> 1.19`), but 1.19.5-otp-28 + OTP 28.5 were already installed under
  asdf. Used those paths directly; global pins verified unchanged.
- **Headless client ceremony.** No GUI client on shrdlu; pairing and the Main-seeding connect
  were driven by `SimClient.pair/3` and `SimClient.connect/4` — the same wire ceremony a real
  client performs, per `docs/TEST-HOSTS.md` §3a.
- **Reboot upgraded the kernel** `6.8.0-134-generic` → `6.8.0-136-generic` (unattended-upgrades),
  and cleared `/tmp`. Explains differing `uname -a` output between early and late tool-use turns.

## Findings raised

- **#67 (NEW, this run)** — fresh-org codex cannot spawn without `models_cache.json`; codex
  does **not** self-generate it. Observed natively before any seeding:
  `catalog_unavailable: cannot validate model "claude-sonnet-5[medium]" for codex:
  {:unavailable, :missing_cache}`, **true exit 1** (measured without a pipeline), identical
  with an explicit codex ref. No codex home created, **no phantom session rows** (5→5). Boot
  summary named it cleanly beforehand: `catalog degraded (:missing_cache) — codex fetched no
  models. Turns will fail model selection until it recovers.` SMOKE.md's fresh-org note is
  correct. Diagnosis deliberately not attempted — owned by recon.
- **§3a headless-connect gap (NEW, this run) — FIXED IN DOCS, no defect number.** It is a
  runbook accuracy defect rather than a product one, so it carries no task id; the fix is
  commit `788a0d5`. `docs/TEST-HOSTS.md` §3a was incomplete for headless runs. It named
  only `SimClient.pair/3`, but the owner's Main stream is seeded by the client's WebSocket
  connect (`seed_main_stream/2`, `lib/tightbeam/wire/socket.ex:281,302`, on `chat`
  subscription). Consequence: step 26's fallback wake sat `queued` ~8 minutes with no error
  and step 31 returned `unknown sessionKey`, because the Main had never been materialized.
  One `SimClient.connect/4` fixed both — Main appeared (`kind=main`, `isBuiltIn=1`) and the
  stuck turn delivered (10351ms). Also affects SMOKE.md §0 step 2's "catalog shows one Main
  stream" PASS condition. Fix: §3a should say pair **then** connect.
- **#68 (NEW, this run)** — silent `ok:false` from `/api/session-control` tune verbs. On a
  harness-round-tripped session, `set_model` returned `ok:false` with **no `code` and no
  `message`**, 3/3 attempts, DB unchanged, while a never-swapped control session accepted the
  identical call (`ok:true`, DB updated) at the same moment; `set_reasoning` likewise.
  **Could not be reproduced**: a fresh session doing the identical swap sequence succeeded,
  the same session succeeded minutes later, and mid-turn tune succeeded. Transient,
  self-recovering, **trigger not isolated**. The durable and reportable part is the *shape*:
  every other error path in this API returns a named code (`model_unavailable`, `auth_failed`,
  `config_denied`, `not_found`, `catalog_unavailable`), so a client receiving bare `ok:false`
  cannot distinguish rejection from transient failure and has nothing to show the user.
  Filed as observed-once, not-reproducible, with that caveat explicit.
- **#69 (NEW, this run)** — `setModel.options` in `/api/session-status` advertises **bare**
  values (`claude-sonnet-5`) while `set_model`/`set_harness` require **effort-suffixed**
  catalog refs (`claude-sonnet-5[medium]`). A client that offers exactly what the capability
  advertises, and sends back exactly what the user picked, gets a rejection. The rejection
  itself is good — `model_unavailable` listing every offered ref — so this is purely a
  contract asymmetry: either `options` should advertise what `set_model` accepts, or
  `set_model` should accept what `options` advertises.
- **#64 (still OPEN, pre-existing)** — a failed onboarding ceremony wedges the provider in
  `pending` with no verb to clear it; only remedy is a service restart. Hit twice this run.
  This is a hole in the *supported* path and is distinct from the waiver above.
- **bandit 1.12.0 HIGH advisory** — `EEF-CVE-2026-65623` (quadratic CPU blow-up reassembling
  fragmented WebSocket messages) printed on every `mix deps.get`, exit 0. Untouched by
  instruction (changing a dependency mid-run changes the artifact under test). WebSockets are
  Tightbeam's primary wire; worth weighing before production.

### Documentation accuracy notes (not defects)

- Step 17's wording implies the copied `statutes.toml` is the only statute source; any org
  built by `tightbeam.init` also has `identity/rails/engineering.toml`.
- Step 20's restore instruction says "then restart"; the observed trigger is a **session
  spawn** (see 20c).
- Step 20b's byte-identity assertion presumes a quiescent failure state; the attestation
  failure is a retry loop that writes durable state.
- SMOKE.md §10 uses `role create` / `role bind` / `role rm` CLI syntax for verbs the CLI does
  not expose. The gateway has `role-create`/`role-bind`/`role-rm`/`role-list`; the "⌥
  CLI/dispatch" annotation covers driving them via `/agent/dispatch`, but the literal syntax
  misleads.
(The `setModel.options` asymmetry was first noted here as a documentation matter; it is a
contract defect and has been promoted to **#69** under Findings above.)

## Probe errors — recorded as NOT findings

Five operator-side mistakes, each caught by checking source or re-measuring before filing.
Recorded so nobody later mistakes them for product defects.

1. Queried `turns.state`; the column is `status` — sqlite errored and my loop printed a false
   "no turn row" for 300s. The turn had delivered in 4.6s.
2. Sent the `cliToken` to `/api/session-control`, which is **device**-authenticated →
   `{"error":{"code":"auth_failed"}}`. The cancel never arrived, so the turn completed
   normally and looked like a cancel failure.
3. Sent `"value"` to `set_model`; the contract field is `"model"` (`wire/router.ex:726`).
4. Identity-guard pattern matched `tightbeam-prodgate` in a cmdline where base_dir lives in
   the **environment**, not the command line. The guard **correctly refused to signal**;
   replaced with `/proc/<pid>/cgroup` = `0::/system.slice/tightbeam.service` plus cmdline.
5. Read "7 `PreToolUse` entries for 2 statutes" as a discrepancy before finding
   `engineering.toml`'s 5. 5+2=7, exact 1:1.

Also: reported `exit=0` once for a codex spawn failure — that was `head`'s status through a
pipe. True exit was **1**, re-measured without a pipeline. And codex queueing replies arrived
`TWO, ONE, THREE`, which looked like a FIFO violation until the timestamps showed my three
parallel CLI processes raced by 1ms and completion order matched submission order exactly.

## Preservation — verified at 02:30:29Z

Nothing belonging to the operator account or to unrelated workloads was modified.

- `~/.codex/auth.json` sha256 `d6dbaeab8f4347eeaaa58031fa26a9eb21d8cf9f267c3111a14885983a91028f`,
  mtime `2026-07-27 20:34:41.336079487` — **unchanged after codex ran 24 turns**, which is the
  load-bearing check for the rotation hazard. `~/.codex` dir mtime `20:40:27.392225613`
  unchanged; `models_cache.json` mtime `20:40:25.506088534` unchanged.
- `~/.claude/.credentials.json` mtime `2026-07-27 20:39:44.078077722` unchanged (read-only).
- Pre-existing orgs untouched: `~/.tightbeam` mtime `2026-07-27 11:07:18.849283668`, identity
  HEAD `05069247694b9a36003ec24b37e4689d69d3d456`; `~/.tightbeam-beam` mtime
  `2026-07-27 09:54:48.928863728`.
- `~/.mix/archives/hex-2.5.1` still `2026-07-27 09:24:31` — not reinstalled.
- clu global git identity: still empty. `clu` account: intact, uid 1001. Never deleted or reset.
- Unrelated workloads `active` at end of run: openclaw-gateway, subspace-daemon,
  postgresql@16-main, docker, containerd, ssh, tailscaled; listeners 18789/18800/5432 up.
- Nothing was installed, run, or read on **gibson**.
