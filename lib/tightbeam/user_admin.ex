defmodule Tightbeam.UserAdmin do
  @moduledoc """
  Admin user listing and exact-user removal (admin-user-list-and-removal r3).

  Removal is deactivation: it stamps `removedAt` and `removedBy` on the
  existing `users` row and deletes or rewrites nothing else. Every record
  that names the user keeps its original attribution. A removed user cannot
  authenticate, be selected or act; those refusals live at the seams that
  admit a user (`Tightbeam.Devices`, the wire router and the operator
  session resolver), not here.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  # Spec §3 ownership columns. Any row naming the user here blocks removal.
  # `key` is the column whose values the refusal lists.
  @ownership [
    %{table: "sessions", key: "sessionKey"},
    %{table: "work_items", key: "id"},
    %{table: "toplines", key: "id"},
    %{table: "decision_requests", key: "id"},
    %{table: "roles", key: "name"},
    %{table: "assets", key: "assetId"},
    %{table: "topline_work_memberships", key: "id"},
    %{table: "topline_placement_obligations", key: "id"},
    %{table: "session_po_associations", key: "sessionKey"},
    %{table: "wakes", key: "wakeId"},
    %{table: "condition_facts", key: "id"}
  ]

  # An open decision request addressed to the user is an obligation it could no
  # longer discharge once removed (spec §3, review P1). Requests the user owns
  # are already counted under decision_requests.ownerUserId.
  @open_expecter "decision_requests.expecterUserId(open)"
  @open_expecter_where "status = 'open' AND expecterUserId = ?1 AND ownerUserId != ?1"

  @user_columns "userId, isAdmin, createdAt, removedAt, removedBy"
  @removed_sql "SELECT 1 FROM users WHERE userId = ?1 AND removedAt IS NOT NULL"

  @id_limit 20

  @doc "Every ownership entry key, in report order."
  def ownership_keys, do: Enum.map(@ownership, &"#{&1.table}.ownerUserId") ++ [@open_expecter]

  @doc "R1: every user, active and removed, ordered by createdAt then userId."
  @spec list(GenServer.server()) :: [map()]
  def list(db) do
    {:ok, rows} =
      DB.transaction(db, fn txn ->
        context = context_in_txn(txn)

        txn
        |> Txn.q("SELECT #{@user_columns} FROM users ORDER BY createdAt, userId")
        |> Enum.map(fn [user_id | _] = user ->
          row(user, context, owned_in_txn(txn, user_id).counts)
        end)
      end)

    rows
  end

  @doc """
  R3/R6: remove one exact user. Returns `%{user: row}` or a refusal map with
  `code` and `message`. A refusal writes nothing.
  """
  @spec remove(GenServer.server(), map()) :: map()
  def remove(db, call) do
    target = call.params[:user_id]
    principal = acting_principal(call)

    {:ok, result} =
      DB.transaction(db, fn txn ->
        with {:ok, actor} <- acting_admin(txn, principal),
             {:ok, user} <- target_in_txn(txn, target),
             :ok <- not_self(actor, target),
             :ok <- not_last_admin(txn, user),
             :ok <- owns_nothing(txn, target) do
          Txn.q(
            txn,
            "UPDATE users SET removedAt = ?2, removedBy = ?3 WHERE userId = ?1 AND removedAt IS NULL",
            [target, System.system_time(:millisecond), principal_string(principal)]
          )

          1 = Txn.changes(txn)

          [stamped] = Txn.q(txn, "SELECT #{@user_columns} FROM users WHERE userId = ?1", [target])

          %{user: row(stamped, context_in_txn(txn), owned_in_txn(txn, target).counts)}
        end
      end)

    result
  end

  @doc "True when the user exists and carries a removal stamp."
  @spec removed?(GenServer.server(), String.t() | nil) :: boolean()
  def removed?(db, user_id) when is_binary(user_id) do
    {:ok, rows} = DB.query(db, @removed_sql, [user_id])
    rows == [[1]]
  end

  def removed?(_db, _user_id), do: false

  @doc "The same check inside an open transaction."
  @spec removed_in_txn?(Txn.t(), String.t() | nil) :: boolean()
  def removed_in_txn?(%Txn{} = txn, user_id) when is_binary(user_id) do
    Txn.q(txn, @removed_sql, [user_id]) == [[1]]
  end

  def removed_in_txn?(%Txn{}, _user_id), do: false

  defmodule RemovedUserError do
    @moduledoc """
    Raised inside a writer's transaction when the write would name a removed
    user as owner or target. Raising rolls the transaction back; `Dispatch`
    turns it into the `user_removed` refusal.
    """
    defexception [:user_id, :diagnostic]

    @impl true
    def message(%{user_id: user_id}), do: Tightbeam.UserAdmin.removed_refusal(user_id).message
  end

  @doc """
  R5 write guard. Call it in the same transaction as, and before, any insert
  that names `user_id` as owner or target. A removal that commits before this
  check makes the writer refuse; one that commits after finds the new row and
  refuses removal with `user_owns_rows`. A nil or unknown user passes, leaving
  existing unknown-user behavior unchanged.
  """
  @spec ensure_active_in_txn!(Txn.t(), String.t() | nil) :: :ok
  def ensure_active_in_txn!(%Txn{} = txn, user_id) do
    if removed_in_txn?(txn, user_id), do: raise(RemovedUserError, user_id: user_id), else: :ok
  end

  @doc """
  The `user_removed` refusal for a raised `RemovedUserError`, including one
  surfaced by a writer's `{:ok, _} = DB.transaction(...)` match; else nil.
  """
  @spec refusal_for_exception(Exception.t()) :: map() | nil
  def refusal_for_exception(%RemovedUserError{user_id: user_id}), do: removed_refusal(user_id)

  def refusal_for_exception(%MatchError{term: {:error, %RemovedUserError{user_id: user_id}}}),
    do: removed_refusal(user_id)

  def refusal_for_exception(_exception), do: nil

  @doc "The fixed refusal for any admission or write naming a removed user."
  @spec removed_refusal(String.t()) :: %{code: String.t(), message: String.t()}
  def removed_refusal(user_id),
    do: %{
      code: "user_removed",
      message: "user #{user_id} was removed; it cannot authenticate, be selected or act"
    }

  # A call without a transport principal is attributed by a `user:` origin only;
  # any other origin has no attributable acting user.
  defp acting_principal(%{principal: principal}) when not is_nil(principal), do: principal
  defp acting_principal(%{origin: "user:" <> user_id}) when user_id != "", do: {:user, user_id}
  defp acting_principal(_call), do: nil

  # C3: removal needs an attributable acting user who is an active effective
  # admin. A process principal has no acting user and is refused.
  defp acting_admin(txn, principal) do
    acting =
      case principal do
        {:user, user_id} ->
          user_id

        {:session, session_key} ->
          session_owner(txn, session_key)

        _ ->
          nil
      end

    if is_binary(acting) and effective_admin?(txn, acting),
      do: {:ok, acting},
      else: refusal("forbidden", "removing a user requires an acting user who is an active admin")
  end

  defp session_owner(txn, session_key) do
    case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey = ?1", [session_key]) do
      [[owner]] -> owner
      [] -> nil
    end
  end

  defp target_in_txn(txn, target) do
    case Txn.q(txn, "SELECT #{@user_columns} FROM users WHERE userId = ?1", [target]) do
      [] ->
        refusal("user_not_found", "no user #{target}")

      [[_user_id, _is_admin, _created_at, removed_at, _removed_by]] when not is_nil(removed_at) ->
        refusal("user_already_removed", "user #{target} was already removed")

      [row] ->
        {:ok, row}
    end
  end

  defp not_self(actor, target) when actor == target,
    do: refusal("cannot_remove_self", "the acting user cannot remove itself")

  defp not_self(_actor, _target), do: :ok

  defp not_last_admin(txn, [user_id, 1, _created_at, nil, _removed_by]) do
    case Txn.q(
           txn,
           "SELECT COUNT(*) FROM users WHERE isAdmin = 1 AND removedAt IS NULL AND userId != ?1",
           [user_id]
         ) do
      [[0]] -> refusal("last_admin", "removing #{user_id} would leave no active admin")
      [[_others]] -> :ok
    end
  end

  defp not_last_admin(_txn, _user), do: :ok

  defp owns_nothing(txn, target) do
    case owned_in_txn(txn, target) do
      %{counts: %{"total" => 0}} ->
        :ok

      %{counts: counts, ids: ids} ->
        lines =
          for key <- ownership_keys(), counts[key] > 0 do
            "#{key}: #{counts[key]} (#{Enum.join(ids[key], ", ")})"
          end

        refusal(
          "user_owns_rows",
          "user #{target} owns rows and was not removed; nothing was reassigned. " <>
            Enum.join(lines, "; ")
        )
    end
  end

  defp refusal(code, message), do: %{code: code, message: message}

  defp effective_admin?(txn, user_id) do
    Txn.q(
      txn,
      "SELECT 1 FROM users WHERE userId = ?1 AND isAdmin = 1 AND removedAt IS NULL",
      [user_id]
    ) == [[1]]
  end

  # Counts and up to @id_limit ids for every §3 ownership entry, plus the total.
  defp owned_in_txn(txn, user_id) do
    entries =
      Enum.map(@ownership, fn %{table: table, key: key} ->
        [[count]] = Txn.q(txn, "SELECT COUNT(*) FROM #{table} WHERE ownerUserId = ?1", [user_id])

        ids =
          ids_in_txn(
            txn,
            "SELECT #{key} FROM #{table} WHERE ownerUserId = ?1 ORDER BY #{key}",
            user_id
          )

        {"#{table}.ownerUserId", count, ids}
      end)

    count_sql = "SELECT COUNT(*) FROM decision_requests WHERE #{@open_expecter_where}"
    [[expecter_count]] = Txn.q(txn, count_sql, [user_id])

    expecter_ids =
      ids_in_txn(
        txn,
        "SELECT id FROM decision_requests WHERE #{@open_expecter_where} ORDER BY id",
        user_id
      )

    entries = entries ++ [{@open_expecter, expecter_count, expecter_ids}]
    counts = Map.new(entries, fn {name, count, _ids} -> {name, count} end)

    %{
      counts: Map.put(counts, "total", Enum.sum(Map.values(counts))),
      ids: Map.new(entries, fn {name, _count, ids} -> {name, ids} end)
    }
  end

  defp ids_in_txn(txn, sql, user_id) do
    txn
    |> Txn.q(sql <> " LIMIT #{@id_limit}", [user_id])
    |> Enum.map(fn [id] -> to_string(id) end)
  end

  defp context_in_txn(txn),
    do: %{
      creations: creations_in_txn(txn),
      acted: acted_as_in_txn(txn),
      devices: devices_in_txn(txn)
    }

  # C2: creation provenance is the earliest accepted add-user audit event whose
  # result names the user. Audit payloads are stored as `inspect/1` text
  # (EventLog.encode/1), so an accepted add-user result reads
  # `%{user: %{... "userId" => <id> ...}}` and a refusal reads `%{code: ...}`.
  # The id is matched in the same `inspect/1` form the writer produced.
  defp creations_in_txn(txn) do
    txn
    |> Txn.q("""
    SELECT id, ts, principal, sessionKey, origin, payload FROM events
    WHERE kind = 'verb' AND verb = 'add-user' AND substr(payload, 1, 8) = '%{user: '
    ORDER BY id
    """)
    |> Enum.map(fn [id, ts, principal, session_key, origin, payload] ->
      {payload,
       %{
         "eventId" => id,
         "at" => ts,
         "principal" => principal,
         "sessionKey" => session_key,
         "origin" => origin
       }}
    end)
  end

  defp creation_for(creations, user_id) do
    needle = ~s("userId" => ) <> inspect(user_id)

    Enum.find_value(creations, fn {payload, creation} ->
      if String.contains?(payload, needle), do: creation
    end)
  end

  # C2: activity is the count of accepted audit events acting as `user:<id>`.
  defp acted_as_in_txn(txn) do
    txn
    |> Txn.q("""
    SELECT principal, COUNT(*), MIN(ts), MAX(ts) FROM events
    WHERE kind = 'verb' AND substr(principal, 1, 5) = 'user:'
    GROUP BY principal
    """)
    |> Map.new(fn [principal, count, first, last] ->
      {principal, %{"count" => count, "firstAt" => first, "lastAt" => last}}
    end)
  end

  defp devices_in_txn(txn) do
    txn
    |> Txn.q("SELECT userId, status, COUNT(*) FROM devices GROUP BY userId, status")
    |> Enum.reduce(%{}, fn [user_id, status, count], acc ->
      Map.update(acc, user_id, %{status => count}, &Map.put(&1, status, count))
    end)
  end

  defp row([user_id, is_admin, created_at, removed_at, removed_by], context, owned) do
    device_counts = Map.get(context.devices, user_id, %{})
    creation = creation_for(context.creations, user_id)
    no_activity = %{"count" => 0, "firstAt" => nil, "lastAt" => nil}

    base = %{
      "userId" => user_id,
      "isAdmin" => is_admin == 1,
      "effectiveAdmin" => is_admin == 1 and is_nil(removed_at),
      "createdAt" => created_at,
      "state" => if(is_nil(removed_at), do: "active", else: "removed"),
      "removedAt" => removed_at,
      "removedBy" => removed_by,
      "creation" => creation,
      "devices" => %{
        "allowlisted" => Map.get(device_counts, "allowlisted", 0),
        "pending" => Map.get(device_counts, "pending", 0),
        "denied" => Map.get(device_counts, "denied", 0)
      },
      "actedAs" => Map.get(context.acted, "user:" <> user_id, no_activity),
      "owned" => owned
    }

    if is_nil(creation),
      do: Map.put(base, "creationNote", "no accepted add-user audit event"),
      else: base
  end

  # The acting principal string, in the audit log's own `kind:value` form.
  defp principal_string({kind, value}), do: "#{kind}:#{value}"
end
