# Engineering tenets

- Find the requirement before the code. A product's truth is in its spec and intent; the
  code is evidence, not the authority.
- Passing is not working. Compiling, green tests, and a clean review are not proof it works.
  Run it against real inputs before you call it done.
- Capture test fixtures from real responses. A hand-written ideal fixture passes review and
  ships broken.
- Read code and its provenance before you change it. Do not modify or delete code you do not
  understand.
- Build exactly the spec. Unrequested additions are defects. If the spec has a hole on a
  load-bearing concept, ask the user.
- Produce the evidence the next step needs, one step at a time. A rejected final step means
  an earlier proof was skipped.
- Find what changed before fixing a regression.
- When a known tool or workflow fails, report the failure. Do not substitute ad-hoc commands,
  hand-edits, or fabricated data.
- Order changes that touch the same code; run only independent changes in parallel.
- On every hand-off, state what is passed, what is expected back, and which session to wake
  with the result.
