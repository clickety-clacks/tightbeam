defmodule Tightbeam.StateVisibility do
  @moduledoc "Canonical owner-or-admin visibility shared by state reads and firehose delivery."

  alias Tightbeam.{DB, Org}
  alias Tightbeam.DB.Txn

  @admin_classes ~w(config.updated host_env.updated host.registered user.added user.promoted identity.updated kungfu.updated)
  @topline_invalidation_classes ~w(topline.created topline_work_membership.linked topline_work_membership.unlinked)

  @spec visible?(DB.server(), map(), String.t(), boolean()) :: boolean()
  def visible?(db, %{"class" => class} = notice, user_id, is_admin)
      when class in @topline_invalidation_classes do
    topline_visible?(db, notice, user_id, is_admin)
  end

  def visible?(db, %{"class" => "subagent_marker.appended"} = notice, user_id, is_admin) do
    subagent_marker_visible?(db, notice, user_id, is_admin)
  end

  def visible?(_db, _notice, _user_id, true), do: true

  def visible?(_db, %{"class" => class}, _user_id, false) when class in @admin_classes do
    admin_resource_visible?(class, false)
  end

  def visible?(_db, %{"class" => "critical_lease.updated"}, _user_id, false), do: false

  def visible?(db, notice, user_id, false) do
    refs = notice["refs"] || %{}
    payload = notice["payload"] || %{}

    direct_owner?(refs, payload, user_id) or
      session_owner?(db, refs, payload, user_id) or
      work_item_owner?(db, refs, payload, user_id) or
      assignment_owner?(db, refs, payload, user_id)
  end

  @doc "Config is admin-only."
  def config_visible?(is_admin), do: is_admin

  @doc "Host-environment metadata is admin-only."
  def host_environment_visible?(is_admin), do: is_admin

  @doc "Host inventory is visible to every authenticated organization principal."
  def host_visible?(is_admin) when is_boolean(is_admin), do: true

  @doc "User administration is admin-only."
  def user_visible?(is_admin), do: is_admin

  @doc "Served identity publication state is admin-only."
  def identity_visible?(is_admin), do: is_admin

  @doc "Kungfu publication state is admin-only."
  def kungfu_visible?(is_admin), do: is_admin

  @doc "Apply the closed AU4 grant for one core detail row."
  def core_detail_visible?(_db, resource, _row, _principal)
      when resource in ["work items", "assignments"],
      do: true

  def core_detail_visible?(db, "decision requests", row, principal) do
    admin = principal.is_admin
    assignment_holder = assignment_holder?(db, value(row, :assignment_id), principal)

    case value(row, :kind) do
      "statute" ->
        admin or principal_ref(principal) == value(row, :raiser_id) or
          user_principal?(principal, value(row, :owner_user_id))

      "effort" ->
        admin or session_principal?(principal, value(row, :expecter_session_key)) or
          user_principal?(principal, value(row, :expecter_user_id)) or assignment_holder

      "agent" ->
        admin or session_principal?(principal, value(row, :raiser_session_key)) or
          session_principal?(principal, value(row, :expecter_session_key)) or
          user_principal?(principal, value(row, :owner_user_id))

      _ ->
        false
    end
  end

  def core_detail_visible?(_db, _resource, _row, %{is_admin: true}), do: true

  def core_detail_visible?(_db, "devices", _row, _principal), do: false

  def core_detail_visible?(_db, "read markers", row, %{kind: "user", id: user_id}),
    do: value(row, :user_id) == user_id

  def core_detail_visible?(_db, "read markers", _row, _principal), do: false

  def core_detail_visible?(_db, "sessions", row, principal) do
    session_key = value(row, :session_key)
    owner_user_id = value(row, :owner_user_id)

    session_principal?(principal, session_key) or user_principal?(principal, owner_user_id)
  end

  def core_detail_visible?(db, "turns", row, principal) do
    session_key = value(row, :session_key)
    owner = session_owner?(db, session_key, principal)
    session_principal?(principal, session_key) or owner
  end

  def core_detail_visible?(db, "wakes", row, principal) do
    target = value(row, :session_key)
    creator = value(row, :creator_session_key)
    target_owner = session_owner?(db, target, principal)
    creator_owner = session_owner?(db, creator, principal)

    session_principal?(principal, target) or session_principal?(principal, creator) or
      target_owner or creator_owner
  end

  def core_detail_visible?(db, "artifacts", row, principal) do
    creator = value(row, :created_by_session)
    work_item_id = value(row, :work_item_id)
    work_item = work_item_visible?(db, work_item_id, principal)

    session_principal?(principal, creator) or work_item
  end

  def core_detail_visible?(_db, _resource, _row, _principal), do: false

  defp session_owner?(db, session_key, %{kind: "user", id: user_id}) do
    session_owner_user_id(db, session_key) == user_id
  end

  defp session_owner?(_db, _session_key, _principal), do: false

  defp work_item_visible?(db, work_item_id, principal) do
    {kind, id} = principal_identity(principal)

    rows =
      query_rows(
        db,
        """
        SELECT 1
        FROM work_items AS wi
        WHERE wi.id = ?1 AND (
          (?2 = 'user' AND wi.ownerUserId = ?3) OR
          (?2 = 'session' AND (
            wi.createdBySession = ?3 OR EXISTS (
              SELECT 1 FROM assignments AS held
              WHERE held.workItemId = wi.id AND held.holderKey = ?3
            )
          ))
        )
        """,
        [work_item_id, kind, id]
      )

    rows != []
  end

  defp assignment_holder?(db, assignment_id, %{kind: "session", id: session_key}) do
    rows =
      query_rows(db, "SELECT 1 FROM assignments WHERE id = ?1 AND holderKey = ?2", [
        assignment_id,
        session_key
      ])

    rows != []
  end

  defp assignment_holder?(_db, _assignment_id, _principal), do: false

  defp principal_identity(%{kind: kind, id: id}), do: {kind, id}
  defp principal_ref(%{kind: kind, id: id}), do: "#{kind}:#{id}"
  defp session_principal?(%{kind: "session", id: id}, id), do: true
  defp session_principal?(_principal, _id), do: false
  defp user_principal?(%{kind: "user", id: id}, id), do: true
  defp user_principal?(_principal, _id), do: false

  defp session_owner_user_id(%Txn{} = txn, session_key),
    do: Org.owner_user_id_in_txn(txn, session_key)

  defp session_owner_user_id(db, session_key) do
    case Org.get(db, session_key) do
      %{owner_user_id: owner_user_id} -> owner_user_id
      nil -> nil
    end
  end

  defp query_rows(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query_rows(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end

  defp value(nil, _key), do: nil

  defp value(row, key) do
    Map.get(row, key) || Map.get(row, Atom.to_string(key)) ||
      Map.get(row, key |> Atom.to_string() |> Macro.camelize() |> lower_first())
  end

  defp lower_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
  defp lower_first(""), do: ""

  @doc "A Topline invalidation uses the committed Topline owner-or-admin grant."
  def topline_visible?(db, notice, user_id, is_admin) do
    topline_id = get_in(notice, ["refs", "toplineId"])

    if is_binary(topline_id) do
      {:ok, rows} = DB.query(db, "SELECT ownerUserId FROM toplines WHERE id = ?1", [topline_id])

      case rows do
        [[owner_user_id]] -> is_admin or owner_user_id == user_id
        [] -> false
      end
    else
      false
    end
  end

  @doc "A marker invalidation requires its resolved assignment and work-item grants."
  def subagent_marker_visible?(db, notice, user_id, is_admin) do
    refs = notice["refs"] || %{}

    with marker_id when is_binary(marker_id) <- refs["markerId"],
         session_key when is_binary(session_key) <- refs["sessionKey"],
         assignment_id when is_binary(assignment_id) <- refs["assignmentId"],
         work_item_id when is_binary(work_item_id) <- refs["workItemId"] do
      {:ok, rows} =
        DB.query(
          db,
          """
          SELECT holder.ownerUserId, wi.ownerUserId
          FROM subagent_markers sm
          JOIN assignments a ON a.id = sm.assignmentId AND a.holderKey = sm.principal
          JOIN sessions holder ON holder.sessionKey = a.holderKey
          JOIN work_items wi ON wi.id = a.workItemId
          WHERE CAST(sm.id AS TEXT) = ?1 AND sm.principal = ?2
            AND a.id = ?3 AND wi.id = ?4
          """,
          [marker_id, session_key, assignment_id, work_item_id]
        )

      Enum.any?(rows, fn [holder_owner, work_owner] ->
        assignment_granted = is_admin or holder_owner == user_id or work_owner == user_id
        work_item_granted = is_admin or work_owner == user_id
        assignment_granted and work_item_granted
      end)
    else
      _ -> false
    end
  end

  defp admin_resource_visible?("config.updated", is_admin), do: config_visible?(is_admin)

  defp admin_resource_visible?("host_env.updated", is_admin),
    do: host_environment_visible?(is_admin)

  defp admin_resource_visible?("host.registered", is_admin), do: host_visible?(is_admin)
  defp admin_resource_visible?("user.added", is_admin), do: user_visible?(is_admin)
  defp admin_resource_visible?("user.promoted", is_admin), do: user_visible?(is_admin)
  defp admin_resource_visible?("identity.updated", is_admin), do: identity_visible?(is_admin)
  defp admin_resource_visible?("kungfu.updated", is_admin), do: kungfu_visible?(is_admin)

  defp direct_owner?(refs, payload, user_id) do
    Enum.any?(
      [refs["ownerUserId"], payload["ownerUserId"], refs["userId"], payload["userId"]],
      &(&1 == user_id)
    ) or refs["principal"] == "user:#{user_id}"
  end

  defp session_owner?(db, refs, payload, user_id) do
    [
      refs["sessionKey"],
      payload["sessionKey"],
      payload["holderKey"],
      payload["createdBySession"],
      payload["bySession"],
      payload["raiserSessionKey"]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(fn session_key ->
      case Org.get(db, session_key) do
        %{owner_user_id: ^user_id} -> true
        _ -> false
      end
    end)
  end

  defp work_item_owner?(db, refs, payload, user_id) do
    work_item_id = refs["workItemId"] || payload["workItemId"] || payload["id"]

    if is_binary(work_item_id) and String.starts_with?(work_item_id, "wi_") do
      {:ok, rows} =
        DB.query(db, "SELECT ownerUserId FROM work_items WHERE id = ?1", [work_item_id])

      rows == [[user_id]]
    else
      false
    end
  end

  defp assignment_owner?(db, refs, payload, user_id) do
    assignment_id = refs["assignmentId"] || payload["assignmentId"] || payload["id"]

    if is_binary(assignment_id) and String.starts_with?(assignment_id, "asg_") do
      {:ok, rows} =
        DB.query(
          db,
          """
          SELECT s.ownerUserId, wi.ownerUserId
          FROM assignments a
          LEFT JOIN sessions s ON s.sessionKey = a.holderKey
          LEFT JOIN work_items wi ON wi.id = a.workItemId
          WHERE a.id = ?1
          """,
          [assignment_id]
        )

      Enum.any?(rows, fn [holder_owner, work_owner] ->
        holder_owner == user_id or work_owner == user_id
      end)
    else
      false
    end
  end
end
