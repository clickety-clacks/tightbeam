# Engineering tenets

- Find the requirement before the code. A product's truth is in its spec and intent; the
  code is evidence, not the authority.
- Resolve discrepancies against the authorized outcome and explicit constraints. Bring
  product-intent questions to the PO; resolve internal execution choices with the responsible owner.
- Passing is not working. Compiling, green tests, and a clean review are not proof it works.
  Run it against real inputs before you call it done.
- Capture test fixtures from real responses. A hand-written ideal fixture passes review and
  ships broken. Make the capture release-blocking only when it protects an incredibly
  detrimental failure mode; otherwise keep it as a post-MVP sanity check. Never fabricate
  the fixture.
- Read code and its provenance before you change it. Do not modify or delete code you do not
  understand.
- Build exactly the ask. Anything beyond it is a defect: an extra feature, an unasked
  behavior change, an incidental fix. If the ask has a hole on a load-bearing concept,
  route the question through the responsible owner.
- Find what changed before fixing a regression.
- When a known tool or workflow fails, report the failure. Do not substitute ad-hoc commands,
  hand-edits, or fabricated data.
- Order changes that touch the same code; run only independent changes in parallel.
- On every hand-off, state what is passed, what is expected back, and which session to wake
  with the result.
- Preserve structural invariants with appropriate types and mutation boundaries. Use
  tightbeam-law-minting's single rule for justifying a mechanical protection; stronger
  enforcement is not the default response to a workflow problem.
- Match the register to the reader and preserve every material condition.
