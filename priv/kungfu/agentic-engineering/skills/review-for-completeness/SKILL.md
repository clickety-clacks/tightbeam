---
name: review-for-completeness
description: Hunt what is missing, not what is wrong: the behavior, edge, error path, test, or teardown the MVP of the ask must contain but does not. Use as the completeness lens on a change.
---

# Review for completeness

Hunt what is missing, not what is wrong. Absent code produces no diff line to object
to; you cannot notice a missing error path by staring at the present code. A checklist
is the only reliable way to find errors of omission; it forces the question "should
this exist?" where the code offers nothing to react to. The checklist is how you look.
The verdict is still fitness: a missing piece the ask cannot ship without is blocking;
a missing piece the ask ships without is post-mvp.

1. From the ask, list what the MVP must contain: every behavior, every error path the
   ask implies on the path it uses, every state the feature enters in normal use.
   Check each against the code. An unimplemented must-have is blocking even when
   everything present is correct. An unimplemented facet the ask ships without goes on
   the post-mvp list.
2. Walk the edges the ask will hit in normal use, or cannot function without:
   - empty, absent, and zero-length inputs;
   - the first and last element; one past the end;
   - concurrent and repeated invocation; re-entry mid-operation;
   - failure of each external call the code makes: what happens when it errors,
     hangs, or returns malformed data;
   - interruption and restart mid-way: what state persists, what recovery runs.
   An unhandled edge the ask will hit is blocking. A speculative edge the ask did not
   name is post-mvp unless leaving it would force a rewrite. An edge outside every
   clause's reach is out of scope, not a gap.
3. Audit the tests against the behavior, not against the code. List the must-have
   behaviors; find the test that exercises each. A must-have with no test is an
   evidence gap and blocking; coverage of lines is not coverage of clauses.
4. Check the lifecycle: everything created is torn down (sessions, worktrees, temp
   files, listeners, scheduled wakes). A resource with no teardown path on the ask's
   path is blocking.
5. Check the failure surface reaches the operator: errors on the ask's path are
   reported where the user or the supervising session can see them, not swallowed.
6. Report each gap with a citation of the clause or edge that requires it and the
   place in the code where it is absent. Class follows the facet, not effort to fix.
