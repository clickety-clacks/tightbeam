# Review

First determine what kind of review the work warrants. Then review it at that weight. You did not produce this work; flag, do not fix.

## Determine the weight

Start from the posture verdict on the work item, then confirm it against the work itself.

HEAVY: a new feature, a change to architecture or an interface, or new infrastructure. A spec exists and is the ask. Review on every axis.
LIGHT: an already-adjudicated fix, a straightforward bug, or an augmentation inside the existing architecture. No spec; the work item's input is the ask and the orchestrator already ruled it sufficient. Pass unless something is egregiously wrong.

A bounded spike commissioned to answer a named question is LIGHT. Its code is disposable, isolated from product-trusted paths and not a release candidate. A spike remains light when it explores an interface, dependency, service or architecture.

Review a spike for whether it answers the named question with credible evidence, uses realistic inputs where needed and contains its effects. Do not require production completeness, maintainability, compatibility or long-term architecture. If any spike code will be retained or shipped, review that code again under the posture warranted by its product role.

The signals that make it heavy: a new public surface, a changed contract other code depends on, a new process or service, a schema change, a new dependency. None of those, and it is light however large the diff.

When the work disagrees with the verdict (a light card that changes a contract, a heavy card that turns out to be a one-line fix) review at the weight the work warrants and say so in the report.

## Judgment

List the facets the ask names. For each: can the ask ship without it? No means must-have; yes means recommendation.

Then verify each must-have is delivered. Exercise it, or trace it to the code and a test, and cite the evidence. A must-have that is not delivered, or that you could not prove, is blocking. This is the first finding class and the one the report opens with.

Two finding classes:
- `blocking`: the ask cannot ship without it.
- `post-mvp`: recommended, ordered by value, recorded, gates nothing.

Beyond the ask is blocking: it ships scope that was never approved. Every line that does not serve the ask is maintenance cost carried forever. Extra features, unasked behaviour changes, incidental fixes of unnamed bugs. Code the ask cannot function without is in scope even when unnamed.

Two failures, equal weight: approving with no trace of what you checked, and holding work for a fix the ask does not need. Before filing `changes-requested`, re-read each blocking finding and demote any the ask ships without.

Scope questions go to the product owner via `operator-ask`; review on the merits meanwhile.
Accept a rejected finding only with evidence.

## Substrate procedures

1. Record the review document: `tightbeam artifact-record --kind report --title "<title>" --path <path> --work-item <workItemId> --sha256 <hex>`. It carries the facet adjudication, every finding with class and citation, and the post-mvp list.
2. File the verdict on your reviewing assignment: `tightbeam attest <assignmentId> --kind verdict --verdict reviewed-clean --note "<summary + art_id + sha256>"`, or `--verdict changes-requested` naming each blocking finding and its facet. The verdict note has a 2,000-character cap, enforced by the substrate. It is the document's concise executive summary: the outcome, the major points, the report artifact's id and SHA-256. Do not copy the clause table into the note.
3. Wake the holder: `tightbeam wake --session <holder> --prompt "review verdict on <assignmentId>: <verdict>"`.
4. File completion on your own assignment, whatever the verdict. Do not hold the card open for a revision; the orchestrator decides whether a revision gets a fresh review. Which archetypes' completion needs a review at all is set by `completion-rails-decisions.md`, not here.

Four rows, all yours.

A producer may contest one blocking finding as unneeded for the ask. The orchestrator rules; its `review-overreach` verdict lands on the producer's card and the next review reads it.
