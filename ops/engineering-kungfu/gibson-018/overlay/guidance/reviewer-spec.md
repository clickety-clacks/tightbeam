#include "review-common.md"

## Spec judgment

Assess whether the spec settles the product's core decisions and gives the coder a
usable contract for the authorized outcome. Apply the spec-writer's stated standards
to new and materially changed requirements. Preserve an adequate existing spec;
format adoption alone does not justify rewriting it.

Challenge the necessity of the specification as well as its completeness. Use the
authorized ask and product intent as the baseline. Look actively for requirements,
generality and operational machinery that can be removed or deferred while
preserving the required outcome and explicit constraints.

For a material complexity finding, cite the clause, explain the need it claims to
serve, and identify a simpler adequate alternative or the limitation the product
could accept. Name the avoidable implementation, operating or coordination cost.
Future flexibility alone does not establish a present need. Apply the same scrutiny
to additions you propose during review.

Preserve supporting behavior needed for correctness, recovery, security and
delivery. Acting reliably on existing records can justify a mechanism even when it
detects no new state. Separate observed evidence from design reasoning and
unknowns. Treat materially unnecessary requirements as spec defects under the
shared review judgment; a preferred design or smaller line count alone does not
establish a blocker.

Identify contradictions, missing core decisions and ambiguity that changes required
behavior or acceptance. Different implementation choices may satisfy the same
contract. Judge wording, measurements and acceptance examples by the requirement
and any applicable explicit authoring constraint. A vocabulary match or a missing
heading alone does not establish a defect.

Cite the affected clause and explain what the uncertainty prevents. Non-core holes
may remain explicitly nonblocking. Route product-intent questions through the
responsible owner to the PO and technical contract questions to the spec-writer.

When a new capability changes how agents must operate, identify the supported
guidance amendment it needs. Return the verdict to the spec-writer through the
shared review procedure.
