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

  `lifecycle/4` writes a row and stops there, which is right for the events
  nobody needs woken for. An event that HAPPENED TO SOMEONE goes through
  `notice/5` instead: same row, plus the chat marker its audience reads. One
  call owns both halves on purpose — see `notice/5`.
  """

  require Logger

  alias Tightbeam.ConnRegistry
  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Org
  alias Tightbeam.Projection
  alias Tightbeam.Wire.Payloads

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

  @typedoc "A payload-projecting dispatch-tier rail denial."
  @type rail_denial :: %{
          id: integer(),
          ts: integer(),
          rule: String.t(),
          edge: String.t(),
          reason: String.t(),
          script_exit_class: String.t() | nil,
          ref: String.t() | nil,
          identity_manifest_sha: String.t() | nil,
          origin: String.t(),
          principal: String.t() | nil
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
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  ## Verb events (dispatch appends these)

  @doc """
  Append a verb event (`kind` is `"verb"` for an accepted call, `"denied"` for
  a refused one). Every dispatch outcome gets a row — including the denials.
  """
  @spec append_event(db(), String.t(), String.t(), String.t(), String.t() | nil, term(), term()) ::
          :ok
  def append_event(
        db \\ Tightbeam.DB,
        kind,
        verb,
        origin,
        session_key \\ nil,
        payload \\ nil,
        principal \\ nil
      )
      when kind in ~w(verb denied) do
    {:ok, _event_id} =
      DB.transaction(db, fn txn ->
        append_event_in_txn(
          txn,
          kind,
          verb,
          origin,
          session_key,
          payload,
          principal,
          now()
        )
      end)

    :ok
  end

  @doc "Append an event inside its caller's transaction and return its durable id."
  @spec append_event_in_txn(
          Txn.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          term(),
          term(),
          non_neg_integer()
        ) :: pos_integer()
  def append_event_in_txn(
        %Txn{} = txn,
        kind,
        verb,
        origin,
        session_key,
        payload,
        principal,
        ts
      )
      when kind in ~w(verb denied) and is_integer(ts) and ts >= 0 do
    [[event_id]] =
      Txn.q(
        txn,
        """
        INSERT INTO events (ts, kind, verb, origin, principal, sessionKey, payload)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        RETURNING id
        """,
        [ts, kind, verb, origin, serialize_principal(principal), session_key, encode(payload)]
      )

    event_id
  end

  @doc "Verb events with id > `after_id`, oldest first — the advance/inspect feed."
  @spec events_after(db(), integer(), pos_integer()) :: [verb_event()]
  def events_after(db \\ Tightbeam.DB, after_id, limit) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT id, ts, kind, verb, origin, principal, sessionKey FROM events WHERE id > ?1 ORDER BY id LIMIT ?2",
        [
          after_id,
          limit
        ]
      )

    Enum.map(rows, fn [id, ts, kind, verb, origin, principal, sk] ->
      %{
        id: id,
        ts: ts,
        kind: kind,
        verb: verb,
        origin: origin,
        principal: principal,
        session_key: sk
      }
    end)
  end

  @doc "Dispatch-tier rail denials with id > `since_id`, including their legibility payload."
  @spec rail_denials(db(), integer(), pos_integer()) :: [rail_denial()]
  def rail_denials(db \\ Tightbeam.DB, since_id, limit) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT id, ts, payload, origin, principal
        FROM events
        WHERE id > ?1 AND kind = 'denied' AND json_valid(payload)
          AND json_type(payload, '$.rule') = 'text'
        ORDER BY id LIMIT ?2
        """,
        [since_id, limit]
      )

    Enum.map(rows, fn [id, ts, payload, origin, principal] ->
      decoded = JSON.decode!(payload)

      %{
        id: id,
        ts: ts,
        rule: decoded["rule"],
        edge: decoded["edge"],
        reason: decoded["reason"],
        script_exit_class: decoded["script_exit_class"],
        ref: decoded["ref"],
        identity_manifest_sha: decoded["identity_manifest_sha"],
        origin: origin,
        principal: principal
      }
    end)
  end

  defp serialize_principal(nil), do: nil

  defp serialize_principal({:remedy, %{statute: statute, action: action}}),
    do: "remedy:#{action}:#{statute}"

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
      DB.query(
        db,
        "INSERT INTO lifecycle_events (ts, kind, subject, detail) VALUES (?1, ?2, ?3, ?4)",
        [
          now(),
          kind,
          subject,
          detail
        ]
      )

    :ok
  end

  @doc "Record a lifecycle event inside an existing DB transaction."
  @spec lifecycle_in_txn(Txn.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def lifecycle_in_txn(%Txn{} = txn, kind, subject, detail) do
    Txn.q(
      txn,
      "INSERT INTO lifecycle_events (ts, kind, subject, detail) VALUES (?1, ?2, ?3, ?4)",
      [now(), kind, subject, detail]
    )

    :ok
  end

  ## Record-and-notify

  @typedoc """
  Who hears about an event, decided by the caller that records it.

  - `{:session, key}` / `{:sessions, keys}` — the sessions the event happened
    TO. A key with no active session is a log line, never a queued message and
    never a session created on demand.
  - `{:ambient, user_id}` — that user's main session, by the same rule.
  - `:record_only` — the row is the whole story; nobody is interrupted.

  There is no "the owner": a Tightbeam serves several, so an ambient audience
  NAMES the one it means rather than inferring a house owner.
  """
  @type audience ::
          {:session, String.t()}
          | {:sessions, [String.t()]}
          | {:ambient, String.t()}
          | :record_only

  @opaque publication_plan :: [
            {session_key :: String.t(), owner_user_id :: String.t(), seq :: pos_integer(),
             payload :: map()}
          ]

  @doc """
  Record an event AND tell whoever it happened to, in one call.

  The lifecycle row is always written — the table is the dashboard-shaped
  record and stays whatever the audience is. What varies is who is
  interrupted, and THAT decision is made here, at the site that knows the
  event, because a `notice` that could be split into "record now, notify
  maybe later" is how faults ended up in a table no client reads while
  recoveries reached the chat.

  Options:
  - `:audience` (required) — see `t:audience/0`.
  - `:message` (required unless `:record_only`) — the sentence a human reads
    in the chat. `detail` is for the record and is usually `inspect/1` output;
    they are different registers and neither is derived from the other. There
    is no kind-to-text registry.
  - `:attention` (required unless `:record_only`) — `:low` for ambient info a
    client hides by default, `:normal` for a fault that affected this session,
    `:high` for something that needs a human now.
  - `:conn_registry` — injected in tests; defaults to `Tightbeam.ConnRegistry`.
  """
  @spec notice(db(), String.t(), String.t(), String.t() | nil, keyword()) :: :ok
  def notice(db \\ Tightbeam.DB, kind, subject, detail, opts) do
    {audience, message, attention} = notice_options(opts)

    {:ok, {plan, undeliverable}} =
      DB.transaction(db, fn txn ->
        notice_in_txn_with_undeliverable(
          txn,
          kind,
          subject,
          detail,
          audience,
          message,
          attention
        )
      end)

    Enum.each(Enum.reverse(undeliverable), fn session_key ->
      Logger.info(
        "#{kind} for #{subject} was not delivered to #{session_key}: no active session there"
      )
    end)

    publish(plan, opts)
  end

  @doc """
  Record a lifecycle event and its process marker inside the caller's transaction.

  The returned plan is immutable data captured from the committed marker. The caller
  must publish it only after the surrounding transaction returns successfully. A
  record-only or inactive audience returns an empty plan.
  """
  @spec notice_in_txn(Txn.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          publication_plan()
  def notice_in_txn(%Txn{} = txn, kind, subject, detail, opts) do
    {audience, message, attention} = notice_options(opts)
    audience = transactional_audience!(audience)

    {plan, _undeliverable} =
      notice_in_txn_with_undeliverable(
        txn,
        kind,
        subject,
        detail,
        audience,
        message,
        attention
      )

    plan
  end

  @doc "Publish a committed notice plan to connected clients."
  @spec publish(publication_plan(), keyword()) :: :ok
  def publish(plan, opts \\ []) when is_list(plan) do
    registry = Keyword.get(opts, :conn_registry, ConnRegistry)
    Enum.each(plan, &publish_marker(registry, &1))
  end

  defp notice_options(opts) do
    audience = Keyword.fetch!(opts, :audience)

    {message, attention} =
      case audience do
        :record_only ->
          {nil, nil}

        _ ->
          {Keyword.fetch!(opts, :message), Keyword.fetch!(opts, :attention)}
      end

    {audience, message, attention}
  end

  defp transactional_audience!(:record_only), do: :record_only
  defp transactional_audience!({:session, session_key}), do: {:session, session_key}

  defp transactional_audience!(audience) do
    raise ArgumentError,
          "notice_in_txn requires zero or one recipient, got audience: #{inspect(audience)}"
  end

  defp notice_in_txn_with_undeliverable(
         txn,
         kind,
         subject,
         detail,
         audience,
         message,
         attention
       ) do
    lifecycle_in_txn(txn, kind, subject, detail)

    # The record and the markers commit together: a crash between them
    # would leave exactly the split this function exists to prevent.
    {plan, undeliverable} =
      Enum.reduce(candidates(audience), {[], []}, fn session_key, {plan, undeliverable} ->
        case active_owner(txn, session_key) do
          nil ->
            {plan, [session_key | undeliverable]}

          owner ->
            {:appended, marker} =
              Projection.append_marker_in_txn(txn, session_key, message, attention)

            publication =
              {session_key, owner, marker.seq, Payloads.server_message(marker)}

            {[publication | plan], undeliverable}
        end
      end)

    {Enum.reverse(plan), undeliverable}
  end

  defp candidates(:record_only), do: []
  defp candidates({:session, session_key}), do: [session_key]
  defp candidates({:sessions, session_keys}), do: session_keys
  defp candidates({:ambient, user_id}), do: [Org.personal_session_key(user_id)]

  # Read through the transaction handle, not Org: a `DB.query` from inside a
  # transaction re-enters the owner process that is running it.
  #
  # The OWNER comes back with the answer rather than being re-read after the
  # commit. `ownerUserId` is NOT NULL, so nil here means exactly one thing —
  # no active session by that key — and the publish below then needs no second
  # trip through the single-writer DB owner. That trip was the wide half of
  # the publication race: it can queue behind another session's transaction,
  # during which the lane that owns this session can commit AND publish a
  # LATER seq. ConnRegistry no longer drops the earlier one (delivery is
  # unconditional now); skipping the second trip still narrows the window in
  # which frames leave in an order the client must settle by seq.
  defp active_owner(txn, session_key) do
    case Txn.q(
           txn,
           "SELECT ownerUserId FROM sessions WHERE sessionKey = ?1 AND state = 'active'",
           [session_key]
         ) do
      [[owner]] -> owner
      [] -> nil
    end
  end

  # The durable half is already committed by the time we get here, so a fan-out
  # that cannot run is a DELIVERY delay, not a lost event: the marker replays to
  # the next socket that drains this session. Letting the exit through would
  # take out the caller — a dying adapter's own coordinator, in the case that
  # found this — over a process whose absence means the wire is down anyway.
  defp publish_marker(registry, {session_key, owner, seq, payload}) do
    ConnRegistry.publish_message(
      registry,
      session_key,
      owner,
      seq,
      payload,
      fn pid, payload -> send(pid, {:push_message, session_key, seq, payload}) end
    )
  catch
    :exit, reason ->
      Logger.warning(
        "live push of #{session_key} seq #{seq} failed (#{inspect(reason)}); " <>
          "the message is stored and replays on the next connect"
      )

      :ok
  end

  @doc "All lifecycle events, oldest first."
  @spec lifecycle_events(db()) :: [lifecycle_event()]
  def lifecycle_events(db \\ Tightbeam.DB) do
    {:ok, rows} =
      DB.query(db, "SELECT id, ts, kind, subject, detail FROM lifecycle_events ORDER BY id")

    Enum.map(rows, fn [id, ts, kind, subject, detail] ->
      %{id: id, ts: ts, kind: kind, subject: subject, detail: detail}
    end)
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
            Tightbeam.DB.Txn.q(
              txn,
              "INSERT INTO lifecycle_events (ts, kind, subject, detail) VALUES (?1,?2,?3,?4)",
              [
                now(),
                "dirty_exit",
                "epoch:#{e}",
                "prior epoch had no clean shutdown"
              ]
            )

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
    {:ok, _} =
      DB.query(db, "UPDATE boot_epochs SET cleanShutdownAt = ?2 WHERE epoch = ?1", [epoch, now()])

    :ok
  end

  defp now, do: System.system_time(:millisecond)

  defp encode(nil), do: "null"
  defp encode(term) when is_binary(term), do: term
  defp encode(term), do: inspect(term)
end
