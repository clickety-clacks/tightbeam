# The office convention

An office is one exec (the FRONT DESK) bound to one principal (the BACK DESK) by a
delegation card. It is a convention, not a substrate noun: nothing new was built to
make it possible. Tightbeam already separates address from obligation — a role
resolves to a session at send time; an assignment's holder is pinned at creation —
and the office is that seam used deliberately:

- **Role binds to the front desk.** Wakes addressed to the role land on the exec
  session. Colleagues keep addressing the role; they need not know a desk exists.
- **Obligations stay on the back desk.** The worker holds its own assignment cards
  and files its own lifecycle attests — the holder-filed doctrine is untouched, and
  scoped precisely: LIFECYCLE attests (progress, completion, surrender) are
  holder-only; directive-kind attests on a delegation card may be filed by the
  card's named principal, and by nobody else, refused by name.
- **The delegation card is the written scope.** The exec holds exactly one
  assignment, whose subject IS its bounded verb list, and the card names its
  principal at creation. Everything the exec does traces to that card; revoking it
  dissolves the office.

The office is anatomy, not physics. An org that wants no desks simply never files a
delegation card; an org that wants different desks rewrites this document through the
identity seam. What it may not do is silently blur the line the card draws: a desk
doing off-card work is not a reshaped office, it is an unaccountable session.

## Dissolution and failover

Dissolving an office is a two-verb sequence — REBIND, then revoke — executed by the
same authority, the principal or the org actor dissolving the office. Order matters,
and the order is rebind-first: revoking a card never changes role binding — the two
live on different seams, address and obligation — so a revoke-first sequence would
leave a window where the role still routes wakes to a desk whose written authority
has ended. Rebind the role to the session that fronts it next (the substrate's
`role-bind` verb — usually the worker itself), THEN revoke the delegation card
(`revoke-assignment`). The sequence is deliberately non-atomic, and its degraded
window is named, not hidden:

- **The crash window.** A crash between the two verbs leaves the role already safe
  on its new session, and the exec briefly still holding its card — the benign
  direction: an on-card desk with no role receives no new role-addressed traffic,
  and the leftover card is revoked when the dissolver resumes; ordinary card
  hygiene, nothing lost. (The dangerous direction — a role routing to an OFF-card
  desk — cannot occur under this ordering.)
- **In-flight traffic.** Batched traffic survives on rows: every message is a
  durable row and every digest is signed by the rule that produced it. An
  undelivered wake addressed to the ROLE re-resolves at send time per existing law;
  a wake addressed to the dead exec SESSION follows the existing wake-delivery
  lifecycle to its delivered or failed terminal state.

Every failure mode degrades to a topology that already works:

- Exec dies → the role falls back per the existing unstaffed rule; the worker's
  cards are unaffected.
- Worker dies → normal restaffing by the worker's parent or spawner, per existing
  restaffing law. The exec cannot restaff its principal — not in its verbs — but it
  keeps triaging and may summon or escalate.
- Card revoked → the office is over in authority; the role does NOT rebind itself
  (revocation never touches routing). The dissolver performs the rebind — which,
  under the rebind-first order above, has already happened.

Atomic desk rebind is substrate work the org earns with evidence of friction, not a
gap in this convention: until then, the sequence above is the law and its windows are
the price, named.
