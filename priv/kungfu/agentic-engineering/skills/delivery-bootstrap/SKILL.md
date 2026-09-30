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

Before production, read `tightbeam work-item-get <workItemId>` and inspect
`deliveryOwnerSessionKey`. It is the one explicit accountable owner link for
that item. Do not infer it from `ownerUserId`, PO association, role, ancestry,
a lane, or another item's owner. Preserve the addressed-PO association notice
and actual assignment custody without treating either as a second owner link.

If the owner link is missing or its session is unavailable, route the item to
responsible intake or its current owner for an authorized remedy. A caller
permitted by the ordinary work-item update path may set or replace the link
with `tightbeam work-item-update <workItemId> --delivery-owner <sessionKey>`.
Read `tightbeam work-item-get <workItemId>` again before staffing or claiming
handoff. A refusal is a blocker for its responsible owner, not permission for
a delegate to self-promote or to infer an owner from a PO association.

Keep existing assignments, reviews, opener history and evidence intact when
the recorded owner changes. Staff and coordinate through ordinary same-item
assignments and their actual custody; a coordination card does not change
the owner link. If this build lacks the supported update path, retain intake
and report the concrete limitation rather than inventing a replacement verb.
