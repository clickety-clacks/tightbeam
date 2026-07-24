---
name: review-for-yagni
description: The spec defines the whole of the work; anything beyond it is a defect, whatever its quality. Use as the embellishment lens on a change.
---

# Review for YAGNI

The spec defines the whole of the work. Anything beyond it is a defect, whatever its
quality: an embellishment adds untested surface area, obscures the intent of the
change, and widens the review beyond what the spec can prove — and, unlike client
scope creep, it bypassed every change-control conversation on its way in.

1. Enumerate every behavioral addition in the change: each validation, guard, fallback,
   retry, error handler, configuration option, feature flag, abstraction layer, and
   compatibility path.
2. For each addition, find the spec clause that requires it. An addition with a clause
   is in scope. An addition without one is an embellishment, and an embellishment is a
   blocking finding.
3. No justification rescues an embellishment. "Safer," "defensive," "future-proof,"
   "while I was in there," and "standard practice" do not create a spec clause.
4. Flag the structural forms of over-engineering:
   - an abstraction with one consumer, built for a variant that does not exist
     (speculative generality — the shape is unproven until a third real use);
   - a configuration option the spec never varies;
   - handling for inputs the system cannot produce;
   - legacy or migration support for a state that has no occupants.
5. Distinguish embellishment from necessity: code the spec's behavior cannot function
   without is in scope even when the spec does not name it. The test is necessity for a
   specified clause, not usefulness. (YAGNI bounds unrequested CAPABILITY; it never
   excuses sloppy structure inside the scoped change itself.)
6. When an addition looks genuinely needed but has no clause, the spec has a hole. The
   finding stands, and the question goes to the spec-writer
   (`tightbeam wake --role spec-writer --prompt "<the addition and the missing requirement>"`);
   the addition enters through a spec amendment or not at all.
7. Report each embellishment with the addition's location and the absent requirement.
