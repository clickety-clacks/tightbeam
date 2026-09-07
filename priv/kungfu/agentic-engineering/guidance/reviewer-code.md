#include "review-common.md"

## Analysis axes: code

Each axis names the measurement, the threshold, and the class of a finding past it.

Cognitive complexity: over 15 in a touched function is post-mvp; over 25 is blocking.
Cyclomatic complexity: over 10 in a touched function is post-mvp.
Clone detection: a duplicated block over 20 lines introduced by the change is post-mvp.
Change coupling: a file that co-changes with a touched file in over half its commits and was not touched is unproven until the producer answers.
Mutation adequacy: an obvious mutant (inverted condition, off-by-one, dropped call) surviving on a must-have path is blocking.
Dependency cycles: any introduced is blocking.
Dead code: any introduced is post-mvp.
Failure mode analysis: an external call with no handled failure path is blocking on a must-have path, else post-mvp.
Boundary value analysis: a must-have input with no boundary test is post-mvp.
Taint analysis: untrusted input reaching a sink unsanitised is blocking.
YAGNI: a behavioural addition the ask did not name is beyond the ask.
Speculative generality: an abstraction with one implementation, a parameter with one call-site value, or an extension point with no caller, introduced by this change and not named by the ask. Blocking if it is public or a contract others must implement, post-mvp otherwise.
Hotspot weighting: report findings in hotspot files first.
Line coverage: not a gate; a percentage is not a finding.

## Substrate procedures: code

The report opens with conformance: every clause of the ask marked satisfied, unsatisfied, unproven, or out of scope, each with its evidence.
Read the ask at its source. Under heavy posture that is the canonical spec at its canonical path; verify the work item's pinned sha256 when present, because conformance is owed to the ruling text. Under light posture the work item's input is the ask.
Unproven is its own class: plausibly met, but no test exercises it, no run demonstrates it, no code path confirms it. Do not round it up to satisfied.
Before judging code, confirm the producer's `tests-passed` receipt names the reviewed commit, the tests, and a passing result. A weak or false receipt is blocking.
Blocking: hand-written ideal fixtures; demo, prototype or placeholder framing on a product-trusted path.
Post-mvp: a missing real-response capture, unless it protects an incredibly detrimental failure mode.
Cite every finding by file and line, log line, or commit.
If the reviewed assignment is already closed when you begin, the producer completed before review; raise it with your hirer.
