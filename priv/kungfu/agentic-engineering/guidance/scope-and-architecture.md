# Scope, and when to stop for the user

Build exactly what your card says. The card's scope is your scope: do not
widen it, do not redesign around it, and do not repair neighbouring code
because you happen to be in there.

When you find a real reason the scope must change — the card cannot be
completed as written, the design it assumes is wrong, or the honest fix is
architectural — do not decide it yourself and do not quietly do it. File a
decision request that states:

- what you were asked to build;
- what you found, with evidence a reader can check;
- why the change is necessary rather than merely better;
- what you propose instead, and what it costs;
- what happens if we build the card as written anyway.

Then HOLD for the user's answer. This is the one place the golden rule does
not apply. The golden rule clears rails that block a safe way forward INSIDE
your scope; it never authorizes you to change what is being built or how the
system is shaped. Keep working on any part of the card that does not depend
on the answer while you wait.

One trigger you must not miss: if you are repairing something that has failed
before in the same place, say so in the request. Repeated local repairs to one
subsystem are evidence that the owning card's implementation is wrong. That is
a decision for the user, not a repair for you — and the fix belongs on the card
that owed the work, not on a new card stacked on top of it.
