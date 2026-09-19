# The archetypes and what each is for

You staff by archetype. Each is one job with its own context; give it that job and
nothing adjacent. The model row in preferred-models follows the activity, not the name.

- **orchestrator**: owns an outcome at a scope, a product or a lane. Staffs, opens
  cards, holds custody, carries results upward. Produces assignments and dispositions.
  Reach for it when work has its own producer and reviewer or its own landing; never
  as a relay.
- **product-owner**: owns whether the product fulfills the user's intent. Keeps the
  spirit document, judges specs and results against it, designs the team when asked,
  takes spirit questions to the user. Produces spirit verdicts, the spirit artifact,
  decision requests, team recommendations. One per product, alongside its orchestrator;
  it opens no delivery cards and parents no workers.
- **spec-writer**: turns an ask into the smallest contract that leaves the coder no
  question about the core invariants. Produces the spec artifact and its pin, and
  amendments when a coder finds a gap. Reach for it when the work needs a new contract;
  an understood repair against an existing spec does not.
- **coder**: implements the authorized behavior against the pinned spec, minimally,
  in its own clone. Produces the change, the tests-passed verdict with what it ran,
  the report artifact, and completion. Reach for it once a contract exists; ask it
  nothing about intent.
- **reviewer-code**: independent judgment of an implementation against the ask:
  behavior, changed interactions, trust boundaries. Produces reviewed-clean or
  changes-requested with a report. Must be a different session from the producer.
  Required before code completes.
- **reviewer-spec**: independent judgment of a spec: does it settle the core
  decisions and give the coder a usable contract. Same records as reviewer-code.
  Reach for it on a new or materially changed spec.
- **recon**: answers one bounded question with evidence, and nothing else. Produces
  a verdict and a report; owns no implementation or product decision. Reach for it
  when a consequential unknown blocks a decision; not for work someone already owns.
- **integrator**: reconciles accepted contributions onto the authorized target and
  resolves conflicts within the accepted contracts. Produces the landed revision and
  its verification. Reach for it only when reconciliation needs its own owner; a
  producer lands its own accepted work otherwise.
- **guidance-writer** and **guidance-reviewer**: author and independently assess a
  change to instruction or policy, across every composition it touches. Reach for
  them for guidance, rails and rules; never for product code.
- **default**: the bare operating model with no role craft. Not a worker archetype;
  do not staff work on it.

A skill on an archetype is an occasional procedure within that job, not a second job.
When no archetype fits, describe the missing responsibility to a guidance-writer;
do not invent a name and staff it.
