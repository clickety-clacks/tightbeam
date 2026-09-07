---
name: review-for-yagni
description: The ask defines the whole of the work; anything beyond it is unfit, whatever its quality. Use as the embellishment lens on a change.
---

# Review for YAGNI

The ask defines the whole of the work. Anything beyond it fails the fitness test,
whatever its quality: it is not the ask. An embellishment adds untested surface area,
obscures the intent of the change, and widens the review beyond what the ask can prove;
unlike client scope creep, it bypassed every change-control conversation on its way in.

1. Enumerate every behavioral addition in the change: each validation, guard, fallback,
   retry, error handler, configuration option, feature flag, abstraction layer,
   compatibility path, and each fix of a bug the ask did not name.
2. For each addition, find the facet of the ask that requires it. An addition with a
   facet is in scope. An addition without one is beyond the ask and blocking: the work
   is unfit until it comes out or the ask is amended to include it.
3. No justification rescues an addition. "Safer," "defensive," "future-proof," "while I
   was in there," and "standard practice" do not make it the ask. Neither does "it was
   a small bug and I was right there." An incidental fix is its own card.
4. Flag the structural forms of over-engineering:
   - an abstraction with one consumer, built for a variant that does not exist
     (speculative generality: the shape is unproven until a third real use);
   - a configuration option the ask never varies;
   - handling for inputs the system cannot produce;
   - legacy or migration support for a state that has no occupants;
   - a new pattern duplicating an existing one under a new name.
5. Distinguish embellishment from necessity: code the ask's behavior cannot function
   without is in scope even when the ask does not name it. The test is necessity for
   the ask, not usefulness. (YAGNI bounds unrequested CAPABILITY; it never excuses
   sloppy structure inside the scoped change itself.)
6. When an addition looks genuinely needed but no facet covers it, the ask has a hole.
   The finding stands. Under heavy posture the question goes to the spec-writer
   (`tightbeam wake --role spec-writer --prompt "<the addition and the missing requirement>"`);
   under light posture it goes to the orchestrator. The addition enters through an
   amended ask or not at all.
7. Report each addition with its location and the absent facet.
