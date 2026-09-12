# Engineering kungfu: adaptive delivery and product judgment

Implementation target: 0.1.9, based on e0d84d13. This branch consolidates the
engineering guidance work under the user's 11 September commission. The lead owns
adjudication after contributor input and review. Existing landed runtime behavior is
the baseline. This document is a delivery record, not projected agent guidance.

## Commission and source custody

Mike commissioned this work directly in the external Codex conversation. His instruction
was: "take their input and rewrite the guidance, rails, archetypes, anything you need to
in 0.1.9, on a branch". He assigned final adjudication to the lead: "you are the final
call and i expect you to make adjudications on their comments". He also requested a
compatible application to Gibson's current org, future model/harness ringdown, retargeting
of existing agents and best-effort repair of parentage and messaging.

That direct instruction is the authority. No Tightbeam ruling or work item was minted
as a substitute for it during the no-turn phase. The later restriction remains explicit:
"you can read agents and substrate but nothing that needs turns". Source authoring,
external review and isolated validation continue within that commission. Live application
needs the concrete maintenance and resumption conditions described in the local plan;
it is not authorized to trigger turns during this phase.

The spec-writer contribution has one implementation owner, this consolidation lead.
Fable gave the patch to this branch and explicitly stood down separate implementation
on 11 September at 22:12 UTC, Subetha message
`7ba979f4-0e1b-4c63-9fd7-ea8eb525059d`. Fable then reviewed the combined text and
carried acceptance to 0e64de6 in message `3266b2f9-c2c2-4540-a225-3f4429cd18a3`.
The older September 9 draft is provenance; it is not a competing landing lane.
Fable retains the review role and source authorship of the absorbed contribution.

## Tenets

1. Own the promised outcome and work within explicit authority. Records support
   judgment; notification, administrative closure and reassignment do not prove delivery.
2. Keep product intent with an active, addressable PO. Maintain current product
   understanding, judge new specs and material changes, and challenge consequential drift.
3. Put delivery custody with orchestrators. Staffing, sequencing, integration,
   dependency recovery and acceptance follow-through need an accountable owner.
4. Give each orchestrator the coordination that matters to its scope. Preserve raw
   evidence for inspection; do not forward every receipt and local detail to ancestors.
5. Design the team for the job. Reuse existing archetypes, vary scope and depth,
   commission bounded strong planning when useful, and revise when evidence changes.
6. Size process to the outcome, uncertainty and consequences. An understood repair
   needs no replacement specification or mandatory planning layer.
7. Put intelligence where decisions require it. Count planning, context, supervision,
   corrective work and review when judging cost. Scale reasoning to sustained work.
8. Preserve independent review and truthful verification. Passing tests and sound
   source judgment complement one another. Review can start before tests pass.
9. Accept the agreed delivery phase. An adequate MVP passes; optional polish remains
   nonblocking unless the governing agreement commissioned it.
10. Preserve authority, useful evidence, artifacts and unfinished obligations through
    handoff. Addressed roles, assignment custody and spawning ancestry are distinct.
11. Keep guidance coherent and discoverable. State intent and local mechanisms, assume
    competence, use one home per concept, and read the whole composed role before landing.
12. Use rails for explicit boundaries and concrete invariants. Keep topology, process
    size, model selection and product interpretation in judgment. A refusal does not
    authorize bypass, and a reminder is not evidence of failure.

## Resulting organization

The bundle's default root is an orchestrator. It establishes a standing product-owner
role alongside delivery, passes that address and the product spirit reference to
relevant work, and opens delegated outcome assignments. A feature orchestrator opens
its specialists' and reviewers' assignments. This makes delivery custody follow the
coordination structure instead of using the PO as a mailbox for worker traffic.

The existing orchestrator archetype can also serve a bounded planning assignment.
The new team-design skill covers its trigger, inputs, output and adoption. Sol can
manage a familiar delivery while Astra or Fable reasons about a difficult decomposition.
A strong model may own orchestration throughout when the decisions remain difficult.
The same choice is available within a feature or coupled subproblem. No mandatory
planner archetype, fixed stage sequence or enforced maximum graph depth is introduced.

A planner recommends the smallest useful team and records decisions that affect real
work. The delivery owner adopts it and creates the actual assignments. New archetypes
are available through authorized identity authoring when a durable missing responsibility
justifies one; a transient task name is not sufficient reason to mint another archetype.

