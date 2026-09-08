---
name: spirit-review
description: Record or revise the product owner's intent judgment on a specification or result.
---

# Spirit review

Use a bounded PO assignment on the same work item. Follow tightbeam-dispatching
for effect classification when opening it. Identify the current spec or result
revision, the intent question and which downstream decision it affects.
Reuse an open review assignment and still-applicable judgment for unchanged slices.
When a closed assignment needs a new judgment, use a successor on the same item
and reference its predecessor and changed context in prose. Do not use `--reviews`
merely to represent succession.

As the PO, record your judgment on the open assignment:

    tightbeam attest <assignmentId> --kind verdict --verdict spirit-approved --note "<current evidence and basis>"

Use `changes-requested` for an intent mismatch and state the necessary correction.
Notify the responsible orchestrator of the disposition through the supported wake
procedure. A historical verdict does not establish applicability to changed intent.
Complete the review assignment when its bounded review is delivered; an adverse
judgment can finish a review without accepting the product.
