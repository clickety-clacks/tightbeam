defmodule Tightbeam.Schema do
  @moduledoc "The single production-owned schema bootstrap for a Tightbeam database."

  alias Tightbeam.DB

  @schema_modules [
    Tightbeam.Ledger,
    Tightbeam.EventLog,
    Tightbeam.Assets,
    Tightbeam.Artifacts,
    Tightbeam.CausalEvents,
    Tightbeam.Adjudication,
    Tightbeam.Devices,
    Tightbeam.Idempotency,
    Tightbeam.ConditionFacts,
    Tightbeam.SubagentMarkers,
    Tightbeam.Escalation,
    Tightbeam.Wakes,
    Tightbeam.Projection,
    Tightbeam.Org,
    Tightbeam.CriticalLeases,
    Tightbeam.Roles,
    Tightbeam.WorkItems,
    Tightbeam.Assignments,
    Tightbeam.EffortCheckin,
    Tightbeam.Placement,
    Tightbeam.RailRemedy,
    Tightbeam.Supervision,
    Tightbeam.WorkState,
    Tightbeam.HarnessProcess,
    Tightbeam.AdapterCoordinator
  ]

  # The shape this build writes. Bump it when a production table changes in a
  # way that makes an older database unreadable, and give the refusal below a
  # sentence saying what changed.
  @shape "model-identity-v1"

  defmodule ShapeError do
    @moduledoc "A database whose shape this build cannot read. Never repaired in place."
    defexception [:message]
  end

  @doc """
  Create every production schema in dependency-safe order.

  Refuses a database this build cannot read. Every `ensure_schema/1` below is
  `CREATE TABLE IF NOT EXISTS`, which is silent about a table that already
  exists in an OLDER shape: it adds no column, so the first query naming one
  dies as an accidental `no such column`, and a column added by hand would be
  worse — `sessions.model` from before the structured identity holds packed
  values like `claude-fable-5[1m]`, which this build would read as a FAMILY.
  A wrong answer, from data that was right when it was written.

  So the shape is STAMPED at creation and CHECKED here, per the house rule: a
  missing or unknown stamp is a refusal and a bug report, never an inference.
  Note the direction — the one existence question below is asked to REFUSE,
  never to deduce a shape and accommodate it. Nothing here migrates, ALTERs,
  or sniffs stored DDL, and nothing should learn to.
  """
  @spec ensure_all(DB.server()) :: :ok
  def ensure_all(db) do
    :ok = ensure_stamp_table(db)
    :ok = check_shape(db)

    Enum.each(@schema_modules, fn module ->
      :ok = module.ensure_schema(db)
    end)

    stamp(db)
  end

  defp ensure_stamp_table(db) do
    DB.execute(db, """
    CREATE TABLE IF NOT EXISTS schema_stamp (
      shape     TEXT PRIMARY KEY,
      stampedAt INTEGER NOT NULL
    );
    """)
  end

  defp check_shape(db) do
    case DB.query(db, "SELECT shape FROM schema_stamp") do
      {:ok, [[@shape]]} ->
        :ok

      {:ok, []} ->
        # No stamp. Either a database this build is about to create, or one
        # written before stamping existed. Those are DIFFERENT, and telling
        # them apart is the whole point — an unstamped database with session
        # rows in it predates the structured model identity.
        unstamped(db)

      {:ok, [[found]]} ->
        raise ShapeError, """
        this Tightbeam database was written by a different build.

          stamped: #{found}
          this build: #{@shape}

        There is no migration. Move the database aside and let it be recreated.
        """
    end
  end

  defp unstamped(db) do
    case DB.query(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='sessions'") do
      {:ok, []} ->
        :ok

      {:ok, [_ | _]} ->
        raise ShapeError, """
        this Tightbeam database predates the structured model identity (#{@shape}).

        Its `sessions` table carries no shape stamp, so its `model` column holds
        PACKED identifiers — `claude-fable-5[1m]` meaning a 1M-context model —
        and `thinkingLevel`/`modelContext` were never written. This build reads
        those three columns as separate fields, so it would take the whole
        packed string as the model's family and silently run the wrong model.

        There is no migration and nothing here will repair it. Move the database
        aside and let it be recreated.
        """
    end
  end

  defp stamp(db) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT OR IGNORE INTO schema_stamp (shape, stampedAt) VALUES (?1, ?2)",
        [@shape, System.system_time(:millisecond)]
      )

    :ok
  end
end
