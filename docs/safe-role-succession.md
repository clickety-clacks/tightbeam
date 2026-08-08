# Safe role succession

Work item: `wi_73f6268e-3df1-43c7-9271-13b89ffb45fb`

## Spirit

A role is a stable address, but safety outranks uninterrupted occupancy. Tightbeam must
not claim that an active role moved safely while an old session can still commit work
under that role or while role-addressed rows can appear after a drain check.

## Goal

Define the supported product boundary for changing the session associated with an
existing role.

## Non-goals

- No active-session A-to-B role transfer.
- No zero-gap or uninterrupted role-address promise.
- No movement of assignments, wakes, turns, review facts, workdirs, transcripts,
  artifacts, session ancestry, or historical rows.
- No authority epoch, binding-generation, multi-table drain lock, replay identity, or
  post-commit recovery mechanism in this slice.
- No implementation is authorized by this document.

## Terms

- **Active succession**: changing role R directly from active session A to active
  session B while preserving R as continuously staffed.
- **Manual recovery**: an operator-controlled sequence that may leave R absent or
  unstaffed between occupants. Tightbeam does not promise atomicity for this sequence.
- **Handoff artifact**: a human-authored report linked to the work item. It carries the
  role name, source and successor session keys, cause, acting principal, predecessor
  assignment ids, and any workspace or context pointers the successor needs.
- **Source work**: durable work opened for or held by A before recovery.
- **Successor work**: a new assignment opened normally for B after recovery.

## Assumptions

- Current role authorization occurs before the state-changing handler transaction.
- A request authorized while A held R can commit after the binding changes.
- Role-targeted assignments, wakes, and turns can be created concurrently with a
  separate drain check.
- Current rows do not provide one deterministic fence covering both authority and all
  role-target producers.

## Invariants

1. Tightbeam never represents active succession as safe or supported without a fence
   that covers already-authorized source requests and every role-target row producer.
2. Durable rows retain their original session, holder, reviewer, origin, and history.
3. Source assignments terminalize before successor assignments open. A successor row
   never substitutes for terminalizing its predecessor.
4. A handoff artifact records a human decision. Tightbeam does not infer whether a
   handoff is sufficient and does not use its prose as a mechanical bind gate.
5. An absent public command returns the ordinary unknown-command response. Tightbeam
   does not reserve a fictional command only to return a special refusal.

## Product ruling

Active succession is unsupported. `role-bind` must not change a role that is already
bound to another active session. A request to do so refuses without changing the role
or any related row.

Tightbeam offers no supported drain-and-rebind ceremony in this slice. An operator may
perform manual recovery only with an accepted unstaffed interval and external
coordination. That recovery is not an atomic product guarantee. It must not be described
as preserving a live role, live work, or uninterrupted authority.

If an operator records a handoff, the report is linked to the same work item and names:

- `roleName`;
- `sourceSessionKey` and `successorSessionKey`;
- `cause = manual_role_recovery`;
- the acting principal and timestamp;
- predecessor assignment ids and their terminal outcomes; and
- required workspace or context pointers.

The handoff does not move or rewrite those referents. Successor assignments open through
the ordinary assignment path after recovery, use the same work item when they continue
the same intent, and cite their predecessor ids in the subject or attest.

`role-shift` is not a public command. It receives the ordinary unknown-command response.
This document does not add special `role-rm` or `role-create` lifecycle states. The
existing delete-and-recreate safety question remains a separate bounded defect; until it
has its own authority and fence, it is not a supported succession path.

## Acceptance

1. Given R bound to active A, an attempted `role-bind` of R to B refuses and leaves the
   binding, assignments, wakes, turns, facts, and session rows byte-equivalent.
2. A request using nonexistent `role-shift` receives the ordinary unknown-command
   result; no role-specific route exists.
3. No supported command claims that drain checks make an active A-to-B transition safe.
4. No row changes holder, reviewer, session key, origin, ancestry, or artifact path as a
   consequence of a succession request.
5. A successor assignment cannot satisfy a source assignment's terminal requirement;
   the source row must already be terminal.
6. A handoff artifact, when used, is linked to the work item, contains every field named
   above, and is explicitly non-gating.
7. Documentation and CLI help describe manual recovery as potentially unstaffed and
   outside Tightbeam's atomic guarantees.

## Open questions

None block this refusal contract. A future proposal for zero-gap active succession must
be a new work item. It must name the smallest deterministic authority and role-target
fence and include both race-order acceptance tests before implementation dispatch.

## Authority and supersession

This file is the canonical product contract. Its committed revision and content hash are
recorded on the work item artifact row.

It supersedes `art_5bd32feb`, `art_a4859241`, `art_87fb4f56`, and the stale post-revocation
specimen `art_35ac1e72`. Those rows remain historical evidence and carry no implementation
authority.
