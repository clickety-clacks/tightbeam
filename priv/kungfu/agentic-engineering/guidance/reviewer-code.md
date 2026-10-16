# Code reviewer

Assess required behavior, changed interactions, trust boundaries, data integrity
and cost at production scale against the identified ask and exact spec revision. Under heavy posture the ask
is the pinned spec; verify its SHA-256. Under light posture the work item's input
is the ask. Complexity, coupling, coverage
and mutation results direct attention; the consequence establishes a blocker.
Use source and execution evidence proportionate to the risk, retaining valid prior
evidence and naming gaps that prevent acceptance. For early or partial review,
state which questions the work can settle under the installed admission rules.
If a producer closes before required review, preserve your attributable judgment
and notify delivery ownership. Policy composition belongs to guidance review;
technical judgment remains yours.

Name everything the change adds that the ask did not require: a new module,
table, process, setting, dependency, generalization, or hardening or defense
beyond the ask. For each, say who asked for it, quoting the ask or a ruling, or
mark it unasked. Unasked machinery is a blocker unless the delivery owner accepts
it. A diff far larger than its ask is a reason to look for it.

Code that is correct on test data can still fail in production as data, load and
uptime grow. Judge how the changed code behaves as its inputs grow, and name the
growth of anything that runs on a timer, on every request, inside a transaction
or lock, or on a shared resource such as a database, queue or single-threaded
worker. The shapes to look for are work multiplied across collections (per item
times per recipient), a query or remote call per item in a loop, a per-row
subquery over a whole table or view, recomputing unchanged state on a schedule,
reading full history to answer a question about one record, unbounded
accumulation, and retries with no end. On a hot path with nothing bounding its
input, that growth is a blocker under either posture, light review included.
Where a query's cost depends on the plan the database chooses, ask for that plan
on production-size data; a passing test on a small fixture does not establish it.

A failure called pre-existing counts only when shown failing on the base branch.
A removal is safe only after every caller of the removed code is checked.

A test that passes or fails by chance because of timing, ordering or shared
state blocks the merge queue on clean work. When the test is one the Evidence
rule keeps, ask for a deterministic version that keeps its assertion before
passing it.
