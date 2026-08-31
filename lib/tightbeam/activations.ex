defmodule Tightbeam.Activations do
  @moduledoc """
  Durable, neutral activation evidence.

  The stream records what a caller declared, attached, attempted, observed,
  reconciled, withdrew, re-notified, or acknowledged. It deliberately does
  not decide whether any of that evidence is sufficient for a domain policy.
  """

  alias Tightbeam.{DB, Wakes}
  alias Tightbeam.DB.Txn

  @noticed_kinds ~w(attempted observed reconciled withdrawn)
  @terminal_states ~w(withdrawn observed)
  @relations ~w(retry-of compensates supersedes)
  @error_codes ~w(invalid_activation_payload not_found activation_head_changed activation_transition_refused activation_assignment_refused activation_owner_refused activation_relation_refused activation_authority_refused activation_notice_refused invalid_idempotency_key idempotency_conflict capability_missing)
  @opaque_token ~r/\A[A-Za-z0-9._:\/@+=-]{1,512}\z/
  @namespace ~r/\A[a-z0-9._-]{1,64}\z/
  @sha ~r/\A[0-9a-f]{64}\z/

  @ddl """
  CREATE TABLE IF NOT EXISTS activation_events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    eventId TEXT NOT NULL UNIQUE CHECK(eventId GLOB 'aev_*'),
    activationId TEXT NOT NULL CHECK(activationId GLOB 'act_*'),
    kind TEXT NOT NULL CHECK(kind IN (
      'declared','authority-attached','attempted','observed','reconciled','withdrawn',
      'notice-requeued','acknowledged'
    )),
    predecessorEventId TEXT NULL REFERENCES activation_events(eventId),
    rootAssignmentId TEXT NOT NULL REFERENCES assignments(id),
    workItemId TEXT NOT NULL REFERENCES work_items(id),
    actorAssignmentId TEXT NULL REFERENCES assignments(id),
    bySession TEXT NULL REFERENCES sessions(sessionKey),
    byUser TEXT NULL REFERENCES users(userId),
    idempotencyKey TEXT NOT NULL,
    requestSha256 TEXT NOT NULL CHECK(length(requestSha256) = 64 AND requestSha256 NOT GLOB '*[^0-9a-f]*'),
    payload TEXT NOT NULL,
    noticeWakeId TEXT NULL REFERENCES wakes(wakeId),
    ts INTEGER NOT NULL CHECK(ts >= 0),
    CHECK((bySession IS NOT NULL) != (byUser IS NOT NULL))
  );
  CREATE INDEX IF NOT EXISTS activation_events_stream ON activation_events(activationId, seq);
  CREATE INDEX IF NOT EXISTS activation_events_work_item ON activation_events(workItemId, seq);
  CREATE UNIQUE INDEX IF NOT EXISTS activation_events_session_key
    ON activation_events(kind, bySession, idempotencyKey) WHERE bySession IS NOT NULL;
  CREATE UNIQUE INDEX IF NOT EXISTS activation_events_user_key
    ON activation_events(kind, byUser, idempotencyKey) WHERE byUser IS NOT NULL;
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_declaration
    ON activation_events(activationId) WHERE kind = 'declared';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_attempt
    ON activation_events(activationId) WHERE kind = 'attempted';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_observation
    ON activation_events(activationId) WHERE kind = 'observed';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_reconciliation
    ON activation_events(activationId) WHERE kind = 'reconciled';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_withdrawal
    ON activation_events(activationId) WHERE kind = 'withdrawn';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_acknowledgement
    ON activation_events(activationId, json_extract(payload, '$.noticedEventId'))
    WHERE kind = 'acknowledged';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_requeue_per_wake
    ON activation_events(activationId, json_extract(payload, '$.replacesWakeId'))
    WHERE kind = 'notice-requeued';
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc false
  def handle(db, verb, call) do
    result =
      case verb do
        "activation-declare" -> declare(db, call)
        "activation-authority" -> authority(db, call)
        "activation-attempt" -> attempt(db, call)
        "activation-observe" -> observe(db, call)
        "activation-reconcile" -> reconcile(db, call)
        "activation-withdraw" -> withdraw(db, call)
        "activation-renotify" -> renotify(db, call)
        "activation-ack" -> acknowledge(db, call)
        "activation-status" -> status(db, call)
        "activations" -> list(db, call)
      end

    if is_map(result) and is_binary(result[:code]) do
      result
      |> Map.put(:event_kind, kind_for_verb(verb))
      |> maybe_put_activation_id(call.params[:activation_id])
    else
      result
    end
  end

  defp declare(db, call) do
    p = call.params

    allowed =
      ~w(root_assignment_id owner_user_id domain correlation_key prepared_input target prior_activation_id relation idempotency_key)a

    with :ok <-
           exact_keys(
             p,
             allowed,
             ~w(root_assignment_id owner_user_id domain correlation_key prepared_input target idempotency_key)a
           ),
         :ok <- principal_kind(call.principal),
         :ok <- token(p.root_assignment_id, 200),
         :ok <- token(p.owner_user_id, 200),
         {:ok, domain} <- namespace_value(p.domain),
         :ok <- token(p.correlation_key, 200),
         {:ok, prepared} <- resource_ref(p.prepared_input, true),
         {:ok, target} <- resource_ref(p.target, false),
         {:ok, prior} <- prior(p[:prior_activation_id], p[:relation]),
         :ok <- idempotency_key(p.idempotency_key) do
      activation_id = "act_" <> Tightbeam.Id.uuid4()

      payload = %{
        "ownerUserId" => p.owner_user_id,
        "domain" => domain,
        "correlationKey" => p.correlation_key,
        "preparedInput" => prepared,
        "target" => target,
        "prior" => prior
      }

      request = %{
        "verb" => "activation-declare",
        "rootAssignmentId" => p.root_assignment_id,
        "ownerUserId" => p.owner_user_id,
        "domain" => domain,
        "correlationKey" => p.correlation_key,
        "preparedInput" => prepared,
        "target" => target,
        "prior" => prior
      }

      write(db, call, "declared", p.idempotency_key, request, fn txn ->
        with {:ok, work_item_id} <-
               declaration_assignment(txn, call.principal, p.root_assignment_id, p.owner_user_id),
             :ok <- declaration_prior(txn, call.principal, prior, work_item_id) do
          append(txn, %{
            activation_id: activation_id,
            predecessor_id: nil,
            root_assignment_id: p.root_assignment_id,
            work_item_id: work_item_id,
            actor_assignment_id: nil,
            principal: call.principal,
            kind: "declared",
            key: p.idempotency_key,
            digest: digest(request),
            payload: payload,
            notice_wake_id: nil
          })
        end
      end)
    end
  end

  defp authority(db, call) do
    p = call.params

    allowed =
      ~w(activation_id predecessor_event_id actor_assignment_id authorizer basis decision idempotency_key)a

    with :ok <-
           exact_keys(
             p,
             allowed,
             ~w(activation_id predecessor_event_id authorizer basis decision idempotency_key)a
           ),
         :ok <- principal_kind(call.principal),
         :ok <- token(p.activation_id, 200),
         :ok <- token(p.predecessor_event_id, 200),
         :ok <- optional_token(p[:actor_assignment_id], 200),
         {:ok, authorizer} <- domain_identity(p.authorizer),
         {:ok, basis} <- resource_ref(p.basis, true),
         {:ok, decision} <- domain_code(p.decision),
         :ok <- idempotency_key(p.idempotency_key) do
      payload = %{"authorizer" => authorizer, "basis" => basis, "decision" => decision}
      request = semantic("activation-authority", p, payload)

      stream_write(db, call, "authority-attached", p.idempotency_key, request, fn txn, stream ->
        with :ok <- require_head(stream, p.predecessor_event_id),
             :ok <- require_state(stream, ["declared"]),
             :ok <- full_read(txn, call.principal, stream),
             :ok <- authority_caller(txn, call.principal, stream, p[:actor_assignment_id]) do
          append_stream(txn, stream, call, "authority-attached", p, payload, request, nil)
        end
      end)
    end
  end

  defp attempt(db, call) do
    p = call.params

    allowed =
      ~w(activation_id predecessor_event_id actor_assignment_id authority_event_ids executor external_attempt target_state_before idempotency_key)a

    with :ok <- exact_keys(p, allowed, allowed),
         :ok <- principal_kind(call.principal),
         :ok <- token(p.activation_id, 200),
         :ok <- token(p.predecessor_event_id, 200),
         :ok <- token(p.actor_assignment_id, 200),
         {:ok, authority_ids} <- token_list(p.authority_event_ids, 1, 32),
         {:ok, executor} <- domain_identity(p.executor),
         {:ok, external_attempt} <- resource_ref(p.external_attempt, false),
         {:ok, before} <- nullable_resource_ref(p.target_state_before, true),
         :ok <- idempotency_key(p.idempotency_key) do
      payload = %{
        "authorityEventIds" => authority_ids,
        "executor" => executor,
        "externalAttempt" => external_attempt,
        "targetStateBefore" => before
      }

      request = semantic("activation-attempt", p, payload)

      stream_write(db, call, "attempted", p.idempotency_key, request, fn txn, stream ->
        with :ok <- require_head(stream, p.predecessor_event_id),
             :ok <- require_state(stream, ["declared"]),
             :ok <- full_read(txn, call.principal, stream),
             :ok <- held_actor(txn, call.principal, stream, p.actor_assignment_id),
             :ok <- authority_events(stream, authority_ids) do
          event_id = "aev_" <> Tightbeam.Id.uuid4()
          wake = notice(txn, stream, event_id, "attempted", p.actor_assignment_id)

          append_stream(
            txn,
            stream,
            call,
            "attempted",
            p,
            payload,
            request,
            wake.wake_id,
            event_id
          )
        end
      end)
    end
  end

  defp observe(db, call) do
    p = call.params

    allowed =
      ~w(activation_id predecessor_event_id actor_assignment_id attempt_event_id certainty result target_state_after outputs evidence external_occurred_at_ms idempotency_key)a

    with :ok <- exact_keys(p, allowed, allowed -- [:actor_assignment_id]),
         :ok <- common_recovery_params(p, call.principal),
         true <-
           p.certainty in ~w(determinate indeterminate) or error("invalid_activation_payload"),
         {:ok, result} <- domain_code(p.result),
         {:ok, after_state} <- nullable_resource_ref(p.target_state_after, true),
         {:ok, outputs} <- resource_list(p.outputs, 0, 32, false),
         {:ok, evidence} <- resource_ref(p.evidence, true),
         :ok <- nullable_ms(p.external_occurred_at_ms) do
      payload = %{
        "attemptEventId" => p.attempt_event_id,
        "certainty" => p.certainty,
        "result" => result,
        "targetStateAfter" => after_state,
        "outputs" => outputs,
        "evidence" => evidence,
        "externalOccurredAtMs" => p.external_occurred_at_ms
      }

      request = semantic("activation-observe", p, payload)

      recovery_write(db, call, "observed", p, payload, request, fn stream ->
        stream.state == "attempted" and event_kind?(stream, p.attempt_event_id, "attempted")
      end)
    else
      false -> error("invalid_activation_payload")
      other -> other
    end
  end

  defp reconcile(db, call) do
    p = call.params

    allowed =
      ~w(activation_id predecessor_event_id actor_assignment_id observed_event_id certainty result target_state_after outputs evidence external_occurred_at_ms idempotency_key)a

    with :ok <- exact_keys(p, allowed, allowed -- [:actor_assignment_id]),
         :ok <- common_recovery_params(p, call.principal),
         true <-
           p.certainty in ~w(determinate irrecoverable) or error("invalid_activation_payload"),
         {:ok, result} <- domain_code(p.result),
         {:ok, after_state} <- nullable_resource_ref(p.target_state_after, true),
         {:ok, outputs} <- resource_list(p.outputs, 0, 32, false),
         {:ok, evidence} <- resource_ref(p.evidence, true),
         :ok <- nullable_ms(p.external_occurred_at_ms) do
      payload = %{
        "observedEventId" => p.observed_event_id,
        "certainty" => p.certainty,
        "result" => result,
        "targetStateAfter" => after_state,
        "outputs" => outputs,
        "evidence" => evidence,
        "externalOccurredAtMs" => p.external_occurred_at_ms
      }

      request = semantic("activation-reconcile", p, payload)

      recovery_write(db, call, "reconciled", p, payload, request, fn stream ->
        stream.state == "needs-reconciliation" and
          event_kind?(stream, p.observed_event_id, "observed") and
          event_payload(stream, p.observed_event_id)["certainty"] == "indeterminate"
      end)
    else
      false -> error("invalid_activation_payload")
      other -> other
    end
  end

  defp withdraw(db, call) do
    p = call.params

    allowed =
      ~w(activation_id predecessor_event_id actor_assignment_id reason basis idempotency_key)a

    with :ok <-
           exact_keys(
             p,
             allowed,
             ~w(activation_id predecessor_event_id reason basis idempotency_key)a
           ),
         :ok <- principal_kind(call.principal),
         :ok <- token(p.activation_id, 200),
         :ok <- token(p.predecessor_event_id, 200),
         :ok <- optional_token(p[:actor_assignment_id], 200),
         {:ok, reason} <- domain_code(p.reason),
         {:ok, basis} <- resource_ref(p.basis, true),
         :ok <- idempotency_key(p.idempotency_key) do
      payload = %{"reason" => reason, "basis" => basis}
      request = semantic("activation-withdraw", p, payload)

      stream_write(db, call, "withdrawn", p.idempotency_key, request, fn txn, stream ->
        with :ok <- require_head(stream, p.predecessor_event_id),
             :ok <- require_state(stream, ["declared"]),
             :ok <- full_read(txn, call.principal, stream),
             :ok <- withdrawal_caller(txn, call.principal, stream, p[:actor_assignment_id]) do
          event_id = "aev_" <> Tightbeam.Id.uuid4()
          wake = notice(txn, stream, event_id, "withdrawn", p[:actor_assignment_id])

          append_stream(
            txn,
            stream,
            call,
            "withdrawn",
            p,
            payload,
            request,
            wake.wake_id,
            event_id
          )
        end
      end)
    end
  end

  defp renotify(db, call) do
    p = call.params

    allowed =
      ~w(activation_id predecessor_event_id noticed_event_id replaces_wake_id idempotency_key)a

    with :ok <- exact_keys(p, allowed, allowed),
         :ok <- principal_kind(call.principal),
         :ok <- token(p.activation_id, 200),
         :ok <- token(p.predecessor_event_id, 200),
         :ok <- token(p.noticed_event_id, 200),
         :ok <- token(p.replaces_wake_id, 200),
         :ok <- idempotency_key(p.idempotency_key) do
      payload = %{"noticedEventId" => p.noticed_event_id, "replacesWakeId" => p.replaces_wake_id}
      request = semantic("activation-renotify", p, payload)

      stream_write(db, call, "notice-requeued", p.idempotency_key, request, fn txn, stream ->
        noticed = find_event(stream, p.noticed_event_id)

        with :ok <- require_head(stream, p.predecessor_event_id),
             true <-
               (noticed && noticed.kind in @noticed_kinds) or error("activation_notice_refused"),
             :ok <- full_read(txn, call.principal, stream),
             :ok <- renotify_caller(txn, call.principal, stream, noticed),
             :ok <- unacknowledged(stream, p.noticed_event_id),
             :ok <- linked_canceled_wake(txn, stream, p.noticed_event_id, p.replaces_wake_id) do
          event_id = "aev_" <> Tightbeam.Id.uuid4()
          wake = notice(txn, stream, event_id, "notice-requeued", nil, p.noticed_event_id)

          append_stream(
            txn,
            stream,
            call,
            "notice-requeued",
            p,
            payload,
            request,
            wake.wake_id,
            event_id
          )
        else
          false -> error("activation_notice_refused")
          other -> other
        end
      end)
    end
  end

  defp acknowledge(db, call) do
    p = call.params

    allowed =
      ~w(activation_id predecessor_event_id noticed_event_id acknowledged_wake_id idempotency_key)a

    with :ok <- exact_keys(p, allowed, allowed),
         :ok <- principal_kind(call.principal),
         :ok <- token(p.activation_id, 200),
         :ok <- token(p.predecessor_event_id, 200),
         :ok <- token(p.noticed_event_id, 200),
         :ok <- token(p.acknowledged_wake_id, 200),
         :ok <- idempotency_key(p.idempotency_key) do
      payload = %{
        "noticedEventId" => p.noticed_event_id,
        "acknowledgedWakeId" => p.acknowledged_wake_id
      }

      request = semantic("activation-ack", p, payload)

      stream_write(db, call, "acknowledged", p.idempotency_key, request, fn txn, stream ->
        noticed = find_event(stream, p.noticed_event_id)

        with :ok <- require_head(stream, p.predecessor_event_id),
             true <-
               (noticed && noticed.kind in @noticed_kinds) or error("activation_notice_refused"),
             :ok <- full_read(txn, call.principal, stream),
             :ok <- owner_caller(txn, call.principal, stream.owner_user_id),
             :ok <- unacknowledged(stream, p.noticed_event_id),
             :ok <- linked_fired_wake(txn, stream, p.noticed_event_id, p.acknowledged_wake_id) do
          append_stream(txn, stream, call, "acknowledged", p, payload, request, nil)
        else
          false -> error("activation_notice_refused")
          other -> other
        end
      end)
    end
  end

  defp recovery_write(db, call, kind, p, payload, request, lifecycle?) do
    stream_write(db, call, kind, p.idempotency_key, request, fn txn, stream ->
      with :ok <- require_head(stream, p.predecessor_event_id),
           true <- lifecycle?.(stream) or error("activation_transition_refused"),
           :ok <- full_read(txn, call.principal, stream),
           :ok <- recovery_caller(txn, call.principal, stream, p[:actor_assignment_id]) do
        event_id = "aev_" <> Tightbeam.Id.uuid4()
        wake = notice(txn, stream, event_id, kind, p[:actor_assignment_id])
        append_stream(txn, stream, call, kind, p, payload, request, wake.wake_id, event_id)
      else
        false -> error("activation_transition_refused")
        other -> other
      end
    end)
  end

  defp common_recovery_params(p, principal) do
    with :ok <- principal_kind(principal),
         :ok <- token(p.activation_id, 200),
         :ok <- token(p.predecessor_event_id, 200),
         :ok <- optional_token(p[:actor_assignment_id], 200),
         :ok <- token(p[:attempt_event_id] || p[:observed_event_id], 200),
         :ok <- idempotency_key(p.idempotency_key),
         do: :ok
  end

  # Replay is deliberately the first database-dependent operation. A matching
  # key returns the original prefix result even if access or lifecycle changed.
  defp write(db, call, kind, key, request, fun) do
    digest = digest(request)

    case DB.transaction(db, fn txn ->
           case replay(txn, call.principal, kind, key) do
             nil -> fun.(txn)
             event when event.request_sha256 == digest -> success(txn, event, event.seq)
             _event -> error("idempotency_conflict")
           end
         end) do
      {:ok, result} -> result
      {:error, exception} -> raise exception
    end
  end

  defp stream_write(db, call, kind, key, request, fun) do
    write(db, call, kind, key, request, fn txn ->
      case stream(txn, call.params.activation_id) do
        nil ->
          error("not_found")

        stream ->
          case full_read(txn, call.principal, stream) do
            :ok -> fun.(txn, stream)
            refusal -> refusal
          end
      end
    end)
  end

  defp append_stream(
         txn,
         stream,
         call,
         kind,
         p,
         payload,
         request,
         notice_wake_id,
         event_id \\ nil
       ) do
    append(txn, %{
      activation_id: stream.activation_id,
      event_id: event_id,
      predecessor_id: p.predecessor_event_id,
      root_assignment_id: stream.root_assignment_id,
      work_item_id: stream.work_item_id,
      actor_assignment_id: p[:actor_assignment_id],
      principal: call.principal,
      kind: kind,
      key: p.idempotency_key,
      digest: digest(request),
      payload: payload,
      notice_wake_id: notice_wake_id
    })
  end

  defp append(txn, input) do
    event_id = input[:event_id] || "aev_" <> Tightbeam.Id.uuid4()
    {by_session, by_user} = principal_columns(input.principal)
    ts = System.system_time(:millisecond)

    Txn.q(
      txn,
      """
      INSERT INTO activation_events
        (eventId, activationId, kind, predecessorEventId, rootAssignmentId, workItemId,
         actorAssignmentId, bySession, byUser, idempotencyKey, requestSha256, payload,
         noticeWakeId, ts)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)
      """,
      [
        event_id,
        input.activation_id,
        input.kind,
        input.predecessor_id,
        input.root_assignment_id,
        input.work_item_id,
        input.actor_assignment_id,
        by_session,
        by_user,
        input.key,
        input.digest,
        canonical(input.payload),
        input.notice_wake_id,
        ts
      ]
    )

    [[seq]] = Txn.q(txn, "SELECT seq FROM activation_events WHERE eventId=?1", [event_id])
    success(txn, event(txn, event_id), seq)
  end

  defp success(txn, event, through_seq) do
    stream = stream(txn, event.activation_id, through_seq)
    %{event: public_event(event), state: stream.state}
  end

  defp replay(txn, principal, kind, key) do
    {session, user} = principal_columns(principal)

    rows =
      if session do
        Txn.q(txn, select_events() <> " WHERE kind=?1 AND bySession=?2 AND idempotencyKey=?3", [
          kind,
          session,
          key
        ])
      else
        Txn.q(txn, select_events() <> " WHERE kind=?1 AND byUser=?2 AND idempotencyKey=?3", [
          kind,
          user,
          key
        ])
      end

    case rows do
      [row] -> row_event(row)
      [] -> nil
    end
  end

  defp stream(txn, activation_id, through_seq \\ nil) do
    suffix = if through_seq, do: " AND seq <= ?2", else: ""
    params = if through_seq, do: [activation_id, through_seq], else: [activation_id]

    rows =
      Txn.q(txn, select_events() <> " WHERE activationId=?1" <> suffix <> " ORDER BY seq", params)

    case Enum.map(rows, &row_event/1) do
      [] ->
        nil

      events ->
        declared = hd(events)

        %{
          activation_id: activation_id,
          root_assignment_id: declared.root_assignment_id,
          work_item_id: declared.work_item_id,
          owner_user_id: declared.payload["ownerUserId"],
          events: events,
          head: List.last(events).event_id,
          state: derive_state(events)
        }
    end
  end

  defp derive_state(events) do
    cond do
      Enum.any?(events, &(&1.kind == "withdrawn")) ->
        "withdrawn"

      Enum.any?(events, &(&1.kind == "reconciled")) ->
        "observed"

      observation = Enum.find(events, &(&1.kind == "observed")) ->
        if observation.payload["certainty"] == "indeterminate",
          do: "needs-reconciliation",
          else: "observed"

      Enum.any?(events, &(&1.kind == "attempted")) ->
        "attempted"

      true ->
        "declared"
    end
  end

  defp require_head(stream, expected) do
    if stream.head == expected,
      do: :ok,
      else: error("activation_head_changed", current_head: stream.head)
  end

  defp require_state(stream, states) do
    if stream.state in states, do: :ok, else: error("activation_transition_refused")
  end

  defp declaration_assignment(txn, principal, assignment_id, owner_user_id) do
    case Txn.q(
           txn,
           """
           SELECT a.holderKey, a.state, a.workItemId, wi.state, wi.ownerUserId, s.ownerUserId
           FROM assignments a JOIN work_items wi ON wi.id=a.workItemId
           JOIN sessions s ON s.sessionKey=a.holderKey WHERE a.id=?1
           """,
           [assignment_id]
         ) do
      [[holder, "open", work_item_id, "open", work_owner, holder_owner]] ->
        cond do
          principal != {:session, holder} -> error("activation_assignment_refused")
          owner_user_id not in [work_owner, holder_owner] -> error("activation_owner_refused")
          true -> {:ok, work_item_id}
        end

      _ ->
        error("activation_assignment_refused")
    end
  end

  defp declaration_prior(_txn, _principal, nil, _work_item_id), do: :ok

  defp declaration_prior(
         txn,
         principal,
         %{"activationId" => id, "relation" => relation},
         work_item_id
       ) do
    case stream(txn, id) do
      nil ->
        error("not_found")

      prior when prior.work_item_id != work_item_id ->
        error("not_found")

      prior when relation in ~w(retry-of compensates) ->
        case full_read(txn, principal, prior),
          do: (
            :ok -> :ok
            _ -> error("not_found")
          )

      prior when relation == "supersedes" and prior.state in @terminal_states ->
        :ok

      _ ->
        error("not_found")
    end
  end

  defp full_read(txn, principal, stream) do
    if readable?(txn, principal, stream), do: :ok, else: error("not_found")
  end

  defp readable?(txn, principal, stream) do
    owner_caller?(txn, principal, stream.owner_user_id) or
      work_owner_caller?(txn, principal, stream.work_item_id) or
      assignment_reader?(txn, principal, stream) or
      filer?(principal, stream.events) or admin_caller?(txn, principal)
  end

  defp assignment_reader?(txn, {:session, session}, stream) do
    Enum.any?([stream.root_assignment_id | Enum.map(stream.events, & &1.actor_assignment_id)], fn
      nil ->
        false

      id ->
        match?([[^session]], Txn.q(txn, "SELECT holderKey FROM assignments WHERE id=?1", [id]))
    end)
  end

  defp assignment_reader?(txn, {:user, user}, stream) do
    Enum.any?([stream.root_assignment_id | Enum.map(stream.events, & &1.actor_assignment_id)], fn
      nil ->
        false

      id ->
        match?(
          [[^user]],
          Txn.q(
            txn,
            "SELECT s.ownerUserId FROM assignments a JOIN sessions s ON s.sessionKey=a.holderKey WHERE a.id=?1",
            [id]
          )
        )
    end)
  end

  defp assignment_reader?(_, _, _), do: false

  defp filer?({:session, session}, events), do: Enum.any?(events, &(&1.by_session == session))
  defp filer?({:user, user}, events), do: Enum.any?(events, &(&1.by_user == user))
  defp filer?(_, _), do: false

  defp owner_caller(txn, principal, owner),
    do: if(owner_caller?(txn, principal, owner), do: :ok, else: error("activation_owner_refused"))

  defp owner_caller?(_txn, {:user, owner}, owner), do: true
  defp owner_caller?(txn, {:session, session}, owner), do: session_owner(txn, session) == owner
  defp owner_caller?(_, _, _), do: false

  defp work_owner_caller?(txn, principal, work_item_id) do
    case Txn.q(txn, "SELECT ownerUserId FROM work_items WHERE id=?1", [work_item_id]) do
      [[owner]] -> owner_caller?(txn, principal, owner)
      _ -> false
    end
  end

  defp admin_caller?(txn, {:user, user}), do: admin_user?(txn, user)
  defp admin_caller?(txn, {:session, session}), do: admin_user?(txn, session_owner(txn, session))
  defp admin_caller?(_, _), do: false

  defp admin_user?(txn, user),
    do: match?([[1]], Txn.q(txn, "SELECT isAdmin FROM users WHERE userId=?1", [user]))

  defp session_owner(txn, session) do
    case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [session]) do
      [[owner]] -> owner
      _ -> nil
    end
  end

  defp authority_caller(txn, principal, stream, actor_assignment_id) do
    with :ok <- authority_actor(txn, principal, stream, actor_assignment_id) do
      cond do
        admin_caller?(txn, principal) or owner_caller?(txn, principal, stream.owner_user_id) or
            work_owner_caller?(txn, principal, stream.work_item_id) ->
          :ok

        match?({:session, _}, principal) and is_binary(actor_assignment_id) ->
          held_actor(txn, principal, stream, actor_assignment_id)

        true ->
          error("activation_authority_refused")
      end
    end
  end

  defp authority_actor(_txn, _principal, _stream, nil), do: :ok

  defp authority_actor(txn, {:session, _} = principal, stream, assignment_id),
    do: held_actor(txn, principal, stream, assignment_id)

  defp authority_actor(txn, {:user, user}, stream, assignment_id) do
    case Txn.q(
           txn,
           "SELECT a.state,a.workItemId,s.ownerUserId FROM assignments a JOIN sessions s ON s.sessionKey=a.holderKey WHERE a.id=?1",
           [assignment_id]
         ) do
      [["open", work_item_id, ^user]] when work_item_id == stream.work_item_id -> :ok
      _ -> error("activation_assignment_refused")
    end
  end

  defp held_actor(txn, {:session, session}, stream, assignment_id) do
    case Txn.q(txn, "SELECT holderKey,state,workItemId FROM assignments WHERE id=?1", [
           assignment_id
         ]) do
      [[^session, "open", work_item_id]] when work_item_id == stream.work_item_id -> :ok
      _ -> error("activation_assignment_refused")
    end
  end

  defp held_actor(_, _, _, _), do: error("activation_assignment_refused")

  defp recovery_caller(txn, principal, stream, assignment_id) do
    with :ok <- recovery_assignment(txn, principal, stream, assignment_id) do
      cond do
        attempt_principal?(txn, principal, stream) ->
          :ok

        work_owner_caller?(txn, principal, stream.work_item_id) ->
          :ok

        match?({:session, _}, principal) and is_binary(assignment_id) ->
          held_actor(txn, principal, stream, assignment_id)

        true ->
          error("activation_assignment_refused")
      end
    end
  end

  defp recovery_assignment(_txn, _principal, _stream, nil), do: :ok

  defp recovery_assignment(txn, principal, stream, assignment_id) do
    case Txn.q(
           txn,
           "SELECT a.holderKey,a.workItemId,s.ownerUserId FROM assignments a JOIN sessions s ON s.sessionKey=a.holderKey WHERE a.id=?1",
           [assignment_id]
         ) do
      [[holder, work_item_id, owner]] when work_item_id == stream.work_item_id ->
        if principal in [{:session, holder}, {:user, owner}],
          do: :ok,
          else: error("activation_assignment_refused")

      _ ->
        error("activation_assignment_refused")
    end
  end

  defp attempt_principal?(txn, principal, stream) do
    attempted = Enum.find(stream.events, &(&1.kind == "attempted"))

    case attempted && event_principal(attempted) do
      {:session, session} -> owner_caller?(txn, principal, session_owner(txn, session))
      {:user, user} -> principal == {:user, user}
      _ -> false
    end
  end

  defp withdrawal_caller(txn, principal, stream, actor_assignment_id) do
    with :ok <- authority_actor(txn, principal, stream, actor_assignment_id) do
      cond do
        work_owner_caller?(txn, principal, stream.work_item_id) ->
          :ok

        match?({:session, _}, principal) and is_binary(actor_assignment_id) ->
          held_actor(txn, principal, stream, actor_assignment_id)

        true ->
          error("activation_assignment_refused")
      end
    end
  end

  defp renotify_caller(txn, principal, stream, noticed) do
    cond do
      admin_caller?(txn, principal) -> :ok
      owner_caller?(txn, principal, stream.owner_user_id) -> :ok
      work_owner_caller?(txn, principal, stream.work_item_id) -> :ok
      principal == event_principal(noticed) -> :ok
      true -> error("activation_notice_refused")
    end
  end

  defp authority_events(stream, ids) do
    actual =
      stream.events
      |> Enum.filter(&(&1.kind == "authority-attached"))
      |> Enum.map(& &1.event_id)
      |> Enum.filter(&(&1 in ids))

    if ids == actual and length(ids) == length(Enum.uniq(ids)),
      do: :ok,
      else: error("activation_authority_refused")
  end

  defp notice(txn, stream, _event_id, kind, actor_assignment_id, noticed_event_id \\ nil) do
    target = Tightbeam.Org.personal_session_key(stream.owner_user_id)

    named_kind =
      if kind == "notice-requeued", do: find_event(stream, noticed_event_id).kind, else: kind

    Wakes.schedule_in_txn(txn, %{
      session_key: target,
      origin: "process:tightbeam",
      prompt:
        "Activation #{stream.activation_id} recorded #{named_kind}. Run tightbeam activation-status --activation #{stream.activation_id}.",
      due_at: System.system_time(:millisecond),
      target_gate: 0,
      work_item_id: stream.work_item_id,
      assignment_id: actor_assignment_id
    })
  end

  defp unacknowledged(stream, noticed_event_id) do
    if Enum.any?(
         stream.events,
         &(&1.kind == "acknowledged" and &1.payload["noticedEventId"] == noticed_event_id)
       ), do: error("activation_notice_refused"), else: :ok
  end

  defp linked_canceled_wake(txn, stream, noticed_event_id, wake_id) do
    with true <- linked_wake?(stream, noticed_event_id, wake_id),
         [["canceled"]] <- Txn.q(txn, "SELECT state FROM wakes WHERE wakeId=?1", [wake_id]),
         false <-
           Enum.any?(
             stream.events,
             &(&1.kind == "notice-requeued" and &1.payload["replacesWakeId"] == wake_id)
           ) do
      :ok
    else
      _ -> error("activation_notice_refused")
    end
  end

  defp linked_fired_wake(txn, stream, noticed_event_id, wake_id) do
    if linked_wake?(stream, noticed_event_id, wake_id) and
         match?([["fired"]], Txn.q(txn, "SELECT state FROM wakes WHERE wakeId=?1", [wake_id])),
       do: :ok,
       else: error("activation_notice_refused")
  end

  defp linked_wake?(stream, noticed_event_id, wake_id) do
    case find_event(stream, noticed_event_id) do
      %{notice_wake_id: ^wake_id} ->
        true

      _ ->
        Enum.any?(
          stream.events,
          &(&1.kind == "notice-requeued" and &1.payload["noticedEventId"] == noticed_event_id and
              &1.notice_wake_id == wake_id)
        )
    end
  end

  defp status(db, call) do
    p = call.params

    with :ok <- exact_keys(p, [:activation_id], [:activation_id]),
         :ok <- principal_kind(call.principal),
         :ok <- token(p.activation_id, 200),
         {:ok, result} <- read_status(db, call.principal, p.activation_id),
         do: result
  end

  defp read_status(db, principal, activation_id) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        case stream(txn, activation_id) do
          nil ->
            error("not_found")

          stream ->
            if readable?(txn, principal, stream),
              do: status_result(txn, stream),
              else: error("not_found")
        end
      end)

    {:ok, result}
  end

  defp status_result(txn, stream) do
    notices =
      stream.events
      |> Enum.filter(&(&1.kind in @noticed_kinds))
      |> Enum.map(fn noticed ->
        wakes = [
          noticed.notice_wake_id
          | Enum.flat_map(stream.events, fn e ->
              if e.kind == "notice-requeued" and e.payload["noticedEventId"] == noticed.event_id,
                do: [e.notice_wake_id],
                else: []
            end)
        ]

        states =
          Map.new(wakes, fn wake_id ->
            state =
              case Txn.q(txn, "SELECT state FROM wakes WHERE wakeId=?1", [wake_id]) do
                [[s]] -> s
                _ -> "missing"
              end

            {wake_id, state}
          end)

        ack =
          Enum.find(
            stream.events,
            &(&1.kind == "acknowledged" and &1.payload["noticedEventId"] == noticed.event_id)
          )

        %{
          noticed_event_id: noticed.event_id,
          wake_states: states,
          acknowledged_event_id: ack && ack.event_id
        }
      end)

    %{
      activation_id: stream.activation_id,
      state: stream.state,
      head_event_id: stream.head,
      root_assignment_id: stream.root_assignment_id,
      work_item_id: stream.work_item_id,
      events: Enum.map(stream.events, &public_event/1),
      notices: notices
    }
  end

  defp list(db, call) do
    p = call.params

    with :ok <- exact_keys(p, ~w(assignment_id work_item_id correlation_key)a, []),
         true <-
           Enum.count([p[:assignment_id], p[:work_item_id], p[:correlation_key]], &is_binary/1) <=
             1 or error("invalid_activation_payload"),
         :ok <- principal_kind(call.principal),
         :ok <- optional_token(p[:assignment_id], 200),
         :ok <- optional_token(p[:work_item_id], 200),
         :ok <- optional_token(p[:correlation_key], 200) do
      {:ok, result} =
        DB.transaction(db, fn txn ->
          ids =
            Txn.q(
              txn,
              "SELECT DISTINCT activationId FROM activation_events ORDER BY activationId"
            )
            |> List.flatten()

          activations =
            ids
            |> Enum.map(&stream(txn, &1))
            |> Enum.filter(&list_match?(&1, p))
            |> Enum.filter(&readable?(txn, call.principal, &1))
            |> Enum.map(&summary/1)

          %{activations: activations, count: length(activations)}
        end)

      result
    else
      false -> error("invalid_activation_payload")
      other -> other
    end
  end

  defp list_match?(stream, p) do
    cond do
      is_binary(p[:assignment_id]) ->
        stream.root_assignment_id == p.assignment_id or
          Enum.any?(stream.events, &(&1.actor_assignment_id == p.assignment_id))

      is_binary(p[:work_item_id]) ->
        stream.work_item_id == p.work_item_id

      is_binary(p[:correlation_key]) ->
        hd(stream.events).payload["correlationKey"] == p.correlation_key

      true ->
        true
    end
  end

  defp summary(stream),
    do: %{
      activation_id: stream.activation_id,
      state: stream.state,
      head_event_id: stream.head,
      root_assignment_id: stream.root_assignment_id,
      work_item_id: stream.work_item_id
    }

  @doc false
  def trace_entries(db, work_item_id) do
    {:ok, rows} =
      DB.query(db, select_events() <> " WHERE workItemId=?1 ORDER BY seq", [work_item_id])

    events = Enum.map(rows, &row_event/1)

    Enum.map(events, fn event ->
      replacements =
        Enum.filter(
          events,
          &(&1.kind == "notice-requeued" and
              &1.payload["noticedEventId"] == event.event_id)
        )

      latest_notice = List.last(replacements)
      wake_id = (latest_notice && latest_notice.notice_wake_id) || event.notice_wake_id

      notice_state =
        if wake_id do
          case Wakes.get(db, wake_id) do
            nil -> "missing"
            wake -> wake.state
          end
        end

      acknowledgement =
        Enum.find(
          events,
          &(&1.kind == "acknowledged" and &1.payload["noticedEventId"] == event.event_id)
        )

      %{
        at: event.ts,
        seqTiebreak: event.seq,
        type: "activation_event",
        id: event.event_id,
        activationId: event.activation_id,
        kind: event.kind,
        principal: principal_ref(event),
        assignmentId: event.actor_assignment_id,
        noticeState: notice_state,
        acknowledgedEventId: acknowledgement && acknowledgement.event_id
      }
    end)
  end

  defp semantic(verb, p, payload) do
    %{
      "verb" => verb,
      "activationId" => p.activation_id,
      "predecessorEventId" => p.predecessor_event_id,
      "actorAssignmentId" => p[:actor_assignment_id],
      "payload" => payload
    }
  end

  defp exact_keys(map, allowed, required) when is_map(map) do
    keys = Map.keys(map)

    if Enum.all?(keys, &(&1 in allowed)) and Enum.all?(required, &Map.has_key?(map, &1)),
      do: :ok,
      else: error("invalid_activation_payload")
  end

  defp exact_keys(_, _, _), do: error("invalid_activation_payload")

  defp principal_kind({kind, id}) when kind in [:session, :user] and is_binary(id), do: :ok
  defp principal_kind(_), do: error("invalid_activation_payload")
  defp principal_columns({:session, id}), do: {id, nil}
  defp principal_columns({:user, id}), do: {nil, id}

  defp idempotency_key(value), do: token(value, 200, "invalid_idempotency_key")

  defp token(value, max, code \\ "invalid_activation_payload") do
    if is_binary(value) and byte_size(value) <= max and Regex.match?(@opaque_token, value),
      do: :ok,
      else: error(code)
  end

  defp optional_token(nil, _max), do: :ok
  defp optional_token(value, max), do: token(value, max)

  defp token_list(values, min, max)
       when is_list(values) and length(values) >= min and length(values) <= max do
    if Enum.all?(values, &(token(&1, 200) == :ok)) and
         length(values) == length(Enum.uniq(values)),
       do: {:ok, values},
       else: error("invalid_activation_payload")
  end

  defp token_list(_, _, _), do: error("invalid_activation_payload")

  defp domain_identity(%{"namespace" => namespace, "id" => id} = map) when map_size(map) == 2 do
    if is_binary(namespace) and Regex.match?(@namespace, namespace) and token(id, 512) == :ok,
      do: {:ok, map},
      else: error("invalid_activation_payload")
  end

  defp domain_identity(_), do: error("invalid_activation_payload")

  defp namespace_value(namespace) when is_binary(namespace) do
    if Regex.match?(@namespace, namespace),
      do: {:ok, namespace},
      else: error("invalid_activation_payload")
  end

  defp namespace_value(_), do: error("invalid_activation_payload")

  defp domain_code(%{"namespace" => namespace, "code" => code} = map) when map_size(map) == 2 do
    if is_binary(namespace) and Regex.match?(@namespace, namespace) and token(code, 64) == :ok,
      do: {:ok, map},
      else: error("invalid_activation_payload")
  end

  defp domain_code(_), do: error("invalid_activation_payload")

  defp resource_ref(%{"namespace" => namespace, "id" => id, "sha256" => sha} = map, required?)
       when map_size(map) == 3 do
    valid_sha =
      if required?,
        do: is_binary(sha) and Regex.match?(@sha, sha),
        else: is_nil(sha) or (is_binary(sha) and Regex.match?(@sha, sha))

    if is_binary(namespace) and Regex.match?(@namespace, namespace) and token(id, 512) == :ok and
         valid_sha, do: {:ok, map}, else: error("invalid_activation_payload")
  end

  defp resource_ref(_, _), do: error("invalid_activation_payload")
  defp nullable_resource_ref(nil, _required?), do: {:ok, nil}
  defp nullable_resource_ref(value, required?), do: resource_ref(value, required?)

  defp resource_list(values, min, max, required?)
       when is_list(values) and length(values) >= min and length(values) <= max do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case resource_ref(value, required?) do
        {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp resource_list(_, _, _, _), do: error("invalid_activation_payload")

  defp prior(nil, nil), do: {:ok, nil}

  defp prior(id, relation) when is_binary(id) and relation in @relations do
    with :ok <- token(id, 200), do: {:ok, %{"activationId" => id, "relation" => relation}}
  end

  defp prior(_, _), do: error("invalid_activation_payload")
  defp nullable_ms(nil), do: :ok

  defp nullable_ms(value)
       when is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807, do: :ok

  defp nullable_ms(_), do: error("invalid_activation_payload")

  defp event_kind?(stream, id, kind), do: match?(%{kind: ^kind}, find_event(stream, id))
  defp event_payload(stream, id), do: find_event(stream, id).payload
  defp find_event(stream, id), do: Enum.find(stream.events, &(&1.event_id == id))
  defp event_principal(%{by_session: session}) when is_binary(session), do: {:session, session}
  defp event_principal(%{by_user: user}), do: {:user, user}

  defp event(txn, id) do
    [row] = Txn.q(txn, select_events() <> " WHERE eventId=?1", [id])
    row_event(row)
  end

  defp select_events do
    "SELECT seq,eventId,activationId,kind,predecessorEventId,rootAssignmentId,workItemId," <>
      "actorAssignmentId,bySession,byUser,idempotencyKey,requestSha256,payload,noticeWakeId,ts FROM activation_events"
  end

  defp row_event([
         seq,
         event_id,
         activation_id,
         kind,
         predecessor_id,
         root_assignment_id,
         work_item_id,
         actor_assignment_id,
         by_session,
         by_user,
         key,
         request_sha,
         payload,
         notice_wake_id,
         ts
       ]) do
    %{
      seq: seq,
      event_id: event_id,
      activation_id: activation_id,
      kind: kind,
      predecessor_event_id: predecessor_id,
      root_assignment_id: root_assignment_id,
      work_item_id: work_item_id,
      actor_assignment_id: actor_assignment_id,
      by_session: by_session,
      by_user: by_user,
      idempotency_key: key,
      request_sha256: request_sha,
      payload: JSON.decode!(payload),
      notice_wake_id: notice_wake_id,
      ts: ts
    }
  end

  defp public_event(event),
    do:
      Map.take(
        event,
        ~w(seq event_id activation_id kind predecessor_event_id root_assignment_id work_item_id actor_assignment_id by_session by_user payload notice_wake_id ts)a
        |> Kernel.++(~w(idempotency_key request_sha256)a)
      )

  defp principal_ref(%{by_session: session}) when is_binary(session), do: "session:" <> session
  defp principal_ref(%{by_user: user}), do: "user:" <> user

  defp digest(value), do: :crypto.hash(:sha256, canonical(value)) |> Base.encode16(case: :lower)

  # The contract's semantic objects contain only integers, strings, nulls,
  # arrays, and ASCII field names. This is the complete JCS subset they need:
  # UTF-8 JSON strings and lexicographically sorted object member names.
  defp canonical(nil), do: "null"
  defp canonical(true), do: "true"
  defp canonical(false), do: "false"
  defp canonical(value) when is_integer(value), do: Integer.to_string(value)
  defp canonical(value) when is_binary(value), do: JSON.encode!(value)

  defp canonical(values) when is_list(values),
    do: "[" <> Enum.map_join(values, ",", &canonical/1) <> "]"

  defp canonical(map) when is_map(map) do
    "{" <>
      (map
       |> Enum.sort_by(fn {key, _} -> key end)
       |> Enum.map_join(",", fn {key, value} ->
         canonical(to_string(key)) <> ":" <> canonical(value)
       end)) <> "}"
  end

  defp error(code, fields \\ []) when code in @error_codes,
    do: fields |> Map.new() |> Map.put(:code, code)

  defp kind_for_verb("activation-declare"), do: "declared"
  defp kind_for_verb("activation-authority"), do: "authority-attached"
  defp kind_for_verb("activation-attempt"), do: "attempted"
  defp kind_for_verb("activation-observe"), do: "observed"
  defp kind_for_verb("activation-reconcile"), do: "reconciled"
  defp kind_for_verb("activation-withdraw"), do: "withdrawn"
  defp kind_for_verb("activation-renotify"), do: "notice-requeued"
  defp kind_for_verb("activation-ack"), do: "acknowledged"
  defp kind_for_verb(_), do: nil

  defp maybe_put_activation_id(map, id) when is_binary(id),
    do: Map.put(map, :activation_id, id)

  defp maybe_put_activation_id(map, _id), do: map
end