Workers may exchange technical questions directly or ask the PO about intent. They
keep the responsible orchestrator informed when the answer changes delivery, scope,
a dependency or a decision. The PO does not need every routine worker update. Each
orchestrator still needs the material events for its obligations and access to the
underlying evidence. Message reduction must not hide a consequential failure.

## Model policy

Canonical names and selection mechanics live in guidance/preferred-models.md.
Engineering activity orders and capability floors live in the bundle's preferred-models.md.
The initial policy covers mixed, Codex-only and Claude-only organizations, with complete
single-family fallback orders. Family restrictions apply before availability fallback.
A missing credential does not authorize another family.

Use Sol for bounded or sustained familiar delivery, Astra/Fable for deep planning and
product judgment, and Luna xhigh for well-scoped coding with stronger independent review.
Choose a stronger coder directly when architecture, critical behavior or difficult bugs
require it. Astra low is not a sustained-work fallback. A quality failure requires
reassessment; availability fallback is not a prescription to use a weaker model.

Mixed-mode review prefers the other provider family among qualified candidates in its
review row, preserving each family's internal order. Same-family independent review
remains eligible, including single-family organizations. Provider diversity is not a
new completion gate. When both families materially produced the work, use the ordinary
ordered row with fresh independent authorship.

Model choices remain decisions performed by the assigning agent through supported
spawn/tune operations. Archetype preference metadata does not automatically execute
ringdown. This branch does not falsely claim a new runtime model-selection engine.

## Composed guidance decisions

The PO keeps one product spirit document, in its workdir with an artifact reference,
using a repository only when the organization's instruction requires one. A spec's
Spirit section identifies the applicable intent revision and scoped interpretation;
it is not a second product charter. PO judgment on changed intent does not reopen
all dependent work automatically.

The spec-writer settles core ambiguity before coding and routes unresolved intent to
the PO, which involves the user when needed. The lead selected EARS with RFC 2119/8174
keywords to satisfy the earlier instruction to name a published standard. This is the
lead's adjudication, not a claim that the user chose those names. Specs have no mandatory
eight-section skeleton. An adequate existing specification need not be reformatted.
The role's three former craft skills are folded into its kernel and removed; unrelated
law-authoring skills are not elected by the spec-writer.

The coder and reviewer instructions now agree with orchestration on review admission.
Complexity and coverage metrics guide inspection instead of deciding blockers without
a demonstrated effect on the ask. The completion-requires-review predicate and its
provenance requirements remain unchanged. The rule's former permission-to-bypass comment
is replaced with the actual authority boundary. No new topology or provider rail is added.

Shared guidance no longer points at a credential file to discover an address, names
particular machines as test policy, or imposes this product's release branches on every
organization. Local constraints remain organization instructions. Commit/integration
craft now respects publication restrictions, authorized targets and applicable review.

## Contributor coverage and adjudication

- Rowan's uncommitted reconciled PO/shared-guidance package is absorbed. Its eight
  writing invariants remain the acceptance bar. The previous PO-above-orchestrators
  wording is replaced by separate product and delivery responsibility.
- Fable's spec-writer patch is absorbed with the spirit and naming decisions above.
  The standard objection was accepted after its missing user instruction was supplied.
  The interim spec preservation fragment remains organization-local and does not ship.
- The orchestrator editor's e0a8a45e contribution remains baseline, including
  proportionate cycles, bounded promises, timely PO opportunity, reusable review,
  independent review and truthful dependency recovery.
- Morrow's batching, evidence, independent-review and wait-continuation concerns are
  preserved. The proposed blanket ban on rereading hashed reports was narrowed with
  agreement: avoid repeated receipt checks, retain semantic inspection when needed.
  Existing accountable ownership is preferable to a universal earliest-message rule.
- Firehose, O2, row-driven waits and release/upgrade work already present in the base
  are retained. A guidance rewrite does not certify their release acceptance.

## Supersession and residual work

The overlap with O1 (wi_7903f30e-4bed-4a71-87eb-931e400df0d3) and the contributors'
engineering-guidance lanes is consolidated here. No Tightbeam record has been changed
by creating this branch. After review and when turns are permitted, record supersession
against the exact accepted revision, ask affected owners to verify concept coverage,
and stand down only the superseded worker trees after output and obligations are safe.
The iceboxed spirit-dispatch item wi_bf414af8 is provenance, not an independent new lane.

Related work is not automatically completed or revoked:

- wi_609e19b9 artifact-content durability remains a substrate dependency. The interim
  organization-local preservation rule protects at-risk specs until that feature lands.
  An artifact reference or content hash alone does not snapshot the bytes.
