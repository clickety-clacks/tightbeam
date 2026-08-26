defmodule Tightbeam.TurnLifecycle do
  @moduledoc """
  The append-only, per-turn observation log.

  `turns` remains the turn state machine. This module records the ordered
  boundaries that produced that state; it never retries work or decides what a
  caller should do next. Version 1 has no expiry path: redaction and the detail
  size bound apply before insertion, and rows remain until a later policy names
  a lawful retention transition.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  require Logger

  @max_detail_bytes 2_048

  @detail_keys %{
    "accepted" => ~w(v origin wakeId clientMessageId authenticatedCaller),
    "claimed" => ~w(v owner),
    "stage_started" => ~w(v),
    "stage_succeeded" => ~w(v mode),
    "stage_failed" => ~w(v failureClass failureDigest),
    "prompt_dispatched" => ~w(v),
    "progress_observed" => ~w(v class label),
    "prompt_resolved" => ~w(v result),
    "assistant_committed" => ~w(v messageCount),
    "terminal_committed" => ~w(v status),
    "terminal_published" => ~w(v status)
  }

  @ddl """
  CREATE TABLE IF NOT EXISTS turn_lifecycle_events (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    turnSeq      INTEGER NOT NULL REFERENCES turns(seq),
    ordinal      INTEGER NOT NULL,
    at           INTEGER NOT NULL,
    eventKey     TEXT NOT NULL,
    kind         TEXT NOT NULL CHECK (kind IN (
                   'accepted','claimed','stage_started','stage_succeeded','stage_failed',
                   'prompt_dispatched','progress_observed','prompt_resolved',
                   'assistant_committed','terminal_committed','terminal_published'
                 )),
    stage        TEXT CHECK (stage IS NULL OR stage IN ('checkout','session','prompt')),
    outcome      TEXT,
    cause        TEXT NOT NULL,
    principal    TEXT NOT NULL,
    ownerLease   TEXT,
    adapterGen   INTEGER,
    acpRequestId INTEGER,
    producerEventId TEXT NOT NULL,
    detail       TEXT NOT NULL DEFAULT '{}',
    UNIQUE (turnSeq, ordinal),
    UNIQUE (turnSeq, eventKey),
    UNIQUE (turnSeq, producerEventId)
  );
  CREATE INDEX IF NOT EXISTS turn_lifecycle_by_turn
    ON turn_lifecycle_events (turnSeq, ordinal);

  CREATE TABLE IF NOT EXISTS turn_lifecycle_epoch (
    singleton   INTEGER PRIMARY KEY CHECK (singleton = 1),
    firstTurnSeq INTEGER NOT NULL CHECK (firstTurnSeq > 0),
    activatedAt INTEGER NOT NULL
  );
  """

  defmodule ConflictError do
    @moduledoc "A deterministic event key was replayed with different typed content."
    defexception [:message, :turn_seq, :event_key]
  end

  defmodule WriteError do
    @moduledoc "A lifecycle writer was stale, post-terminal, or lacked its required authority."
    defexception [:message, :code]
  end

  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ Tightbeam.DB) do
    :ok = DB.execute(db, @ddl)

    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          """
          INSERT OR IGNORE INTO turn_lifecycle_epoch (singleton, firstTurnSeq, activatedAt)
          SELECT 1, COALESCE(MAX(seq), 0) + 1, ?1 FROM turns
          """,
          [System.system_time(:millisecond)]
        )

        :ok
      end)

    :ok
  end

  @doc "Append one event in its own DB transaction."
  @spec append(DB.server(), integer(), map()) ::
          :ok | :duplicate | :legacy | {:error, {:turn_lifecycle_conflict, String.t()} | term()}
  def append(db \\ Tightbeam.DB, turn_seq, attrs) do
    case DB.transaction(db, fn txn -> append_in_txn(txn, turn_seq, attrs) end) do
      {:ok, :appended} ->
        :ok

      {:ok, :duplicate} ->
        :duplicate

      {:ok, :legacy} ->
        :legacy

      {:error, %ConflictError{event_key: event_key} = error} ->
        Logger.error(Exception.message(error))
        {:error, {:turn_lifecycle_conflict, event_key}}

      {:error, %WriteError{code: code} = error} ->
        Logger.error(Exception.message(error))
        {:error, {:turn_lifecycle_write_rejected, code}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Append one event inside the caller's state-changing transaction."
  @spec append_in_txn(Txn.t(), integer(), map()) :: :appended | :duplicate | :legacy
  def append_in_txn(%Txn{} = txn, turn_seq, attrs) do
    if not is_integer(turn_seq) or turn_seq <= 0,
      do: raise(ArgumentError, "turnSeq must be a positive integer")

    if legacy_in_txn?(txn, turn_seq) do
      :legacy
    else
      do_append_in_txn(txn, turn_seq, attrs)
    end
  end

  defp do_append_in_txn(txn, turn_seq, attrs) do
    event = normalize_event(turn_seq, attrs)

    case existing(txn, turn_seq, event.event_key, event.producer_event_id) do
      nil ->
        validate_writer!(txn, turn_seq, event)

        [[ordinal]] =
          Txn.q(
            txn,
            "SELECT COALESCE(MAX(ordinal), 0) + 1 FROM turn_lifecycle_events WHERE turnSeq = ?1",
            [turn_seq]
          )

        Txn.q(
          txn,
          """
          INSERT INTO turn_lifecycle_events
            (turnSeq, ordinal, at, eventKey, kind, stage, outcome, cause, principal,
             ownerLease, adapterGen, acpRequestId, producerEventId, detail)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
          """,
          [
            turn_seq,
            ordinal,
            event.at,
            event.event_key,
            event.kind,
            event.stage,
            event.outcome,
            event.cause,
            event.principal,
            event.owner_lease,
            event.adapter_gen,
            event.acp_request_id,
            event.producer_event_id,
            event.detail
          ]
        )

        :appended

      existing ->
        if existing == comparable(event) do
          :duplicate
        else
          raise ConflictError,
            turn_seq: turn_seq,
            event_key: event.event_key,
            message:
              "turn_lifecycle_conflict: turn #{turn_seq} event #{inspect(event.event_key)} " <>
                "was replayed with different typed content"
        end
    end
  end

  defp legacy_in_txn?(txn, turn_seq) do
    [[epoch]] = Txn.q(txn, "SELECT firstTurnSeq FROM turn_lifecycle_epoch WHERE singleton = 1")

    turn_seq < epoch and
      Txn.q(txn, "SELECT 1 FROM turns WHERE seq=?1", [turn_seq]) == [[1]]
  end

  @doc "Owner-or-admin read for one turn, with hidden and unknown turns conflated."
  @spec read(DB.server(), map()) :: map()
  def read(db, call) do
    session_key = string_param(call.params, :session_key)
    turn_seq = call.params[:turn_seq]

    if is_binary(session_key) and is_integer(turn_seq) and turn_seq > 0 do
      retrieve(db, session_key, turn_seq, call.principal)
    else
      %{code: "invalid", message: "turn-trace requires --session <sessionKey> --seq <turnSeq>"}
    end
  end

  @doc "A privacy-safe progress label for durable trace rows."
  @spec progress_observation(map()) :: %{class: String.t(), label: String.t()} | nil
  def progress_observation(%{"sessionUpdate" => "agent_thought_chunk"}),
    do: %{class: "thought", label: "Thinking"}

  def progress_observation(%{"sessionUpdate" => kind})
      when kind in ["tool_call", "tool_call_update"],
      do: %{class: kind, label: "Tool activity"}

  def progress_observation(_update), do: nil

  @doc "A bounded attribution label for a resolved gateway principal."
  @spec principal(term()) :: String.t()
  def principal({kind, id}) when kind in [:user, :session, :process] and is_binary(id),
    do: "#{kind}:#{id}"

  def principal(value) when is_binary(value) and value != "", do: value
  def principal(_value), do: "process:tightbeam"

  @doc "A stable class and digest for a failure without retaining its raw term."
  @spec failure_detail(term()) :: map()
  def failure_detail(reason) do
    encoded = :erlang.term_to_binary(reason, [:deterministic])

    %{
      failureClass: failure_class(reason),
      failureDigest: :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
    }
  end

  defp failure_class({:adapter_unavailable, _}), do: "adapter_unavailable"
  defp failure_class(:prompt_dispatch_failed), do: "prompt_dispatch_failed"
  defp failure_class(:timeout), do: "timeout"
  defp failure_class(:closed), do: "closed"
  defp failure_class(%{code: code}) when is_binary(code), do: "provider_error:#{code}"
  defp failure_class(%{"code" => code}) when is_integer(code), do: "provider_error"
  defp failure_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_class(_reason), do: "error"

  defp retrieve(db, session_key, turn_seq, principal) do
    caller = caller(db, principal)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT t.seq, t.sessionKey, t.messageId, t.status, t.createdAt, t.startedAt, t.endedAt,
               s.ownerUserId
        FROM turns AS t
        JOIN sessions AS s ON s.sessionKey = t.sessionKey
        WHERE t.seq = ?1 AND t.sessionKey = ?2
        """,
        [turn_seq, session_key]
      )

    case rows do
      [[seq, key, message_id, status, created_at, started_at, ended_at, owner]] ->
        if readable?(caller, owner) do
          {:ok, [[epoch]]} =
            DB.query(db, "SELECT firstTurnSeq FROM turn_lifecycle_epoch WHERE singleton = 1")

          %{
            turn: %{
              seq: seq,
              session_key: key,
              message_id: message_id,
              status: status,
              created_at: created_at,
              started_at: started_at,
              ended_at: ended_at,
              legacy: seq < epoch
            },
            events: events(db, seq)
          }
        else
          not_found()
        end

      [] ->
        not_found()
    end
  end

  defp events(db, turn_seq) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT ordinal, at, eventKey, kind, stage, outcome, cause, principal,
               ownerLease, adapterGen, acpRequestId, producerEventId, detail
        FROM turn_lifecycle_events
        WHERE turnSeq = ?1
        ORDER BY ordinal
        """,
        [turn_seq]
      )

    Enum.map(rows, fn [
                        ordinal,
                        at,
                        key,
                        kind,
                        stage,
                        outcome,
                        cause,
                        principal,
                        lease,
                        gen,
                        req,
                        producer_event_id,
                        detail
                      ] ->
      %{
        ordinal: ordinal,
        at: at,
        event_key: key,
        kind: kind,
        stage: stage,
        outcome: outcome,
        cause: cause,
        principal: principal,
        owner_lease: lease,
        adapter_gen: gen,
        acp_request_id: req,
        producer_event_id: producer_event_id,
        detail: JSON.decode!(detail)
      }
    end)
  end

  defp caller(db, {:user, user}) do
    case DB.query(db, "SELECT isAdmin FROM users WHERE userId = ?1", [user]) do
      {:ok, [[admin]]} -> %{owner: user, admin: admin == 1}
      _ -> %{owner: user, admin: false}
    end
  end

  defp caller(db, {:session, session_key}) do
    case DB.query(
           db,
           """
           SELECT u.userId, u.isAdmin
           FROM sessions AS s
           JOIN users AS u ON u.userId = s.ownerUserId
           WHERE s.sessionKey = ?1
           """,
           [session_key]
         ) do
      {:ok, [[owner, admin]]} -> %{owner: owner, admin: admin == 1}
      _ -> nil
    end
  end

  defp caller(_db, _principal), do: nil
  defp readable?(nil, _owner), do: false
  defp readable?(%{admin: true}, _owner), do: true
  defp readable?(%{owner: owner}, owner), do: true
  defp readable?(_caller, _owner), do: false
  defp not_found, do: %{code: "not_found", message: "turn not found"}

  defp validate_writer!(txn, turn_seq, event) do
    {status, claimed_lease} = writer_state(txn, turn_seq)

    case event.kind do
      "accepted" ->
        if status != "queued" or not is_nil(event.owner_lease),
          do: write_error!(:invalid_accept_authority, turn_seq, event)

      "claimed" ->
        valid_lease = nonempty_string?(event.owner_lease)
        same_lease = is_nil(claimed_lease) or claimed_lease == event.owner_lease

        if status != "running" or not valid_lease or not same_lease,
          do: write_error!(:stale_owner_lease, turn_seq, event)

      "terminal_committed" ->
        cond do
          status not in ~w(delivered canceled failed failed_unknown) ->
            write_error!(:terminal_not_committed, turn_seq, event)

          nonempty_string?(event.owner_lease) and event.owner_lease != claimed_lease ->
            write_error!(:stale_owner_lease, turn_seq, event)

          is_nil(event.owner_lease) and not system_terminal_authority?(event) ->
            write_error!(:invalid_terminal_authority, turn_seq, event)

          true ->
            :ok
        end

      "terminal_published" ->
        if status not in ~w(delivered canceled failed failed_unknown) or
             not is_nil(event.owner_lease) or event.cause != "terminal-publisher" or
             event.principal != "process:tightbeam" do
          write_error!(:invalid_publication_authority, turn_seq, event)
        end

      _ordinary ->
        cond do
          status in ~w(delivered canceled failed failed_unknown) ->
            write_error!(:terminal_absorbing, turn_seq, event)

          status != "running" ->
            write_error!(:turn_not_running, turn_seq, event)

          not nonempty_string?(event.owner_lease) or event.owner_lease != claimed_lease ->
            write_error!(:stale_owner_lease, turn_seq, event)

          true ->
            :ok
        end
    end
  end

  defp writer_state(txn, turn_seq) do
    case Txn.q(
           txn,
           """
           SELECT t.status,
                  (SELECT e.ownerLease FROM turn_lifecycle_events e
                   WHERE e.turnSeq=t.seq AND e.kind='claimed' LIMIT 1)
           FROM turns t WHERE t.seq=?1
           """,
           [turn_seq]
         ) do
      [[status, claimed_lease]] -> {status, claimed_lease}
      [] -> write_error!(:turn_not_found, turn_seq, %{kind: "unknown", event_key: "unknown"})
    end
  end

  defp system_terminal_authority?(event) do
    (event.cause == "session-retired" and nonempty_string?(event.principal)) or
      (event.principal == "process:tightbeam" and
         (event.cause == "boot-recovery" or String.starts_with?(event.cause, "unclaimable:")))
  end

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp write_error!(code, turn_seq, event) do
    raise WriteError,
      code: code,
      message:
        "turn_lifecycle_write_rejected: #{code} for turn #{turn_seq} " <>
          "event #{inspect(event.event_key)} kind #{inspect(event.kind)}"
  end

  defp existing(txn, turn_seq, event_key, producer_event_id) do
    case Txn.q(
           txn,
           """
           SELECT eventKey, kind, stage, outcome, cause, principal, ownerLease,
                  adapterGen, acpRequestId, producerEventId, detail
           FROM turn_lifecycle_events
           WHERE turnSeq = ?1 AND (eventKey = ?2 OR producerEventId = ?3)
           """,
           [turn_seq, event_key, producer_event_id]
         ) do
      [row] -> List.to_tuple(row)
      [] -> nil
      _split_identity_conflict -> :conflict
    end
  end

  defp comparable(event) do
    {
      event.event_key,
      event.kind,
      event.stage,
      event.outcome,
      event.cause,
      event.principal,
      event.owner_lease,
      event.adapter_gen,
      event.acp_request_id,
      event.producer_event_id,
      event.detail
    }
  end

  defp normalize_event(_turn_seq, attrs) do
    kind = required_string(attrs, :kind)
    event_key = required_string(attrs, :event_key)
    cause = required_string(attrs, :cause)
    principal = required_string(attrs, :principal)
    producer_event_id = required_string(attrs, :producer_event_id)
    stage = Map.get(attrs, :stage)
    outcome = Map.get(attrs, :outcome)
    validate_typed_boundary!(kind, stage, outcome, attrs)
    detail = normalize_detail(kind, Map.get(attrs, :detail, %{v: 1}))

    %{
      at: Map.get(attrs, :at, System.system_time(:millisecond)),
      event_key: event_key,
      kind: kind,
      stage: stage,
      outcome: outcome,
      cause: cause,
      principal: principal,
      owner_lease: Map.get(attrs, :owner_lease),
      adapter_gen: Map.get(attrs, :adapter_gen),
      acp_request_id: Map.get(attrs, :acp_request_id),
      producer_event_id: producer_event_id,
      detail: detail
    }
  end

  defp normalize_detail(kind, detail) when is_map(detail) do
    allowed = Map.fetch!(@detail_keys, kind)

    normalized =
      Map.new(detail, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        {key, value} when is_binary(key) -> {key, value}
      end)

    unknown = Map.keys(normalized) -- allowed

    if unknown != [],
      do:
        raise(ArgumentError, "#{kind} detail contains unknown keys: #{Enum.join(unknown, ", ")}")

    if normalized["v"] != 1,
      do: raise(ArgumentError, "#{kind} detail requires v=1")

    encoded = JSON.encode!(normalized)

    if byte_size(encoded) > @max_detail_bytes,
      do: raise(ArgumentError, "#{kind} detail exceeds #{@max_detail_bytes} bytes")

    encoded
  end

  defp normalize_detail(kind, _detail), do: raise(ArgumentError, "#{kind} detail must be a map")

  defp validate_typed_boundary!(kind, stage, outcome, attrs) do
    valid? =
      case kind do
        kind when kind in ["accepted", "claimed"] ->
          is_nil(stage) and is_nil(outcome)

        "stage_started" ->
          stage in ~w(checkout session prompt) and outcome == "started"

        "stage_succeeded" ->
          stage in ~w(checkout session prompt) and outcome == "succeeded"

        "stage_failed" ->
          stage in ~w(checkout session prompt) and outcome == "failed"

        "prompt_dispatched" ->
          stage == "prompt" and outcome == "dispatched"

        "progress_observed" ->
          stage == "prompt" and outcome == "observed"

        "prompt_resolved" ->
          stage == "prompt" and outcome in ~w(delivered failed)

        "assistant_committed" ->
          is_nil(stage) and outcome == "committed"

        "terminal_committed" ->
          is_nil(stage) and outcome in ~w(delivered failed canceled failed_unknown)

        "terminal_published" ->
          is_nil(stage) and outcome in ~w(delivered failed canceled failed_unknown)

        _ ->
          false
      end

    request_id_valid? =
      kind != "prompt_dispatched" or
        (is_integer(Map.get(attrs, :acp_request_id)) and Map.get(attrs, :acp_request_id) > 0)

    if not valid? or not request_id_valid?,
      do: raise(ArgumentError, "invalid typed lifecycle boundary #{kind}")
  end

  defp required_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "#{key} must be a non-empty string"
    end
  end

  defp string_param(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
