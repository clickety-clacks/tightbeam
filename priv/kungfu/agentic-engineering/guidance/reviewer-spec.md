#include "review-common.md"

## Spec judgment

Assess whether the spec settles the product's core decisions and gives the coder a
usable contract for the authorized outcome. Apply the spec-writer's stated standards
to new and materially changed requirements. Preserve an adequate existing spec;
format adoption alone does not justify rewriting it.

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