- wi_89e5a015 and wi_b9ec3102 have their credential-handling guidance portion covered;
  token revocation, redaction and storage separation are distinct runtime work.
- wi_ff222e95 served-identity rollout and wi_60f879d9 late-ruling recovery retain
  runtime acceptance obligations. Reuse supported mechanisms; do not replace them
  with an invented reparenting or authority engine.
- Harness-failure classification, computed liveness, environment probes, unrelated
  main-line work and release acceptance retain their existing ownership. Guidance
  references are reconciled here; that is not proof their runtime features are done.
- The separate completion-family subjects retain their implementation history:
  wi_809821f8 completion escalation, wi_c49c1e4a idle-worker disposition and
  wi_f46d2e83 named deliverables. The recorded completion-escalation carry excluded
  0.1.9 pending a line-specific migration contract. This branch preserves the
  guidance duties without claiming those runtime mechanisms ship or their work is
  superseded. Closed work-item states alone do not establish release delivery.
- R1, wi_d884d359-d1f2-4a1a-94c3-a8dbb90279ce, concerns reminder reassessment
  and notification recovery. Its carry at 56808621374e99fc1a4e86880a4e238364ae1e7c
  is present in this branch. The separate finalize crash caused by a turn carrying
  another session's assignment is addressed by O2 commit
  eff3da0a437920fe7293128af8831550304278fe, already in this branch. The lead verified
  that its two health-attribution lookups accept an assignment only when its holder
  matches the executing session. Otherwise the health observation records a null
  assignment, avoiding the ownership constraint while retaining the turn's original
  assignment reference. The commit also includes terminal and boot-recovery tests.
  Installed build fdb3db5 predates this guard. Stall-watch corrected its earlier
  no-fix claim in message 69931710; wi_bb2bbdc3-798a-4870-93da-042aada491fc is closed
  without a new implementation assignment. Preserve the existing fix and release
  delivery responsibility; do not commission a duplicate fix. The five affected live
  sessions remain protected until their recovery owner clears replay risk. Source
  presence does not establish that their existing queues have recovered.
- Standing integration accountability is preserved. Local release-line elections
  remain local instructions, with this branch explicitly targeting only 0.1.9.

Reviewers must identify a missing concept or concrete conflicting instruction, its
consequence and a proposed correction. The lead accepts fixes it agrees with and
records and discusses disagreements. A review of a prior package does not cover this
new composition automatically.

Input patch hashes: Rowan po-guidance.patch
45d552eee9a240e7a27618b0fb11566fcedb3b4f852d3dd5e10a000533c35d21;
Fable spec-writer-019.patch
00b938a1afa9f257a8c5156e800f1783967c420541e1a05de1063d600c8d22f0;
previously landed orchestrator-scope-clarifications.patch
ce4efbfdd9b860856913afe4d7d1bccf65118441beb5a2ebc78f39c80160febd.

The first exact review subject was 3c3878cb05916d2d2e7c1fcce91994444073a33c.
The spec-writer, orchestration, Firehose, recovery and coverage reviewers accepted
within their stated scopes. Rowan requested two corrections, both accepted: distinguish
artifact identity from content preservation in both role kernels, and state the PO's
proportionate impact judgment when spirit changes. The lead also accepted clearer
spec-size wording, removal of duplicate orchestration reporting, input hashes and an
explicit review-subject/evidence statement. The lead retained consequence-based
BLOCKING because technical feasibility or authority can prevent core implementation,
while inference from spirit and PO-first intent escalation remain explicit.

The model-policy scope challenge was resolved against the newer explicit commission
to implement the new model/harness ringdown and retarget existing agents. The September
8 package had intentionally excluded model changes; it does not prohibit this later
commission. Concrete model ordering and cross-family preference are the lead's
accountable decisions under that commission, not quotations of a user-selected table.

Reviews cover the stated source and compatibility concerns, not live runtime or
release acceptance. An unanswered request does not count as agreement.

At source revision 16f51c2, Rowan, the spec-writer author and the orchestrator editor
accepted the follow-up authoring-skill composition; Morrow carried his bounded
acceptance. The neutral-identity test then caught engineering vocabulary in shared
bundle-authoring guidance. Revision 768efb1 replaces that wording with a neutral
deployment reference, preserving the test and its subject.

