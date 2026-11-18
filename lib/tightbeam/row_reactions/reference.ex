defmodule Tightbeam.RowReactions.Reference do
  @moduledoc false
  alias Tightbeam.DB.Txn

  # Typed durable references, independent of which elected rule writes them.
  def put(txn, %{"resource" => "work_item", "id" => id, "field" => field} = ref, value)
      when field in ["routingWakeId", "slateWakeId"] do
    case Txn.q(txn, "SELECT #{field} FROM work_items WHERE id=?1", [id]) do
      [[current]] ->
        if current in [ref["expected"], value] do
          Txn.q(txn, "UPDATE work_items SET #{field}=?2 WHERE id=?1", [id, value])
        else
          raise ArgumentError, "reaction reference changed before effect"
        end

      [] ->
        raise ArgumentError, "reaction reference resource is missing"
    end

    :ok
  end

  def put(_txn, nil, _value), do: :ok
  def put(_txn, _ref, _value), do: raise(ArgumentError, "unsupported reaction reference")

  def clear(txn, %{"resource" => "work_item", "id" => id, "field" => field}, wake_id)
      when field in ["routingWakeId", "slateWakeId"] do
    Txn.q(txn, "UPDATE work_items SET #{field}=NULL WHERE id=?1 AND #{field}=?2", [id, wake_id])
    :ok
  end

  def clear(_txn, nil, _wake_id), do: :ok
end
