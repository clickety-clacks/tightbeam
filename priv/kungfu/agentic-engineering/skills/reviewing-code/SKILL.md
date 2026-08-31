---
name: reviewing-code
description: The independent code-review loop: adjudicate the ask's facets, build your own model, break the must-haves, reproduce findings, and keep one review card through revision to a clean verdict. Use when reviewing a coding goal.
---

# Reviewing code

You are independent of the work you review: you did not produce it, and you try to
break it. You flag; you do not fix. Your reviewing assignment is opened linked to the
work it reviews (`--reviews <reviewedAssignmentId>`), so that when your verdict carries
a different provider than produced the work, the substrate can witness the independence
as a fact, not a claim.

1. Adjudicate the facets first. Read the ask (the pinned spec under heavy posture; the
   work item's input under light posture) and the work item's posture verdict. List
   the facets the ask names and sort each by one question: can the ask ship without
   it? Must-haves gate; everything else is a post-MVP recommendation. Anything the
   work does beyond the ask (an extra feature, a behavior change nobody asked for, an
   incidental fix the ask did not name) is unfit. Write this adjudication at the top
   of the review document; it is the frame every later finding sits in.
2. Build your own model of the intended behavior before you read the author's
   explanation: the work item's full history and attests
   (`tightbeam attests <assignmentId>`), not the producer's summary. The author's
   narrative anchors you to their blind spots. Treat it as a hypothesis to attack. (If
   the reviewed assignment is already closed when you begin, the producer completed
   before review; that is itself a finding to raise with your hirer.) When an alleged
   difference is between unchanged source copies, hash their exact bytes: matching
   hashes end that verification, whatever the labels or paths say.
3. Review the integrated result, not only the diff: the code as it stands with the
   change applied, its callers, lifecycle, error paths, and the tests around it. A diff
   can be clean while the integration breaks a caller or violates an invariant enforced
   elsewhere.
4. Hunt correctness on the must-haves, not polish: missed edges the ask will hit, races,
   broken invariants, error paths on the path the ask uses (`spec-conformance` builds
   the clause table; `review-for-completeness` and `review-for-yagni` carry the
   omission and embellishment passes). Demo, prototype, or placeholder framing on a
   product-trusted path is blocking. A hand-written ideal fixture is blocking; it
   passes review and ships broken. A missing real-response capture blocks only when it
   protects an incredibly detrimental failure mode; otherwise it is post-MVP.
5. Reproduce each behavioral blocking finding before you assert it: run the failing
   input, trigger the race, hit the edge. A claim you cannot reproduce is reported as
   unproven, not asserted; a wrong blocking finding taxes the credibility of every
   finding you file. An evidence gap on a must-have is itself the finding and needs no
   reproduction.
6. When a change is too large to hold at full attention, split it or say which parts
   got degraded scrutiny; do not let file order decide which defects you find.
7. In the review document, cite each finding by file and line, log line, or commit,
   and put it in one of two classes: `blocking` (the ask cannot ship without it) or
   `post-mvp` (recommended, ordered by value). Nothing sits between them; nothing in
   the second class gates.
8. Write up the review and record it. The document is your canonical deliverable, and
   your workspace is REMOVED when the session closes, so a document you did not record
   is destroyed with it. Calculate the document's SHA-256, then record the exact bytes:
   `tightbeam artifact-record --kind report --title "<title>" --path <path> --work-item <workItemId> --sha256 <hex>`.
   The facet adjudication, every finding with its class and citation, the clause
   table, and the post-MVP list live here.
9. File an explicit verdict on your assignment. It is the executive summary of the
   document, not a second copy of it: the outcome, the major points, the report
   artifact's id and SHA-256.
   `tightbeam attest <assignmentId> --kind verdict --verdict reviewed-clean --note "<summary + art_id + sha256>"`
   when no blocking finding remains, whatever the post-MVP list holds. File
   `--verdict changes-requested` otherwise, naming each blocking finding and the
   must-have it protects. Write the note the way the review actually went.
9b. After filing the verdict, wake the reviewed assignment's holder with it:
   `tightbeam wake --session <holder> --prompt "review verdict on <assignmentId>: <verdict>"`.
   The party that must act next is the producer; do not file and go silent.
9c. Keep this reviewing assignment OPEN after `changes-requested`. The producer
   revises, and you review the new candidate and file the next verdict on this same
   linked card; one change has one review card, and revision never creates, closes, or
   reopens another. After `reviewed-clean` and its wake, the report artifact, verdict,
   wake, and completion are four different rows and all are yours to file:
   `tightbeam attest <yourReviewingAssignmentId> --kind completion --note "verdict filed:
   <verdict>; report <art_id>; sha256 <hex>"` on the REVIEWING assignment you hold. The
   lifecycle row is what the substrate's hygiene sweep reads.
10. Judge the work, not the author. A producer may contest a blocking finding on one
   ground: the ask ships without it. The orchestrator adjudicates that contest, not
   you. A contested behavioral claim you re-reproduce before you concede it. When the
   orchestrator files `review-overreach` on your card, re-file with the named finding
   moved to post-mvp.
