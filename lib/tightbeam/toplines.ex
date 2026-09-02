defmodule Tightbeam.Toplines do
  @moduledoc """
  Durable human-intent Toplines and explicit Work membership.

  This module owns the runtime Topline persistence seam. Production boot calls
  the closed V5 schema activator after the database connection registers the
  deterministic Unicode title functions.

  The old read-only work telemetry remains byte-compatible through `roster/2`
  and `topline/2`, which delegate to `Tightbeam.ExecutionMap`.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Toplines.Schema, as: ToplinesSchema

  @white_space [
    0x0009,
    0x000A,
    0x000B,
    0x000C,
    0x000D,
    0x0020,
    0x0085,
    0x00A0,
    0x1680,
    0x2000,
    0x2001,
    0x2002,
    0x2003,
    0x2004,
    0x2005,
    0x2006,
    0x2007,
    0x2008,
    0x2009,
    0x200A,
    0x2028,
    0x2029,
    0x202F,
    0x205F,
    0x3000
  ]

  @spec ensure_schema(DB.server()) :: :ok | {:error, map()}
  def ensure_schema(db \\ Tightbeam.DB), do: ToplinesSchema.activate(db)

  @doc false
  def __handle__(db, "topline-create", call), do: create(db, call)
  def __handle__(db, "topline-update", call), do: update(db, call)
  def __handle__(db, "topline-close", call), do: close(db, call)
  def __handle__(db, "topline-reopen", call), do: reopen(db, call)
  def __handle__(db, "topline-link-work", call), do: link_work(db, call)
  def __handle__(db, "topline-unlink-work", call), do: unlink_work(db, call)
  def __handle__(db, "topline-concern-create", call), do: create_concern(db, call)
  def __handle__(db, "topline-concern-link-work", call), do: link_concern_work(db, call)
  def __handle__(db, "topline-concern-unlink-work", call), do: unlink_concern_work(db, call)
  def __handle__(db, "toplines", call), do: list(db, call)
  def __handle__(db, "topline", call), do: get(db, call)
  def __handle__(db, "topline-work-leave-unlinked", call), do: leave_unlinked(db, call)
  def __handle__(db, "topline-placement-list", call), do: list_placements(db, call)

  @doc "Query visible durable Toplines for the shared REST read seam."
  @spec query_public(DB.server(), map()) :: [map()] | map()
  def query_public(db, selection) when is_map(selection) do
    principal = Map.get(selection, :principal)
    states = Map.get(selection, :state)

    with {:ok, caller} <- caller(db, principal),
         {:ok, states} <- public_states(states) do
      {owner_sql, owner_params} = owner_filter(caller, "t")
      {state_sql, state_params} = public_state_filter(states, length(owner_params) + 1)

      {:ok, rows} =
        DB.query(
          db,
          summary_sql("WHERE 1 = 1 #{owner_sql} #{state_sql} ORDER BY t.createdAt ASC, t.id ASC"),
          owner_params ++ state_params
        )

      Enum.map(rows, fn row ->
        item = summary(row)

        %{
          topline: item,
          work_memberships: active_memberships(db, item.id),
          concerns: concerns(db, item.id),
          dependency_vector: dependency_vector(db, item.id)
        }
      end)
    end
  end

  @doc "Project one queried Topline to the closed REST state item."
  @spec public_item(map()) :: map()
  def public_item(%{
        topline: topline,
        work_memberships: memberships,
        concerns: concerns,
        dependency_vector: vector
      }) do
    %{
      id: topline.id,
      ownerUserId: topline.ownerUserId,
      title: topline.title,
      state: topline.state,
      createdActor: topline.createdActor,
      createdAt: topline.createdAt,
      updatedAt: topline.updatedAt,
      closedAt: topline.closedAt,
      activeWorkCount: topline.activeWorkCount,
      openConcernCount: topline.openConcernCount,
      workMemberships: memberships,
      concerns:
        Enum.map(concerns, fn concern ->
          %{
            id: concern.id,
            kind: "tag",
            note: concern.title,
            createdAt: concern.createdAt,
            workItemIds: concern.workItemIds
          }
        end),
      dependencyVersion: sha256(canonical_json(vector))
    }
  end

  @doc "Insert one placement episode through Lane 1's frozen transaction seam."
  @spec open_placement_in_txn(Txn.t(), map()) :: map()
  def open_placement_in_txn(%Txn{} = txn, attrs) when is_map(attrs) do
    source_seq = Map.get(attrs, :source_causal_event_seq)
    cause = Map.fetch!(attrs, :cause)
    work_item_id = Map.fetch!(attrs, :work_item_id)

    if cause == "reopened" do
      require_reopen_source!(txn, source_seq, work_item_id)
    end

    [[history_seq]] = Txn.q(txn, "SELECT COALESCE(MAX(seq), 0) FROM causal_events")

    Txn.q(
      txn,
      """
      INSERT INTO topline_placement_obligations
        (id, workItemId, ownerUserId, cause, causeRef, sourceCausalEventSeq,
         historyCausalSeq, openedActorKind, openedActorRef, state,
         openedAt, dueAt, promptWakeId)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'pending', ?10, ?10, ?11)
      """,
      [
        Map.fetch!(attrs, :id),
        work_item_id,
        Map.fetch!(attrs, :owner_user_id),
        cause,
        Map.fetch!(attrs, :cause_ref),
        source_seq,
        history_seq,
        Map.fetch!(attrs, :actor_kind),
        Map.fetch!(attrs, :actor_ref),
        Map.fetch!(attrs, :at),
        Map.fetch!(attrs, :prompt_wake_id)
      ]
    )

    placement_in_txn(txn, Map.fetch!(attrs, :id))
  end

  @doc "Resolve a pending placement through Lane 1's frozen transaction seam."
  @spec resolve_placement_in_txn(Txn.t(), map()) :: map() | nil
  def resolve_placement_in_txn(%Txn{} = txn, attrs) when is_map(attrs) do
    work_item_id = Map.fetch!(attrs, :work_item_id)
    resolution_seq = Map.get(attrs, :resolution_causal_event_seq)

    if Map.fetch!(attrs, :actor_kind) == "process" do
      require_terminal_source!(txn, resolution_seq, work_item_id, Map.fetch!(attrs, :reason))
    end

    [[history_seq]] = Txn.q(txn, "SELECT COALESCE(MAX(seq), 0) FROM causal_events")

    case Txn.q(
           txn,
           "SELECT id FROM topline_placement_obligations WHERE workItemId = ?1 AND state = 'pending'",
           [work_item_id]
         ) do
      [] ->
        nil

      [[id]] ->
        Txn.q(
          txn,
          """
          UPDATE topline_placement_obligations
          SET state = ?2, resolutionActorKind = ?3, resolutionActorRef = ?4,
              resolutionReason = ?5, resolvedAt = ?6,
              resolutionCausalEventSeq = ?7, historyCausalSeq = ?8
          WHERE id = ?1 AND state = 'pending'
          """,
          [
            id,
            Map.fetch!(attrs, :state),
            Map.fetch!(attrs, :actor_kind),
            Map.fetch!(attrs, :actor_ref),
            Map.fetch!(attrs, :reason),
            Map.fetch!(attrs, :at),
            resolution_seq,
            history_seq
          ]
        )

        placement_in_txn(txn, id)
    end
  end

  @spec roster(DB.server(), map()) :: map()
  defdelegate roster(db, call), to: Tightbeam.ExecutionMap

  @spec topline(DB.server(), map()) :: map()
  defdelegate topline(db, call), to: Tightbeam.ExecutionMap

  @spec create(DB.server(), map()) :: map()
  def create(db, call) do
    params = Map.get(call, :params, %{})

    with {:ok, caller} <- caller(db, Map.get(call, :principal)),
         :ok <- valid_shape(params, [:idempotency_key, :title]),
         {:ok, title} <- canonical_title(param(params, :title)),
         :ok <- valid_key(param(params, :idempotency_key)) do
      operation = "topline-create"
      key = param(params, :idempotency_key)
      fingerprint = fingerprint(operation, %{title: title})

      transaction!(db, fn txn ->
        with {:ok, caller} <- reauthorize(txn, caller) do
          case replay(txn, caller.user, operation, key, fingerprint) do
            {:ok, response} ->
              response

            :conflict ->
              error("idempotency_conflict", "idempotency key conflicts with a prior request")

            :new ->
              now = mutation_time(call)
              topline_id = id("tl_")

              Txn.q(
                txn,
                """
                INSERT INTO toplines
                  (id, ownerUserId, title, state, createdActorKind, createdActorRef,
                   createdAt, updatedAt, closedAt)
                VALUES (?1, ?2, ?3, 'open', ?4, ?5, ?6, ?6, NULL)
                """,
                [topline_id, caller.user, title, caller.actor_kind, caller.actor_ref, now]
              )

              append_event(txn, topline_id, "topline_created", nil, nil, nil, caller, nil, now, %{
                title: title
              })

              response = %{topline: summary_in_txn(txn, topline_id)}
              remember(txn, caller.user, operation, key, fingerprint, response)
              response
          end
        end
      end)
    end
  end

  @spec update(DB.server(), map()) :: map()
  def update(db, call) do
    params = Map.get(call, :params, %{})

    with {:ok, caller} <- caller(db, Map.get(call, :principal)),
         :ok <- valid_shape(params, [:idempotency_key, :reason, :title, :topline_id]),
         :ok <- valid_id(param(params, :topline_id), "tl_"),
         {:ok, title} <- canonical_title(param(params, :title)),
         :ok <- valid_reason(param(params, :reason)),
         :ok <- valid_key(param(params, :idempotency_key)) do
      topline_id = param(params, :topline_id)
      reason = param(params, :reason)
      key = param(params, :idempotency_key)

      fingerprint =
        fingerprint("topline-update", %{reason: reason, title: title, toplineId: topline_id})

      transaction!(db, fn txn ->
        with {:ok, caller} <- reauthorize(txn, caller),
             {:ok, topline} <- visible_topline(txn, topline_id, caller) do
          case replay(txn, caller.user, "topline-update", key, fingerprint) do
            {:ok, response} ->
              response

            :conflict ->
              error("idempotency_conflict", "idempotency key conflicts with a prior request")

            :new when title == topline.title ->
              error("no_change", "no change")

            :new when topline.state != "open" ->
              error("topline_closed", "topline is closed")

            :new ->
              now = mutation_time(call)

              Txn.q(txn, "UPDATE toplines SET title = ?2, updatedAt = ?3 WHERE id = ?1", [
                topline_id,
                title,
                now
              ])

              append_event(
                txn,
                topline_id,
                "topline_renamed",
                nil,
                nil,
                nil,
                caller,
                reason,
                now,
                %{
                  fromTitle: topline.title,
                  toTitle: title
                }
              )

              response = %{topline: summary_in_txn(txn, topline_id)}
              remember(txn, caller.user, "topline-update", key, fingerprint, response)
              response
          end
        end
      end)
    end
  end

  @spec close(DB.server(), map()) :: map()
  def close(db, call), do: change_state(db, call, "topline-close", "open", "closed")

  @spec reopen(DB.server(), map()) :: map()
  def reopen(db, call), do: change_state(db, call, "topline-reopen", "closed", "open")

  defp change_state(db, call, operation, from_state, to_state) do
    params = Map.get(call, :params, %{})

    with {:ok, caller} <- caller(db, Map.get(call, :principal)),
         :ok <- valid_shape(params, [:idempotency_key, :reason, :topline_id]),
         :ok <- valid_id(param(params, :topline_id), "tl_"),
         :ok <- valid_reason(param(params, :reason)),
         :ok <- valid_key(param(params, :idempotency_key)) do
      topline_id = param(params, :topline_id)
      reason = param(params, :reason)
      key = param(params, :idempotency_key)
      fingerprint = fingerprint(operation, %{reason: reason, toplineId: topline_id})

      transaction!(db, fn txn ->
        with {:ok, caller} <- reauthorize(txn, caller),
             {:ok, topline} <- visible_topline(txn, topline_id, caller) do
          case replay(txn, caller.user, operation, key, fingerprint) do
            {:ok, response} ->
              response

            :conflict ->
              error("idempotency_conflict", "idempotency key conflicts with a prior request")

            :new when topline.state != from_state ->
              error("invalid_transition", "invalid state transition")

            :new ->
              now = mutation_time(call)
              closed_at = if to_state == "closed", do: now, else: nil

              Txn.q(
                txn,
                "UPDATE toplines SET state = ?2, updatedAt = ?3, closedAt = ?4 WHERE id = ?1",
                [topline_id, to_state, now, closed_at]
              )

              kind = if to_state == "closed", do: "topline_closed", else: "topline_reopened"

              append_event(txn, topline_id, kind, nil, nil, nil, caller, reason, now, %{
                fromState: from_state,
                toState: to_state
              })

              response = %{topline: summary_in_txn(txn, topline_id)}
              remember(txn, caller.user, operation, key, fingerprint, response)
              response
          end
        end
      end)
    end
  end

  @spec link_work(DB.server(), map()) :: map()
  def link_work(db, call) do
    params = Map.get(call, :params, %{})

    with {:ok, caller} <- caller(db, Map.get(call, :principal)),
         :ok <- valid_shape(params, [:idempotency_key, :reason, :topline_id, :work_item_id]),
         :ok <- valid_id(param(params, :topline_id), "tl_"),
         :ok <- valid_id(param(params, :work_item_id), "wi_"),
         :ok <- valid_reason(param(params, :reason)),
         :ok <- valid_key(param(params, :idempotency_key)) do
      operation = "topline-link-work"
      topline_id = param(params, :topline_id)
      work_item_id = param(params, :work_item_id)
      reason = param(params, :reason)
      key = param(params, :idempotency_key)

      fingerprint =
        fingerprint(operation, %{
          reason: reason,
          toplineId: topline_id,
          workItemId: work_item_id
        })

      transaction!(db, fn txn ->
        with {:ok, caller} <- reauthorize(txn, caller),
             {:ok, topline} <- visible_topline(txn, topline_id, caller),
             {:ok, work_item} <- visible_work_item(txn, work_item_id, caller),
             :ok <- same_owner(topline, work_item) do
          case replay(txn, caller.user, operation, key, fingerprint) do
            {:ok, response} ->
              response

            :conflict ->
              error("idempotency_conflict", "idempotency key conflicts with a prior request")

            :new ->
              cond do
                topline.state != "open" ->
                  error("topline_closed", "topline is closed")

                active_membership?(txn, topline_id, work_item_id) ->
                  error("membership_exists", "active membership already exists")

                true ->
                  now = mutation_time(call)
                  membership_id = id("tlm_")

                  Txn.q(
                    txn,
                    """
                    INSERT INTO topline_work_memberships
                      (id, toplineId, workItemId, ownerUserId, linkReason,
                       linkedActorKind, linkedActorRef, linkedAt)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                    """,
                    [
                      membership_id,
                      topline_id,
                      work_item_id,
                      topline.owner_user_id,
                      reason,
                      caller.actor_kind,
                      caller.actor_ref,
                      now
                    ]
                  )

                  touch_topline(txn, topline_id, now)

                  append_event(
                    txn,
                    topline_id,
                    "work_linked",
                    membership_id,
                    nil,
                    nil,
                    caller,
                    reason,
                    now,
                    %{workItemId: work_item_id, linkReason: reason}
                  )

                  response = %{
                    membership: membership_in_txn(txn, membership_id),
                    resolvedPlacementId: nil
                  }

                  remember(txn, caller.user, operation, key, fingerprint, response)
                  response
              end
          end
        end
      end)
    end
  end

  @spec unlink_work(DB.server(), map()) :: map()
  def unlink_work(db, call) do
    params = Map.get(call, :params, %{})

    with {:ok, caller} <- caller(db, Map.get(call, :principal)),
         :ok <- valid_shape(params, [:idempotency_key, :membership_id, :reason]),
         :ok <- valid_id(param(params, :membership_id), "tlm_"),
         :ok <- valid_reason(param(params, :reason)),
         :ok <- valid_key(param(params, :idempotency_key)) do
      operation = "topline-unlink-work"
      membership_id = param(params, :membership_id)
      reason = param(params, :reason)
      key = param(params, :idempotency_key)
      fingerprint = fingerprint(operation, %{membershipId: membership_id, reason: reason})

      transaction!(db, fn txn ->
        with {:ok, caller} <- reauthorize(txn, caller),
             {:ok, membership} <- visible_membership(txn, membership_id, caller) do
          case replay(txn, caller.user, operation, key, fingerprint) do
            {:ok, response} ->
              response

            :conflict ->
              error("idempotency_conflict", "idempotency key conflicts with a prior request")

            :new ->
              if membership.unlinked_at do
                error("membership_ended", "membership is already ended")
              else
                now = mutation_time(call)

                concern_ids =
                  concern_ids_for_work(txn, membership.topline_id, membership.work_item_id)

                Txn.q(
                  txn,
                  """
                  UPDATE topline_work_memberships
                  SET unlinkReason = ?2, unlinkedActorKind = ?3,
                      unlinkedActorRef = ?4, unlinkedAt = ?5
                  WHERE id = ?1 AND unlinkedAt IS NULL
                  """,
                  [membership_id, reason, caller.actor_kind, caller.actor_ref, now]
                )

                touch_topline(txn, membership.topline_id, now)

                append_event(
                  txn,
                  membership.topline_id,
                  "work_unlinked",
                  membership_id,
                  nil,
                  nil,
                  caller,
                  reason,
                  now,
                  %{workItemId: membership.work_item_id, unlinkReason: reason}
                )

                Txn.q(
                  txn,
                  "DELETE FROM topline_concern_refs WHERE toplineId = ?1 AND workItemId = ?2",
                  [membership.topline_id, membership.work_item_id]
                )

                response = %{
                  membership: membership_in_txn(txn, membership_id),
                  openedPlacement: nil,
                  untaggedConcernIds: concern_ids
                }

                remember(txn, caller.user, operation, key, fingerprint, response)
                response
              end
          end
        end
      end)
    end
  end

  @spec create_concern(DB.server(), map()) :: map()
  def create_concern(db, call) do
    params = Map.get(call, :params, %{})

    with {:ok, caller} <- caller(db, Map.get(call, :principal)),
         :ok <- valid_shape(params, [:idempotency_key, :title, :topline_id]),
         :ok <- valid_id(param(params, :topline_id), "tl_"),
         {:ok, title} <- canonical_title(param(params, :title)),
         :ok <- valid_key(param(params, :idempotency_key)) do
      topline_id = param(params, :topline_id)
      key = param(params, :idempotency_key)
      operation = "topline-concern-create"
      fingerprint = fingerprint(operation, %{title: title, toplineId: topline_id})

      transaction!(db, fn txn ->
        with {:ok, caller} <- reauthorize(txn, caller),
             {:ok, topline} <- visible_topline(txn, topline_id, caller) do
          case replay(txn, caller.user, operation, key, fingerprint) do
            {:ok, response} ->
              response

            :conflict ->
              error("idempotency_conflict", "idempotency key conflicts with a prior request")

            :new when topline.state != "open" ->
              error("topline_closed", "topline is closed")

            :new ->
              now = mutation_time(call)
              concern_id = id("tlc_")

              Txn.q(
                txn,
                """
                INSERT INTO topline_concerns
                  (id, toplineId, title, createdActorKind, createdActorRef, createdAt)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """,
                [concern_id, topline_id, title, caller.actor_kind, caller.actor_ref, now]
              )

              touch_topline(txn, topline_id, now)

              append_event(
                txn,
                topline_id,
                "concern_created",
                nil,
                concern_id,
                nil,
                caller,
                nil,
                now,
                %{title: title}
              )

              response = %{concern: concern_in_txn(txn, concern_id)}
              remember(txn, caller.user, operation, key, fingerprint, response)
              response
          end
        end
      end)
    end
  end

  @spec link_concern_work(DB.server(), map()) :: map()
  def link_concern_work(db, call) do
    params = Map.get(call, :params, %{})

    with {:ok, caller} <- caller(db, Map.get(call, :principal)),
         :ok <- valid_shape(params, [:concern_id, :idempotency_key, :reason, :work_item_id]),
         :ok <- valid_id(param(params, :concern_id), "tlc_"),
         :ok <- valid_id(param(params, :work_item_id), "wi_"),
         :ok <- valid_reason(param(params, :reason)),
         :ok <- valid_key(param(params, :idempotency_key)) do
      concern_id = param(params, :concern_id)
      work_item_id = param(params, :work_item_id)
      reason = param(params, :reason)
      key = param(params, :idempotency_key)
      operation = "topline-concern-link-work"

      fingerprint =
        fingerprint(operation, %{concernId: concern_id, reason: reason, workItemId: work_item_id})

      transaction!(db, fn txn ->
        with {:ok, caller} <- reauthorize(txn, caller),
             {:ok, concern} <- visible_concern(txn, concern_id, caller),
             {:ok, work_item} <- visible_work_item(txn, work_item_id, caller),
             :ok <- concern_contains_work(txn, concern, work_item) do
          case replay(txn, caller.user, operation, key, fingerprint) do
            {:ok, response} ->
              response

            :conflict ->
              error("idempotency_conflict", "idempotency key conflicts with a prior request")

            :new when concern.topline_state != "open" ->
              error("topline_closed", "topline is closed")

            :new ->
              if concern_tagged?(txn, concern_id, work_item_id) do
                error("concern_tag_exists", "concern tag is already applied to work item")
              else
                now = mutation_time(call)

                Txn.q(
                  txn,
                  """
                  INSERT INTO topline_concern_refs
                    (toplineId, concernId, workItemId, tagReason,
                     taggedActorKind, taggedActorRef, taggedAt)
                  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                  """,
                  [
                    concern.topline_id,
                    concern_id,
                    work_item_id,
                    reason,
                    caller.actor_kind,
                    caller.actor_ref,
                    now
                  ]
                )

                touch_topline(txn, concern.topline_id, now)

                append_event(
                  txn,
                  concern.topline_id,
                  "concern_work_tagged",
                  nil,
                  concern_id,
                  nil,
                  caller,
                  reason,
                  now,
                  %{workItemId: work_item_id, tagReason: reason}
                )

                response = %{concernTag: concern_tag_in_txn(txn, concern_id, work_item_id)}
                remember(txn, caller.user, operation, key, fingerprint, response)
                response
              end
          end
        end
      end)
    end
  end

  @spec unlink_concern_work(DB.server(), map()) :: map()
  def unlink_concern_work(db, call) do
    params = Map.get(call, :params, %{})

    with {:ok, caller} <- caller(db, Map.get(call, :principal)),
         :ok <- valid_shape(params, [:concern_id, :idempotency_key, :reason, :work_item_id]),
         :ok <- valid_id(param(params, :concern_id), "tlc_"),
         :ok <- valid_id(param(params, :work_item_id), "wi_"),
         :ok <- valid_reason(param(params, :reason)),
         :ok <- valid_key(param(params, :idempotency_key)) do
      concern_id = param(params, :concern_id)
      work_item_id = param(params, :work_item_id)
      reason = param(params, :reason)
      key = param(params, :idempotency_key)
      operation = "topline-concern-unlink-work"

      fingerprint =
        fingerprint(operation, %{concernId: concern_id, reason: reason, workItemId: work_item_id})

      transaction!(db, fn txn ->
        with {:ok, caller} <- reauthorize(txn, caller),
             {:ok, concern} <- visible_concern(txn, concern_id, caller),
             {:ok, _work_item} <- visible_work_item(txn, work_item_id, caller) do
          case replay(txn, caller.user, operation, key, fingerprint) do
            {:ok, response} ->
              response

            :conflict ->
              error("idempotency_conflict", "idempotency key conflicts with a prior request")

            :new ->
              if concern_tagged?(txn, concern_id, work_item_id) do
                now = mutation_time(call)

                Txn.q(
                  txn,
                  "DELETE FROM topline_concern_refs WHERE concernId = ?1 AND workItemId = ?2",
                  [concern_id, work_item_id]
                )

                touch_topline(txn, concern.topline_id, now)

                append_event(
                  txn,
                  concern.topline_id,
                  "concern_work_untagged",
                  nil,
                  concern_id,
                  nil,
                  caller,
                  reason,
                  now,
                  %{workItemId: work_item_id, untagReason: reason}
                )

                response = %{concernId: concern_id, workItemId: work_item_id}
                remember(txn, caller.user, operation, key, fingerprint, response)
                response
              else
                error("concern_tag_absent", "concern tag is not applied to work item")
              end
          end
        end
      end)
    end
  end

  @spec list(DB.server(), map()) :: map()
  def list(db, call) do
    params = Map.get(call, :params, %{})

    with {:ok, caller} <- caller(db, Map.get(call, :principal)),
         :ok <- valid_shape(params, [:state], optional: [:state]),
         {:ok, state} <- list_state(param(params, :state)) do
      {owner_sql, owner_params} = owner_filter(caller, "t")
      {state_sql, state_params} = state_filter(state, length(owner_params) + 1)

      {:ok, rows} =
        DB.query(
          db,
          summary_sql("WHERE 1 = 1 #{owner_sql} #{state_sql} ORDER BY t.createdAt ASC, t.id ASC"),
          owner_params ++ state_params
        )

      %{toplines: Enum.map(rows, &summary/1)}
    end
  end

  @spec get(DB.server(), map()) :: map()
  def get(db, call) do
    params = Map.get(call, :params, %{})

    with {:ok, caller} <- caller(db, Map.get(call, :principal)),
         :ok <- valid_shape(params, [:history, :topline_id], optional: [:history]),
         :ok <- valid_id(param(params, :topline_id), "tl_"),
         :ok <- valid_history(param(params, :history)) do
      topline_id = param(params, :topline_id)
      {owner_sql, owner_params} = owner_filter(caller, "t")

      {:ok, rows} =
        DB.query(
          db,
          summary_sql("WHERE t.id = ?1 #{shifted_owner_filter(owner_sql, 1)}"),
          [topline_id | owner_params]
        )

      case rows do
        [] ->
          error("not_found", "record not found")

        [row] ->
          detail =
            row
            |> summary()
            |> Map.put(:workMemberships, active_memberships(db, topline_id))
            |> Map.put(:concerns, concerns(db, topline_id))

          detail =
            if param(params, :history) == true,
              do: Map.put(detail, :history, history(db, topline_id)),
              else: detail

          %{topline: detail}
      end
    end
  end

  def leave_unlinked(db, call) do
    params = Map.get(call, :params, %{})

    with {:ok, caller} <- caller(db, Map.get(call, :principal)),
         :ok <- valid_shape(params, [:idempotency_key, :reason, :work_item_id]),
         :ok <- valid_id(param(params, :work_item_id), "wi_"),
         :ok <- valid_reason(param(params, :reason)),
         :ok <- valid_key(param(params, :idempotency_key)) do
      work_item_id = param(params, :work_item_id)
      reason = param(params, :reason)
      key = param(params, :idempotency_key)
      operation = "topline-work-leave-unlinked"
      fingerprint = fingerprint(operation, %{workItemId: work_item_id, reason: reason})

      transaction!(db, fn txn ->
        with {:ok, caller} <- reauthorize(txn, caller),
             {:ok, _work_item} <- visible_work_item(txn, work_item_id, caller) do
          case replay(txn, caller.user, operation, key, fingerprint) do
            {:ok, response} ->
              response

            :conflict ->
              error("idempotency_conflict", "idempotency key conflicts with a prior request")

            :new ->
              case resolve_placement_in_txn(txn, %{
                     work_item_id: work_item_id,
                     state: "left_unlinked",
                     actor_kind: caller.actor_kind,
                     actor_ref: caller.actor_ref,
                     reason: reason,
                     at: mutation_time(call)
                   }) do
                nil ->
                  error("placement_not_pending", "placement is not pending")

                placement ->
                  response = %{placement: placement}
                  remember(txn, caller.user, operation, key, fingerprint, response)
                  response
              end
          end
        end
      end)
    end
  end

  def list_placements(db, call) do
    params = Map.get(call, :params, %{})

    with {:ok, caller} <- caller(db, Map.get(call, :principal)),
         :ok <- valid_shape(params, [:state], optional: [:state]),
         {:ok, state} <- placement_state(param(params, :state)) do
      transaction!(db, fn txn ->
        {owner_sql, owner_params} = owner_filter(caller, "p")

        {state_sql, state_params} =
          case state do
            "all" ->
              {"", []}

            "pending" ->
              {" AND p.state = ?#{length(owner_params) + 1}", ["pending"]}

            "resolved" ->
              {" AND p.state IN (?#{length(owner_params) + 1}, ?#{length(owner_params) + 2}, ?#{length(owner_params) + 3})",
               ["linked", "left_unlinked", "work_terminal"]}
          end

        ids =
          Txn.q(
            txn,
            "SELECT p.id FROM topline_placement_obligations p WHERE 1 = 1 #{owner_sql} #{state_sql} ORDER BY p.openedAt ASC, p.id ASC",
            owner_params ++ state_params
          )
          |> Enum.map(&hd/1)

        %{placements: Enum.map(ids, &placement_in_txn(txn, &1))}
      end)
    end
  end

  defp summary_sql(where) do
    """
    SELECT t.id, t.ownerUserId, t.title, t.state, t.createdActorKind,
           t.createdActorRef, t.createdAt, t.updatedAt, t.closedAt,
           (SELECT COUNT(*) FROM topline_work_memberships m
            WHERE m.toplineId = t.id AND m.unlinkedAt IS NULL),
          (SELECT COUNT(*) FROM topline_concerns c
            WHERE c.toplineId = t.id)
    FROM toplines t
    #{where}
    """
  end

  defp summary_in_txn(txn, topline_id) do
    [row] = Txn.q(txn, summary_sql("WHERE t.id = ?1"), [topline_id])
    summary(row)
  end

  defp dependency_vector(db, topline_id) do
    {:ok, [[topline_version]]} =
      DB.query(
        db,
        "SELECT COALESCE(MAX(seq), 0) FROM topline_events WHERE toplineId = ?1",
        [topline_id]
      )

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT m.id,
               (SELECT seq FROM topline_events e
                WHERE e.toplineId = m.toplineId AND e.membershipId = m.id
                  AND e.kind = 'work_linked'),
               wi.id,
               COALESCE((SELECT rowVersion FROM work_item_versions v
                         WHERE v.workItemId = wi.id), wi.createdAt)
        FROM topline_work_memberships m
        JOIN work_items wi ON wi.id = m.workItemId
        WHERE m.toplineId = ?1 AND m.unlinkedAt IS NULL
        ORDER BY m.id ASC
        """,
        [topline_id]
      )

    membership_entries =
      Enum.map(rows, fn [membership_id, version, _work_id, _work_item_row_version] ->
        ["topline work memberships", membership_id, version]
      end)

    work_entries =
      rows
      |> Enum.map(fn [_membership_id, _version, work_id, work_item_row_version] ->
        ["work items", work_id, work_item_row_version]
      end)
      |> Enum.uniq()

    [["toplines", topline_id, topline_version] | membership_entries ++ work_entries]
    |> Enum.sort()
  end

  defp summary([
         id,
         owner,
         title,
         state,
         actor_kind,
         actor_ref,
         created,
         updated,
         closed,
         work_count,
         concern_count
       ]) do
    %{
      id: id,
      ownerUserId: owner,
      title: title,
      state: state,
      createdActor: actor(actor_kind, actor_ref),
      createdAt: created,
      updatedAt: updated,
      closedAt: closed,
      activeWorkCount: work_count,
      openConcernCount: concern_count
    }
  end

  defp active_memberships(db, topline_id) do
    {:ok, rows} =
      DB.query(
        db,
        membership_sql(
          "WHERE m.toplineId = ?1 AND m.unlinkedAt IS NULL ORDER BY m.linkedAt ASC, m.id ASC"
        ),
        [topline_id]
      )

    Enum.map(rows, &membership/1)
  end

  defp membership_in_txn(txn, membership_id) do
    [row] = Txn.q(txn, membership_sql("WHERE m.id = ?1"), [membership_id])
    membership(row)
  end

  defp membership_sql(where) do
    """
    SELECT m.id, m.toplineId, m.workItemId, m.ownerUserId, m.linkReason,
           m.linkedActorKind, m.linkedActorRef, m.linkedAt, m.unlinkReason,
           m.unlinkedActorKind, m.unlinkedActorRef, m.unlinkedAt,
           wi.title, wi.state
    FROM topline_work_memberships m
    JOIN work_items wi ON wi.id = m.workItemId
    #{where}
    """
  end

  defp membership([
         id,
         topline_id,
         work_item_id,
         owner,
         link_reason,
         linked_kind,
         linked_ref,
         linked_at,
         unlink_reason,
         unlinked_kind,
         unlinked_ref,
         unlinked_at,
         work_title,
         work_state
       ]) do
    %{
      id: id,
      toplineId: topline_id,
      workItemId: work_item_id,
      ownerUserId: owner,
      linkReason: link_reason,
      linkedActor: actor(linked_kind, linked_ref),
      linkedAt: linked_at,
      unlinkReason: unlink_reason,
      unlinkedActor: actor(unlinked_kind, unlinked_ref),
      unlinkedAt: unlinked_at,
      workItemTitle: work_title,
      workItemState: work_state
    }
  end

  defp concern_in_txn(txn, concern_id) do
    [row] = Txn.q(txn, concern_sql("WHERE c.id = ?1"), [concern_id])
    concern(row)
  end

  defp concerns(db, topline_id) do
    {:ok, rows} =
      DB.query(
        db,
        concern_sql("WHERE c.toplineId = ?1 ORDER BY c.createdAt ASC, c.id ASC"),
        [topline_id]
      )

    Enum.map(rows, &concern/1)
  end

  defp concern_sql(where) do
    """
    SELECT c.id, c.toplineId, c.title, c.createdActorKind, c.createdActorRef, c.createdAt,
           COALESCE((SELECT json_group_array(workItemId) FROM (
             SELECT r.workItemId FROM topline_concern_refs r
             WHERE r.concernId = c.id ORDER BY r.workItemId ASC
           )), '[]')
    FROM topline_concerns c
    #{where}
    """
  end

  defp concern([id, topline_id, title, created_kind, created_ref, created_at, work_item_ids]) do
    %{
      createdActor: actor(created_kind, created_ref),
      createdAt: created_at,
      id: id,
      title: title,
      toplineId: topline_id,
      workItemIds: JSON.decode!(work_item_ids)
    }
  end

  defp concern_tag_in_txn(txn, concern_id, work_item_id) do
    [[topline_id, ^concern_id, ^work_item_id, reason, kind, ref, tagged_at]] =
      Txn.q(
        txn,
        """
        SELECT toplineId, concernId, workItemId, tagReason,
               taggedActorKind, taggedActorRef, taggedAt
        FROM topline_concern_refs
        WHERE concernId = ?1 AND workItemId = ?2
        """,
        [concern_id, work_item_id]
      )

    %{
      concernId: concern_id,
      tagReason: reason,
      taggedActor: actor(kind, ref),
      taggedAt: tagged_at,
      toplineId: topline_id,
      workItemId: work_item_id
    }
  end

  defp placement_in_txn(txn, id) do
    case Txn.q(
           txn,
           """
           SELECT p.cause, p.causeRef, p.dueAt, p.id, p.openedActorKind,
                  p.openedActorRef, p.openedAt, p.ownerUserId, p.promptWakeId,
                  w.state, p.resolutionActorKind, p.resolutionActorRef,
                  p.resolutionReason, p.resolvedAt, p.state, p.workItemId, wi.title
           FROM topline_placement_obligations p
           JOIN wakes w ON w.wakeId = p.promptWakeId
           JOIN work_items wi ON wi.id = p.workItemId
           WHERE p.id = ?1
           """,
           [id]
         ) do
      [
        [
          cause,
          cause_ref,
          due_at,
          placement_id,
          opened_kind,
          opened_ref,
          opened_at,
          owner,
          wake_id,
          wake_state,
          resolution_kind,
          resolution_ref,
          resolution_reason,
          resolved_at,
          state,
          work_item_id,
          work_title
        ]
      ] ->
        %{
          cause: cause,
          causeRef: cause_ref,
          dueAt: due_at,
          id: placement_id,
          openedActor: actor(opened_kind, opened_ref),
          openedAt: opened_at,
          ownerUserId: owner,
          promptWake: %{id: wake_id, state: wake_state},
          resolutionActor: actor(resolution_kind, resolution_ref),
          resolutionReason: resolution_reason,
          resolvedAt: resolved_at,
          state: state,
          workItemId: work_item_id,
          workItemTitle: work_title
        }

      [] ->
        nil
    end
  end

  defp require_reopen_source!(txn, seq, work_item_id) do
    case Txn.q(
           txn,
           """
           SELECT 1 FROM causal_events
           WHERE seq = ?1 AND jobRef = ?2 AND kind = 'disposition_transition'
             AND json_extract(detail, '$.workItemId') = ?2
             AND json_extract(detail, '$.fromState') = 'iceboxed'
             AND json_extract(detail, '$.toState') = 'open'
           """,
           [seq, work_item_id]
         ) do
      [[1]] -> :ok
      [] -> raise "reopened placement source causal event does not match the work item"
    end
  end

  defp require_terminal_source!(txn, seq, work_item_id, reason) do
    to_state =
      case reason do
        "reupgrade_terminal_reconciliation_closed" -> "closed"
        "reupgrade_terminal_reconciliation_failed" -> "failed"
        "reupgrade_terminal_reconciliation_iceboxed" -> "iceboxed"
        _ -> raise "invalid process placement resolution reason"
      end

    case Txn.q(
           txn,
           """
           SELECT 1 FROM causal_events
           WHERE seq = ?1 AND jobRef = ?2 AND kind = 'disposition_transition'
             AND json_extract(detail, '$.workItemId') = ?2
             AND json_extract(detail, '$.toState') = ?3
           """,
           [seq, work_item_id, to_state]
         ) do
      [[1]] -> :ok
      [] -> raise "terminal placement source causal event does not match the work item"
    end
  end

  defp history(db, topline_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT toplineId, seq, kind, membershipId, concernId,
               actorKind, actorRef, reason, eventAt, detail
        FROM topline_events
        WHERE toplineId = ?1
        ORDER BY seq ASC
        """,
        [topline_id]
      )

    Enum.map(rows, &event/1)
  end

  defp event([
         topline_id,
         seq,
         kind,
         membership_id,
         concern_id,
         actor_kind,
         actor_ref,
         reason,
         at,
         detail
       ]) do
    %{
      actor: actor(actor_kind, actor_ref),
      at: at,
      concernId: concern_id,
      detail: atomize_keys(JSON.decode!(detail)),
      kind: kind,
      membershipId: membership_id,
      reason: reason,
      seq: seq,
      toplineId: topline_id
    }
  end

  defp append_event(
         txn,
         topline_id,
         kind,
         membership_id,
         concern_id,
         _concern_reference_id,
         caller,
         reason,
         at,
         detail
       ) do
    [[seq]] =
      Txn.q(txn, "SELECT COALESCE(MAX(seq), 0) + 1 FROM topline_events WHERE toplineId = ?1", [
        topline_id
      ])

    Txn.q(
      txn,
      """
      INSERT INTO topline_events
        (toplineId, seq, kind, membershipId, concernId,
         actorKind, actorRef, reason, eventAt, detail)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
      """,
      [
        topline_id,
        seq,
        kind,
        membership_id,
        concern_id,
        caller.actor_kind,
        caller.actor_ref,
        reason,
        at,
        canonical_json(detail)
      ]
    )
  end

  defp visible_topline(txn, id, caller) do
    {owner_sql, owner_params} = owner_filter(caller, "")

    rows =
      Txn.q(
        txn,
        "SELECT id, ownerUserId, title, state FROM toplines WHERE id = ?1 #{shifted_owner_filter(owner_sql, 1)}",
        [id | owner_params]
      )

    case rows do
      [[topline_id, owner, title, state]] ->
        {:ok, %{id: topline_id, owner_user_id: owner, title: title, state: state}}

      [] ->
        error("not_found", "record not found")
    end
  end

  defp visible_work_item(txn, id, caller) do
    {owner_sql, owner_params} = owner_filter(caller, "")

    rows =
      Txn.q(
        txn,
        "SELECT id, ownerUserId FROM work_items WHERE id = ?1 #{shifted_owner_filter(owner_sql, 1)}",
        [id | owner_params]
      )

    case rows do
      [[work_item_id, owner]] -> {:ok, %{id: work_item_id, owner_user_id: owner}}
      [] -> error("not_found", "record not found")
    end
  end

  defp visible_membership(txn, id, caller) do
    {owner_sql, owner_params} = owner_filter(caller, "m")

    rows =
      Txn.q(
        txn,
        """
        SELECT m.id, m.toplineId, m.workItemId, m.ownerUserId, m.unlinkedAt
        FROM topline_work_memberships m
        WHERE m.id = ?1 #{shifted_owner_filter(owner_sql, 1)}
        """,
        [id | owner_params]
      )

    case rows do
      [[membership_id, topline_id, work_item_id, owner, unlinked_at]] ->
        {:ok,
         %{
           id: membership_id,
           topline_id: topline_id,
           work_item_id: work_item_id,
           owner_user_id: owner,
           unlinked_at: unlinked_at
         }}

      [] ->
        error("not_found", "record not found")
    end
  end

  defp visible_concern(txn, id, caller) do
    {owner_sql, owner_params} = owner_filter(caller, "t")

    case Txn.q(
           txn,
           """
           SELECT c.id, c.toplineId, c.title, t.state
           FROM topline_concerns c
           JOIN toplines t ON t.id = c.toplineId
           WHERE c.id = ?1 #{shifted_owner_filter(owner_sql, 1)}
           """,
           [id | owner_params]
         ) do
      [[concern_id, topline_id, title, topline_state]] ->
        {:ok,
         %{id: concern_id, topline_id: topline_id, title: title, topline_state: topline_state}}

      [] ->
        error("not_found", "record not found")
    end
  end

  defp concern_contains_work(txn, concern, work_item) do
    if active_membership?(txn, concern.topline_id, work_item.id),
      do: :ok,
      else: error("topline_mismatch", "concern topline does not contain work item")
  end

  defp concern_tagged?(txn, concern_id, work_item_id) do
    case Txn.q(
           txn,
           "SELECT 1 FROM topline_concern_refs WHERE concernId = ?1 AND workItemId = ?2",
           [concern_id, work_item_id]
         ) do
      [[1]] -> true
      [] -> false
    end
  end

  defp concern_ids_for_work(txn, topline_id, work_item_id) do
    txn
    |> Txn.q(
      """
      SELECT concernId FROM topline_concern_refs
      WHERE toplineId = ?1 AND workItemId = ?2
      ORDER BY concernId ASC
      """,
      [topline_id, work_item_id]
    )
    |> Enum.map(fn [concern_id] -> concern_id end)
  end

  defp active_membership?(txn, topline_id, work_item_id) do
    case Txn.q(
           txn,
           "SELECT 1 FROM topline_work_memberships WHERE toplineId = ?1 AND workItemId = ?2 AND unlinkedAt IS NULL",
           [topline_id, work_item_id]
         ) do
      [[1]] -> true
      [] -> false
    end
  end

  defp touch_topline(txn, topline_id, at) do
    Txn.q(txn, "UPDATE toplines SET updatedAt = ?2 WHERE id = ?1", [topline_id, at])
    :ok
  end

  defp same_owner(%{owner_user_id: owner}, %{owner_user_id: owner}), do: :ok
  defp same_owner(_, _), do: error("owner_mismatch", "topline and work item owners differ")

  defp replay(txn, user, operation, key, fingerprint) do
    case Txn.q(
           txn,
           """
           SELECT requestFingerprint, canonicalResponse
           FROM topline_idempotency
           WHERE callerUserId = ?1 AND operation = ?2 AND idempotencyKey = ?3
           """,
           [user, operation, key]
         ) do
      [] -> :new
      [[^fingerprint, response]] -> {:ok, response |> JSON.decode!() |> atomize_keys()}
      [[_other, _response]] -> :conflict
    end
  end

  defp remember(txn, user, operation, key, fingerprint, response) do
    Txn.q(
      txn,
      """
      INSERT INTO topline_idempotency
        (callerUserId, operation, idempotencyKey, requestFingerprint, canonicalResponse)
      VALUES (?1, ?2, ?3, ?4, ?5)
      """,
      [user, operation, key, fingerprint, canonical_json(response)]
    )

    :ok
  end

  defp fingerprint(operation, parameters) do
    bytes = fingerprint_json(%{operation: operation, parameters: parameters})
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp canonical_json(value), do: encode_canonical_json(value, false)
  defp fingerprint_json(value), do: encode_canonical_json(value, true)

  defp encode_canonical_json(value, normalize?) when is_map(value) do
    members =
      value
      |> Enum.map(fn {key, item} -> {maybe_normalize(to_string(key), normalize?), item} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, item} ->
        [json_string(key), ?:, encode_canonical_json(item, normalize?)]
      end)
      |> Enum.intersperse(?,)

    IO.iodata_to_binary([?{, members, ?}])
  end

  defp encode_canonical_json(value, normalize?) when is_list(value) do
    items = value |> Enum.map(&encode_canonical_json(&1, normalize?)) |> Enum.intersperse(?,)
    IO.iodata_to_binary([?[, items, ?]])
  end

  defp encode_canonical_json(value, normalize?) when is_binary(value),
    do: value |> maybe_normalize(normalize?) |> json_string()

  defp encode_canonical_json(value, _normalize?) when is_integer(value),
    do: Integer.to_string(value)

  defp encode_canonical_json(true, _normalize?), do: "true"
  defp encode_canonical_json(false, _normalize?), do: "false"
  defp encode_canonical_json(nil, _normalize?), do: "null"

  defp maybe_normalize(value, true), do: normalize_string(value)
  defp maybe_normalize(value, false), do: value

  defp json_string(value) do
    encoded =
      value
      |> String.to_charlist()
      |> Enum.map(fn
        ?" -> "\\\""
        ?\\ -> "\\\\"
        codepoint when codepoint in 0..31 -> "\\u00" <> hex_byte(codepoint)
        codepoint -> <<codepoint::utf8>>
      end)

    IO.iodata_to_binary([?", encoded, ?"])
  end

  defp hex_byte(value), do: value |> Integer.to_string(16) |> String.pad_leading(2, "0")

  defp atomize_keys(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {existing_atom(key), atomize_keys(item)} end)
  end

  defp atomize_keys(value) when is_list(value), do: Enum.map(value, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp caller(_db, {:process, _}),
    do: error("process_denied", "process principals cannot access Toplines")

  defp caller(db, {:user, user}) when is_binary(user) do
    case DB.query(db, "SELECT isAdmin FROM users WHERE userId = ?1", [user]) do
      {:ok, [[admin]]} ->
        {:ok, %{user: user, admin: admin == 1, actor_kind: "user", actor_ref: user}}

      _ ->
        error("not_found", "record not found")
    end
  end

  defp caller(db, {:session, session}) when is_binary(session) do
    case DB.query(
           db,
           """
           SELECT s.ownerUserId, u.isAdmin
           FROM sessions s
           JOIN users u ON u.userId = s.ownerUserId
           WHERE s.sessionKey = ?1
           """,
           [session]
         ) do
      {:ok, [[user, admin]]} ->
        {:ok, %{user: user, admin: admin == 1, actor_kind: "session", actor_ref: session}}

      _ ->
        error("not_found", "record not found")
    end
  end

  defp caller(_db, _principal), do: error("invalid_message", "invalid message")

  defp reauthorize(txn, %{actor_kind: "user", actor_ref: user}) do
    case Txn.q(txn, "SELECT isAdmin FROM users WHERE userId = ?1", [user]) do
      [[admin]] ->
        {:ok, %{user: user, admin: admin == 1, actor_kind: "user", actor_ref: user}}

      [] ->
        error("not_found", "record not found")
    end
  end

  defp reauthorize(txn, %{actor_kind: "session", actor_ref: session}) do
    case Txn.q(
           txn,
           """
           SELECT s.ownerUserId, u.isAdmin
           FROM sessions s
           JOIN users u ON u.userId = s.ownerUserId
           WHERE s.sessionKey = ?1
           """,
           [session]
         ) do
      [[user, admin]] ->
        {:ok, %{user: user, admin: admin == 1, actor_kind: "session", actor_ref: session}}

      [] ->
        error("not_found", "record not found")
    end
  end

  defp owner_filter(%{admin: true}, _alias), do: {"", []}

  defp owner_filter(caller, alias_name) do
    prefix = if alias_name == "", do: "", else: alias_name <> "."
    {"AND #{prefix}ownerUserId = ?1", [caller.user]}
  end

  defp placement_state(nil), do: {:ok, "pending"}
  defp placement_state(state) when state in ["pending", "resolved", "all"], do: {:ok, state}
  defp placement_state(_), do: error("invalid_message", "invalid message")

  defp shifted_owner_filter("", _offset), do: ""

  defp shifted_owner_filter(sql, offset) do
    String.replace(sql, "?1", "?#{offset + 1}")
  end

  defp state_filter("all", _position), do: {"", []}
  defp state_filter(state, position), do: {"AND t.state = ?#{position}", [state]}

  defp public_states(nil), do: {:ok, nil}

  defp public_states(states) when is_list(states) do
    normalized =
      states
      |> Enum.uniq()
      |> Enum.sort_by(fn state -> Enum.find_index(~w(open closed), &(&1 == state)) end)

    if normalized != [] and Enum.all?(normalized, &(&1 in ~w(open closed))),
      do: {:ok, normalized},
      else: error("invalid_message", "invalid message")
  end

  defp public_states(_), do: error("invalid_message", "invalid message")

  defp public_state_filter(nil, _position), do: {"", []}

  defp public_state_filter(states, position) do
    placeholders =
      states
      |> Enum.with_index(position)
      |> Enum.map_join(",", fn {_state, index} -> "?#{index}" end)

    {"AND t.state IN (#{placeholders})", states}
  end

  defp list_state(nil), do: {:ok, "open"}
  defp list_state(state) when state in ~w(open closed all), do: {:ok, state}
  defp list_state(_), do: error("invalid_message", "invalid message")

  defp valid_history(nil), do: :ok
  defp valid_history(value) when is_boolean(value), do: :ok
  defp valid_history(_), do: error("invalid_message", "invalid message")

  defp valid_shape(params, keys, opts \\ [])

  defp valid_shape(params, keys, opts) when is_map(params) do
    optional = Keyword.get(opts, :optional, [])
    actual = params |> Map.keys() |> Enum.map(&param_key/1) |> MapSet.new()
    allowed = MapSet.new(keys)
    required = MapSet.difference(allowed, MapSet.new(optional))

    if MapSet.subset?(required, actual) and MapSet.subset?(actual, allowed),
      do: :ok,
      else: error("invalid_message", "invalid message")
  end

  defp valid_shape(_params, _keys, _opts), do: error("invalid_message", "invalid message")

  defp param_key(key) when is_atom(key), do: key
  defp param_key("idempotencyKey"), do: :idempotency_key
  defp param_key("concernId"), do: :concern_id
  defp param_key("membershipId"), do: :membership_id
  defp param_key("toplineId"), do: :topline_id
  defp param_key("workItemId"), do: :work_item_id
  defp param_key("history"), do: :history
  defp param_key("reason"), do: :reason
  defp param_key("state"), do: :state
  defp param_key("title"), do: :title
  defp param_key(_), do: :unknown

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, camel_key(key))
  end

  defp camel_key(:idempotency_key), do: "idempotencyKey"
  defp camel_key(:concern_id), do: "concernId"
  defp camel_key(:membership_id), do: "membershipId"
  defp camel_key(:topline_id), do: "toplineId"
  defp camel_key(:work_item_id), do: "workItemId"
  defp camel_key(key), do: Atom.to_string(key)

  defp canonical_title(value) when is_binary(value) do
    if String.valid?(value) do
      title = value |> trim_unicode() |> normalize_string()

      if scalar_length(title) in 1..2000,
        do: {:ok, title},
        else: error("invalid_message", "invalid message")
    else
      error("invalid_message", "invalid message")
    end
  end

  defp canonical_title(_), do: error("invalid_message", "invalid message")

  defp valid_reason(value) when is_binary(value) do
    if String.valid?(value) and scalar_length(trim_unicode(value)) in 1..4000,
      do: :ok,
      else: error("invalid_message", "invalid message")
  end

  defp valid_reason(_), do: error("invalid_message", "invalid message")

  defp valid_key(value) when is_binary(value) do
    if String.valid?(value) and scalar_length(trim_unicode(value)) in 1..200,
      do: :ok,
      else: error("invalid_message", "invalid message")
  end

  defp valid_key(_), do: error("invalid_message", "invalid message")

  defp valid_id(value, prefix) when is_binary(value) do
    if String.valid?(value) and String.starts_with?(value, prefix),
      do: :ok,
      else: error("invalid_message", "invalid message")
  end

  defp valid_id(_value, _prefix), do: error("invalid_message", "invalid message")

  defp trim_unicode(value) do
    codepoints = String.to_charlist(value)

    codepoints
    |> trim_leading()
    |> Enum.reverse()
    |> trim_leading()
    |> Enum.reverse()
    |> to_string()
  end

  defp trim_leading([codepoint | rest]) when codepoint in @white_space, do: trim_leading(rest)
  defp trim_leading(codepoints), do: codepoints

  defp normalize_string(value), do: :unicode.characters_to_nfc_binary(value)
  defp scalar_length(value), do: value |> String.to_charlist() |> length()

  defp actor(nil, nil), do: nil
  defp actor(kind, ref), do: %{kind: kind, ref: ref}

  defp mutation_time(call) do
    case Map.get(call, :now) do
      now when is_integer(now) and now >= 0 -> now
      _ -> System.system_time(:millisecond)
    end
  end

  defp id(prefix), do: prefix <> Tightbeam.Id.uuid4()
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp error(code, message), do: %{code: code, message: message}
end
