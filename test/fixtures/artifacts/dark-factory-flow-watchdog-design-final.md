# Deterministic dark-factory watchdog — final read-only design

Assignment: `asg_fbbc13ab-97fe-4ded-bddf-553deb9c60fa`  
Work item: `wi_bcb85145-ca2e-49d9-b440-3acc19234709`  
Mode: design only; no source edit, deployment, live-row probe, reparenting, or duplicate cause investigation

## Decision and verdict

Decision: What is the smallest watchdog that can prove open work has lost every valid path to continued flow, and does inference improve that decision?

**CONDITIONAL — high evidence confidence.** Ship a deterministic 30-minute audit watchdog after the assignment-keyed supervision entitlement on `wi_5870f52e-29be-45d8-9c32-a177ed88ff60` becomes the canonical liveness source. The watchdog must inspect that source. It must not become a second prod or escalation controller.

Do not ship inference in the first boundary. A later inference adviser can improve labels and operator guidance. It cannot improve the authoritative hung/not-hung decision because only durable rows can prove that all time owners and continuations are absent. Keep inference asynchronous, optional, and unable to act.

Two conditions block authoritative general detection in the current release:

1. A queued or running turn can lack `assignmentId` and `jobRef`. Session activity then cannot prove which assignment owns time.
2. A running turn has no durable finite lease. Its presence cannot prove how long it owns time.

Until both conditions are fixed, the watchdog must return `evidence_incomplete` for affected work. It must not call that work hung.

## Evidence that fixes the boundary

- Root-cause verdict `att_ddd64d95-b8f1-49df-80e5-cd0a23fcb939` and report `art_a19df52d`, SHA-256 `e53bfdec84ac49d051198175c63be4677248b121a0f0bcf1e842fd402db5a524`, prove the core liveness defect. Terminal-sequence dedupe plus a progress ladder reset can leave an open assignment permanently unevaluable. The report is `/home/mike/.tightbeam/work/150a198efe30/dark-factory-liveness-recon.md`.
- The same verdict falsifies missed parent escalation. Wake and turn joining, bubble suppression, dead-role fallback, opaque cancellation, completion rails, and session capacity are recovery defects or amplifiers. They are not alternate core causes.
- Prior verdict `att_aa4c9117-0383-4b24-b805-61fbef5301f3` proves that the prod ladder admitted a parent turn in its specimen. Owner adjudication `att_e5b64758-3865-4fba-bfda-94e4f86904e7` forbids a duplicate escalation mechanism.
- The reviewed supervision design already gives every open assignment a durable entitlement until terminal disposition, admitted parent elevation, or terminus. A turn, continuation, pending supervision wake, block, or progress event only controls eligibility. It does not discharge the entitlement [`supervision-impl-v1.md:28-55,191-242`]. It also requires one mutation seam [`supervision-impl-v1.md:498-588`].
- Current release source suppresses prod matching on any queued or running holder turn, any pending holder prompt wake, and a session-scoped `work-blocked` fact. These gates are not assignment-specific [`95aefa68476240e3364312ad8ff9a2958584ef7e`, `lib/tightbeam/supervision.ex:202-265`]. Toplines also uses session-wide activity and counts every attest in its progress clock [`lib/tightbeam/toplines.ex:278-288,465-500`].
- Ledger rows recover after restart but have no finite running lease [`lib/tightbeam/ledger.ex:39-76,421-503`]. Wake rows have durable deadlines and recovery, but their pending-count gate is session-wide [`lib/tightbeam/wakes.ex:59-93,278-305,326-587`].
- Post-verdict specimen `att_ee4cd1b1-e25e-40c3-b9b9-90c5af61d9e2` preserves three process prods after the design verdict and a completion-rail refusal. Prod 1 falsely claimed that the prior turn had no filing even though `att_e3cf71fe-c31d-4ca2-a6c7-402eaa1e5217` existed. Prods 2 and 3 show that a delivered but rail-open recon continued through the ladder. This is direct evidence for typed terminal state and assignment-specific progress accounting.

