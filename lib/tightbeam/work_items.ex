defmodule Tightbeam.WorkItems do
  @moduledoc """
  Durable work identity across assignment eras and aspects, plus the two
  lifecycle brackets (accountability-constitution §2 "No intent in limbo"):

  - Bracket 1 (routed-or-deadline): create arms a `consumer='prompt'` wake to
    the owner's personal session; the first `assign`/`dispatch` or a
    `work-item-icebox` cancels it, and an ignored owner is re-nagged each
    horizon by the re-arm on fire (the lattice does not watch holderless work).
  - Bracket 2 (concluded-or-adjudicated): the last assignment close of a
    non-terminal item arms a durable slate wake in the SAME close transaction;
    the next `assign`/`dispatch` or a terminal disposition cancels it.

  The owner is ALWAYS a user (constitution §3): a session creator's item is
  owned by that session's owning user. Terminal dispositions (icebox/close/
  fail/reopen) are owner-or-admin verbs that write `state`/`failReason`.
  """

  alias Tightbeam.{
    CausalEvents,
    DB,
    Dispatch,
    ExecutionMap,
    Mementos,
    Org,
    Rules,
    StateResources,
    StateVisibility,
    Wakes
  }

  alias Tightbeam.DB.Txn

  require Logger
  alias Tightbeam.Firehose.Publisher

  @origin "process:tightbeam"
  @default_triage_deadline_ms 86_400_000

  defmodule CancellationRefused do
    @moduledoc false
    defexception [:wake_id]

    @impl true
    def message(%__MODULE__{wake_id: wake_id}),
      do: "typed routing-bracket cancellation refused for #{wake_id}"
  end

  @ddl """
  CREATE TABLE IF NOT EXISTS work_items (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 2000),
    specRefName TEXT NULL CHECK(specRefName IS NULL OR length(trim(specRefName)) BETWEEN 1 AND 2000),
    specRefSha256 TEXT NULL CHECK(specRefSha256 IS NULL OR (length(specRefSha256) = 64 AND specRefSha256 NOT GLOB '*[^0-9a-f]*')),
    isBug INTEGER NOT NULL DEFAULT 0 CHECK(isBug IN (0, 1)),
    ownerUserId TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','iceboxed','closed','failed')),
    failReason TEXT NULL,
    routingWakeId TEXT NULL,
    slateWakeId TEXT NULL,
    createdByUser TEXT NULL,
    createdBySession TEXT NULL,
    createdInTurnSeq INTEGER NULL,
    createdContextKnown INTEGER NOT NULL DEFAULT 0,
    createdAt INTEGER NOT NULL,
    CHECK((specRefName IS NULL) = (specRefSha256 IS NULL)),
    CHECK((createdByUser IS NOT NULL) != (createdBySession IS NOT NULL))
  );
  CREATE TABLE IF NOT EXISTS work_item_versions (
    workItemId TEXT PRIMARY KEY REFERENCES work_items(id),
    rowVersion INTEGER NOT NULL CHECK(rowVersion > 0)
  );
  CREATE INDEX IF NOT EXISTS work_items_created_in_turn ON work_items (createdInTurnSeq)
  """

  @priority_ddl """
  CREATE TABLE IF NOT EXISTS work_item_priorities (
    workItemId TEXT PRIMARY KEY REFERENCES work_items(id),
    priority INTEGER NOT NULL
  )
  """

  @doc "Create the work-item schema."
  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ Tightbeam.DB) do
    with :ok <- DB.execute(db, @ddl),
         :ok <- DB.execute(db, @priority_ddl) do
      :ok
    end
  end

  @doc false
  def __handle__(db, "work-item-create", call), do: create_result(db, call)
  def __handle__(db, "work-item-get", call), do: get_result(db, call)
  def __handle__(db, "work-item-trace", call), do: trace_result(db, call)
  def __handle__(db, "work-item-list", call), do: list_result(db, call)
  def __handle__(db, "work-item-update", call), do: update_result(db, call)
  def __handle__(db, "work-item-handoff", call), do: handoff_result(db, call)
  def __handle__(db, "work-item-icebox", call), do: dispose_result(db, call, :icebox)
  def __handle__(db, "work-item-reopen", call), do: dispose_result(db, call, :reopen)
  def __handle__(db, "work-item-close", call), do: dispose_result(db, call, :close)
  def __handle__(db, "work-item-fail", call), do: dispose_result(db, call, :fail)

  ## Create — bracket 1 + optional idempotency + owner doorbell

  defp create_result(db, call) do
    is_bug = Map.get(call.params, :is_bug, false)
    key = call.params[:idempotency_key]

    with :ok <- ensure_body_schema_for_use(db),
         :ok <- principal_allowed(call.principal),
         :ok <- valid_title(call.params[:title]),
         :ok <- valid_spec_ref(call.params[:spec_ref_name], call.params[:spec_ref_sha256]),
         :ok <- valid_is_bug(is_bug),
         :ok <- valid_priority(call.params[:priority]),
         :ok <- valid_idempotency_key(key),
         {:ok, owner} <- resolve_owner(db, call.principal, call.params) do
      {created_by_user, created_by_session} = creator(call.principal)
      snapshot = Rules.effective_snapshot()

      result =
        transaction(db, fn txn ->
          Rules.with_snapshot(snapshot, fn ->
            case key && idempotency_item(txn, owner, key) do
              nil ->
                admitted =
                  Mementos.admit_in_txn!(
                    txn,
                    call
                    |> Map.put_new(:verb, "work-item-create")
                    |> Map.put_new(:rules_prechecked, true)
                  )

                id = "wi_" <> Tightbeam.Id.uuid4()
                created_in_turn_seq = running_turn_seq(txn, created_by_session)
                priority = call.params[:priority] || default_priority_in_txn(txn)
                created_at = now()

                Txn.q(
                  txn,
                  """
                  INSERT INTO work_items
                    (id, title, specRefName, specRefSha256, isBug, ownerUserId,
                     state, createdByUser, createdBySession, createdInTurnSeq,
                     createdContextKnown, createdAt)
                  VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'open', ?7, ?8, ?9, 1, ?10)
                  """,
                  [
                    id,
                    call.params.title,
                    call.params[:spec_ref_name],
                    call.params[:spec_ref_sha256],
                    bool_to_int(is_bug),
                    owner,
                    created_by_user,
                    created_by_session,
                    created_in_turn_seq,
                    created_at
                  ]
                )

                put_priority_in_txn(txn, id, priority)
                stamp_version_in_txn(txn, id, created_at)
                routing_wake = arm_routing_in_txn(txn, id, owner, call.params.title)

                if key do
                  Txn.q(
                    txn,
                    "INSERT INTO wire_idempotency (ownerUserId, operation, idempotencyKey, sessionKey) VALUES (?1, 'work-item-create', ?2, ?3)",
                    [owner, key, id]
                  )
                end

                item = fetch_in_txn(txn, id)
                Mementos.append_inline!(txn, "work_item", id, admitted)
                on_routing_wake_scheduled_in_txn(call).(txn, routing_wake)
                Publisher.maybe_accepted_in_txn(txn, call, public_work_item(item))
                {:created, item, routing_wake, admitted.memento_close_effects}

              item_id ->
                item = fetch_in_txn(txn, item_id)
                Publisher.maybe_observed_accepted_in_txn(txn, call)
                {:replayed, item}
            end
          end)
        end)

      case result do
        # An actual create makes an owner-visible item — one owner-routed
        # metadata doorbell (constitution §2: the owner is nagged about their
        # unassigned item). A keyed replay created nothing, so it stays silent.
        {:created, item, routing_wake, effects} ->
          if effects != [],
            do:
              Dispatch.close_rule_effects(
                db,
                call[:rule_effect_handlers] || Tightbeam.Gateway.handlers(%{db: db}),
                effects
              )

          best_effort(fn -> on_change(call).(item.id, "metadata") end)
          best_effort(fn -> on_routing_wake_scheduled(call).(routing_wake) end)
          public_work_item(item) |> then(&Mementos.attach(db, "work_item", &1))

        {:replayed, item} ->
          public_work_item(item) |> then(&Mementos.attach(db, "work_item", &1))
      end
    end
  rescue
    error in Mementos.Refusal ->
      error.admission || error.details || %{code: error.code, message: error.message}
  end

  defp idempotency_item(txn, owner, key) do
    case Txn.q(
           txn,
           "SELECT sessionKey FROM wire_idempotency WHERE ownerUserId = ?1 AND operation = 'work-item-create' AND idempotencyKey = ?2",
           [owner, key]
         ) do
      [[work_item_id]] -> work_item_id
      [] -> nil
    end
  end

  defp running_turn_seq(_txn, nil), do: nil

  defp running_turn_seq(txn, session_key) do
    case Txn.q(
           txn,
           "SELECT seq FROM turns WHERE sessionKey = ?1 AND status = 'running' " <>
             "AND status IN ('queued','running') LIMIT 1",
           [session_key]
         ) do
      [[seq]] -> seq
      [] -> nil
    end
  end

  ## Update (work-item metadata and the explicit accountable delivery owner)

  defp update_result(db, call) do
    with :ok <- ensure_body_schema_for_use(db),
         :ok <- principal_allowed(call.principal) do
      result =
        transaction(db, fn txn ->
          result =
            update_in_txn(
              txn,
              call.params
              |> Map.put(:principal, call.principal)
            )

          case result do
            {:updated, item, changed?} ->
              publish_item_result_in_txn(txn, call, item, changed?)

            _ ->
              :ok
          end

          result
        end)

      case result do
        {:updated, item, changed?} ->
          if changed?, do: best_effort(fn -> on_change(call).(item.id, "metadata") end)

          result = public_work_item(item) |> then(&Mementos.attach(db, "work_item", &1))

          if Map.has_key?(call.params, :body) or Map.get(call.params, :clear_body, false),
            do: %{workItem: result, bodyUpdate: body_update_descriptor(item, changed?)},
            else: result

        error ->
          error
      end
    end
  end

  ## Handoff — item/owner change and owner wake commit as one operation

  defp handoff_result(db, call) do
    params = call.params

    with :ok <- ensure_body_schema_for_use(db),
         :ok <- handoff_principal_allowed(call.principal),
         {:ok, mode} <- valid_handoff_input(params),
         {:ok, item_owner} <- handoff_item_owner(db, call, mode) do
      {created_by_user, created_by_session} = creator(call.principal)

      result =
        transaction(db, fn txn ->
          case handoff_item_in_txn(
                 txn,
                 call,
                 mode,
                 item_owner,
                 created_by_user,
                 created_by_session
               ) do
            {:error, error} ->
              {:refused, error}

            {:ok, item, created?, changed?, routing_wake} ->
              if created? or changed? do
                on_handoff_in_txn(call).(txn, item, created?)
              end

              wake = schedule_handoff_wake_in_txn(txn, call, item)

              if is_map(wake) and is_binary(wake[:wake_id]) do
                Publisher.committed_in_txn(
                  txn,
                  "wake.scheduled",
                  wake,
                  %{"workItemId" => item.id}
                )
              else
                raise "delivery-owner handoff did not schedule its wake"
              end

              Publisher.maybe_accepted_in_txn(txn, call, %{id: item.id})
              {:handed_off, item, created?, changed?, routing_wake}
          end
        end)

      case result do
        {:refused, error} ->
          handoff_refusal(error)

        {:handed_off, item, created?, changed?, routing_wake} ->
          if created? or changed?,
            do: best_effort(fn -> on_change(call).(item.id, "metadata") end)

          if is_map(routing_wake) do
            best_effort(fn -> on_routing_wake_scheduled(call).(routing_wake) end)
          end

          %{
            workItem: Mementos.attach(db, "work_item", public_work_item(item)),
            created: created?,
            wakeScheduled: true
          }
      end
    end
  end

  defp handoff_refusal(%{code: "unknown_delivery_owner", message: message} = error),
    do:
      Map.put(
        error,
        :message,
        message <> "; correct deliveryOwnerSessionKey to an active session"
      )

  defp handoff_refusal(%{code: "delivery_owner_unavailable", message: message} = error),
    do: Map.put(error, :message, message <> "; choose an active delivery-owner session")

  defp handoff_refusal(%{code: "ephemeral_obligation", message: message} = error),
    do: Map.put(error, :message, message <> "; choose a persistent delivery-owner session")

  defp handoff_item_owner(_db, _principal, :existing), do: {:ok, nil}
  defp handoff_item_owner(db, call, :new), do: resolve_owner(db, call.principal, call.params)

  defp handoff_item_in_txn(
         txn,
         call,
         :existing,
         _item_owner,
         _created_by_user,
         _created_by_session
       ) do
    item = fetch_in_txn(txn, call.params[:work_item_id])

    if is_nil(item) do
      {:error, unknown(call.params[:work_item_id])}
    else
      case update_metadata_in_txn(txn, item, %{
             delivery_owner_session_key: call.params[:delivery_owner_session_key]
           }) do
        {:updated, updated, changed?} -> {:ok, updated, false, changed?, nil}
        error -> {:error, error}
      end
    end
  end

  defp handoff_item_in_txn(
         txn,
         call,
         :new,
         item_owner,
         created_by_user,
         created_by_session
       ) do
    params = call.params

    with :ok <- valid_delivery_owner(txn, params) do
      id = "wi_" <> Tightbeam.Id.uuid4()
      created_in_turn_seq = running_turn_seq(txn, created_by_session)
      priority = params[:priority] || default_priority_in_txn(txn)
      is_bug = Map.get(params, :is_bug, false)
      created_at = now()

      Txn.q(
        txn,
        """
        INSERT INTO work_items
          (id, title, specRefName, specRefSha256, isBug, ownerUserId,
           state, createdByUser, createdBySession, createdInTurnSeq,
           createdContextKnown, createdAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'open', ?7, ?8, ?9, 1, ?10)
        """,
        [
          id,
          params.title,
          params[:spec_ref_name],
          params[:spec_ref_sha256],
          bool_to_int(is_bug),
          item_owner,
          created_by_user,
          created_by_session,
          created_in_turn_seq,
          created_at
        ]
      )

      put_priority_in_txn(txn, id, priority)
      stamp_version_in_txn(txn, id, created_at)
      item = fetch_in_txn(txn, id)
      item = apply_updates(txn, item, delivery_owner_update(params))
      routing_wake = arm_routing_in_txn(txn, id, item_owner, params.title)
      on_routing_wake_scheduled_in_txn(call).(txn, routing_wake)

      {:ok, fetch_in_txn(txn, id), true, true, routing_wake}
    else
      error -> {:error, error}
    end
  end

  defp schedule_handoff_wake_in_txn(txn, call, item) do
    Wakes.schedule_in_txn(txn, %{
      session_key: call.params[:delivery_owner_session_key],
      origin: call.origin,
      prompt:
        "Delivery-owner handoff for work item #{item.id} (#{item.title}):\n\n" <>
          call.params.brief,
      due_at: now(),
      sender_scheduled: true,
      work_item_id: item.id
    })
  end

  defp valid_handoff_input(params) do
    mode =
      case {Map.has_key?(params, :work_item_id), Map.has_key?(params, :title)} do
        {true, false} -> :existing
        {false, true} -> :new
        _ -> nil
      end

    with mode when not is_nil(mode) <- mode,
         :ok <- valid_handoff_reference(params, mode),
         :ok <- valid_handoff_owner_reference(params[:delivery_owner_session_key]),
         :ok <- valid_handoff_brief(params[:brief]),
         :ok <- valid_handoff_item_fields(params, mode) do
      {:ok, mode}
    else
      nil -> error("invalid_handoff", "supply exactly one of workItemId or title")
      error -> error
    end
  end

  defp valid_handoff_reference(params, :existing) do
    case params[:work_item_id] do
      id when is_binary(id) and byte_size(id) > 0 ->
        if String.trim(id) == "",
          do: error("invalid_handoff", "workItemId must be a non-blank work-item identifier"),
          else: :ok

      _ ->
        error("invalid_handoff", "workItemId must be a non-blank work-item identifier")
    end
  end

  defp valid_handoff_reference(params, :new), do: valid_title(params[:title])

  defp valid_handoff_owner_reference(owner)
       when is_binary(owner) and byte_size(owner) > 0 do
    if String.trim(owner) == "",
      do: error("invalid_delivery_owner", "deliveryOwnerSessionKey must be non-blank"),
      else: :ok
  end

  defp valid_handoff_owner_reference(_owner),
    do: error("invalid_delivery_owner", "deliveryOwnerSessionKey must be an active session")

  defp valid_handoff_brief(brief) when is_binary(brief) do
    if String.valid?(brief) and String.trim(brief) != "",
      do: :ok,
      else: error("invalid_handoff_brief", "brief must be valid non-blank UTF-8 text")
  end

  defp valid_handoff_brief(_brief),
    do: error("invalid_handoff_brief", "brief must be valid non-blank UTF-8 text")

  defp valid_handoff_item_fields(params, :existing) do
    creation_fields = [:spec_ref_name, :spec_ref_sha256, :is_bug, :priority]

    if Enum.any?(creation_fields, &Map.has_key?(params, &1)),
      do:
        error(
          "invalid_handoff",
          "specRefName, specRefSha256, isBug, and priority are only valid when creating a work item"
        ),
      else: :ok
  end

  defp valid_handoff_item_fields(params, :new) do
    is_bug = Map.get(params, :is_bug, false)

    with :ok <- valid_spec_ref(params[:spec_ref_name], params[:spec_ref_sha256]),
         :ok <- valid_is_bug(is_bug),
         :ok <- valid_priority(params[:priority]) do
      :ok
    end
  end

  defp publish_item_result_in_txn(txn, call, item, true),
    do: Publisher.maybe_accepted_in_txn(txn, call, public_event_work_item(item))

  defp publish_item_result_in_txn(txn, call, _item, false),
    do: Publisher.maybe_observed_accepted_in_txn(txn, call)

  defp update_in_txn(txn, params) do
    case fetch_in_txn(txn, params[:work_item_id]) do
      nil ->
        unknown(params[:work_item_id])

      item ->
        if Map.has_key?(params, :body) or Map.get(params, :clear_body, false) do
          update_body_in_txn(txn, item, params)
        else
          update_metadata_in_txn(txn, item, params)
        end
    end
  end

  defp update_metadata_in_txn(txn, item, params) do
    title = if Map.has_key?(params, :title), do: params.title, else: item.title

    {spec_ref_name, spec_ref_sha256} = patch_spec_ref(item, params)
    is_bug = if Map.has_key?(params, :is_bug), do: params.is_bug, else: item.isBug

    with :ok <- valid_title(title),
         :ok <- valid_spec_ref(spec_ref_name, spec_ref_sha256),
         :ok <- valid_is_bug(is_bug),
         :ok <- valid_priority(params[:priority]),
         :ok <- valid_delivery_owner(txn, params) do
      priority = if Map.has_key?(params, :priority), do: params.priority, else: item.priority

      updates =
        patch_updates(params, title, spec_ref_name, spec_ref_sha256, is_bug) ++
          delivery_owner_update(params)

      apply_updates(txn, item, updates)

      if priority != item.priority do
        put_priority_in_txn(txn, item.id, priority)
      end

      updated = fetch_in_txn(txn, item.id)
      changed? = metadata(item) != metadata(updated)

      if item.deliveryOwnerSessionKey != updated.deliveryOwnerSessionKey do
        Wakes.readdress_accountability_notices_in_txn(txn, item.id)
      end

      if changed?, do: stamp_version_in_txn(txn, item.id, now())
      {:updated, fetch_in_txn(txn, item.id), changed?}
    end
  end

  defp update_body_in_txn(txn, item, params) do
    metadata_keys = [
      :title,
      :is_bug,
      :spec_ref_name,
      :spec_ref_sha256,
      :priority,
      :delivery_owner_session_key
    ]

    if Enum.any?(metadata_keys, &Map.has_key?(params, &1)) do
      error(
        "invalid_body_patch",
        "body cannot be combined with title, isBug, specRefName, specRefSha256, priority, or deliveryOwnerSessionKey"
      )
    else
      body = if Map.get(params, :clear_body, false), do: nil, else: params[:body]

      with :ok <- valid_body(body) do
        current = body_record_in_txn(txn, item.id)

        if (current && current.body) === body do
          {:updated, fetch_in_txn(txn, item.id), false}
        else
          {updated_by_user, updated_by_session} = body_attribution(params[:principal])
          updated_at = now()

          Txn.q(
            txn,
            """
            INSERT INTO work_item_bodies
              (workItemId, body, updatedByUser, updatedBySession, updatedAt)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(workItemId) DO UPDATE SET
              body=excluded.body, updatedByUser=excluded.updatedByUser,
              updatedBySession=excluded.updatedBySession,
              updatedAt=excluded.updatedAt
            """,
            [item.id, body, updated_by_user, updated_by_session, updated_at]
          )

          stamp_version_in_txn(txn, item.id, updated_at)
          {:updated, fetch_in_txn(txn, item.id), true}
        end
      end
    end
  end

  defp body_record_in_txn(txn, id) do
    case Txn.q(txn, "SELECT body FROM work_item_bodies WHERE workItemId = ?1", [id]) do
      [[body]] -> %{body: body}
      [] -> nil
    end
  end

  defp body_attribution({:user, user}), do: {user, nil}
  defp body_attribution({:session, session}), do: {nil, session}
  defp body_attribution({:process, _}), do: {nil, nil}
  defp body_attribution(_), do: {nil, "unknown"}

  defp patch_updates(params, title, spec_ref_name, spec_ref_sha256, is_bug) do
    updates =
      []
      |> then(fn fields ->
        if Map.has_key?(params, :title), do: fields ++ [{"title", title}], else: fields
      end)
      |> then(fn fields ->
        if Map.has_key?(params, :is_bug),
          do: fields ++ [{"isBug", bool_to_int(is_bug)}],
          else: fields
      end)

    name_present = Map.has_key?(params, :spec_ref_name)
    sha_present = Map.has_key?(params, :spec_ref_sha256)

    spec_updates =
      cond do
        not name_present and not sha_present ->
          []

        (name_present and is_nil(params[:spec_ref_name])) or
            (sha_present and is_nil(params[:spec_ref_sha256])) ->
          [{"specRefName", spec_ref_name}, {"specRefSha256", spec_ref_sha256}]

        true ->
          []
          |> then(fn fields ->
            if name_present, do: fields ++ [{"specRefName", spec_ref_name}], else: fields
          end)
          |> then(fn fields ->
            if sha_present, do: fields ++ [{"specRefSha256", spec_ref_sha256}], else: fields
          end)
      end

    updates ++ spec_updates
  end

  defp delivery_owner_update(params) do
    if Map.has_key?(params, :delivery_owner_session_key),
      do: [{"deliveryOwnerSessionKey", params[:delivery_owner_session_key]}],
      else: []
  end

  defp valid_delivery_owner(_txn, params)
       when not is_map_key(params, :delivery_owner_session_key),
       do: :ok

  defp valid_delivery_owner(_txn, %{delivery_owner_session_key: nil}), do: :ok

  defp valid_delivery_owner(txn, %{delivery_owner_session_key: session_key})
       when is_binary(session_key) do
    cond do
      Tightbeam.Ephemeral.session?(txn, session_key) ->
        error("ephemeral_obligation", "ephemeral sessions cannot own work items")

      String.trim(session_key) == "" ->
        error(
          "invalid_delivery_owner",
          "deliveryOwnerSessionKey must be an active session or null"
        )

      true ->
        case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [session_key]) do
          [["active"]] ->
            :ok

          [[_state]] ->
            error(
              "delivery_owner_unavailable",
              "delivery owner session #{session_key} is not active"
            )

          [] ->
            error(
              "unknown_delivery_owner",
              "delivery owner session #{session_key} does not exist"
            )
        end
    end
  end

  defp valid_delivery_owner(_txn, _params),
    do:
      error("invalid_delivery_owner", "deliveryOwnerSessionKey must be an active session or null")

  defp apply_updates(_txn, item, []), do: item

  defp apply_updates(txn, item, updates) do
    assignments =
      updates
      |> Enum.with_index(2)
      |> Enum.map_join(", ", fn {{column, _value}, index} -> "#{column} = ?#{index}" end)

    values = [item.id | Enum.map(updates, &elem(&1, 1))]
    Txn.q(txn, "UPDATE work_items SET #{assignments} WHERE id = ?1", values)
    updated = fetch_in_txn(txn, item.id)

    updated
  end

  defp patch_spec_ref(item, params) do
    name_present = Map.has_key?(params, :spec_ref_name)
    sha_present = Map.has_key?(params, :spec_ref_sha256)
    name = params[:spec_ref_name]
    sha = params[:spec_ref_sha256]

    cond do
      (name_present and is_nil(name)) or (sha_present and is_nil(sha)) ->
        if (name_present and not is_nil(name)) or (sha_present and not is_nil(sha)),
          do: {name, sha},
          else: {nil, nil}

      true ->
        {
          if(name_present, do: name, else: item.specRefName),
          if(sha_present, do: sha, else: item.specRefSha256)
        }
    end
  end

  ## Terminal dispositions (owner-or-admin) — icebox/reopen/close/fail

  defp dispose_result(db, call, verb) do
    with :ok <- ensure_body_schema_for_use(db),
         :ok <- principal_allowed(call.principal) do
      id = call.params[:work_item_id]
      reason = call.params[:reason]

      result =
        transaction_with_row_commits(
          db,
          fn txn ->
            result = dispose_in_txn(txn, call.principal, id, verb, reason)

            case result do
              {:disposed, item, changed?, _old_state} ->
                publish_item_result_in_txn(txn, call, item, changed?)

              _ ->
                :ok
            end

            result
          end,
          fn _txn, result ->
            case result do
              {:disposed, item, true, old_state} ->
                [
                  work_item_transition(item, call, "work-item-#{verb}", %{
                    state: %{old: old_state, new: item.state}
                  })
                ]

              _ ->
                []
            end
          end
        )

      case result do
        {:disposed, item, changed?, _old_state} ->
          if changed?, do: best_effort(fn -> on_change(call).(item.id, "metadata") end)
          %{ok: true, workItem: Mementos.attach(db, "work_item", public_work_item(item))}

        error ->
          error
      end
    end
  end

  defp dispose_in_txn(txn, principal, id, verb, reason) do
    case fetch_in_txn(txn, id) do
      nil ->
        unknown(id)

      item ->
        target = target_state(verb)

        cond do
          not disposition_allowed?(txn, principal, item) ->
            error("not_authorized", "work-item disposition requires its owner or an admin")

          item.state == target ->
            # Same-state transition is a no-op success — changes nothing, and
            # emits no doorbell (fail keeps its prior reason untouched).
            {:disposed, item, false, item.state}

          not transition_allowed?(item.state, target) ->
            error(
              "invalid_transition",
              "cannot #{verb} a #{item.state} work item"
            )

          verb != :reopen and open_assignments?(txn, id) ->
            error(
              "assignments_open",
              "work item #{id} still has open assignments; close them first"
            )

          true ->
            apply_disposition(txn, item, verb, target, reason)
            stamp_version_in_txn(txn, id, now())
            disposed = fetch_in_txn(txn, id)

            # The item keeps its CURRENT state only, and reopen nulls failReason;
            # work_item_events is a bare doorbell (kind is 'metadata' or
            # 'composition'), so it records that something changed, never from
            # what to what. jobRef IS the work-item id here, and a disposition
            # belongs to no assignment.
            CausalEvents.append_in_txn(txn, %{
              kind: "disposition_transition",
              job_ref: id,
              assignment_id: nil,
              session_key: nil,
              detail: %{
                workItemId: id,
                fromState: item.state,
                toState: target,
                failReason: disposed.failReason
              }
            })

            [[transition_id]] = Txn.q(txn, "SELECT last_insert_rowid()")

            if verb != :reopen do
              cancel_brackets_in_txn(txn, id, %{
                causal_source: %{kind: "work_item_transition", id: to_string(transition_id)},
                outcome: %{
                  kind: "disposition",
                  disposition_kind: "work_item_transition",
                  disposition_id: to_string(transition_id)
                }
              })
            end

            {:disposed, disposed, true, item.state}
        end
    end
  end

  defp apply_disposition(txn, item, :reopen, "open", _reason) do
    # iceboxed → open re-arms bracket 1 (the routing deadline resumes).
    if is_binary(item.routingWakeId) or is_binary(item.slateWakeId) do
      raise "terminal work item #{item.id} retained a live bracket reference"
    end

    Txn.q(txn, "UPDATE work_items SET state = 'open', failReason = NULL WHERE id = ?1", [item.id])
    arm_routing_in_txn(txn, item.id, item.ownerUserId, item.title)
  end

  defp apply_disposition(txn, item, verb, target, reason) do
    # icebox/close/fail all cancel BOTH brackets (after a last-close a slate
    # wake may exist, so every disposition must cancel bracket 2 too).
    fail_reason = if verb == :fail, do: reason, else: nil

    Txn.q(
      txn,
      "UPDATE work_items SET state = ?2, failReason = ?3 WHERE id = ?1",
      [item.id, target, fail_reason]
    )
  end

  defp target_state(:icebox), do: "iceboxed"
  defp target_state(:reopen), do: "open"
  defp target_state(:close), do: "closed"
  defp target_state(:fail), do: "failed"

  defp transition_allowed?("open", "iceboxed"), do: true
  defp transition_allowed?("iceboxed", "open"), do: true
  defp transition_allowed?(from, "closed") when from in ["open", "iceboxed"], do: true
  defp transition_allowed?(from, "failed") when from in ["open", "iceboxed"], do: true
  defp transition_allowed?(_from, _target), do: false

  defp disposition_allowed?(txn, {:user, user}, item) do
    item.ownerUserId == user or admin_user?(txn, user)
  end

  defp disposition_allowed?(txn, {:session, session}, item) do
    # A session token always arrives as {:session, key} even for an admin, so
    # the owner-or-admin check must resolve the session's owning user and honour
    # its admin bit — not only direct ownership.
    case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey = ?1", [session]) do
      [[owner]] -> owner == item.ownerUserId or admin_user?(txn, owner)
      _ -> false
    end
  end

  defp disposition_allowed?(_txn, {:process, _}, _item), do: true
  defp disposition_allowed?(_txn, _principal, _item), do: false

  defp admin_user?(txn, user),
    do: Txn.q(txn, "SELECT isAdmin FROM users WHERE userId = ?1", [user]) == [[1]]

  defp open_assignments?(txn, work_item_id) do
    Txn.q(
      txn,
      "SELECT 1 FROM assignments WHERE workItemId = ?1 AND state = 'open' LIMIT 1",
      [work_item_id]
    ) != []
  end

  ## Bracket mechanics — shared with Assignments (first assign, last close) and
  ## the Gateway delivery seam (nag re-arm on fire).

  @doc "Committed state of a work item, or nil when unknown."
  @spec state_for(DB.server(), String.t()) :: String.t() | nil
  def state_for(db, id) do
    case DB.query(db, "SELECT state FROM work_items WHERE id = ?1", [id]) do
      {:ok, [[state]]} -> state
      {:ok, []} -> nil
    end
  end

  @doc "In-transaction state read (the assignment-insert interlock uses this)."
  @spec state_in_txn(Txn.t(), String.t()) :: String.t() | nil
  def state_in_txn(%Txn{} = txn, id) do
    case Txn.q(txn, "SELECT state FROM work_items WHERE id = ?1", [id]) do
      [[state]] -> state
      [] -> nil
    end
  end

  @doc "Cancel both bracket wakes through one typed transition and clear their ids."
  @spec cancel_brackets_in_txn(Txn.t(), String.t(), map()) :: :ok
  def cancel_brackets_in_txn(%Txn{} = txn, work_item_id, transition) do
    case Txn.q(
           txn,
           "SELECT routingWakeId, slateWakeId FROM work_items WHERE id = ?1",
           [work_item_id]
         ) do
      [[routing, slate]] ->
        Enum.each([routing, slate], fn
          wake_id when is_binary(wake_id) ->
            cancel_bracket_in_txn(txn, wake_id, transition)

          nil ->
            :ok
        end)

        if is_binary(routing) or is_binary(slate) do
          Txn.q(
            txn,
            "UPDATE work_items SET routingWakeId = NULL, slateWakeId = NULL WHERE id = ?1",
            [work_item_id]
          )
        end

      [] ->
        :ok
    end

    :ok
  end

  defp cancel_bracket_in_txn(txn, wake_id, transition) do
    case Txn.q(txn, "SELECT state FROM wakes WHERE wakeId = ?1", [wake_id]) do
      [["pending"]] ->
        command =
          Map.merge(transition, %{
            wake_id: wake_id,
            requester: %{kind: "process", id: "tightbeam:work-items"},
            reason_kind: "routing_bracket_satisfied"
          })

        if not Wakes.cancel_in_txn(txn, command),
          do: raise(CancellationRefused, wake_id: wake_id)

      [[state]] when state in ["fired", "canceled"] ->
        :ok

      [] ->
        raise "work-item bracket references missing wake #{wake_id}"
    end
  end

  @doc """
  Arm bracket 2 (the slate wake) when this close left the item non-terminal
  with zero open assignments. Called from every assignment-close path INSIDE
  the close transaction.
  """
  @spec arm_slate_in_txn(Txn.t(), String.t() | nil) :: :ok
  def arm_slate_in_txn(%Txn{} = txn, work_item_id) when is_binary(work_item_id) do
    case Txn.q(
           txn,
           "SELECT state, ownerUserId FROM work_items WHERE id = ?1",
           [work_item_id]
         ) do
      [["open", owner]] ->
        if not open_assignments?(txn, work_item_id) do
          wake =
            Wakes.schedule_in_txn(txn, %{
              session_key: Org.personal_session_key(owner),
              origin: @origin,
              prompt:
                "slate clear on #{work_item_id}: close it, card more work, or rule it failed",
              due_at: now(),
              sender_scheduled: true,
              work_item_id: work_item_id
            })

          Txn.q(txn, "UPDATE work_items SET slateWakeId = ?2 WHERE id = ?1", [
            work_item_id,
            wake.wake_id
          ])
        end

      _ ->
        :ok
    end

    :ok
  end

  def arm_slate_in_txn(%Txn{} = _txn, nil), do: :ok

  @doc """
  Re-arm a still-current routing or slate bracket after its durable delivery
  record commits. The pointer match is the discriminator, so a replay or an
  unrelated notice cannot advance the bracket twice.
  """
  @spec rearm_on_fire_in_txn(Txn.t(), String.t() | nil, map() | nil) :: :ok
  def rearm_on_fire_in_txn(%Txn{} = txn, wake_id, %{work_item_id: item_id})
      when is_binary(item_id) and is_binary(wake_id) do
    case Txn.q(
           txn,
           "SELECT state, ownerUserId, title, routingWakeId, slateWakeId FROM work_items WHERE id = ?1",
           [item_id]
         ) do
      [[state, owner, title, routing, slate]] ->
        cond do
          state == "open" and routing == wake_id ->
            arm_routing_in_txn(txn, item_id, owner, title)

          state == "open" and slate == wake_id and not open_assignments?(txn, item_id) ->
            replacement =
              Wakes.schedule_in_txn(txn, %{
                session_key: Org.personal_session_key(owner),
                origin: @origin,
                prompt: "slate clear on #{item_id}: close it, card more work, or rule it failed",
                due_at: now() + triage_deadline_ms(),
                sender_scheduled: true,
                work_item_id: item_id
              })

            Txn.q(txn, "UPDATE work_items SET slateWakeId = ?2 WHERE id = ?1", [
              item_id,
              replacement.wake_id
            ])

          true ->
            :ok
        end

      [] ->
        :ok
    end

    :ok
  end

  def rearm_on_fire_in_txn(%Txn{} = _txn, _wake_id, _gate), do: :ok

  @doc false
  @spec reconcile_delivered_brackets(DB.server(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def reconcile_delivered_brackets(db, recipient_session_key, delivered_wake_id)
      when is_binary(recipient_session_key) and is_binary(delivered_wake_id) do
    case DB.transaction(db, fn txn ->
           txn
           |> delivered_bracket_sources_for_wake(recipient_session_key, delivered_wake_id)
           |> reconcile_delivered_bracket_rows(txn)
         end) do
      {:ok, []} -> :ok
      {:ok, failures} -> {:error, {:source_action_failed, failures}}
      {:error, error} -> {:error, error}
    end
  end

  defp delivered_bracket_sources_for_wake(txn, session_key, wake_id) do
    Txn.q(
      txn,
      """
      SELECT item_id,wake_id,wake_rowid FROM (
        SELECT wi.id AS item_id,w.wakeId AS wake_id,w.rowid AS wake_rowid
        FROM work_items wi JOIN wakes w ON w.wakeId=wi.routingWakeId
        WHERE wi.state='open' AND w.deliveredTurnSeq IS NOT NULL
          AND w.sessionKey=?2 AND w.wakeId=?1
        UNION ALL
        SELECT wi.id AS item_id,w.wakeId AS wake_id,w.rowid AS wake_rowid
        FROM work_items wi JOIN wakes w ON w.wakeId=wi.slateWakeId
        WHERE wi.state='open' AND w.deliveredTurnSeq IS NOT NULL
          AND w.sessionKey=?2 AND w.wakeId=?1
        UNION ALL
        SELECT wi.id AS item_id,w.wakeId AS wake_id,w.rowid AS wake_rowid
        FROM notice_batches b
        JOIN notice_batch_members m ON m.batchId=b.batchId AND m.state='included'
        JOIN wakes w ON w.wakeId=m.sourceWakeId
        JOIN work_items wi ON wi.routingWakeId=w.wakeId
        WHERE b.deliveryWakeId=?1 AND b.state='delivered'
          AND w.sessionKey=?2 AND w.deliveredTurnSeq IS NOT NULL AND wi.state='open'
        UNION ALL
        SELECT wi.id AS item_id,w.wakeId AS wake_id,w.rowid AS wake_rowid
        FROM notice_batches b
        JOIN notice_batch_members m ON m.batchId=b.batchId AND m.state='included'
        JOIN wakes w ON w.wakeId=m.sourceWakeId
        JOIN work_items wi ON wi.slateWakeId=w.wakeId
        WHERE b.deliveryWakeId=?1 AND b.state='delivered'
          AND w.sessionKey=?2 AND w.deliveredTurnSeq IS NOT NULL AND wi.state='open'
      ) ORDER BY wake_rowid
      """,
      [wake_id, session_key]
    )
  end

  defp reconcile_delivered_bracket_rows(rows, txn) do
    Enum.reduce(rows, [], fn
      [work_item_id, wake_id, wake_rowid], failures
      when is_binary(wake_id) and is_binary(work_item_id) and is_integer(wake_rowid) ->
        :ok = Txn.exec(txn, "SAVEPOINT reconcile_work_item_bracket")

        try do
          :ok = rearm_on_fire_in_txn(txn, wake_id, %{work_item_id: work_item_id})
          :ok = Txn.exec(txn, "RELEASE reconcile_work_item_bracket")
          failures
        rescue
          error ->
            :ok = Txn.exec(txn, "ROLLBACK TO reconcile_work_item_bracket")
            :ok = Txn.exec(txn, "RELEASE reconcile_work_item_bracket")

            Logger.warning(
              "work-item bracket action failed for #{wake_id}: #{Exception.message(error)}"
            )

            [wake_id | failures]
        end

      malformed, failures ->
        Logger.warning("malformed delivered work-item bracket ignored: #{inspect(malformed)}")
        failures
    end)
    |> Enum.reverse()
  end

  defp arm_routing_in_txn(txn, id, owner, title) do
    wake =
      Wakes.schedule_in_txn(txn, %{
        session_key: Org.personal_session_key(owner),
        origin: @origin,
        prompt: "route it or icebox it — work item #{id}: #{title}",
        due_at: now() + triage_deadline_ms(),
        sender_scheduled: true,
        work_item_id: id
      })

    Txn.q(txn, "UPDATE work_items SET routingWakeId = ?2 WHERE id = ?1", [id, wake.wake_id])
    wake
  end

  defp triage_deadline_ms do
    Application.get_env(:tightbeam, :work_item_triage_deadline_ms, @default_triage_deadline_ms)
  end

  ## Reads

  defp get_result(db, call) do
    with :ok <- ensure_body_schema_for_use(db),
         :ok <- principal_allowed(call.principal) do
      case fetch(db, call.params[:work_item_id]) do
        nil ->
          unknown(call.params[:work_item_id])

        item ->
          %{
            workItem: Mementos.attach(db, "work_item", public_detail_work_item(item)),
            assignments: Tightbeam.Assignments.__for_work_item__(db, item.id)
          }
      end
    end
  end

  defp ensure_body_schema_for_use(db), do: Tightbeam.Schema.ensure_work_item_body_schema(db)

  defp trace_result(db, call) do
    id = call.params[:work_item_id]

    case fetch(db, id) do
      item when not is_nil(item) ->
        if trace_allowed?(db, call.principal, item) do
          Tightbeam.JobTrace.build(db, item)
        else
          trace_not_found()
        end

      nil ->
        trace_not_found()
    end
  end

  defp trace_allowed?(_db, {:user, user}, item) when user == item.ownerUserId, do: true

  defp trace_allowed?(db, {:user, user}, _item) do
    case DB.query(db, "SELECT isAdmin FROM users WHERE userId = ?1", [user]) do
      {:ok, [[1]]} -> true
      _ -> false
    end
  end

  defp trace_allowed?(db, {:session, session}, item) do
    case DB.query(
           db,
           """
           SELECT u.userId, u.isAdmin
           FROM sessions AS s
           JOIN users AS u ON u.userId = s.ownerUserId
           WHERE s.sessionKey = ?1
           """,
           [session]
         ) do
      {:ok, [[owner, admin]]} -> owner == item.ownerUserId or admin == 1
      _ -> false
    end
  end

  defp trace_allowed?(_db, {:process, _}, _item), do: true
  defp trace_allowed?(_db, _principal, _item), do: false
  defp trace_not_found, do: error("not_found", "work item not found")

  @doc false
  def query_work_item_trace(db, %{id: id, principal: principal}) do
    case DB.read_transaction(db, fn txn ->
           if work_item_trace_visible?(txn, id, principal) do
             root = StateResources.query_work_item(txn, id, %{rest_principal: principal})

             if is_nil(root) do
               {:error, 404, "not_found", nil}
             else
               {:ok, work_item_trace_for_root(txn, root, principal)}
             end
           else
             {:error, 404, "not_found", nil}
           end
         end) do
      {:ok, {:ok, trace}} -> trace
      {:ok, {:error, _status, _code, _message} = error} -> error
      {:error, error} -> raise error
    end
  end

  @doc false
  def work_item_trace_visible?(source, id, principal),
    do: StateVisibility.execution_map_node_visible?(source, id, principal)

  @doc false
  def work_item_trace(%{
        work_item: work_item,
        assignments: assignments,
        causal_children: causal_children,
        parent: parent,
        dependency_entries: dependency_entries
      }) do
    linked = parent.status == "linked"
    attributed = parent.status in ["linked", "from_turn"]

    %{
      work_item: work_item,
      assignments: assignments,
      causal_children: causal_children,
      attribution: %{
        provenance_status: parent.status,
        reason_kind: if(attributed, do: "concurrent_turn"),
        primary_work_kind: if(linked, do: "work_item"),
        primary_work_id: if(linked, do: parent.item)
      },
      dependency_version: work_item_trace_dependency_version(dependency_entries)
    }
  end

  defp work_item_trace_for_root(txn, root, principal) do
    item_rows = StateResources.query_work_item(txn, %{}, %{rest_principal: principal})
    items_by_id = Map.new(item_rows, &{&1.id, &1})
    assignment_rows = work_item_trace_visible_assignments(txn, principal)
    assignments_by_id = Map.new(assignment_rows, &{&1.id, &1})
    item_nodes = Enum.map(item_rows, &work_item_trace_item_node/1)
    assignment_nodes = Enum.map(assignment_rows, &work_item_trace_assignment_node/1)
    resolution = ExecutionMap.work_item_trace_resolution(item_nodes, assignment_nodes)
    turn_rows = work_item_trace_visible_turns(txn, item_rows, principal, resolution)

    parent_data =
      ExecutionMap.work_item_trace_parent_data(
        item_nodes,
        assignment_nodes,
        turn_rows,
        resolution
      )

    emitted_assignments =
      assignment_rows
      |> Enum.filter(&(Map.get(parent_data.resolved, &1.id) == root.id))
      |> Enum.sort_by(&{&1.opened_at, &1.id})
      |> Enum.map(fn assignment ->
        case StateResources.query_assignment(txn, assignment.id, %{rest_principal: principal}) do
          nil -> raise ArgumentError, "visible assignment disappeared inside read transaction"
          row -> StateResources.assignment(row)
        end
      end)

    causal_children =
      parent_data.linked
      |> Enum.filter(fn {_child_id, parent_id} -> parent_id == root.id end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    parent = Map.fetch!(parent_data.parents, root.id)

    cycle_members =
      parent_data.cycles
      |> Map.values()
      |> Enum.filter(&MapSet.member?(&1, root.id))
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    relevant_item_ids =
      [root.id | causal_children] ++
        if(parent.status == "linked", do: [parent.item], else: []) ++
        MapSet.to_list(cycle_members)

    relevant_items =
      relevant_item_ids
      |> Enum.uniq()
      |> Enum.map(&Map.fetch!(items_by_id, &1))

    relevant_turn_item_ids =
      [root.id | causal_children] ++ MapSet.to_list(cycle_members)

    relevant_turn_seqs =
      relevant_turn_item_ids
      |> Enum.uniq()
      |> Enum.map(&Map.fetch!(items_by_id, &1))
      |> Enum.filter(&(&1.created_context_known and is_integer(&1.created_in_turn_seq)))
      |> Enum.map(& &1.created_in_turn_seq)
      |> Enum.uniq()

    relevant_turns =
      relevant_turn_seqs
      |> Enum.flat_map(fn seq ->
        case Enum.find(turn_rows, &(&1.seq == seq)) do
          nil -> []
          turn -> [turn]
        end
      end)

    chain_ids =
      Enum.reduce(emitted_assignments, MapSet.new(), fn assignment, ids ->
        MapSet.union(
          ids,
          work_item_trace_assignment_chain_ids(assignment["id"], assignments_by_id)
        )
      end)

    chain_ids =
      Enum.reduce(relevant_turns, chain_ids, fn turn, ids ->
        MapSet.union(ids, work_item_trace_turn_chain_ids(turn, assignments_by_id))
      end)

    dependency_entries =
      work_item_trace_dependency_entries(
        relevant_items,
        MapSet.to_list(chain_ids),
        relevant_turns,
        assignments_by_id
      )

    work_item_trace(%{
      work_item: StateResources.work_item(root),
      assignments: emitted_assignments,
      causal_children: causal_children,
      parent: parent,
      dependency_entries: dependency_entries
    })
  end

  defp work_item_trace_visible_assignments(txn, principal) do
    {principal_kind, principal_id, is_admin} =
      {principal.kind, principal.id, bool_to_int(principal.is_admin)}

    Txn.q(
      txn,
      """
      SELECT a.id, a.workItemId, a.reviewsAssignmentId, a.openedAt, a.closedAt
      FROM assignments AS a
      LEFT JOIN work_items AS wi ON wi.id = a.workItemId
      WHERE (?1 = 1 OR
        (?2 = 'session' AND (a.holderKey = ?3 OR a.openedBySession = ?3)) OR
        (?2 = 'user' AND (wi.ownerUserId = ?3 OR a.openedByUser = ?3)))
      ORDER BY a.openedAt, a.id
      """,
      [is_admin, principal_kind, principal_id]
    )
    |> Enum.map(fn [id, work_item_id, reviews_assignment_id, opened_at, closed_at] ->
      version =
        StateResources.assignment(%{opened_at: opened_at, closed_at: closed_at})["rowVersion"]

      %{
        id: id,
        work_item_id: work_item_id,
        reviews_assignment_id: reviews_assignment_id,
        opened_at: opened_at,
        row_version: version
      }
    end)
  end

  defp work_item_trace_visible_turns(txn, item_rows, principal, resolution) do
    item_rows
    |> Enum.map(& &1.created_in_turn_seq)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn seq ->
      case StateResources.query_turn_in_txn(txn, seq) do
        nil ->
          []

        turn ->
          if StateVisibility.core_detail_visible?(txn, "turns", turn, principal) and
               ExecutionMap.work_item_trace_turn_has_visible_link?(turn, resolution),
             do: [turn],
             else: []
      end
    end)
  end

  defp work_item_trace_item_node(item) do
    %{
      id: item.id,
      context_known: item.created_context_known,
      created_in_turn_seq: item.created_in_turn_seq
    }
  end

  defp work_item_trace_assignment_node(assignment) do
    %{
      id: assignment.id,
      work_item_id: assignment.work_item_id,
      reviews_assignment_id: assignment.reviews_assignment_id
    }
  end

  defp work_item_trace_assignment_chain_ids(id, assignments_by_id),
    do: work_item_trace_assignment_chain_ids(id, assignments_by_id, MapSet.new())

  defp work_item_trace_assignment_chain_ids(id, assignments_by_id, seen) do
    cond do
      not is_binary(id) or MapSet.member?(seen, id) ->
        seen

      assignment = Map.get(assignments_by_id, id) ->
        seen = MapSet.put(seen, id)

        if is_binary(assignment.work_item_id) do
          seen
        else
          work_item_trace_assignment_chain_ids(
            assignment.reviews_assignment_id,
            assignments_by_id,
            seen
          )
        end

      true ->
        seen
    end
  end

  defp work_item_trace_turn_chain_ids(%{job_ref: job_ref}, _assignments_by_id)
       when is_binary(job_ref),
       do: MapSet.new()

  defp work_item_trace_turn_chain_ids(%{assignment_id: assignment_id}, assignments_by_id),
    do: work_item_trace_assignment_chain_ids(assignment_id, assignments_by_id)

  defp work_item_trace_dependency_entries(items, assignment_ids, turns, assignments_by_id) do
    item_entries =
      Enum.map(items, fn item -> ["work items", item.id, item.row_version] end)

    assignment_entries =
      assignment_ids
      |> Enum.uniq()
      |> Enum.map(fn id ->
        assignment = Map.fetch!(assignments_by_id, id)
        ["assignments", id, assignment.row_version]
      end)

    turn_entries =
      Enum.map(turns, fn turn ->
        ["turns", turn.seq, StateResources.turn(turn)["rowVersion"]]
      end)

    (item_entries ++ assignment_entries ++ turn_entries)
    |> Enum.uniq_by(fn [resource, key, _version] -> {resource, key} end)
    |> Enum.sort_by(fn [resource, key, _version] -> {resource, JSON.encode!(key)} end)
  end

  defp work_item_trace_dependency_version(entries) do
    :crypto.hash(:sha256, JSON.encode!(entries))
    |> Base.encode16(case: :lower)
  end

  defp list_result(db, call) do
    with :ok <- ensure_body_schema_for_use(db),
         :ok <- principal_allowed(call.principal) do
      {:ok, rows} =
        DB.query(db, "SELECT #{columns()} FROM work_items ORDER BY createdAt DESC, id DESC")

      %{
        workItems:
          Enum.map(rows, fn row ->
            row
            |> work_item()
            |> public_work_item()
            |> then(&Mementos.attach(db, "work_item", &1))
          end)
      }
    end
  end

  defp fetch(db, id) do
    case DB.query(db, "SELECT #{columns()} FROM work_items WHERE id = ?1", [id]) do
      {:ok, [row]} -> work_item(row)
      {:ok, []} -> nil
    end
  end

  defp fetch_in_txn(txn, id) do
    case Txn.q(txn, "SELECT #{columns()} FROM work_items WHERE id = ?1", [id]) do
      [row] -> work_item(row)
      [] -> nil
    end
  end

  ## Validation + principals

  defp valid_title(title) when is_binary(title) do
    if String.length(String.trim(title)) in 1..2000,
      do: :ok,
      else: error("invalid_title", "title must be 1..2000 non-blank characters")
  end

  defp valid_title(_),
    do: error("invalid_title", "title must be 1..2000 non-blank characters")

  defp valid_spec_ref(nil, nil), do: :ok

  defp valid_spec_ref(name, sha) when is_binary(name) and is_binary(sha) do
    valid_name = String.length(String.trim(name)) in 1..2000
    valid_sha = String.match?(sha, ~r/^[0-9a-f]{64}$/)

    if valid_name and valid_sha,
      do: :ok,
      else: error("invalid_spec_ref", "spec ref must be a non-blank name and lowercase sha256")
  end

  defp valid_spec_ref(_, _),
    do: error("invalid_spec_ref", "specRefName and specRefSha256 must both be set or null")

  defp valid_is_bug(value) when is_boolean(value), do: :ok
  defp valid_is_bug(_), do: error("invalid_is_bug", "isBug must be a boolean")

  defp valid_priority(nil), do: :ok
  defp valid_priority(value) when is_integer(value) and value in 0..8, do: :ok

  defp valid_priority(_),
    do: error("invalid_priority", "priority must be an integer from 0 through 8")

  defp valid_body(nil), do: :ok

  defp valid_body(body) when is_binary(body) do
    if String.valid?(body) and byte_size(body) <= 65_536,
      do: :ok,
      else: error("invalid_body", "body must be null or valid UTF-8 text of at most 65536 bytes")
  end

  defp valid_body(_),
    do: error("invalid_body", "body must be null or valid UTF-8 text of at most 65536 bytes")

  defp valid_idempotency_key(nil), do: :ok

  defp valid_idempotency_key(key) when is_binary(key) do
    if String.trim(key) == "" or String.length(key) > 200,
      do:
        error(
          "invalid_idempotency_key",
          "idempotencyKey must be non-blank and at most 200 characters"
        ),
      else: :ok
  end

  defp valid_idempotency_key(_),
    do: error("invalid_idempotency_key", "idempotencyKey must be text")

  defp handoff_principal_allowed(nil),
    do:
      error(
        "principal_required",
        "work-item-handoff requires an authenticated principal"
      )

  defp handoff_principal_allowed({kind, _}) when kind in [:session, :user, :process], do: :ok

  defp principal_allowed(nil),
    do:
      error(
        "principal_required",
        "work-item verbs require an authenticated principal"
      )

  defp principal_allowed({kind, _}) when kind in [:session, :user, :process], do: :ok

  defp resolve_owner(_db, {:user, user}, _params), do: {:ok, user}

  defp resolve_owner(db, {:session, session}, _params) do
    case Org.get(db, session) do
      %{owner_user_id: owner} when is_binary(owner) -> {:ok, owner}
      _ -> error("unknown_session", "creator session #{session} not found")
    end
  end

  defp resolve_owner(db, {:process, _}, params) do
    case params[:owner_user_id] do
      nil ->
        error("owner_required", "ownerUserId is required")

      owner ->
        case Tightbeam.Devices.user(db, owner) do
          nil -> error("unknown_user", "unknown ownerUserId: #{owner}")
          _ -> {:ok, owner}
        end
    end
  end

  defp creator({:process, _}), do: {nil, nil}
  defp creator({:user, user}), do: {user, nil}
  defp creator({:session, session}), do: {nil, session}
  defp unknown(id), do: error("unknown_work_item", "unknown work item: #{id}")
  defp error(code, message), do: %{code: code, message: message}

  defp metadata(item),
    do:
      {item.title, item.specRefName, item.specRefSha256, item.isBug, item.priority,
       item.deliveryOwnerSessionKey}

  defp put_priority_in_txn(txn, work_item_id, priority) do
    Txn.q(
      txn,
      "INSERT INTO work_item_priorities (workItemId, priority) VALUES (?1, ?2) ON CONFLICT(workItemId) DO UPDATE SET priority=excluded.priority",
      [work_item_id, priority]
    )
  end

  defp default_priority_in_txn(txn) do
    case Txn.q(txn, "SELECT value FROM org_settings WHERE key='default-priority'") do
      [[value]] -> String.to_integer(value)
      [] -> 4
    end
  end

  defp on_change(call), do: Map.get(call, :on_work_item_change, fn _, _ -> :ok end)

  defp on_routing_wake_scheduled_in_txn(call),
    do: Map.get(call, :on_routing_wake_scheduled_in_txn, fn _, _ -> :ok end)

  defp on_handoff_in_txn(call),
    do: Map.get(call, :on_work_item_handoff_in_txn, fn _, _, _ -> :ok end)

  defp on_routing_wake_scheduled(call),
    do: Map.get(call, :on_routing_wake_scheduled, fn _ -> :ok end)

  defp best_effort(fun) do
    try do
      fun.()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp work_item_transition(item, call, verb, fields) do
    %{
      verb: verb,
      domain: "work_item",
      row_id: item.id,
      owner_user_id: item.ownerUserId,
      principal: principal_label(call.principal),
      bindings: %{workItemId: item.id},
      fields: fields
    }
  end

  defp principal_label({:user, user}), do: "user:#{user}"
  defp principal_label({:session, session}), do: "session:#{session}"
  defp principal_label({:remedy, %{statute: statute}}), do: "remedy:#{statute}"
  defp principal_label({:process, process}), do: "process:#{process}"

  defp transaction_with_row_commits(db, fun, transitions) do
    case DB.transaction_then(db, fun, fn txn, result ->
           Tightbeam.Wakes.row_commit_in_txn(txn, transitions.(txn, result))
           result
         end) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp transaction(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)

  # A timestamp alone repeats when two writes share one millisecond. The
  # sidecar makes the public version strict without changing product fields.
  defp stamp_version_in_txn(txn, work_item_id, proposed) do
    Txn.q(
      txn,
      """
      INSERT INTO work_item_versions (workItemId, rowVersion) VALUES (?1, ?2)
      ON CONFLICT(workItemId) DO UPDATE
      SET rowVersion = MAX(excluded.rowVersion, work_item_versions.rowVersion + 1)
      """,
      [work_item_id, proposed]
    )
  end

  # The wake-id columns are INTERNAL substrate truth — never surfaced in a
  # response object (§Response shapes).
  defp columns do
    "id, title, specRefName, specRefSha256, isBug, ownerUserId, deliveryOwnerSessionKey, state, failReason, " <>
      "routingWakeId, slateWakeId, createdByUser, createdBySession, createdAt, " <>
      "COALESCE((SELECT rowVersion FROM work_item_versions WHERE workItemId = work_items.id), createdAt), " <>
      "COALESCE((SELECT priority FROM work_item_priorities p WHERE p.workItemId=work_items.id), " <>
      "CAST(COALESCE((SELECT value FROM org_settings WHERE key='default-priority'),'4') AS INTEGER)), " <>
      "(SELECT body FROM work_item_bodies b WHERE b.workItemId = work_items.id), " <>
      "(SELECT updatedByUser FROM work_item_bodies b WHERE b.workItemId = work_items.id), " <>
      "(SELECT updatedBySession FROM work_item_bodies b WHERE b.workItemId = work_items.id), " <>
      "(SELECT updatedAt FROM work_item_bodies b WHERE b.workItemId = work_items.id)"
  end

  defp work_item([
         id,
         title,
         spec_ref_name,
         spec_ref_sha256,
         is_bug,
         owner_user_id,
         delivery_owner_session_key,
         state,
         fail_reason,
         routing_wake_id,
         slate_wake_id,
         user,
         session,
         created_at,
         row_version,
         priority,
         body,
         body_updated_by_user,
         body_updated_by_session,
         body_updated_at
       ]) do
    %{
      id: id,
      title: title,
      specRefName: spec_ref_name,
      specRefSha256: spec_ref_sha256,
      isBug: is_bug == 1,
      ownerUserId: owner_user_id,
      deliveryOwnerSessionKey: delivery_owner_session_key,
      state: state,
      failReason: fail_reason,
      routingWakeId: routing_wake_id,
      slateWakeId: slate_wake_id,
      createdByUser: user,
      createdBySession: session,
      createdAt: created_at,
      rowVersion: row_version,
      priority: priority,
      body: body,
      bodyUpdatedByUser: body_updated_by_user,
      bodyUpdatedBySession: body_updated_by_session,
      bodyUpdatedAt: body_updated_at
    }
  end

  defp public_work_item(item), do: public_summary(item)

  defp public_detail_work_item(item), do: Map.drop(item, [:routingWakeId, :slateWakeId])

  defp public_summary(item),
    do:
      Map.drop(item, [
        :routingWakeId,
        :slateWakeId,
        :body,
        :bodyUpdatedByUser,
        :bodyUpdatedBySession,
        :bodyUpdatedAt
      ])

  defp public_event_work_item(item) do
    if is_nil(Map.get(item, :bodyUpdatedAt)) do
      public_summary(item)
    else
      item
      |> public_summary()
      |> Map.merge(body_descriptor(item))
    end
  end

  defp body_descriptor(%{body: nil}),
    do: %{bodyState: "absent", bodyBytes: 0, bodySha256: nil}

  defp body_descriptor(%{body: body}) when is_binary(body),
    do: %{
      bodyState: "present",
      bodyBytes: byte_size(body),
      bodySha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    }

  defp body_update_descriptor(item, changed?) do
    body = Map.get(item, :body)

    %{
      state: if(is_nil(body), do: "absent", else: "present"),
      byteLength: if(is_nil(body), do: 0, else: byte_size(body)),
      sha256:
        if(is_nil(body), do: nil, else: Base.encode16(:crypto.hash(:sha256, body), case: :lower)),
      changed: changed?,
      updatedByUser: Map.get(item, :bodyUpdatedByUser),
      updatedBySession: Map.get(item, :bodyUpdatedBySession),
      updatedAt: Map.get(item, :bodyUpdatedAt)
    }
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0
end
