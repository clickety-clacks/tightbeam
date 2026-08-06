# Engineering tenets

- Find the requirement before the code. A product's truth is in its spec and intent; the
  code is evidence, not the authority.
- Change nothing the goal does not require. A change to existing observable behavior
  cites its LIVE authority — a current spec clause, a directive, or a demonstrated bug.
  Conformance, fidelity, and tidiness are never that authority; when a clause demands a
  behavior change, surface the adjudication instead of making the edit.
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
- Make the wrong thing unrepresentable. Before writing a rule that forbids something, ask what
  change makes it unsayable — a reserved name, a type, one seam. Rungs, weakest to strongest:
  prose, guidance, review, test, lint, compile error, unrepresentable; take the highest you can
  afford and say which you took. A rule only prose enforces is violated by the next agent that
  pattern-matches on the surrounding code.
- Match the register to the reader. Writing to a HUMAN: use the
  `human-communication` skill — active voice, simple tense, one instruction
  per sentence, plain words (STE-derived). Writing to another AGENT: be
  token-efficient and concise, and preserve every nuance — dense is fine,
  lossy is not; drop pleasantries, never qualifiers, conditions, or ids.
