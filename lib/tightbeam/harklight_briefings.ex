defmodule Tightbeam.HarklightBriefings do
  @moduledoc false

  alias Tightbeam.{DB, Devices, Escalation, Id, Org, Placement, Rules, Wakes}
  alias Tightbeam.DB.Txn

  @rule_name "harklight-decision-request-briefing"
  @wake_origin "remedy:" <> @rule_name
  @request_id ~r/\Adr_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  @admission_limit 100

  @ddl """
  CREATE TABLE IF NOT EXISTS harklight_decision_briefings (
    requestId TEXT PRIMARY KEY,
    ownerUserId TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN (
      'staged','reuse_staged','admitted','reserved','pending','bound',
      'reused','unresolved','excluded'
    )),
    disposition TEXT NOT NULL,
    actorSessionKey TEXT,
    sessionKey TEXT,
    wakeId TEXT,
    sendOpId TEXT,
    handle TEXT,
    senderId TEXT,
    messageId TEXT,
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL
  );
  CREATE UNIQUE INDEX IF NOT EXISTS harklight_decision_briefings_operation
    ON harklight_decision_briefings(sendOpId) WHERE sendOpId IS NOT NULL;
  CREATE INDEX IF NOT EXISTS harklight_decision_briefings_thread
    ON harklight_decision_briefings(handle,senderId,messageId);
  """

  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Stage every visible request for the authenticated owner and admit at most `limit` new wakes."
  def catchup(db, call, opts \\ []) do
    limit = call.params[:limit] || 0

    with :ok <- active_admin_origin(db, call, Keyword.get(opts, :authorized, false)),
         true <- is_integer(limit) and limit >= 0 and limit <= @admission_limit,
         {:ok, owner_user_id} <- owner_user_id(db, call),
         requests when is_list(requests) <- Escalation.list(db, call, "all"),
         {:ok, operations} <- send_operations(db) do
      rule = briefing_rule(owner_user_id)

      reconciled =
        requests
        |> Enum.sort_by(&{Map.get(&1, :raised_at, 0), Map.get(&1, :id, "")})
        |> Enum.map(fn listed ->
          safely_reconcile_listed(db, call, owner_user_id, listed.id, operations, rule)
        end)

      candidates = Enum.filter(reconciled, &(&1.state in ["staged", "reuse_staged"]))
      to_admit = Enum.take(candidates, limit) |> MapSet.new(& &1.request_id)

      final =
        Enum.map(reconciled, fn entry ->
          if MapSet.member?(to_admit, entry.request_id) do
            admit(db, call, owner_user_id, entry.request_id, rule)
          else
            entry
          end
        end)

      report(owner_user_id, limit, length(requests), final)
    else
      false -> failure("invalid_harklight_briefing_limit", "limit must be between 0 and 100")
      {:error, code, message} -> failure(code, message)
      %{code: code, message: message} -> failure(code, message)
      requests when is_map(requests) -> requests
      _ -> failure("harklight_briefing_catchup_unavailable", "request enumeration failed")
    end
  rescue
    error -> failure("harklight_briefing_catchup_unavailable", Exception.message(error))
  end

  @doc false
  def reserve_send(db, call, request_id) do
    with true <- Regex.match?(@request_id, request_id || ""),
         :ok <- authenticated_origin(db, call),
         {:ok, owner_user_id} <- owner_user_id(db, call) do
      now = System.system_time(:millisecond)
      wake_id = wake_id(request_id)

      case DB.transaction(db, fn txn ->
             reserve_send_in_txn(txn, call, owner_user_id, request_id, wake_id, now)
           end) do
        {:ok, {:ok, result}} ->
          {:ok, result}

        {:ok, {:error, code, message}} ->
          {:error, code, message}

        {:error, reason} ->
          {:error, "harklight_briefing_association_unavailable", inspect(reason)}
      end
    else
      false -> {:error, "invalid_harklight_decision_request", "decision request ID is invalid"}
      {:error, code, message} -> {:error, code, message}
    end
  end

  @doc false
  def validate_send_binding_in_txn(
        %Txn{} = txn,
        op_id,
        session_key,
        payload,
        handle,
        sender_id,
        message_id
      ) do
    case decision_request_id(payload) do
      nil ->
        :ok

      request_id ->
        case Txn.q(
               txn,
               "SELECT state,sessionKey,sendOpId,handle,senderId,messageId FROM harklight_decision_briefings WHERE requestId=?1",
               [request_id]
             ) do
          [[state, ^session_key, ^op_id, old_handle, old_sender, old_message]]
          when state in ["reserved", "pending", "bound", "reused"] ->
            if compatible_identity?(
                 old_handle,
                 old_sender,
                 old_message,
                 handle,
                 sender_id,
                 message_id
               ),
               do: :ok,
               else: {:error, "harklight_briefing_association_mismatch"}

          _ ->
            {:error, "harklight_briefing_association_missing"}
        end
    end
  end

  @doc false
  def bind_send_in_txn(%Txn{} = txn, op_id, session_key, payload, handle, sender_id, message_id) do
    case decision_request_id(payload) do
      nil ->
        :ok

      request_id ->
        now = System.system_time(:millisecond)

        case Txn.q(
               txn,
               "SELECT ownerUserId,state,sessionKey,sendOpId,handle,senderId,messageId FROM harklight_decision_briefings WHERE requestId=?1",
               [request_id]
             ) do
          [[_owner, state, ^session_key, ^op_id, old_handle, old_sender, old_message]]
          when state in ["reserved", "pending", "bound", "reused"] ->
            if compatible_identity?(
                 old_handle,
                 old_sender,
                 old_message,
                 handle,
                 sender_id,
                 message_id
               ) do
              Txn.q(
                txn,
                "UPDATE harklight_decision_briefings SET state='bound',disposition='Harklight message and originating conversation are bound',handle=?2,senderId=?3,messageId=?4,updatedAt=?5 WHERE requestId=?1",
                [request_id, handle, sender_id, message_id, now]
              )

              :ok
            else
              {:error, "harklight_briefing_association_mismatch"}
            end

          _ ->
            {:error, "harklight_briefing_association_missing"}
        end
    end
  end

  @doc false
  def chat_prompt_context_in_txn(%Txn{} = txn, handle, sender_id, message_id) do
    case Txn.q(
           txn,
           "SELECT requestId,sessionKey FROM harklight_decision_briefings WHERE handle=?1 AND senderId=?2 AND messageId=?3 AND state IN ('bound','reused')",
           [handle, sender_id, message_id]
         ) do
      [[request_id, session_key]] ->
        case Txn.q(
               txn,
               "SELECT sessionKey FROM harklight_wake_handles WHERE handle=?1",
               [handle]
             ) do
          [[^session_key]] ->
            "\n\nThis Harklight thread is associated with decision request #{request_id}. Continue in this same session and thread. Reread the exact request and current status before acting. A question or ambiguous reply needs clarification in the thread and no ruling. For an explicit unambiguous answer to an open request, use `rule` for a statute request, `operator-rule` for an operator request, `effort-rule` for an effort request, or `answer` for an agent request, always as this same session. Preserve the user's exact words; quote the exact choice and cite this Harklight entry ID in ruling rationale, or include the exact answer and entry ID in an agent answer. Then reply in this Harklight thread with what was recorded. If the request is already resolved, withdrawn or superseded, explain the current state in the thread and preserve the existing result."

          _ ->
            ""
        end

      _ ->
        ""
    end
  end

  defp reserve_send_in_txn(txn, call, owner_user_id, request_id, wake_id, now) do
    request = Escalation.raw_by_id_in_txn(txn, request_id)
    existing = progress_in_txn(txn, request_id)
    operation = operation_in_txn(txn, existing && existing.send_op_id)

    cond do
      request == nil ->
        {:error, "decision_request_not_found", "decision request does not exist"}

      request.owner_user_id != owner_user_id ->
        {:error, "decision_request_owner_mismatch", "request is not owned by this session's user"}

      existing && existing.owner_user_id != owner_user_id ->
        {:error, "harklight_briefing_owner_mismatch",
         "stored request association has a different owner"}

      existing && existing.session_key && existing.session_key != call.session_key ->
        {:error, "harklight_briefing_origin_mismatch",
         "only the original compiling session can send this briefing"}

      operation && operation.state == "bound" ->
        with :ok <- bound_operation_matches?(operation, existing, request_id),
             :ok <-
               bind_send_in_txn(
                 txn,
                 operation.op_id,
                 operation.session_key,
                 operation.payload,
                 operation.handle,
                 operation.sender_id,
                 operation.message_id
               ) do
          {:ok,
           %{
             action: :existing,
             op_id: operation.op_id,
             handle: operation.handle,
             sender_id: operation.sender_id,
             message_id: operation.message_id,
             session_key: operation.session_key
           }}
        else
          _ ->
            {:error, "harklight_briefing_association_unresolved",
             "bound send does not match its durable request association"}
        end

      operation && operation.state == "pending" && is_integer(operation.attempted_at) ->
        if operation.session_key == call.session_key and
             decision_request_id(operation.payload) == request_id do
          {:ok, %{action: :recover, op_id: operation.op_id, message_id: operation.message_id}}
        else
          {:error, "harklight_briefing_association_unresolved",
           "pending operation cannot be reconciled to this request and session"}
        end

      request.status != "open" ->
        persist_in_txn(
          txn,
          request_id,
          owner_user_id,
          "excluded",
          "request is #{request.status}; no briefing was sent",
          call.session_key,
          call.session_key,
          wake_id,
          existing && existing.send_op_id,
          existing && existing.handle,
          existing && existing.sender_id,
          existing && existing.message_id,
          now
        )

        {:error, "decision_request_not_open",
         "request is no longer open; no new briefing was sent"}

      addressed_principal(request) != "user:" <> owner_user_id ->
        {:error, "decision_request_address_mismatch", "request is not addressed to this user"}

      not wake_matches_session_in_txn?(txn, wake_id, call.session_key) ->
        {:error, "harklight_briefing_route_unavailable",
         "the configured request wake is absent, canceled, or belongs to another session"}

      existing && existing.state in ["unresolved", "excluded"] ->
        {:error, "harklight_briefing_association_unresolved", existing.disposition}

      existing && existing.send_op_id && operation == nil &&
          existing.state not in ["reserved", "reuse_staged"] ->
        {:error, "harklight_briefing_association_unresolved",
         "stored Harklight operation is missing; refusing to prepare another send"}

      true ->
        op_id = (existing && existing.send_op_id) || Id.uuid4()

        persist_in_txn(
          txn,
          request_id,
          owner_user_id,
          "reserved",
          "original send operation reserved before Harklight preparation",
          call.session_key,
          call.session_key,
          wake_id,
          op_id,
          existing && existing.handle,
          existing && existing.sender_id,
          existing && existing.message_id,
          now
        )

        {:ok, %{action: :start, op_id: op_id}}
    end
  end

  defp reconcile_listed(db, call, owner_user_id, request_id, nil, _operations, _rule),
    do:
      put_entry(
        db,
        call,
        request_id,
        owner_user_id,
        "unresolved",
        "request detail disappeared during enumeration",
        %{}
      )

  defp reconcile_listed(
         db,
         call,
         owner_user_id,
         request_id,
         %{code: code, message: message},
         _operations,
         _rule
       ),
       do:
         put_entry(
           db,
           call,
           request_id,
           owner_user_id,
           "unresolved",
           "request detail refused: #{code}: #{message}",
           %{}
         )

  defp safely_reconcile_listed(db, call, owner_user_id, request_id, operations, rule) do
    request = Escalation.get(db, call, request_id)
    reconcile_listed(db, call, owner_user_id, request_id, request, operations, rule)
  rescue
    error ->
      put_entry(
        db,
        call,
        request_id,
        owner_user_id,
        "unresolved",
        "request reconciliation failed: #{Exception.message(error)}",
        %{}
      )
  catch
    kind, reason ->
      put_entry(
        db,
        call,
        request_id,
        owner_user_id,
        "unresolved",
        "request reconciliation failed (#{kind}): #{inspect(reason)}",
        %{}
      )
  end

  defp reconcile_listed(db, call, owner_user_id, _listed_id, request, operations, rule) do
    cond do
      request.owner_user_id != owner_user_id ->
        %{
          request_id: request.id,
          owner_user_id: request.owner_user_id,
          state: "excluded",
          disposition: "request is outside the authenticated owner's request set"
        }

      request.status != "open" ->
        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          "excluded",
          "request status is #{request.status}",
          %{}
        )

      addressed_principal(request) != "user:" <> owner_user_id ->
        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          "excluded",
          "request is addressed to #{addressed_principal(request)}",
          %{}
        )

      true ->
        reconcile_open(db, call, owner_user_id, request, operations, rule)
    end
  end

  defp reconcile_open(db, call, owner_user_id, request, operations, rule) do
    existing = progress(db, request.id)

    cond do
      existing && existing.send_op_id &&
          existing.state in ["reserved", "pending", "bound", "reused", "reuse_staged"] ->
        reconcile_stored_operation(db, call, owner_user_id, request, existing, rule)

      true ->
        case operation_candidates(operations, request.id) do
          [] ->
            existing_wake_state(db, call, owner_user_id, request, existing, rule)

          [candidate] when candidate.explicit_request_id == request.id ->
            reconcile_candidate(db, call, owner_user_id, request, candidate, rule)

          candidates ->
            put_entry(
              db,
              call,
              request.id,
              owner_user_id,
              "unresolved",
              "existing Harklight operation references this request without one unambiguous durable association",
              %{send_op_id: Enum.map(candidates, & &1.op_id) |> Enum.join(",")}
            )
        end
    end
  end

  defp reconcile_stored_operation(db, call, owner_user_id, request, existing, rule) do
    case operation_by_id(db, existing.send_op_id) do
      nil when existing.state in ["reserved", "reuse_staged"] ->
        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          "reuse_staged",
          "reserved operation has no local send attempt; resume the same operation ID in the original compiling session",
          Map.take(existing, [:session_key, :wake_id, :send_op_id])
        )

      nil ->
        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          "unresolved",
          "stored send operation is missing",
          Map.take(existing, [
            :session_key,
            :wake_id,
            :send_op_id,
            :handle,
            :sender_id,
            :message_id
          ])
        )

      %{state: "bound"} = operation ->
        case valid_thread(db, operation, owner_user_id) do
          :ok ->
            existing_wake_state(
              db,
              call,
              owner_user_id,
              request,
              Map.merge(existing, %{
                session_key: operation.session_key,
                send_op_id: operation.op_id,
                handle: operation.handle,
                sender_id: operation.sender_id,
                message_id: operation.message_id
              }),
              rule
            )

          {:error, reason} ->
            put_entry(
              db,
              call,
              request.id,
              owner_user_id,
              "unresolved",
              reason,
              Map.take(operation, [:session_key, :op_id, :handle, :sender_id, :message_id])
            )
        end

      %{state: "pending", attempted_at: attempted_at} = operation when is_integer(attempted_at) ->
        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          "pending",
          "original send is pending; existing Harklight recovery will settle operation #{operation.op_id}",
          Map.take(operation, [:session_key, :op_id, :handle, :sender_id, :message_id])
        )

      %{state: "pending"} = operation ->
        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          "reuse_staged",
          "prepared operation exists; resume its original operation in the original compiling session",
          Map.take(operation, [:session_key, :op_id, :handle, :sender_id, :message_id])
        )

      operation ->
        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          "unresolved",
          "existing send operation is in state #{operation.state}",
          Map.take(operation, [:session_key, :op_id, :handle, :sender_id, :message_id])
        )
    end
  end

  defp existing_wake_state(db, call, owner_user_id, request, existing, rule) do
    wake_id = wake_id(request.id)

    case wake(db, wake_id) do
      %{origin: @wake_origin, session_key: session_key, state: state}
      when state != "canceled" ->
        if is_nil(existing && existing.session_key) or session_key == existing.session_key do
          put_entry(
            db,
            call,
            request.id,
            owner_user_id,
            if(existing && existing.send_op_id, do: "reused", else: "admitted"),
            "existing request wake reconciled; no duplicate wake or Harklight message created",
            Map.merge(existing || %{}, %{wake_id: wake_id, session_key: session_key})
          )
        else
          put_entry(
            db,
            call,
            request.id,
            owner_user_id,
            "unresolved",
            "existing wake is bound to a different session than the original Harklight conversation",
            Map.merge(existing || %{}, %{wake_id: wake_id, session_key: session_key})
          )
        end

      %{origin: @wake_origin, state: "canceled"} ->
        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          "unresolved",
          "request wake was canceled; refusing to mint a replacement identity",
          Map.merge(existing || %{}, %{wake_id: wake_id})
        )

      nil ->
        status = if existing && existing.send_op_id, do: "reuse_staged", else: "staged"

        disposition =
          if rule,
            do: "eligible request staged for bounded catchup admission",
            else: "eligible request staged but configured filing rule does not match this owner"

        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          status,
          disposition,
          Map.merge(existing || %{}, %{wake_id: wake_id})
        )

      _ ->
        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          "unresolved",
          "stable request wake identity exists with an unexpected origin",
          Map.merge(existing || %{}, %{wake_id: wake_id})
        )
    end
  end

  defp admit(db, call, owner_user_id, request_id, rule) do
    now = System.system_time(:millisecond)

    case DB.transaction(db, fn txn ->
           result = admit_in_txn(txn, call, owner_user_id, request_id, rule, now)

           {state, disposition, attrs} =
             case result do
               {:ok, state, disposition, attrs} -> {state, disposition, attrs}
               {:error, state, disposition, attrs} -> {state, disposition, attrs}
             end

           attrs = normalize_attrs(attrs)

           persist_in_txn(
             txn,
             request_id,
             owner_user_id,
             state,
             disposition,
             call.session_key,
             attrs[:session_key],
             attrs[:wake_id],
             attrs[:send_op_id],
             attrs[:handle],
             attrs[:sender_id],
             attrs[:message_id],
             now
           )

           result
         end) do
      {:ok, {:ok, status, disposition, attrs}} ->
        Map.merge(
          entry(db, request_id, status, disposition, owner_user_id, call.session_key),
          normalize_attrs(attrs)
        )

      {:ok, {:error, status, disposition, attrs}} ->
        Map.merge(
          entry(db, request_id, status, disposition, owner_user_id, call.session_key),
          normalize_attrs(attrs)
        )

      {:error, reason} ->
        put_entry(
          db,
          call,
          request_id,
          owner_user_id,
          "unresolved",
          "admission transaction failed: #{inspect(reason)}",
          %{}
        )
    end
  end

  defp admit_in_txn(txn, call, owner_user_id, request_id, rule, now) do
    request = Escalation.raw_by_id_in_txn(txn, request_id)
    existing = progress_in_txn(txn, request_id)

    cond do
      request == nil ->
        {:error, "unresolved", "request disappeared before admission", %{}}

      request.owner_user_id != owner_user_id or
          addressed_principal(request) != "user:" <> owner_user_id ->
        {:error, "excluded", "request is no longer addressed to the authenticated owner", %{}}

      request.status != "open" ->
        {:error, "excluded", "request status is #{request.status}; no new wake was created", %{}}

      existing == nil ->
        {:error, "unresolved", "staged request ledger row disappeared", %{}}

      existing.send_op_id && existing.state == "reuse_staged" ->
        schedule_reuse_wake(txn, call, owner_user_id, request, existing, rule, now)

      not configured_for_owner?(rule, owner_user_id) ->
        {:error, "staged",
         "waiting for the filing rule to select the authenticated owner principal", %{}}

      true ->
        schedule_new_wake(txn, call, owner_user_id, request, existing, rule, now)
    end
  end

  defp schedule_new_wake(txn, call, owner_user_id, request, _existing, rule, now) do
    trigger = catchup_trigger(call, request.id)
    wake_id = wake_id(request.id)

    case Rules.resolve_notice_in_txn(txn, rule, trigger) do
      {:ok, resolved} ->
        existing_wake = wake_in_txn(txn, wake_id)

        cond do
          existing_wake && existing_wake.origin != @wake_origin ->
            {:error, "unresolved",
             "stable request wake identity exists with an unexpected origin", %{wake_id: wake_id}}

          existing_wake && existing_wake.state == "canceled" ->
            {:error, "unresolved",
             "request wake was canceled; refusing to mint a replacement identity",
             %{wake_id: wake_id}}

          existing_wake ->
            {:ok, "admitted", "filing wake already exists and was reused",
             %{wake_id: wake_id, session_key: existing_wake.session_key}}

          true ->
            wake =
              Wakes.schedule_in_txn(txn, %{
                wake_id: wake_id,
                session_key: resolved.bound_session,
                target_role: resolved.target[:target_role],
                origin: @wake_origin,
                prompt: resolved.params.prompt,
                due_at: now,
                creator_session_key: call.session_key,
                summon: true
              })

            Tightbeam.EventLog.lifecycle_in_txn(
              txn,
              "harklight_briefing_catchup_admitted",
              request.id,
              JSON.encode!(%{
                wake_id: wake.wake_id,
                session_key: wake.session_key,
                actor: call.origin,
                principal: "user:" <> owner_user_id
              })
            )

            {:ok, "admitted",
             "catchup wake admitted using the filing rule and stable request identity",
             %{wake_id: wake.wake_id, session_key: wake.session_key}}
        end

      {:error, reason} ->
        {:error, "staged", "waiting for a resolvable briefing target: #{inspect(reason)}",
         %{wake_id: wake_id}}
    end
  end

  defp schedule_reuse_wake(txn, call, _owner_user_id, request, existing, _rule, now) do
    wake_id = wake_id(request.id)

    case Txn.q(
           txn,
           "SELECT state FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2",
           [existing.session_key, request.owner_user_id]
         ) do
      [["active"]] ->
        case wake_in_txn(txn, wake_id) do
          %{origin: @wake_origin, session_key: session_key, state: state}
          when state != "canceled" ->
            if session_key == existing.session_key do
              {:ok, "reused",
               "existing Harklight conversation and its original compiler wake were reused",
               %{wake_id: wake_id, session_key: session_key}}
            else
              {:error, "unresolved",
               "existing wake targets a different session than the original compiler",
               %{wake_id: wake_id, session_key: session_key}}
            end

          %{state: "canceled"} ->
            {:error, "unresolved",
             "stable request wake was canceled; refusing to mint a replacement identity",
             %{wake_id: wake_id}}

          nil ->
            # An existing conversation takes precedence over today's route binding.
            wake =
              Wakes.schedule_in_txn(txn, %{
                wake_id: wake_id,
                session_key: existing.session_key,
                target_role: nil,
                origin: @wake_origin,
                prompt:
                  "Resume the existing Harklight conversation for decision request #{request.id}. Reconcile its original send operation and thread, continue in this same session, and do not create a replacement message or session.",
                due_at: now,
                creator_session_key: call.session_key,
                summon: true
              })

            Tightbeam.EventLog.lifecycle_in_txn(
              txn,
              "harklight_briefing_catchup_reused",
              request.id,
              JSON.encode!(%{
                wake_id: wake.wake_id,
                session_key: wake.session_key,
                handle: existing.handle,
                message_id: existing.message_id,
                actor: call.origin
              })
            )

            {:ok, "reused",
             "existing Harklight conversation reused by its original compiling session",
             %{wake_id: wake.wake_id, session_key: wake.session_key}}
        end

      _ ->
        {:error, "unresolved",
         "original compiling session is unavailable; refusing to move the existing Harklight conversation",
         %{wake_id: wake_id, session_key: existing.session_key}}
    end
  end

  defp catchup_trigger(call, request_id) do
    %{
      edge: :row_commit,
      origin: call.origin,
      principal: call.principal,
      session_key: call.session_key,
      params: %{decision_request_id: request_id},
      transition: %{
        domain: "condition_fact",
        bindings: %{conditionKind: "decision-request-filed", decisionRequestId: request_id}
      }
    }
  end

  defp briefing_rule(owner_user_id) do
    case Enum.find(Rules.effective_snapshot().rules, &(&1.name == @rule_name)) do
      nil -> nil
      rule -> if configured_for_owner?(rule, owner_user_id), do: rule, else: nil
    end
  end

  defp configured_for_owner?(nil, _owner), do: false

  defp configured_for_owner?(rule, owner) do
    rule.verb == "condition" and "row-commit" in rule.edges and rule.effect == "notice" and
      Enum.any?(rule.conditions, fn condition ->
        condition.fact == "condition_fact.kind" and condition.op == "eq" and
          condition.value == "decision-request-filed"
      end) and
      Enum.any?(rule.conditions, fn condition ->
        condition.fact == "decision_request.addressed_principal" and condition.op == "eq" and
          condition.value == "user:" <> owner
      end) and
      Enum.any?(rule.conditions, fn condition ->
        condition.fact == "condition_fact.matches" and condition.op == "eq" and
          condition.value == true
      end)
  end

  defp reconcile_candidate(db, call, owner_user_id, request, candidate, rule) do
    attrs = candidate_attrs(candidate)

    case candidate.state do
      "pending" when is_integer(candidate.attempted_at) ->
        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          "pending",
          "original send is pending; existing Harklight recovery will settle operation #{candidate.op_id}",
          attrs
        )

      "pending" ->
        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          "reuse_staged",
          "prepared operation exists; resume it in its original compiling session",
          attrs
        )

      "bound" ->
        case valid_thread(db, candidate, owner_user_id) do
          :ok ->
            existing_wake_state(
              db,
              call,
              owner_user_id,
              request,
              Map.merge(attrs, %{state: "bound"}),
              rule
            )

          {:error, reason} ->
            put_entry(db, call, request.id, owner_user_id, "unresolved", reason, attrs)
        end

      _ ->
        put_entry(
          db,
          call,
          request.id,
          owner_user_id,
          "unresolved",
          "existing Harklight operation cannot be safely reused",
          attrs
        )
    end
  end

  defp operation_candidates(operations, request_id) do
    Enum.filter(operations, fn operation ->
      operation.explicit_request_id == request_id or
        String.contains?(operation.reference_text, request_id)
    end)
  end

  defp send_operations(db) do
    case DB.query(
           db,
           "SELECT opId,sessionKey,payload,handle,senderId,messageId,state,attemptedAt FROM harklight_send_operations ORDER BY createdAt,opId"
         ) do
      {:ok, rows} ->
        Enum.reduce_while(rows, {:ok, []}, fn [
                                                op_id,
                                                session,
                                                payload,
                                                handle,
                                                sender,
                                                message,
                                                state,
                                                attempted_at
                                              ],
                                              {:ok, acc} ->
          case JSON.decode(payload) do
            {:ok, decoded} when is_map(decoded) ->
              request_id = decision_request_id(payload)
              message_payload = get_in(decoded, ["request", "message"]) || %{}

              text =
                [message_payload["title"], message_payload["body"]]
                |> Enum.filter(&is_binary/1)
                |> Enum.join("\n")

              item = %{
                op_id: op_id,
                session_key: session,
                payload: payload,
                handle: handle,
                sender_id: sender,
                message_id: message,
                state: state,
                attempted_at: attempted_at,
                explicit_request_id: request_id,
                reference_text: text
              }

              {:cont, {:ok, [item | acc]}}

            _ ->
              {:halt, {:error, "harklight_send_payload_unreadable"}}
          end
        end)
        |> case do
          {:ok, values} -> {:ok, Enum.reverse(values)}
          error -> error
        end

      {:error, reason} ->
        {:error, "harklight_send_operations_unavailable", inspect(reason)}
    end
  end

  defp operation_by_id(db, op_id) when is_binary(op_id) do
    case DB.query(
           db,
           "SELECT opId,sessionKey,payload,handle,senderId,messageId,state,attemptedAt FROM harklight_send_operations WHERE opId=?1",
           [op_id]
         ) do
      {:ok, [[op_id, session, payload, handle, sender, message, state, attempted_at]]} ->
        %{
          op_id: op_id,
          session_key: session,
          payload: payload,
          handle: handle,
          sender_id: sender,
          message_id: message,
          state: state,
          attempted_at: attempted_at
        }

      _ ->
        nil
    end
  end

  defp operation_by_id(_db, _op_id), do: nil

  defp decision_request_id(payload) when is_binary(payload) do
    case JSON.decode(payload) do
      {:ok, %{"decision_request_id" => id}} when is_binary(id) -> id
      {:ok, %{"decisionRequestId" => id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp decision_request_id(_), do: nil

  defp valid_thread(db, operation, expected_owner) do
    with true <-
           is_binary(operation.handle) and is_binary(operation.sender_id) and
             is_binary(operation.message_id),
         {:ok, [[session, state]]} <-
           DB.query(db, "SELECT sessionKey,state FROM harklight_wake_handles WHERE handle=?1", [
             operation.handle
           ]),
         true <- session == operation.session_key and state in ["active", "unavailable"],
         {:ok, [[stored_handle]]} <-
           DB.query(
             db,
             "SELECT handle FROM harklight_wake_requests WHERE senderId=?1 AND messageId=?2",
             [operation.sender_id, operation.message_id]
           ),
         true <- stored_handle == operation.handle,
         {:ok, [[owner, "active"]]} <-
           DB.query(db, "SELECT ownerUserId,state FROM sessions WHERE sessionKey=?1", [
             operation.session_key
           ]),
         true <- owner == expected_owner do
      :ok
    else
      _ ->
        {:error,
         "existing Harklight operation has no recoverable handle, message subscription, or originating session"}
    end
  end

  defp wake_matches_session_in_txn?(txn, wake_id, session_key) do
    case wake_in_txn(txn, wake_id) do
      %{origin: @wake_origin, session_key: ^session_key, state: state} when state != "canceled" ->
        true

      _ ->
        false
    end
  end

  defp wake(db, wake_id) do
    case DB.query(
           db,
           "SELECT wakeId,sessionKey,targetRole,origin,state FROM wakes WHERE wakeId=?1",
           [wake_id]
         ) do
      {:ok, [[id, session, role, origin, state]]} ->
        %{wake_id: id, session_key: session, target_role: role, origin: origin, state: state}

      _ ->
        nil
    end
  end

  defp wake_in_txn(txn, wake_id) do
    case Txn.q(
           txn,
           "SELECT wakeId,sessionKey,targetRole,origin,state FROM wakes WHERE wakeId=?1",
           [wake_id]
         ) do
      [[id, session, role, origin, state]] ->
        %{wake_id: id, session_key: session, target_role: role, origin: origin, state: state}

      [] ->
        nil
    end
  end

  defp progress(db, request_id) do
    case DB.query(
           db,
           "SELECT requestId,ownerUserId,state,disposition,actorSessionKey,sessionKey,wakeId,sendOpId,handle,senderId,messageId FROM harklight_decision_briefings WHERE requestId=?1",
           [request_id]
         ) do
      {:ok, [row]} -> progress_from_row(row)
      _ -> nil
    end
  end

  defp progress_in_txn(txn, request_id) do
    case Txn.q(
           txn,
           "SELECT requestId,ownerUserId,state,disposition,actorSessionKey,sessionKey,wakeId,sendOpId,handle,senderId,messageId FROM harklight_decision_briefings WHERE requestId=?1",
           [request_id]
         ) do
      [row] -> progress_from_row(row)
      [] -> nil
    end
  end

  defp operation_in_txn(_txn, nil), do: nil

  defp operation_in_txn(txn, op_id) do
    case Txn.q(
           txn,
           "SELECT opId,sessionKey,payload,handle,senderId,messageId,state,attemptedAt FROM harklight_send_operations WHERE opId=?1",
           [op_id]
         ) do
      [[op_id, session, payload, handle, sender, message, state, attempted_at]] ->
        %{
          op_id: op_id,
          session_key: session,
          payload: payload,
          handle: handle,
          sender_id: sender,
          message_id: message,
          state: state,
          attempted_at: attempted_at
        }

      [] ->
        nil
    end
  end

  defp progress_from_row([
         request,
         owner,
         state,
         disposition,
         actor,
         session,
         wake,
         op,
         handle,
         sender,
         message
       ]) do
    %{
      request_id: request,
      owner_user_id: owner,
      state: state,
      disposition: disposition,
      actor_session_key: actor,
      session_key: session,
      wake_id: wake,
      send_op_id: op,
      handle: handle,
      sender_id: sender,
      message_id: message
    }
  end

  defp entry(db, request_id, state, disposition, owner_user_id, actor_session_key) do
    case progress(db, request_id) do
      nil ->
        %{
          request_id: request_id,
          owner_user_id: owner_user_id,
          state: state,
          disposition: disposition,
          actor_session_key: actor_session_key
        }

      existing ->
        Map.merge(existing, %{
          state: state,
          disposition: disposition,
          actor_session_key: actor_session_key
        })
    end
  end

  defp put_entry(db, call, request_id, owner_user_id, state, disposition, attrs) do
    attrs = normalize_attrs(attrs)
    now = System.system_time(:millisecond)

    case DB.transaction(db, fn txn ->
           persist_in_txn(
             txn,
             request_id,
             owner_user_id,
             state,
             disposition,
             call.session_key,
             attrs[:session_key],
             attrs[:wake_id],
             attrs[:send_op_id],
             attrs[:handle],
             attrs[:sender_id],
             attrs[:message_id],
             now
           )
         end) do
      {:ok, _} ->
        stored = entry(db, request_id, state, disposition, owner_user_id, call.session_key)

        Map.merge(Map.merge(attrs, stored), %{
          request_id: request_id,
          owner_user_id: owner_user_id,
          state: state,
          disposition: disposition,
          actor_session_key: call.session_key
        })

      {:error, reason} ->
        %{
          request_id: request_id,
          owner_user_id: owner_user_id,
          state: "unresolved",
          disposition: "progress could not be persisted: #{inspect(reason)}",
          actor_session_key: call.session_key
        }
    end
  end

  defp persist_in_txn(
         txn,
         request_id,
         owner_user_id,
         state,
         disposition,
         actor,
         session_key,
         wake_id,
         op_id,
         handle,
         sender,
         message,
         now
       ) do
    Txn.q(
      txn,
      "INSERT INTO harklight_decision_briefings(requestId,ownerUserId,state,disposition,actorSessionKey,sessionKey,wakeId,sendOpId,handle,senderId,messageId,createdAt,updatedAt) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?12) ON CONFLICT(requestId) DO UPDATE SET ownerUserId=excluded.ownerUserId,state=excluded.state,disposition=excluded.disposition,actorSessionKey=COALESCE(excluded.actorSessionKey,harklight_decision_briefings.actorSessionKey),sessionKey=COALESCE(excluded.sessionKey,harklight_decision_briefings.sessionKey),wakeId=COALESCE(excluded.wakeId,harklight_decision_briefings.wakeId),sendOpId=COALESCE(excluded.sendOpId,harklight_decision_briefings.sendOpId),handle=COALESCE(excluded.handle,harklight_decision_briefings.handle),senderId=COALESCE(excluded.senderId,harklight_decision_briefings.senderId),messageId=COALESCE(excluded.messageId,harklight_decision_briefings.messageId),updatedAt=excluded.updatedAt",
      [
        request_id,
        owner_user_id,
        state,
        disposition,
        actor,
        session_key,
        wake_id,
        op_id,
        handle,
        sender,
        message,
        now
      ]
    )

    :ok
  end

  defp normalize_attrs(attrs) do
    attrs
    |> Map.new(fn
      {:op_id, value} -> {:send_op_id, value}
      {key, value} -> {key, value}
    end)
  end

  defp candidate_attrs(candidate),
    do:
      Map.take(candidate, [
        :session_key,
        :wake_id,
        :op_id,
        :send_op_id,
        :handle,
        :sender_id,
        :message_id
      ])
      |> normalize_attrs()

  defp bound_operation_matches?(operation, existing, request_id) do
    if decision_request_id(operation.payload) == request_id and
         operation.session_key == existing.session_key and
         (is_nil(existing.handle) or existing.handle == operation.handle) and
         (is_nil(existing.sender_id) or existing.sender_id == operation.sender_id) and
         (is_nil(existing.message_id) or existing.message_id == operation.message_id),
       do: :ok,
       else: {:error, "operation association mismatch"}
  end

  defp compatible_identity?(nil, nil, nil, _handle, _sender, _message), do: true
  defp compatible_identity?(handle, sender, message, handle, sender, message), do: true
  defp compatible_identity?(_, _, _, _, _, _), do: false

  defp addressed_principal(request) do
    cond do
      is_binary(request.expecter_session_key) -> "session:" <> request.expecter_session_key
      is_binary(request.expecter_user_id) -> "user:" <> request.expecter_user_id
      true -> "user:" <> request.owner_user_id
    end
  end

  defp wake_id(request_id) do
    digest =
      :crypto.hash(:sha256, @rule_name <> <<0>> <> request_id) |> Base.encode16(case: :lower)

    "w_rule_" <> digest
  end

  defp owner_user_id(db, call) do
    case Org.get(db, call.session_key) do
      %{owner_user_id: owner} when is_binary(owner) ->
        {:ok, owner}

      _ ->
        {:error, "harklight_briefing_origin_unavailable", "the originating session has no owner"}
    end
  end

  defp authenticated_origin(db, call) do
    local_host = Placement.local_host_name()

    case Org.get(db, call.session_key) do
      %{state: "active", host: ^local_host}
      when is_binary(call.session_key) and call.principal == {:session, call.session_key} and
             call.transport_session_key == call.session_key ->
        :ok

      _ ->
        {:error, "harklight_origin_unavailable",
         "the Harklight action must run in its active originating session"}
    end
  end

  defp active_admin_origin(db, call, authorized) do
    with true <- authorized,
         :ok <- authenticated_origin(db, call),
         {:ok, owner} <- owner_user_id(db, call),
         %{is_admin: true} <- Devices.user(db, owner) do
      :ok
    else
      _ -> {:error, "not_owner", "catchup requires an active admin-owned session"}
    end
  end

  defp report(owner_user_id, limit, listed, entries) do
    counts =
      Enum.frequencies_by(entries, & &1.state)

    %{
      ok: true,
      owner_user_id: owner_user_id,
      listed: listed,
      limit: limit,
      eligible:
        Enum.count(
          entries,
          &(&1.state in [
              "staged",
              "reuse_staged",
              "admitted",
              "reused",
              "reserved",
              "pending",
              "bound"
            ])
        ),
      admitted: Map.get(counts, "admitted", 0),
      reused: Map.get(counts, "reused", 0),
      staged: Map.get(counts, "staged", 0) + Map.get(counts, "reuse_staged", 0),
      pending:
        Map.get(counts, "pending", 0) + Map.get(counts, "reserved", 0) +
          Map.get(counts, "bound", 0),
      unresolved: Map.get(counts, "unresolved", 0),
      excluded: Map.get(counts, "excluded", 0),
      requests: entries
    }
  end

  defp failure(code, message), do: %{ok: false, code: code, message: message, requests: []}
end
