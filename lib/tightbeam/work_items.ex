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

  alias Tightbeam.{CausalEvents, DB, EffortCheckin, Org, Wakes}
  alias Tightbeam.DB.Txn

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
    with :ok <- DB.execute(db, @ddl), do: DB.execute(db, @priority_ddl)
  end

  @doc false
  def __handle__(db, "work-item-create", call), do: create_result(db, call)
  def __handle__(db, "work-item-get", call), do: get_result(db, call)
  def __handle__(db, "work-item-trace", call), do: trace_result(db, call)
  def __handle__(db, "work-item-list", call), do: list_result(db, call)
  def __handle__(db, "work-item-update", call), do: update_result(db, call)
  def __handle__(db, "work-item-icebox", call), do: dispose_result(db, call, :icebox)
  def __handle__(db, "work-item-reopen", call), do: dispose_result(db, call, :reopen)
  def __handle__(db, "work-item-close", call), do: dispose_result(db, call, :close)
  def __handle__(db, "work-item-fail", call), do: dispose_result(db, call, :fail)

  ## Create — bracket 1 + optional idempotency + owner doorbell

  defp create_result(db, call) do
    is_bug = Map.get(call.params, :is_bug, false)
    key = call.params[:idempotency_key]

    with :ok <- principal_allowed(call.principal),
         :ok <- valid_title(call.params[:title]),
         :ok <- valid_spec_ref(call.params[:spec_ref_name], call.params[:spec_ref_sha256]),
         :ok <- valid_is_bug(is_bug),
         :ok <- valid_priority(call.params[:priority]),
         :ok <- valid_idempotency_key(key),
         {:ok, owner} <- resolve_owner(db, call.principal) do
      {created_by_user, created_by_session} = creator(call.principal)

      result =
        transaction(db, fn txn ->
          case key && idempotency_item(txn, owner, key) do
            nil ->
              id = "wi_" <> Tightbeam.Id.uuid4()
              created_in_turn_seq = running_turn_seq(txn, created_by_session)
              priority = call.params[:priority] || default_priority_in_txn(txn)

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
                  now()
                ]
              )

              put_priority_in_txn(txn, id, priority)
              arm_routing_in_txn(txn, id, owner, call.params.title)

              if key do
                Txn.q(
                  txn,
                  "INSERT INTO wire_idempotency (ownerUserId, operation, idempotencyKey, sessionKey) VALUES (?1, 'work-item-create', ?2, ?3)",
                  [owner, key, id]
                )
              end

              {:created, fetch_in_txn(txn, id)}

            item_id ->
              {:replayed, fetch_in_txn(txn, item_id)}
          end
        end)

      case result do
        # An actual create makes an owner-visible item — one owner-routed
        # metadata doorbell (constitution §2: the owner is nagged about their
        # unassigned item). A keyed replay created nothing, so it stays silent.
        {:created, item} ->
          best_effort(fn -> on_change(call).(item.id, "metadata") end)
          public_work_item(item)

        {:replayed, item} ->
          public_work_item(item)
      end
    end
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
           "SELECT seq FROM turns WHERE sessionKey = ?1 AND status = 'running' LIMIT 1",
           [session_key]
         ) do
      [[seq]] -> seq
      [] -> nil
    end
  end

  ## Update (title/spec-ref/isBug PATCH — unchanged bracket-wise)

  defp update_result(db, call) do
    with :ok <- principal_allowed(call.principal) do
      result =
        transaction(db, fn txn ->
          update_in_txn(
            txn,
            Map.put(call.params, :effort_config, Map.get(call, :effort_config, %{}))
          )
        end)

      case result do
        {:updated, item, changed?} ->
          if changed?, do: best_effort(fn -> on_change(call).(item.id, "metadata") end)
          public_work_item(item)

        error ->
          error
      end
    end
  end

  defp update_in_txn(txn, params) do
    case fetch_in_txn(txn, params[:work_item_id]) do
      nil ->
        unknown(params[:work_item_id])

      item ->
        title = if Map.has_key?(params, :title), do: params.title, else: item.title

        {spec_ref_name, spec_ref_sha256} = patch_spec_ref(item, params)
        is_bug = if Map.has_key?(params, :is_bug), do: params.is_bug, else: item.isBug

        with :ok <- valid_title(title),
             :ok <- valid_spec_ref(spec_ref_name, spec_ref_sha256),
             :ok <- valid_is_bug(is_bug),
             :ok <- valid_priority(params[:priority]) do
          priority = if Map.has_key?(params, :priority), do: params.priority, else: item.priority
          updates = patch_updates(params, title, spec_ref_name, spec_ref_sha256, is_bug)
          apply_updates(txn, item, updates)

          if priority != item.priority do
            put_priority_in_txn(txn, item.id, priority)

            EffortCheckin.reprioritize_work_item_in_txn(
              txn,
              Map.get(params, :effort_config, %{}),
              item.id,
              priority
            )
          end

          updated = fetch_in_txn(txn, item.id)
          {:updated, updated, metadata(item) != metadata(updated)}
        end
    end
  end

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

  defp apply_updates(_txn, item, []), do: item

  defp apply_updates(txn, item, updates) do
    assignments =
      updates
      |> Enum.with_index(2)
      |> Enum.map_join(", ", fn {{column, _value}, index} -> "#{column} = ?#{index}" end)

    values = [item.id | Enum.map(updates, &elem(&1, 1))]
    Txn.q(txn, "UPDATE work_items SET #{assignments} WHERE id = ?1", values)
    fetch_in_txn(txn, item.id)
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
    with :ok <- principal_allowed(call.principal) do
      id = call.params[:work_item_id]
      reason = call.params[:reason]

      result =
        transaction(db, fn txn -> dispose_in_txn(txn, call.principal, id, verb, reason) end)

      case result do
        {:disposed, item, changed?} ->
          if changed?, do: best_effort(fn -> on_change(call).(item.id, "metadata") end)
          %{ok: true, workItem: public_work_item(item)}

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
            {:disposed, item, false}

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

            {:disposed, disposed, true}
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
  Re-arm the bracket wake being delivered, IN the delivery transaction, when
  the item is still unrouted/un-iceboxed (bracket 1) or the slate is still
  clear (bracket 2). The match on `routingWakeId`/`slateWakeId` is the sole
  discriminator: a rumination or ordinary wake never matches, so it no-ops.
  Nag-by-re-arm: the supervision lattice does not watch holderless work.
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

  defp arm_routing_in_txn(txn, id, owner, title) do
    wake =
      Wakes.schedule_in_txn(txn, %{
        session_key: Org.personal_session_key(owner),
        origin: @origin,
        prompt: "route it or icebox it — work item #{id}: #{title}",
        due_at: now() + triage_deadline_ms(),
        work_item_id: id
      })

    Txn.q(txn, "UPDATE work_items SET routingWakeId = ?2 WHERE id = ?1", [id, wake.wake_id])
    :ok
  end

  defp triage_deadline_ms do
    Application.get_env(:tightbeam, :work_item_triage_deadline_ms, @default_triage_deadline_ms)
  end

  ## Reads

  defp get_result(db, call) do
    with :ok <- principal_allowed(call.principal) do
      case fetch(db, call.params[:work_item_id]) do
        nil ->
          unknown(call.params[:work_item_id])

        item ->
          %{
            workItem: public_work_item(item),
            assignments: Tightbeam.Assignments.__for_work_item__(db, item.id)
          }
      end
    end
  end

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

  defp trace_allowed?(_db, _principal, _item), do: false
  defp trace_not_found, do: error("not_found", "work item not found")

  defp list_result(db, call) do
    with :ok <- principal_allowed(call.principal) do
      {:ok, rows} =
        DB.query(db, "SELECT #{columns()} FROM work_items ORDER BY createdAt DESC, id DESC")

      %{workItems: Enum.map(rows, &(work_item(&1) |> public_work_item()))}
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

  defp principal_allowed({:process, _}),
    do: error("process_denied", "process principals cannot use work-item verbs")

  defp principal_allowed(nil),
    do:
      error(
        "principal_required",
        "work-item verbs require a user credential or a session token"
      )

  defp principal_allowed({kind, _}) when kind in [:session, :user], do: :ok

  defp resolve_owner(_db, {:user, user}), do: {:ok, user}

  defp resolve_owner(db, {:session, session}) do
    case Org.get(db, session) do
      %{owner_user_id: owner} when is_binary(owner) -> {:ok, owner}
      _ -> error("unknown_session", "creator session #{session} not found")
    end
  end

  defp creator({:user, user}), do: {user, nil}
  defp creator({:session, session}), do: {nil, session}
  defp unknown(id), do: error("unknown_work_item", "unknown work item: #{id}")
  defp error(code, message), do: %{code: code, message: message}

  defp metadata(item),
    do: {item.title, item.specRefName, item.specRefSha256, item.isBug, item.priority}

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

  defp best_effort(fun) do
    try do
      fun.()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp transaction(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)

  # The wake-id columns are INTERNAL substrate truth — never surfaced in a
  # response object (§Response shapes).
  defp columns do
    "id, title, specRefName, specRefSha256, isBug, ownerUserId, state, failReason, " <>
      "routingWakeId, slateWakeId, createdByUser, createdBySession, createdAt, " <>
      "COALESCE((SELECT priority FROM work_item_priorities p WHERE p.workItemId=work_items.id), " <>
      "CAST(COALESCE((SELECT value FROM org_settings WHERE key='default-priority'),'4') AS INTEGER))"
  end

  defp work_item([
         id,
         title,
         spec_ref_name,
         spec_ref_sha256,
         is_bug,
         owner_user_id,
         state,
         fail_reason,
         routing_wake_id,
         slate_wake_id,
         user,
         session,
         created_at,
         priority
       ]) do
    %{
      id: id,
      title: title,
      specRefName: spec_ref_name,
      specRefSha256: spec_ref_sha256,
      isBug: is_bug == 1,
      ownerUserId: owner_user_id,
      state: state,
      failReason: fail_reason,
      routingWakeId: routing_wake_id,
      slateWakeId: slate_wake_id,
      createdByUser: user,
      createdBySession: session,
      createdAt: created_at,
      priority: priority
    }
  end

  defp public_work_item(item), do: Map.drop(item, [:routingWakeId, :slateWakeId])

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0
end
