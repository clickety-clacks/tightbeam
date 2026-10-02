# M6 migration timeout diagnosis

## Scope

This note records the isolated source diagnosis and candidate verification for
the 0.1.9 M6 repair. The checkout starts at public 0.1.9 commit
`5f066f680f7207a4cf8323cff1f15cfae67b2cec`.

The runner's durable receipt `att_6ecb614f-613d-42b4-b022-e552c6a49d1c`
reports that the real 0.1.8+1343 source copy reached the operator-decision
migration, then stopped before `/version` at the DB owner's 30,000 ms call for
`PRAGMA ignore_check_constraints OFF`. The stamp remained
`operator-decision-requests-v1`, the marker was absent, counts/quick-check/FK
checks were unchanged, and the scratch digest changed. The runner report and
raw log are on its host and were not copied into this session.

## Causal source path

Before this candidate, `migrate_operator_decision_v1/1` made three client calls:

1. `DB.execute("PRAGMA ignore_check_constraints = ON")`.
2. `DB.transaction/2` for the DDL, parity census, and transactional stamp.
3. An `after` cleanup call through `DB.execute("PRAGMA ... = OFF")`.

The ordinary client timeout applied to the transaction. If the large DDL phase
outlived 30 seconds, the owner could still be finishing it while the caller's
`after` cleanup call queued behind it. The observed OFF timeout therefore could
mask the primary transaction timeout.

## Candidate repair

`Tightbeam.DB.migration_transaction/5` runs the migration prelude, one
`commit_phase/4`, and restoration inside the DB owner. The caller waits with
`:infinity` only for this schema operation; ordinary `query`, `execute`, and
`transaction` calls retain `DB.call_timeout/0`. The connection's SQLite
`busy_timeout=5000` remains unchanged. Progress logs name begin, commit or
rollback, and restored checks. The operator migration now uses this seam, so
CHECK enforcement is restored before the caller receives the result and the
existing stamp/rollback path is unchanged.

The implementation cites the primary Erlang `GenServer.call/3` timeout
semantics and SQLite `busy_timeout`/`ignore_check_constraints` documentation in
`lib/tightbeam/db.ex`.

## Isolated regression coverage

`test/db_call_timeout_test.exs` adds:

- a synthetic large-base migration that creates one million SQLite rows and
  runs a two-billion-row join aggregate as real database work. The measured
  operation exceeds the former 30-second client cap without `Process.sleep`,
  then commits with `ignore_check_constraints=0`;
- a failure phase that proves transaction rollback, absent table, and restored
  CHECK enforcement.

The fixture is in-memory and contains no real package or database bytes. It is
representative timing evidence only; it does not claim to reproduce the 22.7 GB
Gibson file. The test timeout is 120 seconds to leave room for the intentionally
large single-threaded SQLite workload on hosted Linux and macOS.

## Runtime timeout rationale

The ordinary `DB.call_timeout/0` default remains 30,000 ms. It bounds short
runtime queries and owner queueing while leaving the migration path independent
of that client wait. The value is deliberately below the 60,000 ms default
client-data timeout in Thousand Island (the HTTP transport used by Bandit) and
above Erlang's 5,000 ms default for `gen_server:call/2`; it is therefore a
request-path ceiling rather than a migration budget. The application also keeps
its 5,000 ms SQLite `busy_timeout` as a separate lock-wait bound. Primary
references: [Erlang `gen_server` documentation](https://www.erlang.org/docs/26/man/gen_server.html),
[Thousand Island options](https://hexdocs.pm/thousand_island/1.0.0-pre.1/ThousandIsland.html),
and [SQLite `busy_timeout`](https://sqlite.org/pragma.html#pragma_busy_timeout).

`mix format --check-formatted` passes. The focused Mix test is currently blocked
before compilation because the isolated checkout has no cached `websock_adapter`,
`toml`, `exqlite`, or `bandit` dependencies; no dependency installation was
performed.
