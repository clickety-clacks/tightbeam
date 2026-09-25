# Engineering roles and intake

Use one accountable product delivery owner (PDO) and an addressed product owner
(PO) per product. Main coordinates across products. The PO owns intent, spirit,
acceptance and delivery topology. The PO decides changes to product intent, task
breakdown and topology; delivery owners resolve routine execution details. The
PDO staffs and carries delivery. Use lane orchestrators below the PDO when their
distinct decisions and worker traffic justify them; ordinary modules and lanes do
not acquire another PDO. Small work can have specialists directly under its PDO.

Accept intake through Main, PO or PDO with the full request, supplied facts,
constraints, work-item identity and whether delivery is authorized now or the request
is to file for later. Preserve file-only requests as nonexecuting backlog; do not
create a permanent team just because a request was filed. Reuse current owners and
covered judgment for authorized delivery.

When no accountable PDO exists, the addressed PO retains the product question and
routes the delivery/setup obligation to Main or the existing owner with supported
bootstrap authority. Main reuses a suitable delivery owner or establishes the
smallest missing PDO/PO arrangement within authority. Retain an existing addressed
PO rather than creating a duplicate office. Bootstrap establishes or adopts delivery
ownership; neither Main nor PO commissions production workers. The PO supplies
setup/topology judgment and opens no delivery assignments.

Keep a named agent accountable for intake until the receiving delivery owner
explicitly accepts custody on the same work item. That owner obtains the applicable
PO decision and staffs production. Carry the full context through this handoff;
do not ask the user to set up routine seats, confirm again or repeat an already-
authorized request. If supported setup is unavailable, retain an accountable
recovery route and state the concrete limitation. Use the existing user-decision
route only for a genuine new authority or scope choice. Routine worker outcomes
and recovery go to their responsible delivery owner; specialists may ask the PO
product questions directly.

On runtimes supporting delivery-scope records, make that acceptance inspectable
before production. Read `tightbeam delivery-responsibility-get <workItemId>` and
the receiving PDO's `po_association` in `tightbeam list`. A delivery scope is the
pair `(ownerUserId, poRole)`, not a lane or a session name; all items bound to that
scope share one accountable owner. Preserve the exact association session and
revision. If the association is missing, have the target session or its current
parent set the intended, registered PO with `tightbeam session-po-set --session
<key> --po-role <role> --key <idempotencyKey>`, then read back the revision.

Have the item's actual Main bind a new intake item and record the accepting PDO;
the human owner/admin can also do this, and a current accountable owner can bind
items to its scope and arrange succession. A role label, PO association or
delegated lane does not grant those bootstrap powers. Use the supported forms:

```text
tightbeam work-item-delivery-scope-set <workItemId> --association-session <key> --association-revision <n> --expected-revision <n> --key <idempotencyKey>
tightbeam delivery-scope-owner-set --session <key> --association-revision <n> [--expected-owner <key>] --expected-revision <n> --key <idempotencyKey>
```

For binding, use the accepting PDO's current association and the item's observed
`scope.bindingRevision` (0 only if unbound). Read responsibility again after
binding; reuse an existing current owner for that scope. For initial ownership,
use the accepting PDO as `--session`, its association revision, expected revision
0 and no expected owner. For succession, supply the observed `accountable.ownerRevision`
and `accountable.accountableSessionKey` as expected revision and expected owner.
Use distinct idempotency keys per intended change; a retry keeps its original key
and arguments. Read responsibility back before claiming the handoff. Preserve
assignment acceptance and open obligations separately; these records neither close
assignments nor reparent sessions.

If ownership is stale or unavailable, route recovery to the human owner/admin or
the owner's actual Main; do not let a delegate self-promote or keep retrying stale
revisions. If the installed CLI lacks these operations, retain accountable intake
and supported assignment custody, report the concrete setup limitation to Main,
and do not claim scope-record enforcement or invent replacement commands.

An archetype supplies responsibility and context, not permission from its name.
Inspect actual assignments and accountable ownership. Session ancestry records who
spawned a session; reuse, a role binding or a new diagram does not reparent it or
transfer open obligations. Arrange supported handoffs before claiming adoption or
owner replacement, preserving one accountable delivery office and its recovery route.

Choose roles for the work, not as required stages:

- `pdo`: product delivery custody and execution of the PO's plan.
- `orchestrator`: executive coordination or a delegated delivery lane.
- `product-owner`: product and topology judgment.
- `team-planner`: bounded planning advice for the PO's decision.
- `spec-writer` and `coder`: contract authorship and implementation.
- `reviewer-spec` and `reviewer-code`: independent specialist judgment.
- `recon`: evidence for a bounded question.
- `guidance-writer` and `guidance-reviewer`: policy authorship and independent review.
- `integrator`: reconciliation when it needs a separate owner.

Use the manual's Hire help contract for durable staffing and helper output. When no
archetype fits, describe the missing responsibility, context and result to the
delivery owner for authorized guidance work; do not invent capabilities from a name.
