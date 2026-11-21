defmodule Tightbeam.TestSupport.OperatorAskFixture do
  @moduledoc false
  # Operator asks must name their product and the work they serve. Tests that
  # are not about that attribution file against a fixture work item owned by
  # the asking session's owner.

  alias Tightbeam.DB

  @project "Fixture product"

  def work_item(owner_user_id), do: "wi-operator-ask-fixture-" <> owner_user_id
  def project, do: @project

  @doc "Adds the fixture project and, unless the ask already names its work, the fixture work item."
  def link(db, session_key, params) when is_map(params) do
    params = Map.put_new(params, :project, @project)

    if Enum.any?(
         [:assignment, :assignment_id, :work_item, :work_item_id],
         &Map.has_key?(params, &1)
       ) do
      params
    else
      {:ok, [[owner_user_id]]} =
        DB.query(db, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [session_key])

      ensure_work_item!(db, owner_user_id)
      Map.put(params, :work_item_id, work_item(owner_user_id))
    end
  end

  @doc "Creates the fixture work item for an owner if it does not exist."
  def ensure_work_item!(db, owner_user_id) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT OR IGNORE INTO work_items (id,title,ownerUserId,createdByUser,createdAt) VALUES (?1,'operator ask fixture',?2,?2,1)",
        [work_item(owner_user_id), owner_user_id]
      )

    :ok
  end
end
