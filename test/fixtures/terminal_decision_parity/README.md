# Terminal decision real-response fixtures

These files are raw response-body captures from the real
`Tightbeam.Wire.Router` `/agent/dispatch` route with the real Gateway handler
table. They are not hand-written response ideals.

- `baseline-3125dfb6.json` was captured from the unmodified active 0.1.9 base
  `3125dfb6df4f1ab62c82e77fb93694eb1ad5015b`. Its file SHA-256 is
  `930c1824be0de64db1ac3b21aa166758157fac097a0e7e9949fc5356d4741e55`.
- `candidate-3246e167.json` was captured from exact runtime commit
  `3246e167781957c4d39e4fb9eea1c71f9bd94fca`. Its file SHA-256 is
  `51f0fd1f996a6fd20165538c35c2dbbecfcc836f404e922e1760a27cbbde6365`.

Each outer fixture records the source commit and transport. Each response
stores the exact HTTP status and exact JSON body bytes returned for the open,
ruled, withdrawn, superseded, legacy, hidden, and impossible-consumed classes.

The capture ran in fresh owned source clones. It created an isolated in-memory
database, paired a fixture owner, created the raiser and hidden sibling
sessions, invoked the real operator lifecycle verbs, and read every class
through the real exact-id gateway route. The legacy and impossible-consumed
classes used fixture-only database mutation after a valid ruling. No durable
Tightbeam work, decision, session, or live database was read or changed.

The compatibility test consumes the stored body bytes. It checks that every
body is canonical JSON, that the three nonterminal detail shapes retain the
complete predecessor key set, and that the candidate changes only the reviewed
terminal, visibility, and integrity behavior.
