defmodule Tightbeam.EventLog do
  @moduledoc """
  Append-only observability (T5): verb events, lifecycle events, and boot
  epochs. Nothing consumes these to make decisions in the core — they exist so
  every failure has a row and a reason, and so future rule reactions have a
  feed. Additive tables only; the shared `events` table (verb|denied) keeps
  its original CHECK — lifecycle records go to their own table.

  Crash recording is BY INFERENCE (spec: lifecycle acceptance): a boot epoch
  with no clean-shutdown stamp is recorded as a dirty exit at the NEXT boot.
  No component claims to log its own death.
  """

  alias Tightbeam.DB

  @type db :: GenServer.server()

  @typedoc "A verb/denied event row (payload omitted — it is write-only observability)."
  @type verb_event :: %{
          id: integer(),
          ts: integer(),
          kind: String.t(),
          verb: String.t(),
          origin: String.t(),
          principal: String.t() | nil,
          session_key: String.t() | nil
        }

  @typedoc "A lifecycle event row (crashes, takeovers, dirty exits …)."
  @type lifecycle_event :: %{
          id: integer(),
          ts: integer(),
          kind: String.t(),
          subject: String.t(),
          detail: String.t() | nil
        }

  @ddl """
  CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    ts         INTEGER NOT NULL,
    kind       TEXT    NOT NULL CHECK (kind IN ('verb','denied')),
    verb       TEXT    NOT NULL,
    origin     TEXT    NOT NULL,
    principal  TEXT,
    sessionKey TEXT,
    payload    TEXT    NOT NULL DEFAULT 'null'
  );
  CREATE INDEX IF NOT EXISTS events_session ON events (sessionKey, id);

  CREATE TABLE IF NOT EXISTS lifecycle_events (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    ts      INTEGER NOT NULL,
    kind    TEXT    NOT NULL,
    subject TEXT    NOT NULL,
    detail  TEXT
  );

  CREATE TABLE IF NOT EXISTS boot_epochs (
    epoch           INTEGER PRIMARY KEY AUTOINCREMENT,
    bootedAt        INTEGER NOT NULL,
    cleanShutdownAt INTEGER
  );
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    result = DB.execute(db, @ddl)

    case DB.query(db, "ALTER TABLE events ADD COLUMN principal TEXT") do
      {:ok, _} -> :ok
      {:error, error} -> if inspect(error) =~ "duplicate column", do: :ok, else: raise(error)
    end

    result
  end

  ## Verb events (dispatch appends these)

  @doc """
  Append a verb event (`kind` is `"verb"` for an accepted call, `"denied"` for
  a refused one). Every dispatch outcome gets a row — including the denials.
  """
  @spec append_event(db(), String.t(), String.t(), String.t(), String.t() | nil, term(), term()) :: :ok
  def append_event(db \\ Tightbeam.DB, kind, verb, origin, session_key \\ nil, payload \\ nil, principal \\ nil)
      when kind in ~w(verb denied) do
    {:ok, _} =
      DB.query(db, """
        INSERT INTO events (ts, kind, verb, origin, principal, sessionKey, payload)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      """, [now(), kind, verb, origin, serialize_principal(principal), session_key, encode(payload)])

    :ok
  end

  @doc "Verb events with id > `after_id`, oldest first — the advance/inspect feed."
  @spec events_after(db(), integer(), pos_integer()) :: [verb_event()]
  def events_after(db \\ Tightbeam.DB, after_id, limit) do
    {:ok, rows} =
      DB.query(db, "SELECT id, ts, kind, verb, origin, principal, sessionKey FROM events WHERE id > ?1 ORDER BY id LIMIT ?2", [
        after_id,
        limit
      ])

    Enum.map(rows, fn [id, ts, kind, verb, origin, principal, sk] ->
      %{id: id, ts: ts, kind: kind, verb: verb, origin: origin, principal: principal, session_key: sk}
    end)
  end

  defp serialize_principal(nil), do: nil
  defp serialize_principal({kind, value}), do: "#{kind}:#{value}"

  @doc "Count verb attempts by exact origin and verb strictly after `since_ms`."
  @spec verb_count(db(), String.t(), String.t(), integer()) :: non_neg_integer()
  def verb_count(db \\ Tightbeam.DB, origin, verb, since_ms) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM events WHERE kind = 'verb' AND origin = ?1 AND verb = ?2 AND ts > ?3",
        [origin, verb, since_ms]
      )

    count
  end

  ## Lifecycle

  @doc """
  Record a lifecycle event (crash, takeover, dirty exit …). `kind` is open —
  the lifecycle table deliberately has no CHECK, so new observations never
  need a migration.
  """
  @spec lifecycle(db(), String.t(), String.t(), String.t() | nil) :: :ok
  def lifecycle(db \\ Tightbeam.DB, kind, subject, detail \\ nil) do
    {:ok, _} =
      DB.query(db, "INSERT INTO lifecycle_events (ts, kind, subject, detail) VALUES (?1, ?2, ?3, ?4)", [
        now(),
        kind,
        subject,
        detail
      ])

    :ok
  end

  @doc "All lifecycle events, oldest first."
  @spec lifecycle_events(db()) :: [lifecycle_event()]
  def lifecycle_events(db \\ Tightbeam.DB) do
    {:ok, rows} = DB.query(db, "SELECT id, ts, kind, subject, detail FROM lifecycle_events ORDER BY id")
    Enum.map(rows, fn [id, ts, kind, subject, detail] -> %{id: id, ts: ts, kind: kind, subject: subject, detail: detail} end)
  end

  ## Boot epochs — dirty-exit inference

  @doc """
  Open a new boot epoch. If the previous epoch was never cleanly stamped,
  record a `dirty_exit` lifecycle event for it — crash recording is by
  inference at the NEXT boot; no component claims to log its own death.
  Returns the new epoch id.
  """
  @spec boot(db()) :: pos_integer()
  def boot(db \\ Tightbeam.DB) do
    {:ok, epoch} =
      DB.transaction(db, fn txn ->
        prior =
          Tightbeam.DB.Txn.q(txn, """
            SELECT epoch FROM boot_epochs
            WHERE cleanShutdownAt IS NULL ORDER BY epoch DESC LIMIT 1
          """)

        case prior do
          [[e]] ->
            Tightbeam.DB.Txn.q(txn, "INSERT INTO lifecycle_events (ts, kind, subject, detail) VALUES (?1,?2,?3,?4)", [
              now(),
              "dirty_exit",
              "epoch:#{e}",
              "prior epoch had no clean shutdown"
            ])

          [] ->
            :ok
        end

        Tightbeam.DB.Txn.q(txn, "INSERT INTO boot_epochs (bootedAt) VALUES (?1)", [now()])
        [[epoch]] = Tightbeam.DB.Txn.q(txn, "SELECT last_insert_rowid()")
        epoch
      end)

    epoch
  end

  @doc """
  Stamp `epoch` as cleanly shut down. Must run while the DB is still up
  (`c:Application.prep_stop/1`, not stop) or the next boot infers a dirty
  exit.
  """
  @spec clean_shutdown(db(), pos_integer()) :: :ok
  def clean_shutdown(db \\ Tightbeam.DB, epoch) do
    {:ok, _} = DB.query(db, "UPDATE boot_epochs SET cleanShutdownAt = ?2 WHERE epoch = ?1", [epoch, now()])
    :ok
  end

  defp now, do: System.system_time(:millisecond)

  defp encode(nil), do: "null"
  defp encode(term) when is_binary(term), do: term
  defp encode(term), do: inspect(term)
end
