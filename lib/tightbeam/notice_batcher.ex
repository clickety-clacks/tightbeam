defmodule Tightbeam.NoticeBatcher do
  require Logger

  @moduledoc """
  Source-preserving, default-on delivery batching for prompt wakes. Class and
  origin remain on every source row; they affect only ordering and envelope
  marking.

  A wake remains the durable source notice. This module owns every batch,
  member, schedule, cancellation, retry, and recovery transition. The source
  wake is never rewritten merely because it became a batch member.
  """

  alias Tightbeam.{DB, EventLog, Gateway, Harness, Org, SubmissionSize, Supervision, Wakes}
  alias Tightbeam.DB.Txn

  @rule "notice-batching-v1 r2"
  @policy_revision "notice-batching-v1 r2"

  @states ~w(open sealed delivery_pending delivered delivery_failed canceled)

  @previous_policy_ddl """
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

  """

  @ddl """
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
    policyRef TEXT NOT NULL,
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

  @staged_message_dedupes_ddl """
  CREATE TABLE IF NOT EXISTS staged_message_dedupes (
    targetSessionKey TEXT NOT NULL,
    deviceId TEXT NOT NULL,
    clientMessageId TEXT NOT NULL,
    sourceWakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
    payloadSha256 TEXT NOT NULL CHECK (length(payloadSha256)=64),
    createdAt INTEGER NOT NULL CHECK (createdAt >= 0),
    PRIMARY KEY (targetSessionKey, deviceId, clientMessageId)
  );
  """

  @staged_prompt_attachments_ddl """
  CREATE TABLE IF NOT EXISTS notice_batch_source_attachments (
    sourceWakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
    attachments TEXT NOT NULL CHECK (json_valid(attachments))
  );
  """

  @doc false
  def source_member_ddl do
    @ddl
    |> String.split(";", trim: true)
    |> Enum.find(&String.contains?(&1, "CREATE TABLE IF NOT EXISTS notice_batch_members"))
    |> Kernel.<>(";")
  end

  @doc false
  def previous_source_member_ddl do
    String.replace(
      source_member_ddl(),
      "policyRef TEXT NOT NULL,",
      "policyRef TEXT NOT NULL REFERENCES notice_delivery_policies(policyRef),"
    )
  end

  @spec ensure_schema(GenServer.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    ensure_bootstrap_schema(db)
  end

  @doc false
  def previous_source_payload_objects do
    policy_objects =
      @previous_policy_ddl
      |> String.split(";", trim: true)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(fn sql ->
        [_, name] = Regex.run(~r/CREATE TABLE IF NOT EXISTS (\w+)/, sql)
        {name, sql <> ";"}
      end)

    policy_objects ++
      [
        {"staged_message_dedupes", @staged_message_dedupes_ddl},
        {"notice_batch_source_attachments", @staged_prompt_attachments_ddl}
      ]
  end

  @doc false
  def persist_source_client_in_txn(%Txn{} = txn, wake_id, identity) when is_map(identity) do
    Txn.q(
      txn,
      "UPDATE wakes SET sourceClientIdentity=?2 WHERE wakeId=?1 AND sourceClientIdentity IS NULL",
      [wake_id, JSON.encode!(identity)]
    )

    if Txn.changes(txn) != 1,
      do: raise(DB.Error, message: "source_client_identity_already_bound_or_missing")

    :ok
  end

  @doc false
  def persist_source_attachments_in_txn(%Txn{} = txn, source_wake_id, attachments)
      when is_binary(source_wake_id) and is_list(attachments) do
    if attachments != [] do
      Txn.q(
        txn,
        "UPDATE wakes SET sourceAttachments=?2 WHERE wakeId=?1 AND sourceAttachments IS NULL",
        [source_wake_id, JSON.encode!(attachments)]
      )

      if Txn.changes(txn) != 1,
        do: raise(DB.Error, message: "source_attachments_already_bound_or_missing")
    end

    :ok
  end

  @doc false
  def delivery_attachments_in_txn(%Txn{} = txn, wake_id) when is_binary(wake_id) do
    rows =
      Txn.q(
        txn,
        """
        SELECT source.sourceAttachments
        FROM notice_batches b
        JOIN notice_batch_members m ON m.batchId=b.batchId AND m.state='included'
        JOIN wakes source ON source.wakeId=m.sourceWakeId
        WHERE b.deliveryWakeId=?1 AND source.sourceAttachments IS NOT NULL
        ORDER BY m.publicationSeq
        """,
        [wake_id]
      )

    case rows do
      [] ->
        case Txn.q(
               txn,
               "SELECT sourceAttachments FROM wakes WHERE wakeId=?1 AND sourceAttachments IS NOT NULL",
               [wake_id]
             ) do
          [[encoded]] -> JSON.decode!(encoded)
          [] -> []
        end

      encoded_rows ->
        Enum.flat_map(encoded_rows, fn [encoded] -> JSON.decode!(encoded) end)
    end
  end

  @doc false
  def ensure_bootstrap_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

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
        %Txn{} = _txn,
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

    %{
      recipient_address: recipient_address,
      visibility_scope: visibility_scope,
      enabled: enabled,
      effective_enabled: true,
      policy_revision: @policy_revision,
      policy_ref: policy_ref,
      selected_by: selected_by,
      cause: cause,
      selected_at: at
    }
  end

  @doc false
  @spec lane_enabled_in_txn(Txn.t(), map()) :: boolean()
  def lane_enabled_in_txn(%Txn{}, _recipient), do: true

  @doc "Keep visibility on the authored source; a reference never selects delivery policy."
  @spec record_policy_in_txn(Txn.t(), map(), keyword()) :: String.t()
  def record_policy_in_txn(%Txn{} = txn, wake, opts \\ []) do
    {address, default_scope} = recipient_lane(wake)

    scope =
      case Keyword.fetch(opts, :visibility_scope) do
        {:ok, explicit} -> delivery_gate_scope(explicit, Map.get(wake, :target_gate, 1))
        :error -> default_scope
      end

    Txn.q(
      txn,
      "UPDATE wakes SET sourceVisibilityScope=COALESCE(sourceVisibilityScope,?2), sourceAddress=COALESCE(sourceAddress,?3) WHERE wakeId=?1",
      [wake.wake_id, scope, address]
    )

    policy_ref(wake.wake_id)
  end

  @doc "The spec-named mutation interface for one source notice delivery."
  @spec enqueue_or_recover(GenServer.server(), String.t(), String.t()) ::
          map() | {:error, map()}
  def enqueue_or_recover(db \\ Tightbeam.DB, source_wake_id, policy_delivery_ref) do
    :ok = Wakes.dispose_closed_remedy_sources(db)

    transaction!(db, fn txn ->
      enqueue_or_recover_in_txn(txn, {:enqueue, source_wake_id, policy_delivery_ref})
    end)
  end

  @doc false
  def enqueue_or_recover_in_txn(%Txn{} = txn, source_wake_id, policy_delivery_ref) do
    enqueue_or_recover_in_txn(txn, {:enqueue, source_wake_id, policy_delivery_ref})
  end

  def enqueue_or_recover_in_txn(%Txn{} = txn, {:enqueue, source_wake_id, policy_ref}) do
    case Wakes.get_in_txn(txn, source_wake_id) do
      %{consumer: "prompt", digest: false, state: "pending"} ->
        if policy_ref == policy_ref(source_wake_id) do
          {:deferred,
           %{
             code: "recipient_readiness_required",
             message: "the source stays editable until the recipient's session snapshot"
           }}
        else
          {:error,
           %{code: "invalid_policy_delivery_ref", message: "source reference does not match"}}
        end

      _ ->
        {:error,
         %{code: "stale_source_notice", message: "source is not an editable pending prompt"}}
    end
  end

  def enqueue_or_recover_in_txn(%Txn{} = txn, {:cancel, source_wake_id, cancellation_ref}) do
    cancel_member_in_txn(txn, source_wake_id, cancellation_ref)
  end

  # Historical open/sealed rows are recovered through the same session queue.
  # Compatibility requests cannot form or arm a second per-address queue.
  def enqueue_or_recover_in_txn(%Txn{}, {:seal_if_due, _batch_id, _at}), do: :noop
  def enqueue_or_recover_in_txn(%Txn{}, {:arm, _batch_id}), do: :noop
  def enqueue_or_recover_in_txn(%Txn{}, {:arm_if_due, _batch_id, _at}), do: :noop

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
          | {:immutable_delivery, map()}
          | {:error, map()}
  def preserve_retargeted_source_in_txn(
        %Txn{} = txn,
        source_wake_id,
        replacement_wake_id
      )
      when is_binary(source_wake_id) and is_binary(replacement_wake_id) do
    case Txn.q(txn, "SELECT sourceVisibilityScope FROM wakes WHERE wakeId=?1", [source_wake_id]) do
      [[scope]] ->
        Txn.q(
          txn,
          """
          UPDATE wakes SET sourceVisibilityScope=COALESCE(?2,sourceVisibilityScope)
          WHERE wakeId=?1 AND state='pending'
          """,
          [replacement_wake_id, scope]
        )

      [] ->
        :ok
    end

    case Txn.q(
           txn,
           """
           SELECT m.batchId,b.state,b.deliveryWakeId
           FROM notice_batch_members m JOIN notice_batches b ON b.batchId=m.batchId
           WHERE m.sourceWakeId=?1 AND m.state IN ('active','included')
           """,
           [source_wake_id]
         ) do
      [[batch_id, state, carrier]] ->
        committed? =
          is_binary(carrier) and
            Txn.q(txn, "SELECT 1 FROM turns WHERE wakeId=?1 LIMIT 1", [carrier]) != []

        cond do
          committed? or state in ["delivered", "delivery_failed"] ->
            if is_binary(carrier) do
              {:immutable_delivery,
               %{batch_id: batch_id, batch_state: state, delivery_wake_id: carrier}}
            else
              {:error,
               %{
                 code: "immutable_delivery_missing_carrier",
                 message: "historical delivery has no carrier"
               }}
            end

          true ->
            :released =
              invalidate_unclaimed_batch_in_txn(txn, batch_id, "source-retargeted", now())

            :not_batched
        end

      [] ->
        :not_batched

      _ ->
        {:error,
         %{code: "ambiguous_source_delivery", message: "source has several live memberships"}}
    end
  end

  @doc "Resolve and admit one ready snapshot per concrete session atomically."
  @spec recover(GenServer.server(), integer(), keyword()) :: [String.t()]
  def recover(db \\ Tightbeam.DB, at \\ now(), delivery_opts \\ []) do
    :ok = Wakes.dispose_closed_remedy_sources(db, at)
    reconcile_committed_deliveries(db, at)

    # Only carriers with no actual turn can return to the editable queue.
    # Their frozen bytes remain historical evidence; committed deliveries do
    # not participate in a later recipient snapshot.
    restore_unclaimed_sources(db, at)

    {:ok, ready_ids} = DB.transaction(db, &ready_sources_in_txn(&1, at))

    # Group ready sources by recipient without preparing them. Preparation
    # happens once, inside the recipient's own drain transaction, and only when
    # that recipient can receive. A source whose recipient does not resolve
    # keeps the old path: prepare it here and dispose of it if still unresolved.
    # A failed source rolls back only that source, never an unrelated recipient.
    {recipients, deferred_ids} =
      Enum.reduce(ready_ids, {[], MapSet.new()}, fn wake_id, {targets, deferred} ->
        case DB.transaction_then(
               db,
               fn txn -> source_recipient_in_txn(txn, wake_id, at) end,
               fn txn, target ->
                 Wakes.row_commit_in_txn(txn, [])
                 target
               end
             ) do
          {:ok, nil} ->
            {targets, deferred}

          {:ok, target} ->
            {[{target, wake_id} | targets], deferred}

          {:error, error} ->
            reason =
              if match?(%DB.Error{}, error), do: :persistence_refused, else: :recognition_failed

            Logger.warning("notice source #{wake_id} preparation deferred: #{reason}")
            {targets, MapSet.put(deferred, wake_id)}
        end
      end)

    recipients = Enum.reverse(recipients)
    own_sources = Enum.group_by(recipients, &elem(&1, 0), &elem(&1, 1))

    deliveries =
      recipients
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.flat_map(fn target ->
        own_ids = MapSet.new(Map.fetch!(own_sources, target))

        case DB.transaction_then(
               db,
               fn txn ->
                 drain_session_in_txn(txn, target, own_ids, at, delivery_opts, deferred_ids)
               end,
               fn txn, result ->
                 Wakes.row_commit_in_txn(txn, [])
                 result
               end
             ) do
          {:ok, {:deliveries, chunks}} ->
            Enum.map(chunks, fn {:delivered, wake_id, delivery} ->
              Gateway.complete_delivery(db, delivery)
              wake_id
            end)

          {:ok, _} ->
            []

          {:error, error} ->
            Logger.error(
              "notice session drain refused recipient=#{target} reason=#{inspect(error)}"
            )

            []
        end
      end)

    deliveries
  end

  defp restore_unclaimed_sources(db, at) do
    transaction!(db, fn txn ->
      Txn.q(
        txn,
        "SELECT batchId FROM notice_batches WHERE state IN ('open','sealed','delivery_pending')"
      )
      |> Enum.each(fn [batch_id] ->
        invalidate_unclaimed_batch_in_txn(txn, batch_id, "recipient-readiness-regroup", at)
      end)
    end)
  end

  # This invalidates transport membership, never the underlying source mail.
  # The no-turn predicate fences running, committed and unknown-effect history.
  defp invalidate_unclaimed_batch_in_txn(txn, batch_id, cause, at) do
    case Txn.q(
           txn,
           """
           SELECT b.deliveryWakeId FROM notice_batches b
           WHERE b.batchId=?1 AND b.state IN ('open','sealed','delivery_pending')
             AND (b.deliveryWakeId IS NULL OR EXISTS (
               SELECT 1 FROM wakes w WHERE w.wakeId=b.deliveryWakeId AND w.state='pending' AND w.digest=1))
             AND NOT EXISTS (SELECT 1 FROM turns t WHERE t.wakeId=b.deliveryWakeId)
           """,
           [batch_id]
         ) do
      [[wake_id]] ->
        Txn.q(
          txn,
          """
          UPDATE notice_batch_members SET state='canceled',canceledAt=?2,cancellationRef=?3
          WHERE batchId=?1 AND state IN ('active','included')
          """,
          [batch_id, at, "transport:" <> batch_id <> ":" <> cause]
        )

        if is_binary(wake_id) do
          mark_delivery_failed_in_txn(txn, wake_id, cause, at)
        else
          Txn.q(
            txn,
            """
            UPDATE notice_batches SET state='canceled',terminalCause=?2,
              terminalPrincipal='process:tightbeam:batcher' WHERE batchId=?1
            """,
            [batch_id, cause]
          )
        end

        lifecycle(txn, "unclaimed_membership_released", batch_id, nil, nil, cause)
        :released

      [] ->
        :immutable
    end
  end

  @doc false
  def carrier_admission_in_txn(%Txn{} = txn, wake_id) when is_binary(wake_id) do
    case Txn.q(
           txn,
           """
           SELECT b.batchId,m.sourceWakeId,m.payload FROM notice_batches b
           JOIN notice_batch_members m ON m.batchId=b.batchId AND m.state='included'
           WHERE b.deliveryWakeId=?1 AND b.state='delivery_pending'
           ORDER BY m.publicationSeq
           """,
           [wake_id]
         ) do
      [] ->
        :ready

      rows ->
        carrier = Wakes.get_in_txn(txn, wake_id)
        target = source_delivery_target(txn, carrier)

        valid? =
          Enum.reduce(rows, true, fn [_, source_id, payload], valid ->
            prepared? = prepare_due_source_in_txn(txn, source_id)
            source = Wakes.get_in_txn(txn, source_id)

            prepared? and source.prompt == payload and
              same_delivery_target?(source_delivery_target(txn, source), target) and valid
          end)

        if valid? do
          :ready
        else
          [batch_id, _, _] = hd(rows)

          :released =
            invalidate_unclaimed_batch_in_txn(txn, batch_id, "source-changed-at-admission", now())

          :skipped
        end
    end
  end

  def carrier_admission_in_txn(%Txn{}, _wake_id), do: :ready

  defp same_delivery_target?({key, _, _}, {key, _, _}) when is_binary(key), do: true
  defp same_delivery_target?(_, _), do: false

  defp dispose_unresolved_source_in_txn(txn, source, at) do
    case Gateway.cancel_unavailable_supervision_controller_in_txn(
           txn,
           [wake_id: source.wake_id],
           source.session_key
         ) do
      :canceled -> :ok
      :ordinary -> dispose_missing_role_in_txn(txn, source, at)
    end
  end

  # A removed role cannot produce a recipient boundary. Preserve the source
  # and the scheduler's visible unresolved disposition instead of silently
  # leaving it pending forever. Other unresolved targets retain their existing
  # supervision/terminal-recognition obligations.
  defp dispose_missing_role_in_txn(txn, %{target_role: role} = wake, at)
       when is_binary(role) do
    with [] <- Txn.q(txn, "SELECT 1 FROM roles WHERE name=?1", [role]),
         true <- prepare_due_source_in_txn(txn, wake.wake_id),
         %{state: "pending", target_role: ^role} = source <- Wakes.get_in_txn(txn, wake.wake_id),
         nil <- source_delivery_target(txn, source) do
      Txn.q(
        txn,
        "UPDATE wakes SET state='fired',firedAt=COALESCE(firedAt,?2) WHERE wakeId=?1 AND state='pending'",
        [wake.wake_id, at]
      )

      if Txn.changes(txn) == 1 do
        EventLog.lifecycle_in_txn(
          txn,
          "wake_unresolved",
          wake.wake_id,
          "role #{role} no longer exists"
        )

        Wakes.publish_change_in_txn(txn, "wake.fired", wake.wake_id)
        Wakes.settle_batched_wait_in_txn(txn, wake.wake_id, "delivery-failed")
      end
    else
      _ -> :ok
    end
  end

  defp dispose_missing_role_in_txn(_txn, _wake, _at), do: :ok

  defp ready_sources_in_txn(txn, at) do
    Txn.q(
      txn,
      """
      SELECT w.wakeId FROM wakes w
      WHERE w.state='pending' AND w.consumer='prompt' AND w.digest=0
        AND COALESCE(w.deliveryRule,'')<>'turn-boundary-digest r1'
        AND (w.conditionKind IS NULL OR w.firedAt IS NOT NULL)
        AND (w.waitMode IS NULL OR w.recognitionAt IS NOT NULL)
        AND (w.dueAt<=?1 OR w.firedAt IS NOT NULL OR w.recognitionAt IS NOT NULL)
        AND (w.dueAt<=?1 OR NOT EXISTS (
          SELECT 1 FROM wake_retry_attempts r WHERE r.wakeId=w.wakeId))
        AND NOT EXISTS (SELECT 1 FROM notice_batch_members m
          WHERE m.sourceWakeId=w.wakeId AND m.state IN ('active','included'))
      ORDER BY CASE w.class WHEN 'algedonic' THEN 0 WHEN 'blocker' THEN 1
        WHEN 'input-needed' THEN 2 WHEN 'status-query' THEN 3
        WHEN 'fyi' THEN 4 WHEN 'information' THEN 4 ELSE 5 END,
        w.createdAt,COALESCE((SELECT root.rowid FROM wake_retry_attempts r
          JOIN wakes root ON root.wakeId=r.rootWakeId WHERE r.wakeId=w.wakeId),w.rowid)
      """,
      [at]
    )
    |> Enum.map(&hd/1)
  end

  defp prepared_source_in_txn(txn, wake_id) do
    if prepare_due_source_in_txn(txn, wake_id) do
      case Wakes.get_in_txn(txn, wake_id) do
        %{state: "pending"} = source -> source
        _ -> nil
      end
    end
  end

  # Resolve a ready source's recipient from its stored routing, without
  # preparing it. Only a terminal notice or a source with no resolvable
  # recipient is prepared here.
  defp source_recipient_in_txn(txn, wake_id, at) do
    case Wakes.get_in_txn(txn, wake_id) do
      %{state: "pending"} = wake ->
        # A terminal notice can change recipient when prepared, so it is
        # grouped by its prepared recipient, not by stored routing.
        stored_target =
          if Wakes.terminal_notice?(wake), do: nil, else: source_delivery_target(txn, wake)

        case stored_target do
          {target, _, _} ->
            target

          nil ->
            case prepared_source_in_txn(txn, wake_id) do
              nil ->
                nil

              source ->
                case source_delivery_target(txn, source) do
                  {target, _, _} ->
                    target

                  nil ->
                    dispose_unresolved_source_in_txn(txn, source, at)
                    nil
                end
            end
        end

      _ ->
        nil
    end
  end

  # A busy recipient's sources are left untouched until it can receive. For a
  # free recipient, re-check readiness and prepare only its own sources, each
  # once, in this transaction. A source that fails preparation rolls back to
  # its savepoint and waits for a later tick; the recipient's others proceed.
  defp drain_session_in_txn(txn, target, own_ids, at, delivery_opts, deferred_ids) do
    if recipient_running?(txn, target, nil) do
      :busy
    else
      sources =
        ready_sources_in_txn(txn, at)
        |> Enum.filter(&MapSet.member?(own_ids, &1))
        |> Enum.reject(&MapSet.member?(deferred_ids, &1))
        |> Enum.flat_map(fn wake_id ->
          case prepared_own_source_in_txn(txn, wake_id) do
            nil ->
              []

            source ->
              case source_delivery_target(txn, source) do
                {^target, _, _} -> [source]
                _ -> []
              end
          end
        end)

      if sources == [] do
        :empty
      else
        admit_session_snapshot_in_txn(txn, target, sources, at, delivery_opts)
      end
    end
  end

  defp prepared_own_source_in_txn(txn, wake_id) do
    :ok = Txn.exec(txn, "SAVEPOINT notice_source_prepare")

    try do
      source = prepared_source_in_txn(txn, wake_id)
      :ok = Txn.exec(txn, "RELEASE notice_source_prepare")
      source
    rescue
      error ->
        :ok = Txn.exec(txn, "ROLLBACK TO notice_source_prepare")
        :ok = Txn.exec(txn, "RELEASE notice_source_prepare")

        reason =
          if match?(%DB.Error{}, error), do: :persistence_refused, else: :recognition_failed

        Logger.warning("notice source #{wake_id} preparation deferred: #{reason}")
        nil
    end
  end

  defp admit_session_snapshot_in_txn(txn, target, sources, at, delivery_opts) do
    address = "session:" <> target
    scope = address <> ":readiness-v3"

    [[seq]] =
      Txn.q(
        txn,
        "SELECT COALESCE(MAX(publicationSeq),0)+1 FROM notice_batch_members WHERE recipientAddress=?1 AND visibilityScope=?2",
        [address, scope]
      )

    rows =
      Enum.with_index(sources, seq)
      |> Enum.map(fn {wake, publication_seq} ->
        [
          wake.wake_id,
          wake.origin,
          wake.work_item_id || wake.assignment_id || "wake",
          wake.class,
          publication_seq,
          Wakes.delivery_prompt_in_txn(txn, wake.wake_id)
        ]
      end)

    pairs = Enum.zip(sources, rows)
    boundary = latest_turn_end(txn, target, nil)
    receiver = Org.get_in_txn(txn, target).harness

    plan =
      SubmissionSize.pack_text(
        pairs,
        fn {_, row} -> render_member(row) end,
        fn {first, _}, count ->
          cause = release_cause(boundary, first)
          # UUIDs, SHA256 values and token identifiers have fixed scalar
          # widths. Measure the real header/footer and inter-member newlines.
          overhead = envelope_body("nb_00000000-0000-0000-0000-000000000000", cause, count, "")

          SubmissionSize.text_chars("[from process:tightbeam]\n\n" <> overhead) +
            2 * (count - 1)
        end,
        Harness.submission_text_limit(receiver)
      )

    case plan do
      {:ok, chunks} ->
        # Every chunk belongs to this one locked eligibility snapshot. Failure
        # of any admission rolls all chunks back; later arrivals remain editable.
        deliveries =
          Enum.map(chunks, fn chunk ->
            {chunk_sources, chunk_rows} = Enum.unzip(chunk)
            admit_session_chunk_in_txn(txn, target, chunk_sources, chunk_rows, at, delivery_opts)
          end)

        {:deliveries, deliveries}

      {:error, {:source_submission_too_large, {source, _}, chars, limit}} ->
        EventLog.lifecycle_in_txn(
          txn,
          "notice_source_submission_too_large",
          source.wake_id,
          "receiver=#{receiver} textChars=#{chars} limitChars=#{limit} recipient=#{target}"
        )

        {:submission_size_refused, target}
    end
  end

  defp release_cause(boundary, first) do
    if is_integer(boundary) and boundary > first.created_at, do: "turn-boundary", else: "idle"
  end

  defp admit_session_chunk_in_txn(txn, target, sources, rows, at, delivery_opts) do
    address = "session:" <> target
    scope = address <> ":readiness-v3"
    bytes = Enum.reduce(rows, 0, fn row, sum -> sum + byte_size(render_member(row)) end)
    first = hd(sources)

    boundary = latest_turn_end(txn, target, nil)

    cause = release_cause(boundary, first)

    batch_id = "nb_" <> Tightbeam.Id.uuid4()
    wake_id = delivery_wake_id(batch_id)
    token = delivery_token(batch_id)
    rendered = envelope(batch_id, cause, rows)

    work =
      sources
      |> Enum.map(&[&1.work_item_id, &1.assignment_id])
      |> Enum.reject(&(&1 == [nil, nil]))
      |> Enum.uniq()

    {work_item_id, assignment_id} =
      case work do
        [[item, assignment]] -> {item, assignment}
        _ -> {nil, nil}
      end

    # Selection, frozen membership and the actual turn share this transaction.
    # There is no provisional per-address open/seal/arm delivery queue.
    carrier =
      Wakes.schedule_in_txn(txn, %{
        wake_id: wake_id,
        session_key: target,
        target_role: nil,
        origin: "process:tightbeam",
        prompt: rendered,
        due_at: at,
        class: "fyi",
        digest: true,
        target_gate: first.target_gate,
        work_item_id: work_item_id,
        assignment_id: assignment_id
      })

    Txn.q(
      txn,
      """
      INSERT INTO notice_batches(batchId,recipientAddress,sessionKey,targetRole,
        visibilityScope,policyRevision,state,dueAt,openedAt,sealedAt,releaseCause,
        deliveryToken,envelope,envelopeSha256,deliveryWakeId,memberCount,renderedBytes)
      VALUES(?1,?2,?3,NULL,?4,?5,'delivery_pending',?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)
      """,
      [
        batch_id,
        address,
        target,
        scope,
        @policy_revision,
        Enum.min(Enum.map(sources, & &1.due_at)),
        first.created_at,
        at,
        cause,
        token,
        rendered,
        sha256(rendered),
        wake_id,
        length(rows),
        bytes
      ]
    )

    for {wake, row} <- Enum.zip(sources, rows) do
      policy_ref = policy_ref(wake.wake_id)
      member_id = "nbm_" <> Tightbeam.Id.uuid4()
      [_, _, cause, _, publication_seq, _] = row

      Txn.q(
        txn,
        """
        INSERT INTO notice_batch_members(memberId,batchId,sourceWakeId,policyRef,
          recipientAddress,visibilityScope,publicationSeq,policyRevision,senderPrincipal,
          cause,class,payload,renderedBytes,state,addedAt)
        VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,'fyi',?11,?12,'included',?13)
        """,
        [
          member_id,
          batch_id,
          wake.wake_id,
          policy_ref,
          address,
          scope,
          publication_seq,
          @policy_revision,
          wake.origin,
          cause,
          wake.prompt,
          byte_size(render_member(row)),
          wake.created_at
        ]
      )

      lifecycle(
        txn,
        "member_added",
        batch_id,
        member_id,
        wake.wake_id,
        "session-readiness"
      )
    end

    lifecycle(txn, "session_snapshot_admitted", batch_id, nil, nil, cause)

    EventLog.lifecycle_in_txn(
      txn,
      "wake_digest_materialized",
      wake_id,
      "rule=#{@rule} batchId=#{batch_id} members=#{length(rows)} trigger=session-readiness"
    )

    case Gateway.deliver_prompt_in_txn(
           txn,
           target,
           carrier.origin,
           carrier.prompt,
           Keyword.merge(delivery_opts,
             wake_id: wake_id,
             sender: carrier.origin,
             target_gate: if(carrier.target_gate == 0, do: nil, else: carrier),
             fire_wake_in_txn: true
           )
         ) do
      {:appended, ^target, _, _} = delivery ->
        mark_delivered_in_txn(txn, wake_id, at)
        {:delivered, wake_id, delivery}

      other ->
        raise DB.Error, message: "notice_session_admission_refused: #{inspect(other)}"
    end
  end

  defp prepare_due_source_in_txn(txn, wake_id) do
    if Wakes.suppress_supervision_if_blocked_in_txn?(txn, wake_id) do
      false
    else
      :ok = Tightbeam.Assignments.assert_retry_decision_in_txn!(txn, wake_id)
      :ok = Tightbeam.Productions.Bubble.assert_retry_disposer_in_txn!(txn, wake_id)

      case Supervision.prepare_batch_source_in_txn(txn, wake_id) do
        :stale -> false
        :ready -> prepare_due_source_after_suppression_in_txn(txn, wake_id)
      end
    end
  end

  defp prepare_due_source_after_suppression_in_txn(txn, wake_id) do
    case Txn.q(txn, "SELECT sessionKey FROM turns WHERE wakeId=?1 ORDER BY seq LIMIT 1", [wake_id]) do
      [[delivered_to]] ->
        # A pre-batching delivery may have committed its turn before the wake
        # row was marked fired. On recovery, acknowledge that exact source
        # instead of creating a second carrier for an already-visible message.
        Wakes.batch_source_delivered_in_txn(txn, wake_id, delivered_to)
        false

      [] ->
        case Wakes.terminal_notice_delivery_in_txn(txn, wake_id) do
          {:terminal_notice, wake} ->
            update_source_lane_in_txn(txn, wake)
            prepare_liveness_source_in_txn(txn, wake_id)

          {:terminal_notice_undeliverable, _evidence} ->
            false

          :ordinary ->
            prepare_liveness_source_in_txn(txn, wake_id)
        end
    end
  end

  defp prepare_liveness_source_in_txn(txn, wake_id) do
    case Tightbeam.Supervision.idle_cleanup_delivery_in_txn(
           txn,
           wake_id,
           now()
         ) do
      :ordinary ->
        true

      :stale ->
        Txn.q(
          txn,
          "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1 AND state='pending'",
          [wake_id, now()]
        )

        if Txn.changes(txn) == 1, do: Wakes.publish_change_in_txn(txn, "wake.fired", wake_id)
        false

      {:idle_cleanup_deferred, _reason} ->
        false

      {:deliver, wake} ->
        update_source_lane_in_txn(txn, wake)
        true
    end
  end

  defp update_source_lane_in_txn(txn, wake) do
    {address, scope} = recipient_lane(wake)

    Txn.q(txn, "UPDATE wakes SET sourceVisibilityScope=?2,sourceAddress=?3 WHERE wakeId=?1", [
      wake.wake_id,
      scope,
      address
    ])

    :ok
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

  @doc "Read individually authorized sources without disclosing a denied batch envelope."
  def read_batch_sources(db, batch_id, principal) do
    {:ok, sources} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "SELECT sourceWakeId FROM notice_batch_members WHERE batchId=?1 ORDER BY publicationSeq",
          [batch_id]
        )
        |> Enum.flat_map(fn [wake_id] ->
          if source_readable?(txn, wake_id, principal) do
            case Wakes.get_in_txn(txn, wake_id) do
              nil -> []
              source -> [source]
            end
          else
            []
          end
        end)
      end)

    sources
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
        WHERE m.batchId=?1
        ORDER BY CASE w.class
          WHEN 'algedonic' THEN 0
          WHEN 'blocker' THEN 1
          WHEN 'input-needed' THEN 2
          WHEN 'status-query' THEN 3
          WHEN 'fyi' THEN 4
          WHEN 'information' THEN 4
          ELSE 5
        END, m.publicationSeq
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

  defp row_exists?(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params) == [[1]]

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
        ORDER BY CASE w.class
          WHEN 'algedonic' THEN 0
          WHEN 'blocker' THEN 1
          WHEN 'input-needed' THEN 2
          WHEN 'status-query' THEN 3
          WHEN 'fyi' THEN 4
          WHEN 'information' THEN 4
          ELSE 5
        END, m.publicationSeq
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

  @doc false
  @spec carrier_source_ids_in_txn(Txn.t(), String.t()) :: [String.t()]
  def carrier_source_ids_in_txn(%Txn{} = txn, delivery_wake_id)
      when is_binary(delivery_wake_id) do
    Txn.q(
      txn,
      """
      SELECT m.sourceWakeId
      FROM notice_batches b
      JOIN notice_batch_members m ON m.batchId=b.batchId
      WHERE b.deliveryWakeId=?1 AND m.state='included'
      ORDER BY m.publicationSeq
      """,
      [delivery_wake_id]
    )
    |> Enum.map(&hd/1)
  end

  @doc false
  # One read-only relation for actual delivery history. Transport membership
  # before a turn exists is deliberately not delivery evidence. Callers keep
  # their domain/assignment/authority predicates outside this relation.
  #
  # SQLite cannot push a caller's correlated predicate into this UNION ALL, so a
  # caller that wants one source, turn or assignment passes the same predicate
  # here and each arm applies it through its own index. The values are
  # source-owned SQL expressions (a bound parameter such as "?1"), never caller
  # input. Each option filters the relation's output column of the same name:
  #   source_wake: sourceWakeId    turn_seq: turnSeq
  #   assignment:  assignmentId    turn_wake: the delivery turn's wakeId
  def source_deliveries_sql(filters \\ []) do
    direct =
      source_delivery_arm_filters(filters, %{
        source_wake: "t.wakeId",
        turn_seq: "t.seq",
        turn_wake: "t.wakeId",
        assignment: "t.assignmentId"
      })

    carried =
      source_delivery_arm_filters(filters, %{
        source_wake: "m.sourceWakeId",
        turn_seq: "t.seq",
        turn_wake: "t.wakeId",
        assignment: "w.assignmentId"
      })

    """
    SELECT t.seq AS turnSeq,t.wakeId AS sourceWakeId,t.assignmentId AS assignmentId,
           0 AS carrier,NULL AS publicationSeq
    FROM turns t WHERE t.wakeId IS NOT NULL#{direct}
    UNION ALL
    SELECT t.seq,m.sourceWakeId,w.assignmentId,1,m.publicationSeq
    FROM notice_batch_members m
    JOIN notice_batches b ON b.batchId=m.batchId
    JOIN wakes w ON w.wakeId=m.sourceWakeId
    JOIN turns t ON t.wakeId=b.deliveryWakeId
    WHERE m.state='included'#{carried}
    """
  end

  defp source_delivery_arm_filters(filters, columns) do
    Enum.map_join(filters, fn {key, expression} when is_binary(expression) ->
      " AND #{Map.fetch!(columns, key)}=#{expression}"
    end)
  end

  @doc false
  # True when the source wake `expression` (a correlated column such as
  # "w.wakeId", never caller input) has actual delivery history: the same rows as an EXISTS over
  # `source_deliveries_sql/0` filtered by sourceWakeId, as two indexed lookups.
  def source_delivered_sql(expression) when is_binary(expression) do
    """
    (EXISTS (SELECT 1 FROM turns sd_t WHERE sd_t.wakeId=#{expression})
      OR EXISTS (SELECT 1 FROM notice_batch_members sd_m
        JOIN notice_batches sd_b ON sd_b.batchId=sd_m.batchId
        JOIN wakes sd_w ON sd_w.wakeId=sd_m.sourceWakeId
        JOIN turns sd_t ON sd_t.wakeId=sd_b.deliveryWakeId
        WHERE sd_m.sourceWakeId=#{expression} AND sd_m.state='included'))
    """
  end

  @doc false
  def source_delivery_turns_in_txn(%Txn{} = txn, source_wake_id) do
    Txn.q(
      txn,
      """
      WITH source_deliveries AS (#{source_deliveries_sql(source_wake: "?1")})
      SELECT t.seq,t.status,d.assignmentId
      FROM source_deliveries d JOIN turns t ON t.seq=d.turnSeq
      WHERE d.sourceWakeId=?1 ORDER BY t.seq
      """,
      [source_wake_id]
    )
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

  defp source_delivery_target(txn, %{target_role: role}) when is_binary(role),
    do: Gateway.delivery_target(txn, nil, %{target_role: role})

  defp source_delivery_target(txn, %{target_gate: 0, session_key: session_key}),
    do: Gateway.delivery_target(txn, session_key, nil)

  defp source_delivery_target(txn, source) do
    gate = %{
      reresolve: source.reresolve,
      reresolve_seed: source.reresolve_seed,
      reresolve_rung: source.reresolve_rung
    }

    Gateway.delivery_target(txn, source.session_key, gate)
  end

  defp recipient_lane(recipient) do
    target_role = recipient[:target_role]
    target_user_id = recipient[:target_user_id]

    recipient_address =
      cond do
        is_binary(target_user_id) -> "user:" <> target_user_id
        is_binary(target_role) -> "role:" <> target_role
        true -> "session:" <> Map.fetch!(recipient, :session_key)
      end

    visibility_scope = Map.get(recipient, :visibility_scope, recipient_address <> ":recipient")

    {recipient_address,
     delivery_gate_scope(visibility_scope, Map.get(recipient, :target_gate, 1))}
  end

  # Retain the authored gate in source visibility metadata. Each source's gate
  # is validated before the single concrete-session snapshot; this suffix does
  # not split that snapshot into separate delivery lanes.
  defp delivery_gate_scope(visibility_scope, 0),
    do: visibility_scope <> ":delivery-target-gate-0"

  defp delivery_gate_scope(visibility_scope, _target_gate), do: visibility_scope

  defp recipient_running?(txn, session_key, target_role) do
    resolved =
      if is_binary(target_role) do
        case Gateway.delivery_target(txn, nil, %{target_role: target_role}) do
          {key, _role, _fallback} -> key
          nil -> nil
        end
      else
        session_key
      end

    is_binary(resolved) and
      Txn.q(
        txn,
        "SELECT 1 FROM turns WHERE sessionKey=?1 AND status IN ('running','queued') LIMIT 1",
        [resolved]
      ) != []
  end

  @doc false
  def queued_sources_ready_in_txn?(%Txn{} = txn, session_key, target_role, at \\ now()) do
    queued_sources_ready_excluding_in_txn?(txn, session_key, target_role, nil, at)
  end

  @doc false
  def queued_sources_ready_for_delivery_in_txn?(
        %Txn{} = txn,
        session_key,
        target_role,
        source_wake_id,
        at \\ now()
      ) do
    queued_sources_ready_excluding_in_txn?(txn, session_key, target_role, source_wake_id, at)
  end

  defp queued_sources_ready_excluding_in_txn?(txn, session_key, target_role, source_wake_id, at) do
    recipient_running?(txn, session_key, target_role) or
      Enum.any?(ready_sources_in_txn(txn, at), fn wake_id ->
        wake_id != source_wake_id and
          case source_delivery_target(txn, Wakes.get_in_txn(txn, wake_id)) do
            {^session_key, _, _} -> true
            _ -> false
          end
      end)
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
          [[0]] ->
            Txn.q(
              txn,
              "UPDATE notice_batches SET state='canceled',terminalCause='no-active-members',terminalPrincipal='process:tightbeam:batcher' WHERE batchId=?1 AND state='open'",
              [batch_id]
            )

          _ ->
            :ok
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

    source_ids = carrier_source_ids_in_txn(txn, wake_id)

    Enum.each(source_ids, fn source_id ->
      Txn.q(
        txn,
        "UPDATE wakes SET state='fired',firedAt=COALESCE(firedAt,?2) WHERE wakeId=?1 AND state='pending'",
        [source_id, at]
      )

      source_updated? = Txn.changes(txn) == 1
      Wakes.settle_batched_wait_in_txn(txn, source_id, "delivered")
      if source_updated?, do: Wakes.publish_change_in_txn(txn, "wake.fired", source_id)
      Tightbeam.Supervision.record_idle_cleanup_delivery_in_txn(txn, source_id)
    end)

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

  defp envelope(batch_id, cause, rows) do
    body = Enum.map_join(rows, "\n\n", &render_member/1)
    envelope_body(batch_id, cause, length(rows), body)
  end

  defp envelope_body(batch_id, cause, count, body) do
    provenance = sha256(batch_id <> "\0" <> cause <> "\0" <> body)
    wake_id = delivery_wake_id(batch_id)

    "[batched notices: #{count}]\n" <>
      "batchId=#{batch_id} wake #{wake_id} token=#{delivery_token(batch_id)} rule=#{@rule}\n" <>
      "release=#{cause} provenanceSha256=#{provenance}\n\n" <>
      body <> "\n\n" <> Wakes.digest_signature(count)
  end

  defp render_member([source, sender, cause, class, seq, payload]) do
    "[#{seq}] source=#{source} sender=#{sender} cause=#{cause} class=#{class}\n" <> payload
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