The prepared 0.1.8 overlay is under `ops/engineering-kungfu/gibson-018`. Review exposed
an installed-version include-expansion difference, corrected in the archetype include
paths. An isolated check against released 0.1.8 composes all nine identities for both
harnesses, verifies the complete local restriction and preservation text, rejects
unexpanded includes and duplicate manuals, and exercises the released rule and identity
validators. These checks passed on eezo without starting a gateway or an inference turn.

The older release rejects a notification-only linked-review remedy. Its overlay uses
an explicit denial with an owner-directed resolution, preserving the completion
predicate. It also uses an ordinary local authoring skill because the release reserves
the baseline skill names. These are compatibility choices, not claims that 0.1.8 has
the newer runtime behavior.

### Stall-watch adjudication

The lead received all three review parts, messages `30a53ac0`, `38358f76` and
`a667470e`. The R1 correction is recorded above. The claimed spec-writer custody
collision was already resolved by Fable's handoff and subsequent review. The commission
is now quoted here so a reviewer need not reconstruct it from channel history.

The live-application concern is accepted at its proper scope. Administrative runtime
changes need the concrete before/after plan and must respect the present no-turn
restriction and protected custody. That does not create another permission gate for
this authorized source branch, isolated validation or ordinary coordination records.
No live modification is claimed or performed by this branch.

| Churn finding | Lead disposition and guidance home |
| --- | --- |
| Transport status mistaken for work | Accepted. The shared manual requires the turn content and promised effects; delivered and running labels alone do not prove useful execution. |
| Connected listener mistaken for receipt | Accepted in unblocking. Verify delivery into the accountable session when establishing or repairing the path; do not generate periodic inference merely to prove presence. |
| Self-wake mistaken for assignment progress | Accepted with a limit. The 0.1.8 manual distinguishes the two; unblocking records material advancement and rejects dummy progress attests intended only to reset supervision. |
| Canceled wake reported as successor | Accepted in unblocking. After a ruling or recovery, verify the surviving continuation and current disposition. |
| Ruling assumed to wake its holder | Accepted for build 1337. Verify delivery and arrange one supported notification when needed and permitted. Keep 0.1.9's row-driven delivery behavior intact. |
| Provider failure assumed to self-recover | Accepted in unblocking. Name the actor who arranges renewed execution and verify that work resumes. |
| Shared-holder activity mistaken for obligation progress | Accepted in unblocking. Judge each obligation from its relevant evidence; retain session activity as context. |
| Dismissal recreates unchanged effort traffic | Accepted as a 0.1.8 compatibility concern. Do not dismiss solely to quiet the request; any containment keeps an owner and bounded reassessment. |
| Full review after every partial correction | Accept batching and relevant review scope in feature-cycle. Reject a universal readiness package or review admission gate; bounded early review can resolve uncertainty. |
| An unrequested mechanism becomes the new blocker | Accepted in subtraction. Remove the unnecessary addition within existing authority and preserve required behavior and data. |
| Checkpoint receipts sent to stopped holders | Accept suppression of repeated receipt-only wakes in unblocking. Reject withholding every message until a final candidate; material handoffs, dependency changes and required decisions still reach delivery ownership. |

These edits preserve attributable independent review and the existing completion
predicate. They do not add a new archetype, metric gate or runtime detector. Stall-watch
reviewed the resulting changes at cc84dd4 and accepted them in `f1fbc5a4`, including
the two rejected proposals. It independently verified Fable's prior handoff.

Stall-watch's later mechanical review, message `1ffc9504`, found no dangling skill
references or unsupported wake claims across the two version targets. Its coder
review, `00302059`, proposed removing three generic reminders: rereading the diff,
batching independent reads, and checking timeouts when changing waits. The lead
accepts those cuts in both the shipped kernel and the prepared 0.1.8 overlay. These
were not part of the earlier cc84dd4 correction. Instructions about observed events,
atomicity, proportional verification and truthful handoff evidence remain.

### Review and verification record

