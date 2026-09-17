defmodule Tightbeam.ProductOwner do
  @moduledoc """
  Find the session that speaks for a product, and the session that currently owns
  work on an item, so a rule notice can be addressed without naming a product.

  Roles are named per product (`product-owner:tightbeam`), so a rule shipped in a
  kungfu bundle cannot address "the PO for whatever product this is" by role. This
  module answers that from the org's shape instead: walk the current lineage from a
  starting session and, at each level, take that session when it is an active
  product owner, else its single active product-owner child. When a level has
  several product-owner children, prefer the one bound to a `product-owner:*` role;
  if that does not single one out, stop. Guessing the wrong product is worse than
  not answering, and an unresolved notice is recorded, never raised.
  """

  alias Tightbeam.{DB, Org, Roles}

  @max_depth 16

  @doc "The product owner that speaks for the product `start_key` works in, or nil."
  @spec resolve(DB.server() | DB.Txn.t(), String.t() | nil) :: String.t() | nil
  def resolve(_db, nil), do: nil

  def resolve(db, start_key) when is_binary(start_key),
    do: walk(db, start_key, MapSet.new(), 0)

  defp walk(_db, nil, _seen, _depth), do: nil
  defp walk(_db, _key, _seen, depth) when depth > @max_depth, do: nil

  defp walk(db, key, seen, depth) do
    if MapSet.member?(seen, key) do
      nil
    else
      case Org.get(db, key) do
        nil ->
          nil

        %{archetype: "product-owner", state: "active"} ->
          key

        session ->
          case product_owner_children(db, key) do
            [one] ->
              one

            [] ->
              walk(db, session.current_parent, MapSet.put(seen, key), depth + 1)

            several ->
              case Enum.filter(several, &role_bound?(db, &1)) do
                [one] -> one
                _ -> nil
              end
          end
      end
    end
  end

  defp product_owner_children(db, parent_key) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT s.sessionKey FROM sessions s
         WHERE #{Org.current_parent_sql("s")} = ?1
           AND s.state = 'active' AND s.archetype = 'product-owner'
         ORDER BY s.createdAt
        """,
        [parent_key]
      )

    Enum.map(rows, fn [key] -> key end)
  end

  defp role_bound?(db, key) do
    db
    |> Roles.for_session(key)
    |> Enum.any?(&String.starts_with?(&1, "product-owner:"))
  end

  @doc """
  The session that currently owns work on `work_item_id`: the opener of the most
  recently opened open implementation card, else the session that created the item.
  Nil when neither exists or the creator was a user.
  """
  @spec work_owner(DB.server() | DB.Txn.t(), String.t() | nil) :: String.t() | nil
  def work_owner(_db, nil), do: nil

  def work_owner(db, work_item_id) when is_binary(work_item_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT a.openedBySession FROM assignments a
          JOIN sessions s ON s.sessionKey = a.holderKey
         WHERE a.workItemId = ?1 AND a.state = 'open' AND a.openedBySession IS NOT NULL
           AND s.archetype = 'coder'
         ORDER BY a.openedAt DESC LIMIT 1
        """,
        [work_item_id]
      )

    case rows do
      [[opener]] when is_binary(opener) ->
        opener

      _ ->
        {:ok, rows} =
          DB.query(db, "SELECT createdBySession FROM work_items WHERE id = ?1", [work_item_id])

        case rows do
          [[creator]] when is_binary(creator) -> creator
          _ -> nil
        end
    end
  end

  @doc false
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
