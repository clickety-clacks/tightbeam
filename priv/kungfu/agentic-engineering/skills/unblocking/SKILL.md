---
name: unblocking
description: Detect a stalled assignment, classify the block (wrong assumption, unneeded gate, refused workaround, real block), and either clear it yourself or escalate it to the user — never a third state. Use when a goal has stopped moving.
---

# Unblocking

Work never stalls silently. Every block is either cleared by you or escalated to the
user; a third state does not exist. When an agent hands you a blocker, the problem
stays theirs to carry until you have established it is genuinely yours — the failure
mode is answering "leave it with me," absorbing the block, and becoming the bottleneck
for work you assigned. Classify first; hand most blocks back with what the agent was
missing.

## Classify activity theater

Activity theater is truthful work activity that leaves the assigned deliverable
unchanged. Detect it by asking, "What changed on the deliverable since my last look?"
Never substitute how many turns, attests, audits, wakes, or replies occurred. Classify
the evidence before you clear a block or authorize more of the same activity:

- **RECEIPT-FILING** — the holder files truthful attests about activity that did not
  move the deliverable. `asg_3d219794` filed ruling acknowledgments as progress for
  five days.
- **AUDIT-LOOPING** — the holder schedules more evidence gathering while ordered work
  stays untouched. Historical lane D3 spent 13 hours on dependency audits; audit
  specimen G5 reached a "fourth fallback audit"; specimen G6 reached a "ninth
  recurrence."
- **PROD-ANSWERING** — each turn answers the liveness prompt and does nothing else.
  `asg_852fc8f1` produced eleven consecutive one-turn windows with zero receipts.
- **SCOPE-NARROWING AT CLOSE** — the holder delivers adjacent or partial work and
  stamps the original card complete. `wi_113442f5` closed with "Completed D3 spec
  authoring and push only" although its deliverable included implementation.
- **RUBBER-STAMP SUPERVISION** — the supervisor absorbs repeated stall signals and
  authorizes continuation without changing the lane. More than 30 operator continues
  accumulated on unmoving lanes on 2026-08-26.

Treat the shared signature as decisive: every row can be truthful while the
deliverable does not move. Stop authorizing more activity of the same class. Name the
unchanged deliverable boundary and choose a different next action or end the lane.

Use the tracked mechanical countermeasures only after you verify that their reviewed
bytes reached the running substrate. The typed-progress work item
`wi_990f7b7e-837b-4aba-8f2e-ac6617327d78` is designed to remove effect credit from
RECEIPT-FILING, AUDIT-LOOPING, and PROD-ANSWERING. The completion-deliverable work
item `wi_f46d2e83-e152-429f-93c7-3c51989bd391` is designed to prevent
SCOPE-NARROWING AT CLOSE.
The adjudication ledger `wi_8d1dcdb7-363a-4049-9381-aa100ab2c716` is the record for
RUBBER-STAMP SUPERVISION. Until each mechanism ships, classification and intervention
remain the supervisor's judgment; do not describe a tracked contract as an active rail.

1. **Detect stalls.** Sweep your own obligations with
   `tightbeam assignments --role <your-role>`, and the assignments you opened for your
   agents by their recorded ids with `tightbeam attests <assignmentId>`. An assignment
   with no new fact since your last sweep and no answer to a wake is a stall — and an
   escalation wake from the substrate's patrol means it noticed before you did. On
   every sweep, each active goal is fed or shot — advanced, or retired with a reason;
   nothing sits half-alive.
2. **Classify the block.** Read the surrender or the last progress attest and decide
   which kind it is:
   - **Wrong assumption** — the agent believes something false about the code, the
     spec, or the environment. Correct it with evidence and wake the agent.
   - **Unneeded gate** — the agent waits for permission or input the work does not
     require. Name the authority it already holds and wake it.
   - **Refused workaround** — a viable path that breaks no rule exists and the agent
     has not taken it. State the path and wake the agent to take it.
   - **Real block** — the work cannot proceed without a decision that belongs to the
     user, access only the user can grant, or an external condition no agent controls.
3. **Clear bad blocks yourself.** A bad block is resolved by information or direction,
   not by escalation. Do not forward a wrong assumption to the user — that is the
   agent's problem landing on the user's desk with your name on it.
4. **Escalate real blocks:**
   `tightbeam wake --user <id> --prompt "<the exact blocker, the options, the single decision needed>"`.
   Hand the user a decision, not a status: the exact blocker, the choices, and the one
   thing you need them to decide. The answer is recorded as an attest on the
   assignment and releases the work.
5. **While a real block waits, keep separable work moving,** and schedule yourself to
   re-check:
   `tightbeam wake --role <your-role> --prompt "re-check blocked assignment <id>" --after 1h`.
   A blocked goal you are waiting on is still a goal on your board; the re-check wake
   is how it stays fed instead of forgotten.
