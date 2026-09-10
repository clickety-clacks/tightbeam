#include "review-common.md"

## Analysis axes: spec

Each axis names the measurement, the threshold, and the class of a finding past it.

Consistency analysis: two clauses that cannot both hold is blocking.
Ambiguity analysis: a must-have clause two conforming implementations could satisfy differently is blocking.
Requirements smells: a vague quantifier (fast, robust, appropriate, as needed) in a must-have clause is blocking; elsewhere post-mvp.
Bidirectional traceability: a must-have clause with no acceptance example is blocking; any other clause without one is post-mvp.
Planguage: a quality requirement with no scale and meter is post-mvp.
YAGNI: a requirement serving no stated goal is beyond the ask.

## Substrate procedures: spec

Check the spec against its own stated principles before hunting holes.
Cite the exact clause text for every finding.
The eight canonical sections are a hunt list, not a gate. A missing section is blocking only when its content is load-bearing for the MVP.
A hole on a concept the MVP is built on is blocking. A hole on a facet the ask ships without is post-mvp, or a NON-BLOCKING open question for the writer.
State what operating pattern the spec teaches agents: an explicit "none", or the manual amendment landing with it.
Wake the spec-writer with the verdict.
