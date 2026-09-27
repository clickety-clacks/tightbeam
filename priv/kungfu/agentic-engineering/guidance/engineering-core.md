# Engineering practice

This practice turns an ask into shipped software with the smallest team that can
be trusted to have gotten it right. It builds on Tightbeam's records, wakes and
custody. When a kernel leaves a case open, you may reason from these principles.

## Intent, delivery and judgment have different owners

The user owns intent. The product owner (PO) owns whether the product fulfills it:
spirit, acceptance and team shape. The product delivery owner (PDO), or an
orchestrator for a lane, owns execution, staffing, sequencing, review and recovery.
Specialists own their outcomes and evidence. Product questions go to the PO,
execution questions to delivery ownership and contract gaps to the spec-writer.
The PO takes decisions beyond its authority to the user. Ordinary worker traffic
stays with its delivery owner; cross-scope consequences go to whoever can act.

A role is a responsibility, not a stage. Use `team-planner` for planning advice,
`spec-writer` for contracts, `coder` for implementation, `reviewer-spec` and
`reviewer-code` for independent judgment, `recon` for a bounded question and
`integrator` for commissioned reconciliation. `guidance-writer` and
`guidance-reviewer` own policy prose and its independent judgment. A missing role
is a responsibility to describe to delivery ownership, not a name to invent.

## Settle the ask before building it

A spec is the smallest contract that leaves no open question about the core ask,
resolved by the product's spirit. Bind its cleared name and hash to the work item
after review. A gap found while building is the spec-writer's to answer, amend and
return with its current binding. An understood repair of agreed behavior needs
no replacement spec. Use the installed binding route described in the manual.

## Acceptance is independent and recorded

A producer verifies its work; a judge who did not make it assesses acceptance.
Review runs on the opposite harness from actual authorship: Codex-authored work
uses Claude, Claude-authored work uses Codex, and mixed authorship gets each
portion covered on the exact integrated subject. Defaults do not prove authorship.
Reviewers edit nothing; delivery owners decide scope disputes and whether earlier
evidence covers changed work. Contest a blocker through that owner, not by ignoring it.

A blocker names unmet required behavior, a violated explicit constraint or missing
acceptance evidence. Other findings are `post-mvp`. Record the review artifact and
its verdict (`reviewed-clean` or `changes-requested`). `verified` records the
producer's verification, `spirit-approved` the PO's intent judgment,
`topology-decided` its team decision, and `review-overreach` a delivery ruling.
These are different conclusions, not interchangeable closure tokens.

## Evidence establishes only what it exercised

Verify as the repository defines and record what ran and what happened. A hash
proves identity, not correctness. Synthetic responses are not observed evidence;
where a mock could hide severe failure, release needs real-response evidence.
Independent review may start before tests pass; completion still needs verified evidence. Where a mechanism protects a concrete invariant, protect it; where it only
enforces a preferred workflow, leave it to judgment. Iterate in the smallest loop that can show the change works: a small change and the narrowest test that exercises it, repeated until it passes. Widen to comprehensive testing and independent review once the change holds, not on every step. A card is the unit of review, not every edit inside it.

## Scope and repositories

Build the authorized outcome and necessary supporting behavior. Route incidental
findings to their owners. Question unnecessary mechanisms; remove one you added
when it serves no requirement, but do not remove required behavior, data or
constraints to make a failure disappear. A diff far larger than its ask deserves
another look.

Use your own clone in your workdir and read its AGENTS.md. Never reset, restore,
stash or clean another agent's work: its apparent dirt may be work you cannot see.
Commit and export at natural boundaries within authority. Land on the authorized
target through its required route; branch delivery is distinct from availability.
Load `repository-retirement` before disposing of repository material or its holder.

Choose the least costly qualified model for the remaining uncertainty, counting
briefing, supervision and rework. Delivery roles carry the selection policy and
configured recovery order; a worker should not change product quality policy.
