defmodule Tightbeam.ArtifactArchive do
  @moduledoc false

  alias Tightbeam.{Placement, WorkspaceCleanup}
  alias Tightbeam.Harness.Support

  defmodule Digest do
    @moduledoc false
    defstruct [:hash, :limit, size: 0, chunks: []]

    def new(limit), do: %__MODULE__{hash: :crypto.hash_init(:sha256), limit: limit}

    def append(state, bytes) do
      size = state.size + byte_size(bytes)
      chunks = if size <= state.limit, do: [bytes | state.chunks], else: []
      %{state | hash: :crypto.hash_update(state.hash, bytes), size: size, chunks: chunks}
    end

    def result(state, home) do
      %{
        sha256: Base.encode16(:crypto.hash_final(state.hash), case: :lower),
        size: state.size,
        bytes: if(state.size <= state.limit, do: IO.iodata_to_binary(Enum.reverse(state.chunks))),
        home: home
      }
    end
  end

  defimpl Collectable, for: Digest do
    def into(state) do
      {state,
       fn
         acc, {:cont, bytes} -> Digest.append(acc, bytes)
         acc, :done -> acc
         _acc, :halt -> :ok
       end}
    end
  end

  def read(db, row, config) do
    base_dir = config[:base_dir] || Application.get_env(:tightbeam, :base_dir)
    hosts = Placement.hosts(base_dir, db)

    with true <- Path.type(row.home) == :absolute and not String.contains?(row.home, <<0>>),
         {:ok, host} <- holding_host(hosts, row) do
      read_home(host, row.home, config)
    else
      false -> {:error, :invalid_archive_home}
      error -> error
    end
  end

  defp holding_host(hosts, %{origin_host: name}) when is_binary(name) do
    case hosts[name] || Enum.find_value(hosts, fn {_, h} -> h.ssh == name && h end) do
      nil -> {:error, :archive_host_unknown}
      host -> {:ok, host}
    end
  end

  defp holding_host(hosts, row) do
    # Legacy rows have no origin stamp. An archive prefix can identify the
    # host independently of the recording session's current placement.
    routes =
      for {_, host} <- hosts,
          host.base_dir,
          root <- Enum.uniq([archive_root(host), default_root(host)]),
          String.starts_with?(row.home, root <> "/"),
          do: {byte_size(root), host}

    case Enum.sort_by(routes, &elem(&1, 0), :desc) do
      [{length, _}, {length, _} | _] -> {:error, :archive_host_ambiguous}
      [{_, host} | _] -> {:ok, host}
      [] -> {:error, :archive_host_unknown}
    end
  end

  defp read_home(%{ssh: nil} = host, home, config) do
    limit = inline_limit(config)

    case read_local(home, limit) do
      {:error, :enoent} when is_binary(host.base_dir) ->
        source = default_root(host)
        destination = archive_root(host)

        if destination != source and String.starts_with?(home, source <> "/") do
          read_local(String.replace_prefix(home, source, destination), limit)
        else
          {:error, :enoent}
        end

      result ->
        result
    end
  end

  defp read_home(%{ssh: ssh}, home, config) do
    quoted = Support.shell_quote(home)
    script = "[ -f #{quoted} ] && [ ! -L #{quoted} ] && exec cat #{quoted}"
    command = Support.catalog_probe_argv(ssh, script)
    runner = config[:artifact_archive_runner] || (&run_remote/2)
    collect = Digest.new(inline_limit(config))

    case Support.bounded_run(fn argv -> runner.(argv, collect) end, command, 30_000) do
      {:ok, {%Digest{} = digest, 0}} -> {:ok, Digest.result(digest, home)}
      {:ok, {_, status}} -> {:error, {:remote_archive_read_failed, status}}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_remote([command | args], collect), do: System.cmd(command, args, into: collect)

  @doc false
  def read_local(path, limit) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        case File.open(path, [:read, :raw, :binary], &hash_file(&1, Digest.new(limit), path)) do
          {:ok, result} -> result
          error -> error
        end

      {:ok, _} ->
        {:error, :archive_home_not_a_regular_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hash_file(file, digest, home) do
    case :file.read(file, 64 * 1024) do
      {:ok, bytes} -> hash_file(file, Digest.append(digest, bytes), home)
      :eof -> {:ok, Digest.result(digest, home)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def inline_limit(config) do
    Map.get_lazy(config, :artifact_archive_inline_limit_bytes, fn ->
      Application.get_env(:tightbeam, :artifact_archive_inline_limit_bytes, 8 * 1024 * 1024)
    end)
  end

  defp archive_root(host), do: host |> WorkspaceCleanup.archive_root() |> Path.expand()
  defp default_root(host), do: host.base_dir |> Path.join("archive") |> Path.expand()
end