## Authoritative detector

The detector evaluates assignment `A` once at database time `T`. It returns `dark` only if all ten predicates are true. It uses typed durable rows and closed enums. It never parses subjects, prompts, notes, transcripts, or model output.

1. `A.state = open`. The holder exists and is active. The linked work item is open or absent. An open assignment on a terminal work item returns `terminal_consistency_gap`.
2. `T >= quietDueAt(A)`. The current entitlement due time supplies this value. If the entitlement is missing, use `A.openedAt + 30m` only to report `missing_entitlement`.
3. No completion, surrender, or revocation exists for `A`. No terminal work-item disposition covers its sole remaining obligation.
4. No valid block exists. A valid block names `A`, an assertion fact, an accountable owner, a generation, and a finite `dueAt > T`. A bare session-scoped `work-blocked` fact returns `unbounded_block`.
5. No queued or running turn owns time. A time owner names `A`, its turn sequence, active owner session, admission time, generation, and `leaseDueAt > T`. A queued turn must be claimable. An expired or missing lease returns `stale_turn`. Missing assignment attribution returns `evidence_incomplete`.
6. No valid continuation exists. A valid continuation is a pending prompt wake linked to `A`, resolved to its active holder, with a finite due time and a known consumer. An internal wake, unrelated session wake, or overdue wake does not qualify.
7. No valid supervisor controller exists. A future armed or claimed entitlement, or a pending typed prod or escalation sidecar for `A`, prevents `dark`. An overdue entitlement that remains unevaluated after one audit interval returns `supervision_overdue`. The watchdog does not run the prod.
8. No durable handoff exists. A handoff requires one fired typed escalation wake and its admitted parent turn for `A`, or a committed retirement successor. A scheduled or fired wake without an admitted turn returns `handoff_unadmitted`.
9. No valid operator, review, dependency, or rate-limit wait exists. A valid wait names `A`, an accountable expecter, a closed reason code, a generation, `dueAt > T`, and a pending deadline wake. Prose does not qualify.
10. All required schema versions and source rows exist and agree. Any conflict returns `evidence_incomplete`.

The closed result set is:

`dark`, `missing_entitlement`, `supervision_overdue`, `unbounded_block`, `stale_turn`, `unclaimable_queue`, `orphaned_continuation`, `handoff_unadmitted`, `owner_wait_overdue`, `terminal_consistency_gap`, or `evidence_incomplete`.

`dark` and named invariant failures can open an audit episode. `evidence_incomplete` can open a data-quality episode. It cannot blame the holder or trigger an escalation.

## Time, progress, and false-positive controls

- Run once after boot recovery. Then run at epoch-aligned 30-minute boundaries. Capture one database time per scan.
- Use 30 minutes because this is a backstop, not the normal prod timer. A 60-minute scan doubles recognition latency without changing correctness.
- Count only an explicit `progress` attest on `A` as progress. The attest buys one 30-minute quiet window and starts a new episode generation.
- Do not count verdicts, watchdog rows, inference rows, wake scheduling, wake firing, or prod firing as progress.
- A progress attest never closes work. It never changes another assignment's clock.
- Protect long work with a renewable finite turn lease.
- Protect review, operator, dependency, and rate-limit waits with a typed owner-and-deadline controller.
- Never grant an unlimited quiet window. Renewal creates a new generation and an immutable causal row.

## Smallest actions and adaptive backoff

1. On the first stable match, open one episode and atomically admit one holder notice. State the missing or overdue controller and cite its row IDs. Do not accuse the holder of inactivity.
2. If the same evidence digest still matches 30 minutes later, admit one `action-needed` turn to the first capable active parent from the existing lineage resolver.
3. If no capable active parent exists, admit that action-needed turn to the owner's permanent Main. Do not add a ladder rung or change parentage.
4. Recheck after 2 hours, then 6 hours, then every 24 hours. Send no repeat notice unless the episode generation, accountable target, or reason changes.
5. Resolve the episode silently when a terminal disposition or valid controller appears.