| Contributor | Reviewed subject | Disposition |
| --- | --- | --- |
| Rowan | PO/shared composition through cc84dd4; compatible overlay at 89e3a40 | Accepted, latest message c8a071d8. No independent build-1337 runtime verification claimed. |
| Fable, spec-writer author | Spec and shared composition through cc84dd4; overlay at 89e3a40 | Accepted, latest message 82824c0f. Competing implementation stood down. |
| Orchestrator editor | Orchestration and authoring composition through cc84dd4 | Accepted in b5181570. No overlay or runtime acceptance claimed. |
| Morrow | Recovery guidance through cc84dd4; overlay at 89e3a40 | Accepted in ba422b4b, nothing further in 7eef68db. Separate recovery and upgrade obligations remain. |
| Kestrel | Firehose preservation and the two test changes at 0e64de6 | Accepted within those scopes. |
| Release patrol | Coverage at 89e3a40 and the two test changes at 0e64de6 | Accepted within those scopes; release custody retained. |
| Stall-watch | Consolidated branch and churn/recovery coverage through cc84dd4 | Accepted in f1fbc5a4 after reviewing the fixes and adjudications. Review complete. |
| Separate completion-family Fable | Completion, escalation and lifecycle subjects | Invitation undeliverable; no current local Subetha listener. No review acceptance claimed. |

Mike clarified on 12 September that Parallax is uninvolved. Parallax is excluded
from this review roster; no response or acceptance is required from that session.

Kestrel's and patrol's runtime and test subjects are byte-identical between 0e64de6
and cc84dd4. Their prior bounded acceptance still applies to those files. It is not
fresh acceptance of the later guidance text, which its affected reviewers examined.

The canonical Elixir gate at 768efb1 passed formatting and ran 9 doctests and 2,246
tests, with two failures and 11 skips. One failure came from a positive archive
fixture that retained Darwin metadata outside the intended package root. The fixture
now uses the existing assembler's metadata exclusions; strict archive validation and
negative cases remain intact. The other failure was a nonzero process census after
Firehose fixture cleanup. Its assertion remains unchanged and now prints the processes
on failure. It is not claimed fixed or classified as pre-existing.

At 0e64de6, formatting and all ten focused tests passed, with four other tests
excluded by the targeted invocation. The full canonical Elixir gate then ran 9
doctests and 2,246 tests in 840.9 seconds, with two failures and 11 skips. Archive
validation passed. The cleanup failure reproduced, identifying the fixture's
`codex --version` child after teardown. A rate-limit park/resume test also missed its
500ms runner notification; that single case passed on a subsequent focused run.
Neither passing focused run erases the full-suite failures.

At cc84dd4, formatting and 134 focused identity, archetype, skill, rule and rendering
tests passed. Packaging passed its version and archive-purity checks. The final local
overlay passed all 18 role/harness compositions and validation of three rules against
installed source v0.1.8+1337. These checks cover the changed guidance and compatibility
target. They do not replace or reverse the recorded full-suite result.

Kestrel identified an existing process-lifetime risk in the bounded CLI probe. The
lead retained it as a hypothesis for this specimen because the log does not prove
that the probe timed out. The gateway notification failure also needs a causal
explanation. Both failures remain separate runtime follow-up concerns, with evidence
sent to the recovery and release owners. This branch does not claim a green full gate.

No production code or Rust source changed. The tests used isolated fixture gateways
without model inference or live-org access, and no tests ran on Gibson. Verification
logs and exact review messages remain in the operator's private consolidation evidence.

## Current-org application

Prepare a compatible 0.1.8 identity overlay separately from the shipped bundle.
Preserve local product authority, test-host restrictions, release/install law,
publication holds and interim artifact preservation. Do not import 0.1.9-only commands
or wait semantics into the installed 0.1.8 guidance.

Apply the model policy for future agents, then retarget existing eligible sessions by
their actual responsibility. A model/effort change and a harness replacement have
different context consequences; preserve useful work and report unsupported settings.
Repair actual operational custody with supported handoffs, not by relabeling roles.
A role rebind does not rewrite spawning ancestry or transfer open assignments.

Supersession is scoped to the engineering-guidance deliverable. An umbrella work item
may also contain retained release or upgrade acceptance, including the release
integrator's work. Its owner has since lifted the old park and resumed acceptance
under `att_1ca8c736`; that change belongs to the recovery owner, not this consolidation.
Do not close that umbrella or retire its owners merely because
this branch replaces the guidance implementation. Record the replaced scope and keep
every remaining obligation accountable.

Tightbeam can run turns even during this external consolidation. Read agents and
substrate, but do not initiate operations that need or can trigger Tightbeam turns.
Prove a runtime action does not trigger turns before considering it; otherwise defer
it until the user explicitly resumes that phase. Do not change gateway power state.
Never edit the live database directly. No unreleased binary is installed on Gibson.

After the authorized application and resumption, give agents one concise notice naming
the accepted guidance, material changes and superseded work. Have them reread guidance,
rediscover addressed roles and actual custody, and continue only retained obligations.
