# Database timeouts during boot and normal requests

`Schema.ensure_all/1` passes an explicit `DB.Migration` context through every
schema operation, including delegated module setup and final guard publication.
Those DB calls wait without a client or statement deadline. The context does not
change application configuration or the ordinary server handle. Each call logs
its operation and elapsed time; the operator-decision migration also names its
DDL, historical terminal-request census and stamp phases. The existing migration
transactions and exact predecessor checks are retained. The build-owner marker
is published only after the complete schema path succeeds; it is not an atomic
filesystem participant in the preceding SQL transactions.

The operator-decision migration restores CHECK enforcement inside the DB owner
before returning. A failure during prelude also attempts restoration. A failed
restoration reports both the primary result and cleanup failure and closes the
owner rather than serving a connection with uncertain enforcement state.

This separation matches the explicit unbounded orchestration and transaction
timeouts in [Ecto SQL 3.13.2 Migrator](https://github.com/elixir-ecto/ecto_sql/blob/v3.13.2/lib/ecto/migrator.ex#L304-L327)
and its [DDL runner](https://github.com/elixir-ecto/ecto_sql/blob/v3.13.2/lib/ecto/migration/runner.ex#L323-L326).
[Rails](https://guides.rubyonrails.org/active_record_migrations.html#transactions)
and [Django](https://docs.djangoproject.com/en/5.2/topics/migrations/#transactions)
document transactional migrations where the database supports DDL transactions.
[Flyway](https://documentation.red-gate.com/flyway/flyway-concepts/migrations/migration-transaction-handling)
documents ordered migrations and per-migration transactions, stopping on failure.
[Liquibase](https://support.liquibase.com/hc/en-us/articles/39517962072219-How-to-Configure-Timeouts)
distinguishes changelog-lock, native-executor and JDBC timeout settings. These
sources support separating migration execution from runtime request deadlines;
they do not establish a universal absence of database or tool timeouts.

Normal DB calls retain a configurable 30,000 ms client wait. This bounds time in
the single owner's queue plus execution; it is not cancellation of queued or
running SQL. The regression for a supported transient queue exceeding five seconds
rules out simply restoring the inherited GenServer default. As comparisons,
[Ecto.Repo](https://hexdocs.pm/ecto/Ecto.Repo.html#module-shared-options) defaults
to 15,000 ms per query, and
[Microsoft SqlClient](https://learn.microsoft.com/en-us/dotnet/api/microsoft.data.sqlclient.sqlcommand.commandtimeout)
defaults to 30 seconds, measured as network-read time with different semantics.
Thirty seconds is a conservative bounded ceiling for this serialized owner,
allowing more queue headroom than Ecto's query default without adopting an
unbounded runtime wait. This is a design choice, not a measured optimum or an SLA;
request owners may use the existing shorter monotonic-deadline APIs.

SQLite's existing [busy_timeout](https://sqlite.org/pragma.html#pragma_busy_timeout)
remains 5,000 ms: it controls lock-contention waiting, not total migration or
query duration. The repair does not increase it. It also does not authorize a
live-data retry, change guard admission, or replace existing per-step rollback
with a claim that the complete multi-step upgrade is one transaction.
