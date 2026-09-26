defmodule Tightbeam.TurnLifecycle do
  @moduledoc """
  Durable claim, actual-dispatch and terminal evidence for stale-turn settlement.

  `turns` remains the turn state machine. This module records the ordered
  boundaries that produced that state; it never retries work or decides what a
  caller should do next. Redaction and the detail size bound apply before
  insertion. This internal persistence slice exposes no tracing read surface.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  require Logger

  @max_detail_bytes 2_048

  @detail_keys %{
    "claimed" => ~w(v owner),
    "prompt_dispatched" => ~w(v),
    "terminal_committed" => ~w(v status)
  }

  @ddl """
  CREATE TABLE IF NOT EXISTS turn_lifecycle_events (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    turnSeq      INTEGER NOT NULL REFERENCES turns(seq),
    ordinal      INTEGER NOT NULL,
    at           INTEGER NOT NULL,
    eventKey     TEXT NOT NULL,
    kind         TEXT NOT NULL CHECK (kind IN (
                   'claimed','prompt_dispatched','terminal_committed'
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
    {:ok, :ok} = DB.transaction(db, &ensure_schema_in_txn/1)
    :ok
  end

  # Schema activation must commit the epoch with its named successor stamp.
  # Existing turns stay legacy; no historical dispatch evidence is synthesized.
  @doc false
  def ensure_schema_in_txn(%Txn{} = txn) do
    :ok = Txn.exec(txn, @ddl)

    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO turn_lifecycle_epoch (singleton, firstTurnSeq, activatedAt)
      SELECT 1, COALESCE(MAX(seq), 0) + 1, ?1 FROM turns
      """,
      [System.system_time(:millisecond)]
    )

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

  defp validate_writer!(txn, turn_seq, event) do
    {status, claimed_lease} = writer_state(txn, turn_seq)

    case event.kind do
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

      _ordinary ->
        cond do
          status in ~w(delivered canceled failed failed_unknown) ->
            write_error!(:terminal_absorbing, turn_seq, event)

          status != "running" ->
            write_error!(:turn_not_running, turn_seq, event)

          not nonempty_string?(event.owner_lease) or event.owner_lease != claimed_lease ->
            write_error!(:stale_owner_lease, turn_seq, event)

          event.kind == "prompt_dispatched" and
              Txn.q(txn, "SELECT adapterGen FROM turns WHERE seq=?1", [turn_seq]) != [
                [event.adapter_gen]
              ] ->
            write_error!(:generation_mismatch, turn_seq, event)

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
    (event.cause in ["operator:stale-running-turn", "operator:clear-stranded"] and
       String.starts_with?(event.principal, "user:")) or
      (event.cause == "session-retired" and nonempty_string?(event.principal)) or
      (event.principal == "process:tightbeam" and
         (event.cause in ["boot-recovery", "queued-message-suppressed"] or
            String.starts_with?(event.cause, "unclaimable:")))
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
        "claimed" ->
          is_nil(stage) and is_nil(outcome)

        "prompt_dispatched" ->
          stage == "prompt" and outcome == "dispatched"

        "terminal_committed" ->
          is_nil(stage) and outcome in ~w(delivered failed canceled failed_unknown)

        _ ->
          false
      end

    request_id_valid? =
      kind != "prompt_dispatched" or
        (is_integer(Map.get(attrs, :acp_request_id)) and Map.get(attrs, :acp_request_id) > 0)

    generation_valid? =
      kind != "prompt_dispatched" or
        (is_integer(Map.get(attrs, :adapter_gen)) and Map.get(attrs, :adapter_gen) > 0)

    if not valid? or not request_id_valid? or not generation_valid?,
      do: raise(ArgumentError, "invalid typed lifecycle boundary #{kind}")
  end

  defp required_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "#{key} must be a non-empty string"
    end
  end
end
