# Inception — how a product is born

A product-scale request — from the user or from an agent — is not a task to start;
it is an org to found. The inception SOP turns the request into a spirit, the
spirit into a charter, and the charter into a running graph, with every step a row.

The flow:

1. **The request opens a huddle work item and spawns a Product Owner.** The huddle
   is the durable thread; the PO is the mind that will own what the product IS.
2. **The PO runs the spirit interview.** Structured, in plain STE-style language,
   per the PO playbook. The requester is summoned via the input-needed
   decision-request (`ask --user <id>` / `ask --role <role>`), tied to the huddle
   so the thread is findable (`--about` the huddle's assignment today; the
   decision-request's own conversation anchor arrives with its build card), and
   the request closes on charter ratification — the interview is a bounded
   decision request, never an open-ended correspondence.
3. **The output is a spirit charter** — a document in the org's spec commons,
   recorded via `artifact-record` and bound to the product's work items via
   spec-ref (`--spec-ref <name> --spec-sha256 <hex>`), so every card names the
   exact charter text it serves. Template below.
4. **The PO rules "spirit ratified", the PO's DESK spawns orchestrator + desk,
   wires, hands over the binding.** That order is the design, verbatim: the mind
   judges ratification; its desk executes the hire as directed execution (office
   templates, authority row cited, per the desk playbook), wires the new office
   into the graph, and hands the orchestrator the charter binding.
5. **The orchestrator builds and runs the graph; the PO stands aside as
   judgment.** Staffing, sequencing, review commissioning, dispositions belong to
   the orchestrator for the lifetime of its work items — the altitude statute is
   the arming template — under the PO's spirit rulings, which govern everything.

## The spirit charter template

Spec-commons conventions: one document, versioned in the commons, its hash the
binding. Rulings accrete; a changed mind is a new ruling on the record, never an
edit that erases the old one.

    # <product> — spirit charter

    invariants: <what must stay true of this product, each one testable
      against a delivered thing>
    non-goals: <what this product deliberately is not; a non-goal is a
      decision, not an omission>
    taste rulings: <the requester's judgment calls, dated, in their words
      wherever possible — the record acceptance judges against>
    boundaries: <where this product ends and its neighbors begin>
    ratified: <date>, by <PO role>, interview: <decision-request id>
    recorded: <artifact row>, bound: <spec-ref name + sha256>

The charter is the PO's instrument, not scripture: when built work and charter
diverge, the PO judges which is wrong and corrects the record first, then the work.
