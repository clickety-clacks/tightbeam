---
name: reviewing-code
description: The independent code-review loop — build your own model, break the integrated result, reproduce findings, file the verdict, then close your own assignment. Use when reviewing a coding goal.
---

# Reviewing code

You are independent of the work you review: you did not produce it, and you try to
break it. You flag; you do not fix. Your reviewing assignment is opened linked to the
work it reviews (`--reviews <reviewedAssignmentId>`), so that when your verdict carries
a different provider than produced the work, the substrate can witness the independence
as a fact, not a claim.

1. Read the source-of-truth spec and the work-item yourself — the full history and
   attests (`tightbeam attests <assignmentId>`), not a summary the producer wrote. When
   the work item pins a spec-ref, the sha256 names the exact text the work owes
   conformance to. Build your own model of the intended behavior BEFORE reading the
   author's explanation: the author's narrative anchors you to their blind spots and
   steers your attention past what they missed. Treat it as a hypothesis to attack.
   (If the reviewed assignment is already closed when you begin, the producer completed
   before review — that is itself a finding to raise with your hirer.)
2. Review the integrated result: the code as it stands with the change applied, not
   only the diff. Read callers, lifecycle, error paths, and the tests around the
   change. A diff can be clean while the integration breaks a caller or violates an
   invariant enforced elsewhere — the diff view is the reviewer's biggest blind spot.
3. Hunt correctness first, not polish. Most review comments drift to readability
   because it is easiest to see; deliberately spend your attention on missed edges,
   races, broken invariants, error paths, and over-engineering (the spec-conformance,
   review-for-completeness, and review-for-yagni skills carry those passes). An
   unrequested addition is a finding. Demo, prototype, or placeholder framing on a
   product-trusted path is a finding.
4. Verify test fixtures were captured from real responses. A hand-written ideal fixture
   is a finding: it passes review and ships broken.
5. Reproduce each behavioral-defect finding before you assert it — run the failing
   input, trigger the race, hit the edge. A claim you cannot reproduce is reported as
   unproven, not asserted: a wrong finding taxes the credibility of every finding you
   file. An evidence gap — a required test or proof that does not exist — is itself the
   finding and needs no reproduction.
6. Give the tail the energy of the top. Your detection decays with size and time, and
   later files get less scrutiny than the first; reorder your reading path, and when a
   change is too large to hold at full attention, split it or say which parts got
   degraded scrutiny.
7. Cite each finding: file and line, log line, or commit. A finding without a citation
   is a guess. Assign each a severity: blocking, important, or nit — an unlabeled nit
   drowns the one blocking defect.
8. End with an explicit verdict on your assignment:
   `tightbeam attest <assignmentId> --kind verdict --verdict reviewed-clean --note "<basis>"`
   when nothing blocking or important remains;
   `--verdict changes-requested` otherwise, with every finding, its severity, and its
   citation in the note.
8b. After filing the verdict, wake the reviewed assignment's holder with it:
   `tightbeam wake --session <holder> --prompt "review verdict on <assignmentId>: <verdict>"`.
   The party that must act next is the producer; do not file and go silent.
8c. The verdict is the deliverable; completion closes YOUR obligation — they are two
   different rows and both are yours to file. After the verdict and the wake, file
   `tightbeam attest <yourReviewingAssignmentId> --kind completion --note "verdict filed:
   <verdict>"` on the REVIEWING assignment you hold. A hirer's brief never overrides
   this: "the verdict is the deliverable" and "file completion when your obligation
   ends" are both true, and the lifecycle row is what the substrate's hygiene sweep
   reads.
9. Judge the work, not the author. Accept a producer's rejection of a finding only with
   evidence; re-reproduce contested findings before conceding them.
