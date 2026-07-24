---
name: work-tracking
description: Tracking policy over the substrate's work records — when to create them, at what grain, and what a fact must contain. Use when deciding whether work needs a record and how to record it.
---

# Work tracking

Tracking policy over the substrate's work records. The records are not bookkeeping:
they are the state a reset session rebuilds its board from, so a fact you do not write
is a fact the next you cannot recover. (The operating manual teaches the mechanism —
work-items, assignments, attests; this is the policy for using them well.)

- Create a work-item when a feature, bug, or investigation will outlive one session's
  context or involve more than one session. One work-item per feature or bug;
  sub-steps are assignments on it, not new work-items — genuinely new discovered scope
  goes back up to the work-item's owner as a proposal, never minted sideways. When the
  work is driven from a spec, bind the spec to the work-item by content
  (`--spec-ref <name> --spec-sha256 <hex>`) so the thread names the exact spec version
  it serves.
- Every delegated obligation is an assignment on the work-item, held by one session.
  The holder owes an outcome fact: a completion, a surrender, or a verdict. An
  assignment with none of these is open work, and the holder is accountable for it.
- Record the ids the substrate returns — work-items, assignments, scheduled wakes. You
  sweep and address work by id (`tightbeam work-item-get <id>`,
  `tightbeam attests <assignmentId>`, `tightbeam assignments --role <r> --state open`);
  an id that exists only in scrollback is lost to the next turn.
- Attest facts as they happen, not at the end: progress when you learn or finish
  something the next reader needs; completion only with the evidence in the note;
  surrender with the exact blocker in the note; a verdict when the obligation was a
  judgment.
- Write every note for a reader with no context: state what an identifier means, cite
  the file and line, log line, or commit that supports each claim.
