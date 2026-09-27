---
name: delivery-bootstrap
description: Establish or recover accountable product delivery ownership, bind its scope, or arrange owner succession before staffing.
---

# Establish delivery ownership

Preserve intake through Main, PO or PDO with the full request, facts, constraints,
work item and authority to execute now or file for later. File-only stays backlog.
When no PDO exists, the PO retains the product question and routes setup to Main
or the existing authorized owner. Reuse the PO and the smallest adequate delivery
arrangement; Main and PO do not become production staffers. A named agent retains
intake until the receiving PDO explicitly accepts it on the same work item. Do
not ask the user to repeat or reconfirm already-authorized work.

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
