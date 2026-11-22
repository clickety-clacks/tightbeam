defmodule Tightbeam.ArtifactBlobStore do
  @moduledoc false
  use GenServer
  require Logger

  alias Tightbeam.ArtifactArchive

  @gib 1024 * 1024 * 1024
  @default_budget 64 * @gib
  @default_floor_bytes 100 * @gib
  @default_floor_percent 5

  def options(base_dir, overrides \\ []) do
    archive = Tightbeam.WorkspaceCleanup.archive_root(%{ssh: nil, base_dir: base_dir})
    archive = Path.expand(archive)
    match = fn name, default -> Application.get_env(:tightbeam, name, default) end

    options =
      Keyword.merge(
        [
          name: __MODULE__,
          root: match.(:artifact_blob_root, Path.join(Path.dirname(archive), "artifact-blobs")),
          budget_bytes: match.(:artifact_blob_budget_bytes, @default_budget),
          floor_bytes: match.(:artifact_blob_free_floor_bytes, @default_floor_bytes),
          floor_percent: match.(:artifact_blob_free_floor_percent, @default_floor_percent)
        ],
        overrides
      )

    root = options |> Keyword.fetch!(:root) |> Path.expand()

    if root == archive or String.starts_with?(root, archive <> "/") or
         String.starts_with?(archive, root <> "/"),
       do: raise(ArgumentError, "artifact blob root must be outside the archive tree")

    Keyword.put(options, :root, root)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def begin_upload(store, opts \\ []), do: GenServer.call(store, {:begin_upload, opts})
  def append(store, upload, bytes), do: GenServer.call(store, {:append, upload, bytes}, :infinity)
  def finish(store, upload), do: GenServer.call(store, {:finish, upload}, :infinity)
  def abort(store, upload), do: GenServer.call(store, {:abort, upload})
  def capacity(store), do: GenServer.call(store, :capacity)

  def inspect_blob(root, digest, limit),
    do: ArtifactArchive.read_local(blob_path(root, digest), limit)

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)
    staging = Path.join(root, "staging")

    case File.ls(staging) do
      {:ok, names} -> Enum.each(names, &File.rm!(Path.join(staging, &1)))
      {:error, :enoent} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "list staging", path: staging
    end

    used =
      ["blobs/*/*", "quarantine/*"]
      |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
      |> Enum.sum_by(fn path -> File.stat!(path).size end)

    {:ok,
     %{
       root: root,
       staging: staging,
       used: used,
       staged: 0,
       budget: Keyword.get(opts, :budget_bytes, @default_budget),
       floor_bytes: Keyword.get(opts, :floor_bytes, @default_floor_bytes),
       floor_percent: Keyword.get(opts, :floor_percent, @default_floor_percent),
       disk_space: Keyword.get(opts, :disk_space, &disk_space/1),
       uploads: %{}
     }}
  end

  @impl true
  def handle_call({:begin_upload, opts}, {caller, _}, state) do
    upload = Process.monitor(caller)

    entry = %{
      expected: Keyword.get(opts, :expected_sha),
      allow_unpinned: Keyword.get(opts, :allow_unpinned, false),
      hash: :crypto.hash_init(:sha256),
      size: 0,
      staged: 0,
      file: nil,
      path: nil,
      out_of_space: false
    }

    {:reply, {:ok, upload}, put_in(state.uploads[upload], entry)}
  end

  def handle_call({:append, upload, bytes}, _from, state) do
    entry = Map.fetch!(state.uploads, upload)

    entry = %{
      entry
      | hash: :crypto.hash_update(entry.hash, bytes),
        size: entry.size + byte_size(bytes)
    }

    case append_bytes(state, entry, bytes) do
      {:ok, state, entry} ->
        {:reply, :ok, put_in(state.uploads[upload], entry)}

      {:error, reason, state, entry} ->
        {:reply, {:error, reason}, put_in(state.uploads[upload], entry)}
    end
  end

  def handle_call({:finish, upload}, _from, state) do
    {entry, state} = pop_in(state.uploads[upload])
    Process.demonitor(upload, [:flush])
    digest = entry.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
    {result, state, entry} = finish_upload(state, entry, digest)
    {state, _} = discard_stage(state, entry)
    {:reply, result, state}
  end

  def handle_call({:abort, upload}, _from, state) do
    Process.demonitor(upload, [:flush])
    {:reply, :ok, cleanup(state, upload)}
  end

  def handle_call(:capacity, _from, state), do: {:reply, measure_capacity(state), state}

  @impl true
  def handle_info({:DOWN, upload, :process, _, _}, state), do: {:noreply, cleanup(state, upload)}

  defp append_bytes(state, %{out_of_space: true} = entry, _bytes), do: {:ok, state, entry}

  defp append_bytes(state, entry, bytes) do
    with {:ok, capacity} <- measure_capacity(state),
         true <-
           capacity.used_bytes + capacity.staged_bytes + byte_size(bytes) <=
             capacity.effective_limit_bytes,
         {:ok, entry} <- open_stage(state, entry) do
      case :file.write(entry.file, bytes) do
        :ok ->
          length = byte_size(bytes)

          {:ok, %{state | staged: state.staged + length},
           %{entry | staged: entry.staged + length}}

        {:error, :enospc} ->
          stop_staging(state, entry)

        {:error, reason} ->
          {state, entry} = discard_stage(state, entry)
          {:error, reason, state, entry}
      end
    else
      false -> stop_staging(state, entry)
      {:error, :enospc} -> stop_staging(state, entry)
      {:error, reason} -> {:error, reason, state, entry}
    end
  end

  defp stop_staging(state, entry) do
    {state, entry} = discard_stage(state, entry)
    {:ok, state, %{entry | out_of_space: true}}
  end

  defp open_stage(_state, %{file: file} = entry) when not is_nil(file), do: {:ok, entry}

  defp open_stage(state, entry) do
    name = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    path = Path.join(state.staging, name)

    with :ok <- File.mkdir_p(state.staging),
         {:ok, file} <- File.open(path, [:write, :binary, :raw, :exclusive]) do
      case File.chmod(path, 0o600) do
        :ok ->
          {:ok, %{entry | file: file, path: path}}

        error ->
          File.close(file)
          File.rm(path)
          error
      end
    end
  end

  defp finish_upload(state, entry, digest) do
    cond do
      entry.expected && entry.expected != digest ->
        {{:error, {:sha_mismatch, entry.expected, digest}}, state, entry}

      true ->
        case inspect_blob(state.root, digest, 0) do
          {:ok, %{sha256: ^digest, size: size}} when size == entry.size ->
            {{:ok, pin(entry, digest)}, state, entry}

          {:ok, _different} ->
            if entry.out_of_space,
              do: no_capacity(state, entry, digest),
              else: publish(state, entry, digest, :replace)

          {:error, :enoent} ->
            if entry.out_of_space,
              do: no_capacity(state, entry, digest),
              else: publish(state, entry, digest, :new)

          {:error, reason} ->
            {{:error, reason}, state, entry}
        end
    end
  end

  defp publish(state, entry, digest, mode) do
    path = blob_path(state.root, digest)

    with {:ok, capacity} <- measure_capacity(state),
         true <- capacity.free_bytes >= capacity.free_floor_bytes,
         {:ok, entry} <- open_stage(state, entry) do
      with :ok <- :file.sync(entry.file),
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- install_blob(state.root, entry.path, path, mode) do
        {{:ok, pin(entry, digest)}, %{state | used: state.used + entry.staged},
         %{entry | path: nil}}
      else
        {:error, :enospc} -> no_capacity(state, entry, digest)
        {:error, reason} -> {{:error, reason}, state, entry}
      end
    else
      false -> no_capacity(state, entry, digest)
      {:error, :enospc} -> no_capacity(state, entry, digest)
      {:error, reason} -> {{:error, reason}, state, entry}
    end
  end

  defp install_blob(_root, stage, path, :new), do: File.rename(stage, path)

  defp install_blob(root, stage, path, :replace) do
    directory = Path.join(root, "quarantine")
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    quarantine = Path.join(directory, Path.basename(path) <> "-" <> suffix)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.ln(path, quarantine) do
      case File.rename(stage, path) do
        :ok ->
          Logger.warning(
            "replaced corrupt artifact blob #{Path.basename(path)}; kept at #{quarantine}"
          )

          :ok

        error ->
          File.rm(quarantine)
          error
      end
    end
  end

  defp no_capacity(state, entry, digest) do
    {state, entry} = discard_stage(state, entry)

    result =
      if entry.allow_unpinned do
        {:ok, %{pin(entry, digest) | custody: "unpinned"}}
      else
        case measure_capacity(state) do
          {:ok, capacity} -> {:error, {:capacity, capacity}}
          error -> error
        end
      end

    {result, state, entry}
  end

  defp pin(entry, digest), do: %{custody: "pinned", sha256: digest, size: entry.size}

  defp cleanup(state, upload) do
    case pop_in(state.uploads[upload]) do
      {nil, state} -> state
      {entry, state} -> elem(discard_stage(state, entry), 0)
    end
  end

  defp discard_stage(state, %{file: nil} = entry), do: {state, entry}

  defp discard_stage(state, entry) do
    File.close(entry.file)
    if entry.path, do: File.rm(entry.path)

    {%{state | staged: state.staged - entry.staged}, %{entry | file: nil, path: nil, staged: 0}}
  end

  defp measure_capacity(state) do
    with {:ok, total, free} <- state.disk_space.(existing_directory(state.root)) do
      floor = max(state.floor_bytes, div(total * state.floor_percent, 100))
      effective = min(state.budget, state.used + state.staged + max(free - floor, 0))

      {:ok,
       %{
         used_bytes: state.used,
         staged_bytes: state.staged,
         free_bytes: free,
         free_floor_bytes: floor,
         effective_limit_bytes: effective
       }}
    end
  end

  defp existing_directory(path) do
    if File.dir?(path), do: path, else: existing_directory(Path.dirname(path))
  end

  defp disk_space(root) do
    with {output, 0} <- System.cmd("df", ["-Pk", root], env: [{"LC_ALL", "C"}]),
         [_, total, free] <- Regex.run(~r/\s+(\d+)\s+\d+\s+(\d+)\s+\d+%\s/, output) do
      {:ok, String.to_integer(total) * 1024, String.to_integer(free) * 1024}
    else
      _ -> {:error, :artifact_filesystem_capacity_unavailable}
    end
  end

  defp blob_path(root, digest), do: Path.join([root, "blobs", binary_part(digest, 0, 2), digest])
end
