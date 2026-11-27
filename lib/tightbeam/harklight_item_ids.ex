defmodule Tightbeam.HarklightItemIds do
  @moduledoc false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @legacy_requests """
  FROM harklight_wake_requests r
  JOIN harklight_send_operations s
    ON s.senderId=r.senderId AND s.messageId=r.messageId AND s.handle=r.handle
  LEFT JOIN harklight_item_ids i
    ON i.senderId=r.senderId AND i.messageId=r.messageId AND i.handle=r.handle
  WHERE s.state='bound' AND json_extract(s.payload,'$.request.protocol') IS NOT 2
    AND json_extract(s.payload,'$.request.message.message_id')=r.messageId
    AND i.itemId IS NULL
  """

  def enabled?, do: Application.get_env(:tightbeam, :harklight_item_id_matching, false)

  def capture_enabled?, do: Application.get_env(:tightbeam, :harklight_item_id_capture, false)

  def ensure_schema(db) do
    if enabled?() or capture_enabled?() do
      DB.execute(db, """
      CREATE TABLE IF NOT EXISTS harklight_item_ids (
        handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
        senderId TEXT NOT NULL,
        messageId TEXT NOT NULL,
        itemId TEXT NOT NULL UNIQUE,
        PRIMARY KEY(handle,senderId,messageId)
      );
      """)
    else
      :ok
    end
  end

  def migrated_in_txn(txn, item_id) do
    case Txn.q(
           txn,
           "SELECT handle,senderId,messageId FROM harklight_item_ids WHERE itemId=?1",
           [item_id]
         ) do
      [[handle, sender_id, message_id]] -> {:ok, handle, sender_id, message_id}
      [] -> :unregistered
    end
  end

  def resolve(db, record) do
    case lookup(db, record) do
      {:ok, nil} -> {:error, {:unmapped_item_id, record.message_id}}
      {:ok, item_id} -> {:ok, item_id}
      error -> error
    end
  end

  defp lookup(db, record) do
    case DB.query(
           db,
           "SELECT itemId FROM harklight_item_ids WHERE handle=?1 AND senderId=?2 AND messageId=?3",
           [record.handle, record.sender_id, record.message_id]
         ) do
      {:ok, [[item_id]]} -> {:ok, item_id}
      {:ok, []} -> {:ok, nil}
      {:error, _} -> {:error, "harklight_item_id_unavailable"}
    end
  end

  def ensure_handle(db, handle) do
    case DB.query(db, "SELECT 1 " <> @legacy_requests <> " AND r.handle=?1 LIMIT 1", [handle]) do
      {:ok, []} -> :ok
      {:ok, [[1]]} -> {:error, "harklight_item_id_unmapped"}
      {:error, _} -> {:error, "harklight_item_id_unavailable"}
    end
  end

  def capture_status(db) do
    if capture_enabled?() do
      case DB.query(db, "SELECT COUNT(*) " <> @legacy_requests) do
        {:ok, [[remaining]]} -> {:ok, remaining}
        {:error, _} -> {:error, "harklight_item_id_unavailable"}
      end
    else
      {:ok, 0}
    end
  end

  def collect_legacy(messages, acc) do
    Enum.filter(messages, &(is_map(&1) and is_binary(&1["legacy_message_id"]))) ++ acc
  end

  def import_in_txn(txn, messages) do
    if capture_enabled?() do
      for %{
            "item_id" => item,
            "legacy_message_id" => legacy,
            "sender" => sender,
            "session" => handle
          } <- messages,
          Enum.all?([item, legacy, sender, handle], &(is_binary(&1) and &1 != "")) do
        Txn.q(
          txn,
          """
          INSERT INTO harklight_item_ids(handle,senderId,messageId,itemId)
          SELECT r.handle,r.senderId,r.messageId,?4
          """ <>
            @legacy_requests <>
            """
            AND r.handle=?1 AND r.senderId=?2 AND r.messageId=?3
            ON CONFLICT DO NOTHING
            """,
          [handle, sender, legacy, item]
        )
      end
    end

    :ok
  end

  def read_sent(runner, acc, collect) do
    read_pages(runner, nil, MapSet.new(), acc, collect)
  end

  defp read_pages(runner, token, seen, acc, collect) do
    args = if token, do: ["messages", "--page", token], else: ["messages"]

    with {output, 0} <- runner.(args),
         {:ok, %{"messages" => messages} = page} when is_list(messages) <- decode_page(output) do
      acc = collect.(messages, acc)

      case page["next_page"] do
        next when next in [nil, ""] ->
          {:ok, acc}

        next when is_binary(next) ->
          if MapSet.member?(seen, next) do
            {:error, "harklight_messages_paging_invalid"}
          else
            read_pages(runner, next, MapSet.put(seen, next), acc, collect)
          end

        _ ->
          {:error, "harklight_messages_paging_invalid"}
      end
    else
      {:ok, _} -> {:error, "harklight_messages_unexpected"}
      {:error, _} = error -> error
      _ -> {:error, "harklight_messages_unavailable"}
    end
  rescue
    _ -> {:error, "harklight_messages_unavailable"}
  end

  defp decode_page(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value({:error, "harklight_messages_unexpected"}, fn line ->
      case JSON.decode(line) do
        {:ok, %{"messages" => _} = page} -> {:ok, page}
        _ -> nil
      end
    end)
  end
end
