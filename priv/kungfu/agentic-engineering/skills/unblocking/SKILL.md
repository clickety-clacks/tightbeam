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

1. **Detect stalls.** Sweep your own obligations with
   `tightbeam assignments --role <your-role>`, and the assignments you opened for your
   agents by their recorded ids with `tightbeam attests <assignmentId>`. An assignment
   with no new fact since your last sweep and no answer to a wake is a stall. First read
   its liveness receipts: a valid receipt ends the response, even if a later patrol alarm
   claims it is missing. Do not rebut that false alarm with an attest or wake, and do not
   re-staff the work. On
   every sweep, each active goal is fed or shot — advanced, or retired with a reason;
   nothing sits half-alive.
2. **Classify the block.** Read the surrender or the last progress attest and decide
   which kind it is:
   - **Wrong assumption** — the agent believes something false about the code, the
     spec, or the environment. Correct it with evidence and wake the agent.
   - **Unneeded gate** — the agent waits for permission or input the work does not
     require. Name the authority it already holds and wake it. A review holding work
     for a facet the ask ships without is this class, and it reaches you as the
     producer's contest rather than as your own audit (orchestrator kernel,
     "Verifying without redoing").
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
