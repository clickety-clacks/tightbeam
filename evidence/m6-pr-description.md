# M6 migration timeout repair

The 0.1.8-to-0.1.9 boot path could spend more than the ordinary 30,000 ms DB
client wait in the operator-decision migration. The caller then timed out while
the DB owner continued, and the queued CHECK-restoration call timed out behind
it. That made the cleanup phase hide the primary migration stall.

The producer handoff supplies the immutable full commit SHA and tree for this
PR; do not substitute an abbreviated or stale SHA. It keeps the repair narrow:

- `DB.migration_transaction/5` is the only unbounded client wait. The DB owner
  serializes the migration prelude, transaction, commit or rollback, and CHECK
  restoration, with begin/commit/rollback/restoration logs.
- Ordinary `query`, `execute`, and runtime `transaction` calls retain the
  configured 30,000 ms `DB.call_timeout/0` default. SQLite's 5,000 ms
  `busy_timeout` remains a separate lock-wait bound.
- Admission, schema qualification, transactional stamp/marker behavior,
  rollback, and row-integrity checks are unchanged.

The large-base regression creates one million SQLite rows and performs a
two-billion-row join aggregate as actual database work, without a sleep. It
asserts that the operation exceeds the former 30-second client cap, commits,
and restores `ignore_check_constraints=0`. A separate failure regression proves
rollback and CHECK restoration.

The 30,000 ms runtime default is retained as a request-path ceiling: it is above
Erlang's documented 5,000 ms `gen_server:call/2` default and below the
60,000 ms default client-data timeout in Thousand Island, which backs the
Bandit HTTP server. It is not used as a migration budget. References:

- https://www.erlang.org/docs/26/man/gen_server.html
- https://hexdocs.pm/thousand_island/1.0.0-pre.1/ThousandIsland.html
- https://sqlite.org/pragma.html#pragma_busy_timeout

Local verification: `mix format --check-formatted`, `git diff --check`, and
Elixir syntax parsing pass. The focused Mix test could not compile in this
isolated checkout because `websock_adapter`, `toml`, `exqlite`, and `bandit`
are absent; no dependency installation was performed. Hosted Linux/macOS CI is
the executable test gate. No real-data, Gibson, live, or E2E runner action was
performed.
