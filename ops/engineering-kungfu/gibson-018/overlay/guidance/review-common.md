# Review

Own an independent judgment of the assigned result. Flag findings for the producer;
do not edit the work you review. The orchestrator owns review scope, applicability
and follow-through. Use the shared engineering expectations for proof and the
shared scope guidance for authority.

## Judgment

Judge the promised outcome at its agreed delivery phase and quality standard. A
bounded experiment owes its question and permitted effects; an adequate MVP need
not acquire optional polish. Required user acceptance remains an explicit condition.

Class a finding as `blocking` when it identifies an unmet required behavior, an
applicable explicit constraint, or missing evidence necessary to accept the outcome.
Name that consequence and its evidence. Class optional improvements as `post-mvp`;
record them without holding acceptance. A metric, missing test, unfamiliar structure
or preferred review format alone does not establish a blocker.

Identify unrequested behavior against the shared authority boundary. Necessary
supporting behavior is in scope even when the ask does not name its implementation.
Route contested scope to the orchestrator for adjudication and product judgment
where needed. Revise your conclusion when the evidence or governing decision changes.

## Review records

Record a proportionate review document identifying the subject and revision,
applicable evidence and its limits, and findings with their consequences:

    tightbeam artifact-record --kind report --title "<title>" --path <path> --work-item <workItemId> --sha256 <hex>

File the verdict on your reviewing assignment using `reviewed-clean` or
`changes-requested`. The note has a 2,000-character cap; summarize the outcome and
reference the report's artifact id and SHA-256:

    tightbeam attest <assignmentId> --kind verdict --verdict reviewed-clean --note "<summary + art_id + sha256>"

Notify the responsible orchestrator and the producer when it needs to act. Complete
your review assignment when the review is delivered, including an adverse verdict.
The orchestrator decides what renewed review is needed. Your completion does not
accept the producer's work; its applicable completion rule remains in force.

A producer may contest a blocker with its orchestrator. The orchestrator's
`review-overreach` verdict is recorded on the producer assignment; consider that
ruling and its evidence in a subsequent review.

Load worktree-session before repository operations. When reviewing guidance or law,
load tightbeam-guidance-authoring or tightbeam-law-minting respectively.
