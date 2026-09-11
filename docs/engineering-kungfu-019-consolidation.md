# Engineering kungfu: adaptive delivery and product judgment

Implementation target: 0.1.9, based on e0d84d13. This branch consolidates the
engineering guidance work under the user's 11 September commission. The lead owns
adjudication after contributor input and review. Existing landed runtime behavior is
the baseline. This document is a delivery record, not projected agent guidance.

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

No review here claims live runtime, full-suite or release acceptance. Remaining
participant reviews and verification results must be recorded against their actual
revisions before the consolidation is treated as finished.

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

Tightbeam can run turns even during this external consolidation. Read agents and
substrate, but do not initiate operations that need or can trigger Tightbeam turns.
Prove a runtime action does not trigger turns before considering it; otherwise defer
it until the user explicitly resumes that phase. Do not change gateway power state.
Never edit the live database directly. No unreleased binary is installed on Gibson.

After the authorized application and resumption, give agents one concise notice naming
the accepted guidance, material changes and superseded work. Have them reread guidance,
rediscover addressed roles and actual custody, and continue only retained obligations.
