---
name: tightbeam-dispatching
description: Assignment and attest hygiene when dispatching work to another session or holding an assignment yourself. Use when hiring, delegating, or working under an open assignment.
---

Dispatching work: spawn (or pick) the worker, then open the
obligation as a row — `tightbeam assign --subject "..."
(--session K | --role R) [--work-item <id>]` — and wake the worker
with a brief of AT MOST ONE SENTENCE plus the references:

    tightbeam wake --role coder:x --prompt \
      "You hold asg_123 (wi_456): fix the picker titles — read the \
      assignment, its attests, and the work-item from the substrate."

Link every assignment to the work item it serves (--work-item): the
work item is the one identity that survives every session in the
tree. Decompose work into assignment SUBJECTS down the chain — never
mint a new work item for a piece of an existing one; genuinely new
discovered scope goes back up to its owner as a new work item.

(The dispatch LAW — card first, one-sentence pointer wake, work-item threading,
retire-your-hires — is in the operating manual every session carries; this skill is
the dispatcher's deeper ceremony.)

Holding an assignment: every turn must leave a valid durable liveness
receipt or a scheduled continuation wake. Create a reporting attest or
reporting wake only for a new material result or evidence, an exact new
blocker or refusal, a bounded decision request, or one new, unexpired
bounded checkpoint. The checkpoint names the next action or condition
and its deadline or scheduled continuation.

A continuation wake is a liveness receipt, not a status report. It names
concrete continuation work or a dependency recheck and when it resumes.
Do not file "still working," "unchanged," "waiting," or "no update."
Do not repeat a result, blocker, refusal, decision request, or checkpoint
without new evidence or owner-relevant state.

Ask another agent only when answering is that agent's normal work. If its
answer is necessary and does not arrive, keep the question and evidence as
your assignment's exact blocker, continue separable work, and schedule a
re-check. Do not chase a parent or Main merely because the answer is late;
normal lifecycle routing is the substrate's job.

If no reporting exception applies, record the one valid bounded checkpoint
when available or schedule a concrete continuation wake. Never manufacture
a generic progress attest. Completion and surrender remain truthful terminal
receipts. A qualifying progress row resets the prod countdown; scheduled
wakes pause it; words do neither. If you stall, prods arrive from
process:tightbeam and escalate up your spawner chain after N misses.

Retiring: your hires are yours to clean up. When a hire's last open
assignment closes and you have no further work planned for it, retire
it — `tightbeam retire --session <key>` (forcible, spawner's act, no
negotiation; history survives retirement). An idle hire with no open
obligation is drawer noise and context cost, not capacity. Sweep after
every completed piece of work: `assignments --session <hire>` empty →
retire. Sweep BOTTOM-UP: if a hire has hires of its own, its subtree
settles before it does — never retire a session whose dependents still
hold open work; check with `tightbeam list` (spawnedBy) first.

Supervising: an escalation wake means your hire's assignment
stalled — N prods, no rows. Judgment is yours: read their stream,
wake them, re-staff, or ask the operator to revoke the assignment.
The substrate will not conclude why and will not act for you.
