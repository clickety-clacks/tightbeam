defmodule Tightbeam.IdPrefix do
  @moduledoc false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @types %{
    assignment: %{table: "assignments", column: "id", prefix: "asg_", label: "assignment id"},
    work_item: %{table: "work_items", column: "id", prefix: "wi_", label: "work-item id"},
    wake: %{table: "wakes", column: "wakeId", prefix: "w_", label: "wake id"}
  }

  @type resolution :: {:ok, String.t()} | :unknown | {:ambiguous, map()}

  @doc "Resolve an exact id or one visible typed prefix against committed rows."
  @spec resolve(DB.server(), atom(), term(), (String.t() -> boolean())) :: resolution()
  def resolve(db, type, supplied, visible? \\ fn _id -> true end) do
    resolve_with(
      type,
      supplied,
      fn sql, params ->
        {:ok, rows} = DB.query(db, sql, params)
        rows
      end,
      visible?
    )
  end

  @doc "Resolve inside the transaction that will act on the selected row."
  @spec resolve_in_txn(Txn.t(), atom(), term(), (String.t() -> boolean())) :: resolution()
  def resolve_in_txn(%Txn{} = txn, type, supplied, visible? \\ fn _id -> true end) do
    resolve_with(type, supplied, &Txn.q(txn, &1, &2), visible?)
  end

  @doc "Resolve against a caller-visible snapshot that already contains canonical ids."
  @spec resolve_ids(atom(), term(), [String.t()]) :: resolution()
  def resolve_ids(type, supplied, ids) when is_binary(supplied) and is_list(ids) do
    %{prefix: prefix, label: label} = Map.fetch!(@types, type)
    visible = ids |> Enum.uniq() |> Enum.sort()

    cond do
      supplied in visible ->
        {:ok, supplied}

      not String.starts_with?(supplied, prefix) ->
        :unknown

      true ->
        case Enum.filter(visible, &String.starts_with?(&1, supplied)) do
          [id] -> {:ok, id}
          [] -> :unknown
          candidates -> {:ambiguous, ambiguous(label, supplied, candidates)}
        end
    end
  end

  def resolve_ids(_type, _supplied, _ids), do: :unknown

  defp resolve_with(type, supplied, query, visible?) when is_binary(supplied) do
    %{table: table, column: column, prefix: prefix, label: label} = Map.fetch!(@types, type)

    case query.("SELECT #{column} FROM #{table} WHERE #{column} = ?1", [supplied]) do
      [[^supplied]] ->
        {:ok, supplied}

      [] ->
        if String.starts_with?(supplied, prefix) do
          candidates =
            query.(
              "SELECT #{column} FROM #{table} WHERE substr(#{column}, 1, length(?1)) = ?1 ORDER BY #{column}",
              [supplied]
            )
            |> Enum.map(&hd/1)
            |> Enum.filter(visible?)

          case candidates do
            [id] -> {:ok, id}
            [] -> :unknown
            ids -> {:ambiguous, ambiguous(label, supplied, ids)}
          end
        else
          :unknown
        end
    end
  end

  defp resolve_with(_type, _supplied, _query, _visible?), do: :unknown

  defp ambiguous(label, supplied, candidates) do
    %{
      code: "ambiguous_id",
      message: "#{label} prefix #{supplied} is ambiguous: #{Enum.join(candidates, ", ")}",
      candidates: candidates
    }
  end
end
