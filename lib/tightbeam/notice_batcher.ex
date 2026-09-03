defmodule Tightbeam.NoticeBatcher do
  @moduledoc """
  Source-preserving delivery batching for eligible V1 `fyi` wakes and
  sender-marked V2 agent `information` messages.

  A wake remains the durable source notice. This module owns every batch,
  member, schedule, cancellation, retry, and recovery transition. The source
  wake is never rewritten merely because it became a batch member.
  """

  alias Tightbeam.{DB, EventLog, Gateway, Wakes}
  alias Tightbeam.DB.Txn

  @rule "notice-batching-v1 r1"
  @policy_revision "notice-batching-v1"
  @max_members 50
  @max_rendered_bytes 65_536

  @states ~w(open sealed delivery_pending delivered delivery_failed canceled)

  @ddl """
  CREATE TABLE IF NOT EXISTS notice_batching_lane_policies (
    recipientAddress TEXT NOT NULL,
    visibilityScope TEXT NOT NULL,
    enabled INTEGER NOT NULL CHECK (enabled IN (0,1)),
    policyRevision TEXT NOT NULL,
    policyRef TEXT NOT NULL CHECK (length(trim(policyRef)) > 0),
    selectedBy TEXT NOT NULL,
    cause TEXT NOT NULL CHECK (length(trim(cause)) > 0),
    selectedAt INTEGER NOT NULL CHECK (selectedAt >= 0),
    PRIMARY KEY (recipientAddress, visibilityScope),
    UNIQUE (policyRef)
  );

  CREATE TABLE IF NOT EXISTS notice_delivery_policies (
    policyRef TEXT PRIMARY KEY,
    sourceWakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
    recipientAddress TEXT NOT NULL,
    sessionKey TEXT NOT NULL,
    targetRole TEXT,
    visibilityScope TEXT NOT NULL,
    policyRevision TEXT NOT NULL,
    deadlineAt INTEGER NOT NULL CHECK (deadlineAt >= 0),
    enabled INTEGER NOT NULL CHECK (enabled IN (0,1)),
    createdAt INTEGER NOT NULL CHECK (createdAt >= 0)
  );

  CREATE TABLE IF NOT EXISTS notice_batches (
    batchId TEXT PRIMARY KEY,
    recipientAddress TEXT NOT NULL,
    sessionKey TEXT NOT NULL,
    targetRole TEXT,
    visibilityScope TEXT NOT NULL,
    policyRevision TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN (
      'open','sealed','delivery_pending','delivered','delivery_failed','canceled'
    )),
    dueAt INTEGER NOT NULL CHECK (dueAt >= 0),
    openedAt INTEGER NOT NULL CHECK (openedAt >= 0),
    sealedAt INTEGER,
    releaseCause TEXT,
    deliveryToken TEXT UNIQUE,
    envelope TEXT,
    envelopeSha256 TEXT,
    deliveryWakeId TEXT UNIQUE REFERENCES wakes(wakeId),
    deliveredAt INTEGER,
    terminalCause TEXT,
    terminalPrincipal TEXT,
    retryCount INTEGER NOT NULL DEFAULT 0 CHECK (retryCount >= 0),
    overflowCount INTEGER NOT NULL DEFAULT 0 CHECK (overflowCount >= 0),
    memberCount INTEGER NOT NULL DEFAULT 0 CHECK (memberCount >= 0),
    renderedBytes INTEGER NOT NULL DEFAULT 0 CHECK (renderedBytes >= 0),
    lastAttemptAt INTEGER,
    lastFailure TEXT,
    CHECK (
      (state = 'open' AND sealedAt IS NULL AND deliveryToken IS NULL AND envelope IS NULL)
      OR
      (state IN ('sealed','delivery_pending','delivered','delivery_failed') AND
       sealedAt IS NOT NULL AND deliveryToken IS NOT NULL AND envelope IS NOT NULL)
      OR
      state = 'canceled'
    )
  );

  CREATE UNIQUE INDEX IF NOT EXISTS notice_batches_one_open_lane
    ON notice_batches(recipientAddress, visibilityScope)
    WHERE state = 'open';
  CREATE INDEX IF NOT EXISTS notice_batches_recovery
    ON notice_batches(state, dueAt, openedAt);

  CREATE TABLE IF NOT EXISTS notice_batch_members (
    memberId TEXT PRIMARY KEY,
    batchId TEXT NOT NULL REFERENCES notice_batches(batchId),
    sourceWakeId TEXT NOT NULL REFERENCES wakes(wakeId),
    policyRef TEXT NOT NULL REFERENCES notice_delivery_policies(policyRef),
    recipientAddress TEXT NOT NULL,
    visibilityScope TEXT NOT NULL,
    publicationSeq INTEGER NOT NULL CHECK (publicationSeq > 0),
    policyRevision TEXT NOT NULL,
    senderPrincipal TEXT NOT NULL,
    cause TEXT NOT NULL,
    class TEXT NOT NULL CHECK (class = 'fyi'),
    payload TEXT NOT NULL,
    renderedBytes INTEGER NOT NULL CHECK (renderedBytes > 0),
    state TEXT NOT NULL CHECK (state IN ('active','included','canceled')),
    addedAt INTEGER NOT NULL CHECK (addedAt >= 0),
    canceledAt INTEGER,
    cancellationRef TEXT,
    UNIQUE(sourceWakeId, recipientAddress, visibilityScope),
    UNIQUE(recipientAddress, visibilityScope, publicationSeq),
    CHECK (
      (state = 'canceled' AND canceledAt IS NOT NULL AND cancellationRef IS NOT NULL)
      OR
      (state != 'canceled' AND canceledAt IS NULL AND cancellationRef IS NULL)
    )
  );

  CREATE INDEX IF NOT EXISTS notice_batch_members_batch
    ON notice_batch_members(batchId, publicationSeq);
  """

  @spec ensure_schema(GenServer.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @spec rule() :: String.t()
  def rule, do: @rule

  @spec policy_revision() :: String.t()
  def policy_revision, do: @policy_revision

  @spec policy_ref(String.t()) :: String.t()
  def policy_ref(source_wake_id), do: "notice-policy:" <> source_wake_id

  @doc false
  @spec apply_lane_policy_in_txn(
          Txn.t(),
          map(),
          boolean(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: map()
  def apply_lane_policy_in_txn(
        %Txn{} = txn,
        recipient,
        enabled,
        policy_ref,
        selected_by,
        cause,
        at
      )
      when is_boolean(enabled) and is_binary(policy_ref) and policy_ref != "" and
             is_binary(selected_by) and selected_by != "" and is_binary(cause) and cause != "" and
             is_integer(at) and at >= 0 do
    {recipient_address, visibility_scope} = recipient_lane(recipient)

    Txn.q(
      txn,
      """
      INSERT INTO notice_batching_lane_policies
        (recipientAddress, visibilityScope, enabled, policyRevision, policyRef,
         selectedBy, cause, selectedAt)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
      ON CONFLICT(recipientAddress, visibilityScope) DO UPDATE SET
        enabled=excluded.enabled,
        policyRevision=excluded.policyRevision,
        policyRef=excluded.policyRef,
        selectedBy=excluded.selectedBy,
        cause=excluded.cause,
        selectedAt=excluded.selectedAt
      """,
      [
        recipient_address,
        visibility_scope,
        if(enabled, do: 1, else: 0),
        @policy_revision,
        policy_ref,
        selected_by,
        cause,
        at
      ]
    )

    %{
      recipient_address: recipient_address,
      visibility_scope: visibility_scope,
      enabled: enabled,
      policy_revision: @policy_revision,
      policy_ref: policy_ref,
      selected_by: selected_by,
      cause: cause,
      selected_at: at
    }
  end

  @doc false
  @spec lane_enabled_in_txn(Txn.t(), map()) :: boolean()
  def lane_enabled_in_txn(%Txn{} = txn, recipient) do
    {recipient_address, visibility_scope} = recipient_lane(recipient)

    case Txn.q(
           txn,
           """
           SELECT enabled FROM notice_batching_lane_policies
           WHERE recipientAddress=?1 AND visibilityScope=?2 AND policyRevision=?3
             AND length(trim(policyRef)) > 0
             AND length(trim(selectedBy)) > 0
             AND length(trim(cause)) > 0
           """,
           [recipient_address, visibility_scope, @policy_revision]
         ) do
      [[1]] -> true
      _ -> false
    end
  end

  @doc "Record the publisher's durable policy decision before admission."
  @spec record_policy_in_txn(Txn.t(), map(), keyword()) :: String.t()
  def record_policy_in_txn(%Txn{} = txn, wake, opts \\ []) do
    ref = policy_ref(wake.wake_id)
    {recipient_address, default_scope} = recipient_lane(wake)
    visibility_scope = Keyword.get(opts, :visibility_scope, default_scope)

    Txn.q(
      txn,
      """
      INSERT INTO notice_delivery_policies
        (policyRef, sourceWakeId, recipientAddress, sessionKey, targetRole,
         visibilityScope, policyRevision, deadlineAt, enabled, createdAt)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
      ON CONFLICT(policyRef) DO NOTHING
      """,
      [
        ref,
        wake.wake_id,
        recipient_address,
        wake.session_key,
        wake[:target_role],
        visibility_scope,
        @policy_revision,
        wake.due_at,
        if(Keyword.get(opts, :enabled, false), do: 1, else: 0),
        wake.created_at
      ]
    )

    ref
  end

  @doc "The spec-named mutation interface for one source notice delivery."
  @spec enqueue_or_recover(GenServer.server(), String.t(), String.t()) ::
          map() | {:error, map()}
  def enqueue_or_recover(db \\ Tightbeam.DB, source_wake_id, policy_delivery_ref) do
    transaction!(db, fn txn ->
      enqueue_or_recover_in_txn(txn, {:enqueue, source_wake_id, policy_delivery_ref})
    end)
  end

  @doc false
  def enqueue_or_recover_in_txn(%Txn{} = txn, source_wake_id, policy_delivery_ref) do
    enqueue_or_recover_in_txn(txn, {:enqueue, source_wake_id, policy_delivery_ref})
  end

  def enqueue_or_recover_in_txn(%Txn{} = txn, {:enqueue, source_wake_id, policy_ref}) do
    with {:ok, source} <- authoritative_source(txn, source_wake_id, policy_ref),
         :ok <- eligible(source) do
      case existing_member(txn, source) do
        nil -> admit_member(txn, source)
        member -> member_result(member)
      end
    end
  end

  def enqueue_or_recover_in_txn(%Txn{} = txn, {:cancel, source_wake_id, cancellation_ref}) do
    cancel_member_in_txn(txn, source_wake_id, cancellation_ref)
  end

  def enqueue_or_recover_in_txn(%Txn{} = txn, {:seal_if_due, batch_id, at}) do
    seal_if_due_in_txn(txn, batch_id, at)
  end

  def enqueue_or_recover_in_txn(%Txn{} = txn, {:arm, batch_id}) do
    arm_if_due_in_txn(txn, batch_id, now())
  end

  def enqueue_or_recover_in_txn(%Txn{} = txn, {:arm_if_due, batch_id, at}) do
    arm_if_due_in_txn(txn, batch_id, at)
  end

  def enqueue_or_recover_in_txn(%Txn{} = txn, {:attempt, delivery_wake_id, at}) do
    update_attempt_in_txn(txn, delivery_wake_id, at)
  end

  def enqueue_or_recover_in_txn(%Txn{} = txn, {:attempt_failed, delivery_wake_id, reason, at}) do
    update_attempt_failure_in_txn(txn, delivery_wake_id, reason, at)
  end

  def enqueue_or_recover_in_txn(%Txn{} = txn, {:delivered, delivery_wake_id, at}) do
    mark_delivered_in_txn(txn, delivery_wake_id, at)
  end

  def enqueue_or_recover_in_txn(%Txn{} = txn, {:delivery_failed, delivery_wake_id, reason, at}) do
    mark_delivery_failed_in_txn(txn, delivery_wake_id, reason, at)
  end

  @doc false
  @spec preserve_retargeted_source_in_txn(Txn.t(), String.t(), String.t()) ::
          :not_batched
          | map()
          | {:immutable_delivery, map()}
          | {:immutable_delivery_pending, map()}
          | {:error, map()}
  def preserve_retargeted_source_in_txn(
        %Txn{} = txn,
        source_wake_id,
        replacement_wake_id
      )
      when is_binary(source_wake_id) and is_binary(replacement_wake_id) do
    case Txn.q(
           txn,
           """
           SELECT p.visibilityScope, p.deadlineAt, m.memberId, m.batchId,
                  m.state, b.state, b.deliveryWakeId
           FROM notice_delivery_policies p
           JOIN notice_batch_members m
             ON m.sourceWakeId=p.sourceWakeId
            AND m.recipientAddress=p.recipientAddress
            AND m.visibilityScope=p.visibilityScope
           JOIN notice_batches b ON b.batchId=m.batchId
           WHERE p.sourceWakeId=?1 AND p.enabled=1 AND p.policyRevision=?2
             AND ((m.state='active' AND b.state='open')
                  OR (m.state='included' AND b.state IN
                      ('sealed','delivery_pending','delivered','delivery_failed')))
           """,
           [source_wake_id, @policy_revision]
         ) do
      [[visibility_scope, deadline_at, _member_id, _batch_id, "active", "open", nil]] ->
        replacement_policy_ref =
          copy_retargeted_policy_in_txn(
            txn,
            replacement_wake_id,
            visibility_scope,
            deadline_at
          )

        enqueue_or_recover_in_txn(txn, replacement_wake_id, replacement_policy_ref)

      [
        [
          visibility_scope,
          deadline_at,
          member_id,
          batch_id,
          "included",
          batch_state,
          delivery_wake_id
        ]
      ] ->
        _replacement_policy_ref =
          copy_retargeted_policy_in_txn(
            txn,
            replacement_wake_id,
            visibility_scope,
            deadline_at
          )

        delivery_wake_id =
          case {batch_state, delivery_wake_id} do
            {"sealed", nil} ->
              case arm_if_due_in_txn(txn, batch_id, now()) do
                {:new, wake_id} -> wake_id
                :noop -> delivery_wake_id_in_txn(txn, batch_id)
              end

            {_state, wake_id} when is_binary(wake_id) ->
              wake_id

            _ ->
              nil
          end

        cond do
          is_binary(delivery_wake_id) ->
            lifecycle(
              txn,
              "retarget_preserved_by_immutable_delivery",
              batch_id,
              member_id,
              replacement_wake_id,
              delivery_wake_id
            )

            {:immutable_delivery,
             %{
               batch_id: batch_id,
               batch_state: batch_state,
               delivery_wake_id: delivery_wake_id
             }}

          overflow_waiting_for_trigger?(txn, batch_id) ->
            lifecycle(
              txn,
              "retarget_preserved_by_immutable_delivery",
              batch_id,
              member_id,
              replacement_wake_id,
              "pending-original-trigger"
            )

            {:immutable_delivery_pending, %{batch_id: batch_id, batch_state: batch_state}}

          true ->
            refusal(
              "immutable_delivery_missing_carrier",
              "a sealed selected source has no durable carrier"
            )
        end

      [] ->
        :not_batched
    end
  end

  defp copy_retargeted_policy_in_txn(
         txn,
         replacement_wake_id,
         visibility_scope,
         deadline_at
       ) do
    replacement_policy_ref = policy_ref(replacement_wake_id)

    Txn.q(
      txn,
      """
      INSERT INTO notice_delivery_policies
        (policyRef, sourceWakeId, recipientAddress, sessionKey, targetRole,
         visibilityScope, policyRevision, deadlineAt, enabled, createdAt)
      SELECT ?2, w.wakeId,
             CASE WHEN w.targetRole IS NULL
                  THEN 'session:' || w.sessionKey
                  ELSE 'role:' || w.targetRole END,
             w.sessionKey, w.targetRole, ?3, ?4, ?5, 1, w.createdAt
      FROM wakes w
      WHERE w.wakeId=?1 AND w.state='pending'
      ON CONFLICT(policyRef) DO NOTHING
      """,
      [
        replacement_wake_id,
        replacement_policy_ref,
        visibility_scope,
        @policy_revision,
        deadline_at
      ]
    )

    replacement_policy_ref
  end

  defp delivery_wake_id_in_txn(txn, batch_id) do
    case Txn.q(txn, "SELECT deliveryWakeId FROM notice_batches WHERE batchId=?1", [batch_id]) do
      [[wake_id]] when is_binary(wake_id) -> wake_id
      _ -> nil
    end
  end

  defp overflow_waiting_for_trigger?(txn, batch_id) do
    Txn.q(
      txn,
      "SELECT 1 FROM notice_batches WHERE batchId=?1 AND state='sealed' AND releaseCause='overflow' AND deliveryWakeId IS NULL",
      [batch_id]
    ) == [[1]]
  end

  @doc "Seal due batches, arm sealed batches, and reconcile committed deliveries."
  @spec recover(GenServer.server(), integer()) :: [String.t()]
  def recover(db \\ Tightbeam.DB, at \\ now()) do
    reconcile_committed_deliveries(db, at)

    {:ok, open_ids} =
      DB.query(
        db,
        "SELECT batchId FROM notice_batches WHERE state='open' ORDER BY openedAt, batchId"
      )

    Enum.each(open_ids, fn [batch_id] ->
      transaction!(db, fn txn ->
        enqueue_or_recover_in_txn(txn, {:seal_if_due, batch_id, at})
      end)
    end)

    {:ok, sealed_ids} =
      DB.query(
        db,
        "SELECT batchId FROM notice_batches WHERE state='sealed' ORDER BY sealedAt, batchId"
      )

    Enum.flat_map(sealed_ids, fn [batch_id] ->
      case transaction!(db, fn txn ->
             enqueue_or_recover_in_txn(txn, {:arm_if_due, batch_id, at})
           end) do
        {:new, wake_id} -> [wake_id]
        _ -> []
      end
    end)
  end

  @spec deliver_batch(GenServer.server(), String.t(), String.t()) :: map() | {:error, map()}
  def deliver_batch(db \\ Tightbeam.DB, batch_id, token) do
    case batch(db, batch_id) do
      nil ->
        {:error, %{code: "not_found", message: "notice batch not found"}}

      %{delivery_token: ^token, delivery_wake_id: wake_id, state: state} = row
      when state in @states ->
        if is_binary(wake_id), do: Wakes.get(db, wake_id) || row, else: row

      _ ->
        {:error, %{code: "invalid_delivery_token", message: "delivery token does not match"}}
    end
  end

  @spec cancel_source_in_txn(Txn.t(), String.t(), String.t()) :: :ok
  def cancel_source_in_txn(%Txn{} = txn, source_wake_id, cancellation_ref) do
    _ = enqueue_or_recover_in_txn(txn, {:cancel, source_wake_id, cancellation_ref})
    :ok
  end

  @spec delivery_attempted(GenServer.server(), String.t(), integer()) :: :ok
  def delivery_attempted(db \\ Tightbeam.DB, wake_id, at \\ now()) do
    transaction!(db, fn txn -> enqueue_or_recover_in_txn(txn, {:attempt, wake_id, at}) end)
  end

  @spec delivery_failed_attempt(GenServer.server(), String.t(), term(), integer()) :: :ok
  def delivery_failed_attempt(db \\ Tightbeam.DB, wake_id, reason, at \\ now()) do
    transaction!(db, fn txn ->
      enqueue_or_recover_in_txn(txn, {:attempt_failed, wake_id, inspect(reason), at})
    end)
  end

  @spec delivery_delivered(GenServer.server(), String.t(), integer()) :: :ok
  def delivery_delivered(db \\ Tightbeam.DB, wake_id, at \\ now()) do
    transaction!(db, fn txn -> enqueue_or_recover_in_txn(txn, {:delivered, wake_id, at}) end)
  end

  @spec delivery_terminal_failure(GenServer.server(), String.t(), term(), integer()) :: :ok
  def delivery_terminal_failure(db \\ Tightbeam.DB, wake_id, reason, at \\ now()) do
    transaction!(db, fn txn ->
      enqueue_or_recover_in_txn(txn, {:delivery_failed, wake_id, inspect(reason), at})
    end)
  end

  @spec batch(GenServer.server(), String.t()) :: map() | nil
  def batch(db \\ Tightbeam.DB, batch_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT batchId, recipientAddress, sessionKey, targetRole, visibilityScope,
               policyRevision, state, dueAt, openedAt, sealedAt, releaseCause,
               deliveryToken, envelope, envelopeSha256, deliveryWakeId, deliveredAt,
               terminalCause, terminalPrincipal, retryCount, overflowCount,
               memberCount, renderedBytes, lastAttemptAt, lastFailure
        FROM notice_batches WHERE batchId=?1
        """,
        [batch_id]
      )

    case rows do
      [row] -> batch_from_row(row)
      [] -> nil
    end
  end

  @doc "Read a batch only when the authenticated principal can read every source wake."
  @spec read_batch(GenServer.server(), String.t(), term()) :: map() | nil
  def read_batch(db \\ Tightbeam.DB, batch_id, principal) do
    case batch(db, batch_id) do
      nil ->
        nil

      value ->
        batch_members = members(db, batch_id)

        if batch_members != [] and
             Enum.all?(batch_members, &source_readable?(db, &1.source_wake_id, principal)) do
          Map.put(value, :members, batch_members)
        end
    end
  end

  @spec members(GenServer.server(), String.t()) :: [map()]
  def members(db \\ Tightbeam.DB, batch_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT m.memberId, m.batchId, m.sourceWakeId, m.policyRef, m.recipientAddress,
               m.visibilityScope, m.publicationSeq, m.policyRevision, m.senderPrincipal,
               m.cause, w.class, m.payload, m.renderedBytes, m.state, m.addedAt, m.canceledAt,
               m.cancellationRef
        FROM notice_batch_members m
        JOIN wakes w ON w.wakeId=m.sourceWakeId
        WHERE m.batchId=?1 ORDER BY m.publicationSeq
        """,
        [batch_id]
      )

    Enum.map(rows, &member_from_row/1)
  end

  @spec source_refs(GenServer.server(), String.t()) :: [map()]
  def source_refs(db \\ Tightbeam.DB, source_wake_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT m.memberId, m.batchId, m.state, b.deliveryWakeId, b.state
        FROM notice_batch_members m
        JOIN notice_batches b ON b.batchId=m.batchId
        WHERE m.sourceWakeId=?1 ORDER BY m.addedAt, m.memberId
        """,
        [source_wake_id]
      )

    Enum.map(rows, fn [member_id, batch_id, member_state, wake_id, batch_state] ->
      %{
        member_id: member_id,
        batch_id: batch_id,
        member_state: member_state,
        delivery_wake_id: wake_id,
        batch_state: batch_state
      }
    end)
  end

  defp source_readable?(db, source_wake_id, {:user, user_id})
       when is_binary(user_id) and user_id != "" do
    row_exists?(
      db,
      """
      SELECT 1
      FROM wakes source
      JOIN sessions recipient ON recipient.sessionKey=source.sessionKey
      WHERE source.wakeId=?1 AND recipient.ownerUserId=?2 AND recipient.state='active'
      """,
      [source_wake_id, user_id]
    )
  end

  defp source_readable?(db, source_wake_id, {:session, caller_session_key})
       when is_binary(caller_session_key) and caller_session_key != "" do
    row_exists?(
      db,
      """
      SELECT 1
      FROM wakes source
      JOIN sessions recipient ON recipient.sessionKey=source.sessionKey
      JOIN sessions caller ON caller.sessionKey=?2
      WHERE source.wakeId=?1 AND recipient.ownerUserId=caller.ownerUserId
        AND recipient.state='active' AND caller.state='active'
      """,
      [source_wake_id, caller_session_key]
    )
  end

  defp source_readable?(db, source_wake_id, {:process, process_id})
       when is_binary(process_id) and process_id != "" do
    row_exists?(
      db,
      "SELECT 1 FROM wakes WHERE wakeId=?1 AND origin=?2",
      [source_wake_id, "process:" <> process_id]
    )
  end

  defp source_readable?(_db, _source_wake_id, _principal), do: false

  defp row_exists?(db, sql, params) do
    case DB.query(db, sql, params) do
      {:ok, [[1]]} -> true
      {:ok, []} -> false
    end
  end

  @spec carrier_members(GenServer.server(), String.t()) :: [map()]
  def carrier_members(db \\ Tightbeam.DB, delivery_wake_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT m.sourceWakeId, m.senderPrincipal, m.cause, w.class,
               m.publicationSeq, m.payload, w.classElection, w.createdAt
        FROM notice_batches b
        JOIN notice_batch_members m ON m.batchId=b.batchId
        JOIN wakes w ON w.wakeId=m.sourceWakeId
        WHERE b.deliveryWakeId=?1 AND m.state='included'
        ORDER BY m.publicationSeq
        """,
        [delivery_wake_id]
      )

    Enum.map(rows, fn [wake_id, sender, cause, class, seq, payload, election, created_at] ->
      %{
        wake_id: wake_id,
        prompt: payload,
        sender_principal: sender,
        cause: cause,
        class: class,
        class_election: election,
        publication_seq: seq,
        payload: payload,
        created_at: created_at
      }
    end)
  end

  @spec pending?(Txn.t(), String.t()) :: boolean()
  def pending?(%Txn{} = txn, source_wake_id) do
    case Txn.q(
           txn,
           """
           SELECT 1
           FROM notice_batch_members m
           JOIN notice_batches b ON b.batchId=m.batchId
           WHERE m.sourceWakeId=?1 AND m.state IN ('active','included')
             AND b.state IN ('open','sealed','delivery_pending')
           LIMIT 1
           """,
           [source_wake_id]
         ) do
      [[1]] -> true
      [] -> false
    end
  end

  defp authoritative_source(txn, source_wake_id, policy_ref) do
    case Txn.q(
           txn,
           """
           SELECT w.wakeId, w.sessionKey, w.targetRole, w.origin, w.creatorSessionKey, w.prompt,
                  w.consumer, w.state, w.createdAt, w.work_item_id, w.assignmentId,
                  w.class, w.classElection, w.digest, p.policyRef, p.recipientAddress,
                  p.visibilityScope, p.policyRevision, p.deadlineAt, p.enabled
           FROM wakes w
           JOIN notice_delivery_policies p ON p.sourceWakeId=w.wakeId
           WHERE w.wakeId=?1 AND p.policyRef=?2
           """,
           [source_wake_id, policy_ref]
         ) do
      [row] ->
        {:ok, source_from_row(row)}

      [] ->
        {:error,
         %{
           code: "invalid_policy_delivery_ref",
           message: "source policy reference is missing or stale"
         }}
    end
  end

  defp eligible(source) do
    cond do
      source.enabled != 1 ->
        refusal("batching_disabled", "batching is disabled for this recipient lane")

      source.state != "pending" ->
        refusal("stale_source_notice", "source notice is not pending")

      source.consumer != "prompt" ->
        refusal("ineligible_source_notice", "source notice is not principal delivery traffic")

      source.digest == 1 ->
        refusal("ineligible_source_notice", "a batch carrier cannot become a member")

      String.starts_with?(source.origin, "user:") ->
        refusal("user_source_notice", "user-authored notices never batch")

      not eligible_class?(source) ->
        refusal(
          "ineligible_notice_class",
          "only non-user v1 fyi notices or sender-marked v2 information messages batch"
        )

      true ->
        :ok
    end
  end

  defp refusal(code, message), do: {:error, %{code: code, message: message}}

  defp eligible_class?(%{class: "fyi"} = source), do: not agent_message?(source)

  defp eligible_class?(%{class: "information", class_election: "sender"} = source),
    do: agent_message?(source)

  defp eligible_class?(_source), do: false

  defp agent_message?(source) do
    Tightbeam.Origin.class(Map.get(source, :origin)) == "agent" and
      agent_session?(Map.get(source, :creator_session_key)) and
      agent_session?(Map.get(source, :session_key))
  end

  defp agent_session?("agent:" <> principal) when principal != "", do: true
  defp agent_session?(_principal), do: false

  defp recipient_lane(recipient) do
    target_role = recipient[:target_role]

    recipient_address =
      if is_binary(target_role),
        do: "role:" <> target_role,
        else: "session:" <> Map.fetch!(recipient, :session_key)

    {recipient_address, Map.get(recipient, :visibility_scope, recipient_address <> ":recipient")}
  end

  defp existing_member(txn, source) do
    case Txn.q(
           txn,
           """
           SELECT memberId, batchId, state
           FROM notice_batch_members
           WHERE sourceWakeId=?1 AND recipientAddress=?2 AND visibilityScope=?3
           """,
           [source.wake_id, source.recipient_address, source.visibility_scope]
         ) do
      [row] -> row
      [] -> nil
    end
  end

  defp admit_member(txn, source) do
    rendered_bytes = rendered_member_bytes(source, next_publication_seq(txn, source))

    if rendered_bytes > @max_rendered_bytes do
      {:bypass,
       %{
         code: "member_payload_too_large",
         message: "one source notice exceeds the v1 rendered payload floor"
       }}
    else
      batch = open_batch(txn, source)

      batch =
        if batch && boundary_after_open?(txn, batch) do
          boundary = latest_turn_end(txn, batch.session_key, batch.target_role)
          seal_open_batch_in_txn(txn, batch.batch_id, "turn-boundary", boundary)
          create_batch(txn, source, 0)
        else
          batch
        end

      batch =
        if batch && overflow?(batch, rendered_bytes) do
          seal_open_batch_in_txn(txn, batch.batch_id, "overflow", source.created_at)
          create_batch(txn, source, 1)
        else
          batch || create_batch(txn, source, 0)
        end

      publication_seq = next_publication_seq(txn, source)
      member_id = "nbm_" <> Tightbeam.Id.uuid4()
      cause = source.work_item_id || source.assignment_id || "wake"

      Txn.q(
        txn,
        """
        INSERT INTO notice_batch_members
          (memberId, batchId, sourceWakeId, policyRef, recipientAddress,
           visibilityScope, publicationSeq, policyRevision, senderPrincipal,
           cause, class, payload, renderedBytes, state, addedAt, canceledAt,
           cancellationRef)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'fyi', ?11, ?12,
                'active', ?13, NULL, NULL)
        """,
        [
          member_id,
          batch.batch_id,
          source.wake_id,
          source.policy_ref,
          source.recipient_address,
          source.visibility_scope,
          publication_seq,
          source.policy_revision,
          source.origin,
          cause,
          source.prompt,
          rendered_bytes,
          source.created_at
        ]
      )

      Txn.q(
        txn,
        """
        UPDATE notice_batches
        SET dueAt=MIN(dueAt, ?2), memberCount=memberCount+1,
            renderedBytes=renderedBytes+?3
        WHERE batchId=?1 AND state='open'
        """,
        [batch.batch_id, source.deadline_at, rendered_bytes]
      )

      lifecycle(txn, "member_added", batch.batch_id, member_id, source.wake_id, "admitted")
      %{member_id: member_id, batch_id: batch.batch_id, state: "open"}
    end
  end

  defp open_batch(txn, source) do
    case Txn.q(
           txn,
           """
           SELECT batchId, memberCount, renderedBytes, openedAt, sessionKey, targetRole
           FROM notice_batches
           WHERE recipientAddress=?1 AND visibilityScope=?2 AND state='open'
           """,
           [source.recipient_address, source.visibility_scope]
         ) do
      [[batch_id, count, bytes, opened_at, session_key, target_role]] ->
        %{
          batch_id: batch_id,
          member_count: count,
          rendered_bytes: bytes,
          opened_at: opened_at,
          session_key: session_key,
          target_role: target_role
        }

      [] ->
        nil
    end
  end

  defp create_batch(txn, source, overflow_count) do
    batch_id = "nb_" <> Tightbeam.Id.uuid4()

    Txn.q(
      txn,
      """
      INSERT INTO notice_batches
        (batchId, recipientAddress, sessionKey, targetRole, visibilityScope,
         policyRevision, state, dueAt, openedAt, retryCount, overflowCount,
         memberCount, renderedBytes)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'open', ?7, ?8, 0, ?9, 0, 0)
      """,
      [
        batch_id,
        source.recipient_address,
        source.session_key,
        source.target_role,
        source.visibility_scope,
        source.policy_revision,
        source.deadline_at,
        source.created_at,
        overflow_count
      ]
    )

    lifecycle(txn, "batch_opened", batch_id, nil, source.wake_id, "first-member")
    %{batch_id: batch_id, member_count: 0, rendered_bytes: 0}
  end

  defp overflow?(batch, candidate_bytes) do
    batch.member_count >= @max_members or
      batch.rendered_bytes + candidate_bytes > @max_rendered_bytes
  end

  defp boundary_after_open?(txn, batch) do
    case latest_turn_end(txn, batch.session_key, batch.target_role) do
      boundary when is_integer(boundary) ->
        boundary > batch.opened_at

      _ ->
        false
    end
  end

  defp next_publication_seq(txn, source) do
    [[seq]] =
      Txn.q(
        txn,
        """
        SELECT COALESCE(MAX(publicationSeq), 0) + 1
        FROM notice_batch_members
        WHERE recipientAddress=?1 AND visibilityScope=?2
        """,
        [source.recipient_address, source.visibility_scope]
      )

    seq
  end

  defp seal_if_due_in_txn(txn, batch_id, at) do
    case Txn.q(
           txn,
           """
           SELECT batchId, sessionKey, targetRole, dueAt, openedAt
           FROM notice_batches WHERE batchId=?1 AND state='open'
           """,
           [batch_id]
         ) do
      [[^batch_id, session_key, target_role, due_at, opened_at]] ->
        boundary = latest_turn_end(txn, session_key, target_role)

        cond do
          at >= due_at ->
            seal_open_batch_in_txn(txn, batch_id, "ceiling", at)

          is_integer(boundary) and boundary > opened_at ->
            seal_open_batch_in_txn(txn, batch_id, "turn-boundary", at)

          true ->
            :noop
        end

      [] ->
        :noop
    end
  end

  defp latest_turn_end(txn, session_key, target_role) do
    resolved =
      if is_binary(target_role) do
        case Gateway.delivery_target(txn, nil, %{target_role: target_role}) do
          {key, _role, _fallback} -> key
          nil -> nil
        end
      else
        session_key
      end

    if is_binary(resolved) do
      case Txn.q(
             txn,
             "SELECT MAX(endedAt) FROM turns WHERE sessionKey=?1 AND endedAt IS NOT NULL",
             [resolved]
           ) do
        [[nil]] -> nil
        [[ended]] -> ended
      end
    end
  end

  defp seal_open_batch_in_txn(txn, batch_id, cause, at) do
    rows = active_member_rows(txn, batch_id)

    if rows == [] do
      Txn.q(
        txn,
        """
        UPDATE notice_batches
        SET state='canceled', terminalCause='no-active-members',
            terminalPrincipal='process:tightbeam:batcher'
        WHERE batchId=?1 AND state='open'
        """,
        [batch_id]
      )

      lifecycle(txn, "batch_canceled", batch_id, nil, nil, "no-active-members")
      :canceled
    else
      envelope = envelope(batch_id, cause, rows)
      sha = sha256(envelope)
      token = delivery_token(batch_id)

      Txn.q(
        txn,
        """
        UPDATE notice_batches
        SET state='sealed', sealedAt=?2, releaseCause=?3, deliveryToken=?4,
            envelope=?5, envelopeSha256=?6
        WHERE batchId=?1 AND state='open'
        """,
        [batch_id, at, cause, token, envelope, sha]
      )

      Txn.q(
        txn,
        "UPDATE notice_batch_members SET state='included' WHERE batchId=?1 AND state='active'",
        [batch_id]
      )

      lifecycle(txn, "batch_sealed", batch_id, nil, nil, cause)
      :sealed
    end
  end

  # Overflow freezes a bounded prefix; it is not a delivery trigger. Keep the
  # sealed bytes immutable, then arm only when that prefix's original ceiling
  # or recipient turn boundary becomes observable.
  defp arm_if_due_in_txn(txn, batch_id, at) do
    case Txn.q(
           txn,
           """
           SELECT releaseCause, dueAt, openedAt, sessionKey, targetRole, sealedAt
           FROM notice_batches WHERE batchId=?1 AND state='sealed'
           """,
           [batch_id]
         ) do
      [["overflow", due_at, opened_at, session_key, target_role, _sealed_at]] ->
        boundary = latest_turn_end(txn, session_key, target_role)

        cond do
          at >= due_at ->
            arm_in_txn(txn, batch_id, due_at, "ceiling")

          is_integer(boundary) and boundary > opened_at ->
            arm_in_txn(txn, batch_id, boundary, "turn-boundary")

          true ->
            :noop
        end

      [[cause, _due_at, _opened_at, _session_key, _target_role, sealed_at]] ->
        arm_in_txn(txn, batch_id, sealed_at, cause)

      [] ->
        :noop
    end
  end

  defp arm_in_txn(txn, batch_id, delivery_at, delivery_trigger) do
    case Txn.q(
           txn,
           """
           SELECT sessionKey, targetRole, envelope, deliveryToken, deliveryWakeId, sealedAt
           FROM notice_batches WHERE batchId=?1 AND state='sealed'
           """,
           [batch_id]
         ) do
      [[session_key, target_role, envelope, token, nil, sealed_at]] ->
        delivery_at = delivery_at || sealed_at
        delivery_trigger = delivery_trigger || release_cause(txn, batch_id)
        wake_id = delivery_wake_id(batch_id)
        existing = Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", [wake_id])
        {work_item_id, assignment_id} = shared_work(txn, batch_id)

        {carrier_session_key, owner_field} = carrier_identity(txn, session_key, target_role)

        if existing == [] do
          Wakes.schedule_in_txn(txn, %{
            wake_id: wake_id,
            session_key: carrier_session_key,
            target_role: target_role,
            origin: "process:tightbeam",
            prompt: envelope,
            due_at: delivery_at,
            class: "fyi",
            digest: true,
            target_gate: 0,
            work_item_id: work_item_id,
            assignment_id: assignment_id
          })
        end

        Txn.q(
          txn,
          """
          UPDATE notice_batches
          SET state='delivery_pending', deliveryWakeId=?2
          WHERE batchId=?1 AND state='sealed' AND deliveryToken=?3
          """,
          [batch_id, wake_id, token]
        )

        supersede_deferred_retargets_in_txn(txn, batch_id, wake_id)

        lifecycle(txn, "delivery_armed", batch_id, nil, nil, wake_id)

        EventLog.lifecycle_in_txn(
          txn,
          "wake_digest_materialized",
          wake_id,
          "rule=#{@rule} batchId=#{batch_id} members=#{member_count(txn, batch_id)} " <>
            "trigger=#{delivery_trigger}#{owner_field}"
        )

        {:new, wake_id}

      [] ->
        :noop
    end
  end

  defp supersede_deferred_retargets_in_txn(txn, batch_id, delivery_wake_id) do
    replacements =
      Txn.q(
        txn,
        """
        SELECT DISTINCT c.replacementWakeId
        FROM notice_batch_members m
        JOIN wake_cancellations c ON c.wakeId=m.sourceWakeId
        JOIN wakes replacement ON replacement.wakeId=c.replacementWakeId
        WHERE m.batchId=?1 AND m.state='included'
          AND c.reasonKind='target_retired' AND c.outcomeKind='replacement'
          AND replacement.state='pending'
        """,
        [batch_id]
      )

    Enum.each(replacements, fn [replacement_wake_id] ->
      canceled =
        Wakes.cancel_in_txn(txn, %{
          wake_id: replacement_wake_id,
          requester: %{kind: "process", id: "tightbeam:batcher"},
          reason_kind: "superseded",
          causal_source: %{kind: "wake", id: delivery_wake_id},
          outcome: %{kind: "replacement", replacement_wake_id: delivery_wake_id}
        })

      if not canceled do
        raise "deferred retirement replacement carrier supersession refused for #{replacement_wake_id}"
      end
    end)
  end

  defp cancel_member_in_txn(txn, source_wake_id, cancellation_ref) do
    case Txn.q(
           txn,
           """
           SELECT m.memberId, m.batchId, m.state, b.state
           FROM notice_batch_members m
           JOIN notice_batches b ON b.batchId=m.batchId
           WHERE m.sourceWakeId=?1
           """,
           [source_wake_id]
         ) do
      [[member_id, batch_id, "active", "open"]] ->
        at = now()

        Txn.q(
          txn,
          """
          UPDATE notice_batch_members
          SET state='canceled', canceledAt=?2, cancellationRef=?3
          WHERE memberId=?1 AND state='active'
          """,
          [member_id, at, cancellation_ref]
        )

        lifecycle(txn, "member_canceled", batch_id, member_id, source_wake_id, cancellation_ref)

        case Txn.q(
               txn,
               "SELECT COUNT(*) FROM notice_batch_members WHERE batchId=?1 AND state='active'",
               [batch_id]
             ) do
          [[0]] -> seal_open_batch_in_txn(txn, batch_id, "empty-after-cancellation", at)
          _ -> :ok
        end

        :ok

      [[member_id, batch_id, "included", state]]
      when state in ~w(sealed delivery_pending delivered delivery_failed) ->
        lifecycle(
          txn,
          "member_cancellation_after_seal",
          batch_id,
          member_id,
          source_wake_id,
          cancellation_ref
        )

        :ok

      _ ->
        :ok
    end
  end

  defp update_attempt_in_txn(txn, wake_id, at) do
    Txn.q(
      txn,
      """
      UPDATE notice_batches SET lastAttemptAt=?2
      WHERE deliveryWakeId=?1 AND state='delivery_pending'
      """,
      [wake_id, at]
    )

    lifecycle_for_wake(txn, "delivery_attempted", wake_id, "attempt")
    :ok
  end

  defp update_attempt_failure_in_txn(txn, wake_id, reason, at) do
    Txn.q(
      txn,
      """
      UPDATE notice_batches
      SET retryCount=retryCount+1, lastAttemptAt=?2, lastFailure=?3
      WHERE deliveryWakeId=?1 AND state='delivery_pending'
      """,
      [wake_id, at, reason]
    )

    lifecycle_for_wake(txn, "delivery_failed", wake_id, reason)
    :ok
  end

  defp mark_delivered_in_txn(txn, wake_id, at) do
    Txn.q(
      txn,
      """
      UPDATE notice_batches
      SET state='delivered', deliveredAt=?2, terminalCause='wake-committed',
          terminalPrincipal='process:tightbeam:wake-scheduler'
      WHERE deliveryWakeId=?1 AND state='delivery_pending'
      """,
      [wake_id, at]
    )

    lifecycle_for_wake(txn, "delivery_delivered", wake_id, "wake-committed")
    :ok
  end

  defp mark_delivery_failed_in_txn(txn, wake_id, reason, at) do
    Txn.q(
      txn,
      "UPDATE wakes SET state='fired', firedAt=?2 WHERE wakeId=?1 AND state='pending'",
      [wake_id, at]
    )

    if Txn.changes(txn) == 1, do: Wakes.publish_change_in_txn(txn, "wake.fired", wake_id)

    Txn.q(
      txn,
      """
      UPDATE notice_batches
      SET state='delivery_failed', deliveredAt=?2, terminalCause=?3,
          terminalPrincipal='process:tightbeam:wake-scheduler'
      WHERE deliveryWakeId=?1 AND state='delivery_pending'
      """,
      [wake_id, at, reason]
    )

    lifecycle_for_wake(txn, "delivery_failed", wake_id, reason)
    :ok
  end

  defp reconcile_committed_deliveries(db, at) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT b.deliveryWakeId,
               EXISTS (SELECT 1 FROM turns t WHERE t.wakeId=b.deliveryWakeId)
        FROM notice_batches b
        LEFT JOIN wakes w ON w.wakeId=b.deliveryWakeId
        WHERE b.state='delivery_pending'
          AND (w.state='fired' OR EXISTS (SELECT 1 FROM turns t WHERE t.wakeId=b.deliveryWakeId))
        """
      )

    Enum.each(rows, fn
      [wake_id, 1] -> delivery_delivered(db, wake_id, at)
      [wake_id, 0] -> delivery_terminal_failure(db, wake_id, :not_committed, at)
    end)
  end

  defp active_member_rows(txn, batch_id) do
    Txn.q(
      txn,
      """
        SELECT m.sourceWakeId, m.senderPrincipal, m.cause, w.class,
               m.publicationSeq, m.payload
        FROM notice_batch_members m
        JOIN wakes w ON w.wakeId=m.sourceWakeId
        WHERE m.batchId=?1 AND m.state='active'
        ORDER BY m.publicationSeq
      """,
      [batch_id]
    )
  end

  defp envelope(batch_id, cause, rows) do
    body =
      rows
      |> Enum.map(&render_member/1)
      |> Enum.join("\n\n")

    provenance = sha256(batch_id <> "\0" <> cause <> "\0" <> body)

    wake_id = delivery_wake_id(batch_id)

    """
    [batched notices: #{length(rows)}]
    batchId=#{batch_id} wake #{wake_id} token=#{delivery_token(batch_id)} rule=#{@rule}
    release=#{cause} provenanceSha256=#{provenance}

    #{body}

    #{Wakes.digest_signature(length(rows))}
    """
    |> String.trim()
  end

  defp rendered_member_bytes(source, seq) do
    byte_size(
      render_member([
        source.wake_id,
        source.origin,
        source.work_item_id || source.assignment_id || "wake",
        source.class,
        seq,
        source.prompt
      ])
    )
  end

  defp render_member([source, sender, cause, class, seq, payload]) do
    "[#{seq}] source=#{source} sender=#{sender} cause=#{cause} class=#{class}\n" <> payload
  end

  defp carrier_identity(_txn, session_key, nil), do: {session_key, ""}

  defp carrier_identity(txn, _session_key, target_role) do
    session_key =
      case Gateway.delivery_target(txn, nil, %{target_role: target_role}) do
        {resolved, _role, _fallback} -> resolved
        nil -> "role:" <> target_role
      end

    owner_field =
      case Txn.q(txn, "SELECT ownerUserId FROM roles WHERE name=?1", [target_role]) do
        [[owner]] -> " ownerUserId=" <> URI.encode_www_form(owner)
        [] -> ""
      end

    {session_key, owner_field}
  end

  defp member_count(txn, batch_id) do
    [[count]] =
      Txn.q(
        txn,
        "SELECT COUNT(*) FROM notice_batch_members WHERE batchId=?1 AND state='included'",
        [
          batch_id
        ]
      )

    count
  end

  defp release_cause(txn, batch_id) do
    [[cause]] = Txn.q(txn, "SELECT releaseCause FROM notice_batches WHERE batchId=?1", [batch_id])
    cause
  end

  defp delivery_token(batch_id), do: "nbt_" <> sha256(batch_id)
  defp delivery_wake_id(batch_id), do: "w_nb_" <> sha256(batch_id)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp lifecycle(txn, kind, batch_id, member_id, source_id, cause) do
    detail =
      [
        "batchId=#{batch_id}",
        member_id && "memberId=#{member_id}",
        source_id && "sourceWakeId=#{source_id}",
        "cause=#{cause}",
        "principal=process:tightbeam:batcher",
        "rule=#{@rule}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    EventLog.lifecycle_in_txn(txn, kind, batch_id, detail)
  end

  defp lifecycle_for_wake(txn, kind, wake_id, cause) do
    case Txn.q(txn, "SELECT batchId FROM notice_batches WHERE deliveryWakeId=?1", [wake_id]) do
      [[batch_id]] -> lifecycle(txn, kind, batch_id, nil, nil, cause)
      [] -> :ok
    end
  end

  defp shared_work(txn, batch_id) do
    rows =
      Txn.q(
        txn,
        """
        SELECT DISTINCT w.work_item_id, w.assignmentId
        FROM notice_batch_members m
        JOIN wakes w ON w.wakeId=m.sourceWakeId
        WHERE m.batchId=?1 AND (w.work_item_id IS NOT NULL OR w.assignmentId IS NOT NULL)
        """,
        [batch_id]
      )

    case rows do
      [[work_item_id, assignment_id]] -> {work_item_id, assignment_id}
      _ -> {nil, nil}
    end
  end

  defp source_from_row([
         wake_id,
         session_key,
         target_role,
         origin,
         creator_session_key,
         prompt,
         consumer,
         state,
         created_at,
         work_item_id,
         assignment_id,
         class,
         class_election,
         digest,
         policy_ref,
         recipient_address,
         visibility_scope,
         policy_revision,
         deadline_at,
         enabled
       ]) do
    %{
      wake_id: wake_id,
      session_key: session_key,
      target_role: target_role,
      origin: origin,
      creator_session_key: creator_session_key,
      prompt: prompt,
      consumer: consumer,
      state: state,
      created_at: created_at,
      work_item_id: work_item_id,
      assignment_id: assignment_id,
      class: class,
      class_election: class_election,
      digest: digest,
      policy_ref: policy_ref,
      recipient_address: recipient_address,
      visibility_scope: visibility_scope,
      policy_revision: policy_revision,
      deadline_at: deadline_at,
      enabled: enabled
    }
  end

  defp member_result([member_id, batch_id, state]),
    do: %{member_id: member_id, batch_id: batch_id, state: state}

  defp member_from_row([
         member_id,
         batch_id,
         source_wake_id,
         policy_ref,
         recipient_address,
         visibility_scope,
         publication_seq,
         policy_revision,
         sender_principal,
         cause,
         class,
         payload,
         rendered_bytes,
         state,
         added_at,
         canceled_at,
         cancellation_ref
       ]) do
    %{
      member_id: member_id,
      batch_id: batch_id,
      source_wake_id: source_wake_id,
      policy_ref: policy_ref,
      recipient_address: recipient_address,
      visibility_scope: visibility_scope,
      publication_seq: publication_seq,
      policy_revision: policy_revision,
      sender_principal: sender_principal,
      cause: cause,
      class: class,
      payload: payload,
      rendered_bytes: rendered_bytes,
      state: state,
      added_at: added_at,
      canceled_at: canceled_at,
      cancellation_ref: cancellation_ref
    }
  end

  defp batch_from_row([
         batch_id,
         recipient_address,
         session_key,
         target_role,
         visibility_scope,
         policy_revision,
         state,
         due_at,
         opened_at,
         sealed_at,
         release_cause,
         delivery_token,
         envelope,
         envelope_sha256,
         delivery_wake_id,
         delivered_at,
         terminal_cause,
         terminal_principal,
         retry_count,
         overflow_count,
         member_count,
         rendered_bytes,
         last_attempt_at,
         last_failure
       ]) do
    %{
      batch_id: batch_id,
      recipient_address: recipient_address,
      session_key: session_key,
      target_role: target_role,
      visibility_scope: visibility_scope,
      policy_revision: policy_revision,
      state: state,
      due_at: due_at,
      opened_at: opened_at,
      sealed_at: sealed_at,
      release_cause: release_cause,
      delivery_token: delivery_token,
      envelope: envelope,
      envelope_sha256: envelope_sha256,
      delivery_wake_id: delivery_wake_id,
      delivered_at: delivered_at,
      terminal_cause: terminal_cause,
      terminal_principal: terminal_principal,
      retry_count: retry_count,
      overflow_count: overflow_count,
      member_count: member_count,
      rendered_bytes: rendered_bytes,
      last_attempt_at: last_attempt_at,
      last_failure: last_failure
    }
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)
end
