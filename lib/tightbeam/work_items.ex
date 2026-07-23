defmodule Tightbeam.WorkItems do
  @moduledoc "Durable work identity across assignment eras and aspects."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS work_items (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 2000),
    specRefName TEXT NULL CHECK(specRefName IS NULL OR length(trim(specRefName)) BETWEEN 1 AND 2000),
    specRefSha256 TEXT NULL CHECK(specRefSha256 IS NULL OR (length(specRefSha256) = 64 AND specRefSha256 NOT GLOB '*[^0-9a-f]*')),
    createdByUser TEXT NULL,
    createdBySession TEXT NULL,
    createdAt INTEGER NOT NULL,
    CHECK((specRefName IS NULL) = (specRefSha256 IS NULL)),
    CHECK((createdByUser IS NOT NULL) != (createdBySession IS NOT NULL))
  )
  """

  @doc "Create the work-item schema."
  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc false
  def __handle__(db, "work-item-create", call), do: create_result(db, call)
  def __handle__(db, "work-item-get", call), do: get_result(db, call)
  def __handle__(db, "work-item-list", call), do: list_result(db, call)
  def __handle__(db, "work-item-update", call), do: update_result(db, call)

  defp create_result(db, call) do
    with :ok <- principal_allowed(call.principal),
         :ok <- valid_title(call.params[:title]),
         :ok <- valid_spec_ref(call.params[:spec_ref_name], call.params[:spec_ref_sha256]) do
      id = "wi_" <> Tightbeam.Id.uuid4()
      {created_by_user, created_by_session} = creator(call.principal)

      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO work_items
            (id, title, specRefName, specRefSha256, createdByUser, createdBySession, createdAt)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
          """,
          [
            id,
            call.params.title,
            call.params[:spec_ref_name],
            call.params[:spec_ref_sha256],
            created_by_user,
            created_by_session,
            now()
          ]
        )

      fetch(db, id)
    end
  end

  defp update_result(db, call) do
    with :ok <- principal_allowed(call.principal) do
      result = transaction(db, fn txn -> update_in_txn(txn, call.params) end)

      case result do
        {:updated, item, changed?} ->
          # Work-item-grain metadata doorbell (observability-v1 §work_item_events,
          # kind="metadata"): title/spec-ref pin changed, so observability must
          # invalidate/refetch its card (work-item-v1 §Mutability cross-spec note).
          # observability-v1 OWNS this doorbell; work-item-v1 declines to build it,
          # it does not forbid it.
          if changed? do
            best_effort(fn ->
              Map.get(call, :on_work_item_change, fn _, _ -> :ok end).(item.id, "metadata")
            end)
          end

          item

        error ->
          error
      end
    end
  end

  defp update_in_txn(txn, params) do
    case fetch_in_txn(txn, params[:work_item_id]) do
      nil ->
        unknown(params[:work_item_id])

      item ->
        title = if Map.has_key?(params, :title), do: params.title, else: item.title

        {spec_ref_name, spec_ref_sha256} = patch_spec_ref(item, params)
        updates = patch_updates(params, title, spec_ref_name, spec_ref_sha256)

        with :ok <- valid_title(title),
             :ok <- valid_spec_ref(spec_ref_name, spec_ref_sha256) do
          updated = apply_updates(txn, item, updates)
          {:updated, updated, metadata(item) != metadata(updated)}
        end
    end
  end

  defp patch_updates(params, title, spec_ref_name, spec_ref_sha256) do
    updates = if Map.has_key?(params, :title), do: [{"title", title}], else: []
    name_present = Map.has_key?(params, :spec_ref_name)
    sha_present = Map.has_key?(params, :spec_ref_sha256)

    spec_updates =
      cond do
        not name_present and not sha_present ->
          []

        (name_present and is_nil(params[:spec_ref_name])) or
            (sha_present and is_nil(params[:spec_ref_sha256])) ->
          [{"specRefName", spec_ref_name}, {"specRefSha256", spec_ref_sha256}]

        true ->
          []
          |> then(fn fields ->
            if name_present, do: fields ++ [{"specRefName", spec_ref_name}], else: fields
          end)
          |> then(fn fields ->
            if sha_present, do: fields ++ [{"specRefSha256", spec_ref_sha256}], else: fields
          end)
      end

    updates ++ spec_updates
  end

  defp apply_updates(_txn, item, []), do: item

  defp apply_updates(txn, item, updates) do
    assignments =
      updates
      |> Enum.with_index(2)
      |> Enum.map_join(", ", fn {{column, _value}, index} -> "#{column} = ?#{index}" end)

    values = [item.id | Enum.map(updates, &elem(&1, 1))]
    Txn.q(txn, "UPDATE work_items SET #{assignments} WHERE id = ?1", values)
    fetch_in_txn(txn, item.id)
  end

  defp patch_spec_ref(item, params) do
    name_present = Map.has_key?(params, :spec_ref_name)
    sha_present = Map.has_key?(params, :spec_ref_sha256)
    name = params[:spec_ref_name]
    sha = params[:spec_ref_sha256]

    cond do
      (name_present and is_nil(name)) or (sha_present and is_nil(sha)) ->
        if (name_present and not is_nil(name)) or (sha_present and not is_nil(sha)),
          do: {name, sha},
          else: {nil, nil}

      true ->
        {
          if(name_present, do: name, else: item.specRefName),
          if(sha_present, do: sha, else: item.specRefSha256)
        }
    end
  end

  defp get_result(db, call) do
    with :ok <- principal_allowed(call.principal) do
      case fetch(db, call.params[:work_item_id]) do
        nil ->
          unknown(call.params[:work_item_id])

        item ->
          %{workItem: item, assignments: Tightbeam.Assignments.__for_work_item__(db, item.id)}
      end
    end
  end

  defp list_result(db, call) do
    with :ok <- principal_allowed(call.principal) do
      {:ok, rows} =
        DB.query(db, "SELECT #{columns()} FROM work_items ORDER BY createdAt DESC, id DESC")

      %{workItems: Enum.map(rows, &work_item/1)}
    end
  end

  defp fetch(db, id) do
    case DB.query(db, "SELECT #{columns()} FROM work_items WHERE id = ?1", [id]) do
      {:ok, [row]} -> work_item(row)
      {:ok, []} -> nil
    end
  end

  defp fetch_in_txn(txn, id) do
    case Txn.q(txn, "SELECT #{columns()} FROM work_items WHERE id = ?1", [id]) do
      [row] -> work_item(row)
      [] -> nil
    end
  end

  defp valid_title(title) when is_binary(title) do
    if String.length(String.trim(title)) in 1..2000,
      do: :ok,
      else: error("invalid_title", "title must be 1..2000 non-blank characters")
  end

  defp valid_title(_),
    do: error("invalid_title", "title must be 1..2000 non-blank characters")

  defp valid_spec_ref(nil, nil), do: :ok

  defp valid_spec_ref(name, sha) when is_binary(name) and is_binary(sha) do
    valid_name = String.length(String.trim(name)) in 1..2000
    valid_sha = String.match?(sha, ~r/^[0-9a-f]{64}$/)

    if valid_name and valid_sha,
      do: :ok,
      else: error("invalid_spec_ref", "spec ref must be a non-blank name and lowercase sha256")
  end

  defp valid_spec_ref(_, _),
    do: error("invalid_spec_ref", "specRefName and specRefSha256 must both be set or null")

  defp principal_allowed({:process, _}),
    do: error("process_denied", "process principals cannot use work-item verbs")

  defp principal_allowed(nil),
    do:
      error(
        "principal_required",
        "work-item verbs require a user credential or a session token"
      )

  defp principal_allowed({kind, _}) when kind in [:session, :user], do: :ok

  defp creator({:user, user}), do: {user, nil}
  defp creator({:session, session}), do: {nil, session}
  defp unknown(id), do: error("unknown_work_item", "unknown work item: #{id}")
  defp error(code, message), do: %{code: code, message: message}

  defp metadata(item), do: {item.title, item.specRefName, item.specRefSha256}

  defp best_effort(fun) do
    try do
      fun.()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp transaction(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)

  defp columns do
    "id, title, specRefName, specRefSha256, createdByUser, createdBySession, createdAt"
  end

  defp work_item([id, title, spec_ref_name, spec_ref_sha256, user, session, created_at]) do
    %{
      id: id,
      title: title,
      specRefName: spec_ref_name,
      specRefSha256: spec_ref_sha256,
      createdByUser: user,
      createdBySession: session,
      createdAt: created_at
    }
  end
end
