defmodule Tightbeam.StateVisibility do
  @moduledoc "Canonical owner-or-admin visibility shared by state reads and firehose delivery."

  alias Tightbeam.{DB, Org}

  @admin_classes ~w(config.updated host_env.updated host.registered user.added user.promoted identity.updated kungfu.updated)

  @spec visible?(DB.server(), map(), String.t(), boolean()) :: boolean()
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