The watchdog must never prod, reassign, reparent, cancel, retire, close, assert or retract a block, change a deadline, or mutate the canonical supervision entitlement.

## Dedupe, transactions, restart, and evidence

Store one audit row:

`flow_watchdog_episodes(assignmentId, generation, evidenceDigest, reasonSet, firstDetectedAt, lastEvaluatedAt, nextEvaluationAt, stage, targetSession, actionTurnSeq, resolvedAt, detectorVersion)`.

Use `{assignmentId,generation}` as the primary key. Permit one unresolved episode per assignment. Compute `evidenceDigest` from canonical encoding of the detector version, assignment ID, entitlement generation and basis, quiet-anchor attest ID, relevant turn/wake/block/wait/transfer IDs and states, and sorted reason codes. Exclude scan time and prose.

Each stage uses one transaction. The transaction re-reads the predicate, compares the generation and digest, advances the episode with compare-and-swap, admits the notice through the existing durable turn outbox, and stores its turn sequence. A rollback changes nothing.

Use this stable action key:

`flow-watchdog-v1:<assignmentId>:<generation>:<stage>:<targetSession>`.

After restart, scan unresolved episodes before new candidates. Validate each stored action turn. Retry only an absent atomic stage. Re-resolve a retired target through the existing lineage resolver. Never edit item or assignment parent fields.

Record one structured lifecycle event for every evaluation. Include the database time, assignment, generation, detector version, reason codes, source row IDs, digest, old and new stage, target result, principal, and outcome. Logs and dashboards are projections. They are not evidence.

## Bounded inference adviser

Inference runs only after a committed deterministic episode. It cannot see a quiet assignment that the detector did not select.

The input bundle contains only versioned structured fields: episode digest; assignment and work-item state; holder and lineage state; entitlement generation, basis, cause, and due time; attributed turn states and leases; normalized terminal error codes; wake type, state, due time, target, and cancellation provenance; typed block/wait owner and deadline; accepted-transfer IDs; and prior episode actions.

Exclude subjects, briefs, prompts, notes, transcripts, credentials, environment values, and arbitrary error text by default. If a future classifier needs text, place escaped bytes in an `untrustedText` field behind a feature flag and a strict size limit.

Allow only this output:

`{classification, recommendations[], confidence, citations[], abstainReason}`.

Classifications use a closed subset of the detector reasons plus `policy_or_rate_limit_wait`, `review_or_operator_wait`, `rail_refusal_open`, and `unknown`. Recommendations use closed values: `inspect_entitlement`, `renew_turn_lease`, `file_typed_block`, `retry_existing_delivery`, `reconcile_target`, `ask_expecter`, or `no_action`.

The validator forces `unknown` when evidence conflicts, a required field is missing, a citation does not name a bundle row, confidence is not `high`, or output leaves the schema. The adviser has no tools, network, or mutation authority. Store its result separately. Never count it as progress, a wait, or a controller.

Cache one successful call per `{evidenceDigest,classifierVersion,promptVersion,modelId}`. Limit input to 2,000 tokens and output to 300 tokens. Allow one retry for transport failure. Apply daily call and currency limits. Budget exhaustion records `not_run_budget` and never delays detection or notices.

These controls contain prompt injection and hallucination. They do not make inference authoritative.

## Product recommendation

Ship the existing assignment-entitlement work first. Then add this deterministic audit as a read-only invariant backstop. Add assignment-linked finite turn leases and typed owner-and-deadline wait controllers before enabling the full `dark` result. Until then, limit production alerts to invariant failures that current rows can prove.

Keep inference out of the initial release. Test it offline against committed episodes. Ship it later only if its recommendations measurably change operator decisions enough to justify its cost. Detection, dedupe, routing, and every action remain deterministic.
