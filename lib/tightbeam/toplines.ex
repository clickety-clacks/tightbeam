defmodule Tightbeam.Toplines do
  @moduledoc """
  Durable human-intent Toplines and explicit Work membership.

  This module is the only runtime writer for the Topline rows in this tranche.
  `ensure_schema/1` is intentionally callable by focused tests and integration;
  production boot registration and the packaged Unicode 15.1 SQLite functions
  are a later, separately owned seam. Until that seam lands, validation here is
  authoritative for runtime writes and these tables are not exposed at boot.

  The old read-only work telemetry remains byte-compatible through `roster/2`
  and `topline/2`, which delegate to `Tightbeam.ExecutionMap`.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

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

  @ddl """
  CREATE TABLE IF NOT EXISTS toplines (
    id               TEXT PRIMARY KEY CHECK (substr(id, 1, 3) = 'tl_'),
    ownerUserId      TEXT NOT NULL REFERENCES users(userId),
    title            TEXT NOT NULL CHECK (typeof(title) = 'text' AND length(title) BETWEEN 1 AND 2000),
    state            TEXT NOT NULL CHECK (state IN ('open','closed')),
    createdActorKind TEXT NOT NULL CHECK (createdActorKind IN ('user','session')),
    createdActorRef  TEXT NOT NULL CHECK (length(trim(createdActorRef)) > 0),
    createdAt        INTEGER NOT NULL CHECK (typeof(createdAt) = 'integer'),
    updatedAt        INTEGER NOT NULL CHECK (typeof(updatedAt) = 'integer' AND updatedAt >= createdAt),
    closedAt         INTEGER,
    CHECK (
      (state = 'open' AND closedAt IS NULL) OR
      (state = 'closed' AND typeof(closedAt) = 'integer' AND closedAt >= createdAt)
    )
  );

  CREATE UNIQUE INDEX IF NOT EXISTS toplines_id_owner
    ON toplines (id, ownerUserId);
  CREATE UNIQUE INDEX IF NOT EXISTS work_items_id_owner
    ON work_items (id, ownerUserId);

  CREATE TABLE IF NOT EXISTS topline_work_memberships (
    id                TEXT PRIMARY KEY CHECK (substr(id, 1, 4) = 'tlm_'),
    toplineId         TEXT NOT NULL,
    workItemId        TEXT NOT NULL,
    ownerUserId       TEXT NOT NULL,
    linkReason        TEXT NOT NULL CHECK (length(trim(linkReason)) BETWEEN 1 AND 4000),
    linkedActorKind   TEXT NOT NULL CHECK (linkedActorKind IN ('user','session')),
    linkedActorRef    TEXT NOT NULL CHECK (length(trim(linkedActorRef)) > 0),
    linkedAt          INTEGER NOT NULL CHECK (typeof(linkedAt) = 'integer'),
    unlinkReason      TEXT,
    unlinkedActorKind TEXT,
    unlinkedActorRef  TEXT,
    unlinkedAt        INTEGER,
    FOREIGN KEY (toplineId, ownerUserId) REFERENCES toplines(id, ownerUserId),
    FOREIGN KEY (workItemId, ownerUserId) REFERENCES work_items(id, ownerUserId),
    CHECK (
      (unlinkedAt IS NULL AND unlinkReason IS NULL AND unlinkedActorKind IS NULL AND unlinkedActorRef IS NULL) OR
      (unlinkedAt IS NOT NULL AND unlinkReason IS NOT NULL AND
       unlinkedActorKind IS NOT NULL AND unlinkedActorRef IS NOT NULL AND
       typeof(unlinkedAt) = 'integer' AND unlinkedAt >= linkedAt AND
       length(trim(unlinkReason)) BETWEEN 1 AND 4000 AND
       unlinkedActorKind IN ('user','session') AND length(trim(unlinkedActorRef)) > 0)
    )
  );

  CREATE UNIQUE INDEX IF NOT EXISTS topline_memberships_active_pair
    ON topline_work_memberships (toplineId, workItemId)
    WHERE unlinkedAt IS NULL;
  CREATE UNIQUE INDEX IF NOT EXISTS topline_memberships_id_topline
    ON topline_work_memberships (id, toplineId);
  CREATE INDEX IF NOT EXISTS topline_memberships_work_active
    ON topline_work_memberships (workItemId)
    WHERE unlinkedAt IS NULL;

  CREATE TABLE IF NOT EXISTS topline_events (
    toplineId   TEXT NOT NULL REFERENCES toplines(id),
    seq         INTEGER NOT NULL CHECK (typeof(seq) = 'integer' AND seq >= 1),
    kind        TEXT NOT NULL CHECK (kind IN ('topline_created','work_linked','work_unlinked')),
    membershipId TEXT,
    actorKind   TEXT NOT NULL CHECK (actorKind IN ('user','session')),
    actorRef    TEXT NOT NULL CHECK (length(trim(actorRef)) > 0),
    reason      TEXT,
    eventAt     INTEGER NOT NULL CHECK (typeof(eventAt) = 'integer'),
    detail      TEXT NOT NULL CHECK (json_valid(detail) AND json_type(detail) = 'object'),
    PRIMARY KEY (toplineId, seq),
    FOREIGN KEY (membershipId, toplineId)
      REFERENCES topline_work_memberships(id, toplineId),
    CHECK (
      (kind = 'topline_created' AND membershipId IS NULL AND reason IS NULL) OR
      (kind IN ('work_linked','work_unlinked') AND membershipId IS NOT NULL AND
       length(trim(reason)) BETWEEN 1 AND 4000)
    )
  );

  CREATE TABLE IF NOT EXISTS topline_idempotency (
    callerUserId       TEXT NOT NULL REFERENCES users(userId),
    operation          TEXT NOT NULL CHECK (operation IN ('topline-create','topline-link-work','topline-unlink-work')),
    idempotencyKey     TEXT NOT NULL CHECK (length(trim(idempotencyKey)) BETWEEN 1 AND 200),
    requestFingerprint TEXT NOT NULL CHECK (length(requestFingerprint) = 64),
    canonicalResponse  TEXT NOT NULL CHECK (json_valid(canonicalResponse)),
    PRIMARY KEY (callerUserId, operation, idempotencyKey)
  );
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc false
  def __handle__(db, "topline-create", call), do: create(db, call)
  def __handle__(db, "topline-link-work", call), do: link_work(db, call)
  def __handle__(db, "topline-unlink-work", call), do: unlink_work(db, call)
  def __handle__(db, "toplines", call), do: list(db, call)
  def __handle__(db, "topline", call), do: get(db, call)

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

              append_event(txn, topline_id, "topline_created", nil, caller, nil, now, %{
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
                  caller,
                  reason,
                  now,
                  %{workItemId: membership.work_item_id, unlinkReason: reason}
                )

                response = %{
                  endedConcernReferenceIds: [],
                  membership: membership_in_txn(txn, membership_id),
                  openedPlacement: nil
                }

                remember(txn, caller.user, operation, key, fingerprint, response)
                response
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
            |> Map.put(:concerns, [])

          detail =
            if param(params, :history) == true,
              do: Map.put(detail, :history, history(db, topline_id)),
              else: detail

          %{topline: detail}
      end
    end
  end

  defp summary_sql(where) do
    """
    SELECT t.id, t.ownerUserId, t.title, t.state, t.createdActorKind,
           t.createdActorRef, t.createdAt, t.updatedAt, t.closedAt,
           (SELECT COUNT(*) FROM topline_work_memberships m
            WHERE m.toplineId = t.id AND m.unlinkedAt IS NULL)
    FROM toplines t
    #{where}
    """
  end

  defp summary_in_txn(txn, topline_id) do
    [row] = Txn.q(txn, summary_sql("WHERE t.id = ?1"), [topline_id])
    summary(row)
  end

  defp summary([id, owner, title, state, actor_kind, actor_ref, created, updated, closed, count]) do
    %{
      id: id,
      ownerUserId: owner,
      title: title,
      state: state,
      createdActor: actor(actor_kind, actor_ref),
      createdAt: created,
      updatedAt: updated,
      closedAt: closed,
      activeWorkCount: count,
      openConcernCount: 0
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

  defp history(db, topline_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT toplineId, seq, kind, membershipId, actorKind, actorRef,
               reason, eventAt, detail
        FROM topline_events
        WHERE toplineId = ?1
        ORDER BY seq ASC
        """,
        [topline_id]
      )

    Enum.map(rows, &event/1)
  end

  defp event([topline_id, seq, kind, membership_id, actor_kind, actor_ref, reason, at, detail]) do
    %{
      actor: actor(actor_kind, actor_ref),
      at: at,
      concernId: nil,
      concernReferenceId: nil,
      detail: atomize_keys(JSON.decode!(detail)),
      kind: kind,
      membershipId: membership_id,
      reason: reason,
      seq: seq,
      toplineId: topline_id
    }
  end

  defp append_event(txn, topline_id, kind, membership_id, caller, reason, at, detail) do
    [[seq]] =
      Txn.q(txn, "SELECT COALESCE(MAX(seq), 0) + 1 FROM topline_events WHERE toplineId = ?1", [
        topline_id
      ])

    Txn.q(
      txn,
      """
      INSERT INTO topline_events
        (toplineId, seq, kind, membershipId, actorKind, actorRef, reason, eventAt, detail)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
      """,
      [
        topline_id,
        seq,
        kind,
        membership_id,
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
        "SELECT id, ownerUserId, state FROM toplines WHERE id = ?1 #{shifted_owner_filter(owner_sql, 1)}",
        [id | owner_params]
      )

    case rows do
      [[topline_id, owner, state]] ->
        {:ok, %{id: topline_id, owner_user_id: owner, state: state}}

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

  defp shifted_owner_filter("", _offset), do: ""

  defp shifted_owner_filter(sql, offset) do
    String.replace(sql, "?1", "?#{offset + 1}")
  end

  defp state_filter("all", _position), do: {"", []}
  defp state_filter(state, position), do: {"AND t.state = ?#{position}", [state]}

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

  defp mutation_time(_call), do: System.system_time(:millisecond)
  defp id(prefix), do: prefix <> Tightbeam.Id.uuid4()

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp error(code, message), do: %{code: code, message: message}
end
