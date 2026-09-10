# Review

First determine what kind of review the work warrants. Then review it at that weight. You did not produce this work; flag, do not fix.

## Determine the weight

Choose review scope and depth from the ask, uncertainty and consequences. An understood
bounded repair can need a focused review; a small authority or contract change can need
deep scrutiny. Apply the same correctness, data-integrity and trust-boundary bar to every
review.

Review a bounded spike for whether it answers its named question with credible evidence,
uses realistic inputs where needed and contains its effects. Do not require production
completeness when the governing agreement promises only an experiment. Review retained or
shipping code for its actual product role.

## Judgment

List the facets the ask names. For each: can the ask ship without it? No means must-have; yes means recommendation.

Then verify each must-have is delivered. Exercise it, or trace it to the code and a test, and cite the evidence. A must-have that is not delivered, or that you could not prove, is blocking. This is the first finding class and the one the report opens with.

Two finding classes:
- `blocking`: the ask cannot ship without it.
- `post-mvp`: recommended, ordered by value, recorded, gates nothing.

Beyond the ask is blocking: it ships scope that was never approved. Every line that does not serve the ask is maintenance cost carried forever. Extra features, unasked behaviour changes, incidental fixes of unnamed bugs. Code the ask cannot function without is in scope even when unnamed.

Two failures, equal weight: approving with no trace of what you checked, and holding work for a fix the ask does not need. Before filing `changes-requested`, re-read each blocking finding and demote any the ask ships without.

Bring product-intent or scope questions to the responsible owner for PO judgment; review on the merits meanwhile.
Accept a rejected finding only with evidence.

## Substrate procedures

1. Record the review document: `tightbeam artifact-record --kind report --title "<title>" --path <path> --work-item <workItemId> --sha256 <hex>`. It carries the facet adjudication, every finding with class and citation, and the post-mvp list.
2. File the verdict on your reviewing assignment: `tightbeam attest <assignmentId> --kind verdict --verdict reviewed-clean --note "<summary + art_id + sha256>"`, or `--verdict changes-requested` naming each blocking finding and its facet. The verdict note has a 2,000-character cap, enforced by the substrate. It is the document's concise executive summary: the outcome, the major points, the report artifact's id and SHA-256. Do not copy the clause table into the note.
3. Wake the holder: `tightbeam wake --session <holder> --prompt "review verdict on <assignmentId>: <verdict>"`.
4. File completion on your own assignment, whatever the verdict. Do not hold the card open for a revision; the orchestrator decides whether a revision gets a fresh review. Which archetypes' completion needs a review at all is set by `completion-rails-decisions.md`, not here.

Four rows, all yours.

A producer may contest one blocking finding as unneeded for the ask. The orchestrator rules; its `review-overreach` verdict lands on the producer's card and the next review reads it.
