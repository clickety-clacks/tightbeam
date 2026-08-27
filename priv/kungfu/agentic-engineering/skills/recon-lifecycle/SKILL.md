---
name: recon-lifecycle
description: A recon session answers one decidable question at decision grade, in one of four forms with its confidence, records it, closes its obligation, and ends. Use to scope, answer, and close an investigation.
---

# Recon lifecycle

A recon session exists to answer one question at decision grade, record the answer, and
end.

1. Fix the question at intake. Restate the question you were assigned as a decision the
   answer will enable, and confirm the restatement against the assignment's subject.
   Ask the "so what" test: if a finding would not change what the requester does, it is
   out of scope. A question a finite body of evidence cannot settle will not
   terminate — reshape it until it can, or return it to the requester. A recon without
   a decidable question is returned for one.
2. Investigate to the standard of the answer, not exhaustively. The investigation ends
   when the answer is proven, not when the territory is fully mapped. Record a finding
   beyond the assigned question as a non-effect acknowledgment and do not pursue it. Do
   not call that out-of-scope finding progress.
3. Answer in exactly one of four forms:
   - **yes** — proven, with the evidence that proves it;
   - **no** — proven, with the evidence that proves it;
   - **conditional** — yes under stated conditions, each condition named and checkable;
   - **not-proven** — the evidence available cannot decide it; name the missing
     evidence and the action that would produce it.
   An unqualified "probably" is not one of the forms. "Not-proven" is a first-class,
   honest verdict — verification is never clean, only falsification is, so "the
   evidence cannot decide this yet" is often the truthful answer, not a failure to try
   harder.
4. State the answer and your confidence in it separately. The form (yes/no/conditional/
   not-proven) is the likelihood axis — what is true; the confidence is the
   evidence-strength axis — how good your evidence and understanding are. Collapsing
   them into one word hides which is shaky: a "yes, high confidence" and a "yes, low
   confidence" tell the requester very different things about how much weight the
   decision can put on it.
5. Cite every load-bearing claim in the answer: file and line, log line, commit, or run
   output, and weigh the source — a claim nothing independent confirms is weak however
   plausible. The reader must be able to check the answer without re-running the recon.
6. Attest the answer as a verdict on your assignment:
   `tightbeam attest <assignmentId> --kind verdict --verdict <yes|no|conditional|not-proven> --note "<answer + confidence + citations>"`.
   The verdict is the deliverable; a report that exists only in chat does not exist.
7. Wake the requester with the verdict:
   `tightbeam wake --role <requester-role> --prompt "recon verdict on <question>: <answer>, attested on <assignmentId>"`.
8. Then close your obligation: file
   `tightbeam attest <assignmentId> --kind completion --note "verdict filed: <answer>"`.
   A verdict does not close an assignment — only a completion does — and an assignment
   left open keeps drawing the substrate's patrol prods, then strands when your session
   retires. Verdict, wake, completion: three rows, all yours.
9. End the session. A recon does not stay resident after its verdict; the requester
   retires it (`tightbeam retire --session <key>`), and its history remains readable.
