---
name: review-for-completeness
description: Hunt what is missing, not what is wrong — the behavior, edge, error path, test, or teardown a complete implementation must contain but does not. Use as the completeness lens on a change.
---

# Review for completeness

Hunt what is missing, not what is wrong. Absent code produces no diff line to object
to; you cannot notice a missing error path by staring at the present code. A checklist
is the only reliable way to find errors of omission — it forces the question "should
this exist?" where the code offers nothing to react to.

1. From the spec, list what a complete implementation must contain: every behavior,
   every error path the spec implies, every state the feature can enter. Check each
   against the code. An unimplemented clause is a blocking finding even when everything
   present is correct.
2. Walk the edges a spec clause demands, implies, or cannot function without — an edge
   outside every clause's reach is out of scope, not a gap:
   - empty, absent, and zero-length inputs;
   - the first and last element; one past the end;
   - concurrent and repeated invocation; re-entry mid-operation;
   - failure of each external call the code makes — what happens when it errors,
     hangs, or returns malformed data;
   - interruption and restart mid-way: what state persists, what recovery runs.
   An edge the code does not handle and the spec does not exclude is a finding.
3. Audit the tests against the behavior, not against the code. List the behaviors the
   spec requires; find the test that exercises each. A behavior with no test is a
   finding — coverage of lines is not coverage of clauses.
4. Check the lifecycle: everything created is torn down — sessions, worktrees, temp
   files, listeners, scheduled wakes. A resource with no teardown path is a finding.
5. Check the failure surface reaches the operator: errors are reported where the user
   or the supervising session can see them, not swallowed.
6. Report each gap with a citation of the clause or edge that requires it and the
   place in the code where it is absent. Severity follows consequence, not effort to
   fix.
