defmodule Tightbeam.Lineage do
  @moduledoc """
  Find sessions by their place in the org's shape, for rule notices that must
  address a role the substrate does not know by name.

  The substrate knows sessions, parents and archetype strings; it does not know
  what a "product owner" or a "coder" is. A kungfu rule supplies the archetype
  it means, and these lookups answer from the tree.

  `nearest/3` walks the current lineage from a starting session and, at each
  level, takes that session when it is an active session of the archetype, else
  the level's single active child of that archetype, preferring a role-bound one
  when there are several. Ambiguity answers nil: guessing the wrong session is
  worse than not answering, and an unresolved notice is recorded, never raised.

  `open_card_opener/3` answers who currently owns work on an item: the session
  that opened the most recently opened open card held by the given archetype,
  else the item's creator.
  """

  alias Tightbeam.{DB, Org, Roles}

  @max_depth 16

  @spec nearest(DB.server() | DB.Txn.t(), String.t() | nil, String.t()) :: String.t() | nil
  def nearest(_db, nil, _archetype), do: nil

  def nearest(db, start_key, archetype) when is_binary(start_key) and is_binary(archetype),
    do: walk(db, start_key, archetype, MapSet.new(), 0)

  defp walk(_db, nil, _archetype, _seen, _depth), do: nil
  defp walk(_db, _key, _archetype, _seen, depth) when depth > @max_depth, do: nil

  defp walk(db, key, archetype, seen, depth) do
    if MapSet.member?(seen, key) do
      nil
    else
      case Org.get(db, key) do
        nil ->
          nil

        %{archetype: ^archetype, state: "active"} ->
          key

        session ->
          case children_of_archetype(db, key, archetype) do
            [one] ->
              one

            [] ->
              walk(db, session.current_parent, archetype, MapSet.put(seen, key), depth + 1)

            several ->
              case Enum.filter(several, &role_bound?(db, &1, archetype)) do
                [one] -> one
                _ -> nil
              end
          end
      end
    end
  end

  defp children_of_archetype(db, parent_key, archetype) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT s.sessionKey FROM sessions s
         WHERE #{Org.current_parent_sql("s")} = ?1
           AND s.state = 'active' AND s.archetype = ?2
         ORDER BY s.createdAt
        """,
        [parent_key, archetype]
      )

    Enum.map(rows, fn [key] -> key end)
  end

  defp role_bound?(db, key, archetype) do
    db
    |> Roles.for_session(key)
    |> Enum.any?(&String.starts_with?(&1, archetype <> ":"))
  end

  @spec open_card_opener(DB.server() | DB.Txn.t(), String.t() | nil, String.t()) ::
          String.t() | nil
  def open_card_opener(_db, nil, _archetype), do: nil

  def open_card_opener(db, work_item_id, archetype)
      when is_binary(work_item_id) and is_binary(archetype) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT a.openedBySession FROM assignments a
          JOIN sessions s ON s.sessionKey = a.holderKey
         WHERE a.workItemId = ?1 AND a.state = 'open' AND a.openedBySession IS NOT NULL
           AND s.archetype = ?2
         ORDER BY a.openedAt DESC LIMIT 1
        """,
        [work_item_id, archetype]
      )

    case rows do
      [[opener]] when is_binary(opener) -> opener
      _ -> creator_session(db, work_item_id)
    end
  end

  @spec creator_session(DB.server() | DB.Txn.t(), String.t() | nil) :: String.t() | nil
  def creator_session(_db, nil), do: nil

  def creator_session(db, work_item_id) when is_binary(work_item_id) do
    {:ok, rows} =
      DB.query(db, "SELECT createdBySession FROM work_items WHERE id = ?1", [work_item_id])

    case rows do
      [[creator]] when is_binary(creator) -> creator
      _ -> nil
    end
  end
end
