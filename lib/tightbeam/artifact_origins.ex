defmodule Tightbeam.ArtifactOrigins do
  @moduledoc false

  alias Tightbeam.{DB.Txn, Placement}

  # Capture within the artifact INSERT transaction. A later host move or host
  # registry edit must not rebind an already recorded unqualified path.
  def registration_context(txn, call) do
    case parse(call.params.origin_path) do
      {:qualified, host, _path} ->
        {host, nil}

      kind when kind in [:absolute, :relative] ->
        case Txn.q(txn, "SELECT host FROM sessions WHERE sessionKey=?1", [call.session_key]) do
          [[host]] ->
            workspace =
              if kind == :relative do
                case Placement.host_in_txn(txn, call[:artifact_base_dir], host) do
                  nil -> nil
                  location -> Placement.host_workdir_path(location, call.session_key)
                end
              end

            {host, workspace}

          [] ->
            {nil, nil}
        end

      kind when kind in [:unknown, :non_filesystem] ->
        {nil, nil}
    end
  end

  # Explicit host-qualified paths carry their own location evidence. A missing
  # stamp on any other legacy form remains unknown; current placement is not a
  # substitute for registration-time origin.
  def resolve(row) do
    case parse(row.origin_path) do
      {:qualified, host, path} ->
        if row.origin_host in [nil, host],
          do: {:ok, host, Path.expand(path)},
          else: {:error, :conflicting_origin_host}

      :absolute when is_binary(row.origin_host) ->
        {:ok, row.origin_host, Path.expand(row.origin_path)}

      :relative when is_binary(row.origin_host) and is_binary(row.origin_workspace) ->
        {:ok, row.origin_host, Path.expand(Path.join(row.origin_workspace, row.origin_path))}

      _ ->
        {:error, :unknown_origin}
    end
  end

  def parse(path) when is_binary(path) and byte_size(path) > 0 do
    cond do
      non_filesystem?(path) ->
        :non_filesystem

      String.contains?(path, <<0>>) or ".." in String.split(path, "/") ->
        :unknown

      match?([_, _, _], Regex.run(~r{^([^/:\s]+):(/.*)$}s, path)) ->
        [_, host, absolute] = Regex.run(~r{^([^/:\s]+):(/.*)$}s, path)
        {:qualified, host, absolute}

      String.contains?(path, ":") ->
        :unknown

      Path.type(path) == :absolute ->
        :absolute

      true ->
        :relative
    end
  end

  def parse(_path), do: :unknown

  # These explicit reference forms do not name filesystem content. A colon on
  # its own is insufficient because host-qualified filesystem origins also use
  # one.
  defp non_filesystem?(path) do
    case URI.new(path) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        String.starts_with?(path, "tightbeam-transcript:") and
          not String.starts_with?(path, "tightbeam-transcript:/") and
          byte_size(path) > byte_size("tightbeam-transcript:") and
          not String.contains?(path, <<0>>)
    end
  end

  # An unstamped absolute location is a possible location, never an inferred
  # host. Cleanup may prove its route disjoint on the selected host; overlap or
  # unsafe routes remain ambiguous and cannot authorize deletion.
  def possible_location(row) do
    case {parse(row.origin_path), resolve(row)} do
      {:non_filesystem, _} ->
        :non_filesystem

      {_, {:ok, host, path}} ->
        {:ok, host, path}

      {:absolute, {:error, :unknown_origin}} ->
        {:ok, nil, Path.expand(row.origin_path)}

      _ ->
        {:error, :unknown_origin}
    end
  end
end
