defmodule Tightbeam.ArtifactCapture do
  @moduledoc false
  alias Tightbeam.{ArtifactBlobStore, ArtifactOrigins, DB, Placement}
  alias Tightbeam.Harness.Support

  def record(db, call, config) do
    case config[:artifact_blob_store] do
      nil ->
        Tightbeam.Artifacts.record(db, call)

      store ->
        capture =
          if is_nil(call[:artifact_capture]) and
               not Map.has_key?(call.params, :content_base64) and
               ArtifactOrigins.parse(call.params[:origin_path]) == :non_filesystem do
            %{custody: "external_pointer", sha256: call.params[:content_sha256]}
          else
            call[:artifact_capture] || capture_origin(db, store, call, config)
          end

        case capture do
          %{custody: _} = capture ->
            result = Tightbeam.Artifacts.record(db, Map.put(call, :artifact_capture, capture))

            if result[:custody] == "unpinned" do
              Map.put(result, :warning, "recorded unpinned; Tightbeam did not store the bytes")
            else
              result
            end

          error ->
            error
        end
    end
  end

  def upload(conn, store, params) do
    capture(store, params, conn, &read_request/3)
  end

  def promote(store, captured) do
    {result, _} =
      capture(store, %{content_sha256: captured.content_sha256}, nil, fn store, upload, context ->
        {ArtifactBlobStore.append(store, upload, captured.content), context}
      end)

    result
  end

  defp capture_origin(db, store, call, config) do
    {result, _} =
      capture(store, call.params, nil, fn store, upload, context ->
        {transfer_origin(db, call, config, store, upload), context}
      end)

    result
  end

  defp capture(store, params, context, transfer) do
    expected = params[:content_sha256]

    if is_nil(expected) or
         (is_binary(expected) and Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, expected)) do
      {:ok, upload} =
        ArtifactBlobStore.begin_upload(store,
          expected_sha: expected && String.downcase(expected),
          allow_unpinned: params[:allow_unpinned] == true
        )

      try do
        {result, context} = transfer.(store, upload, context)

        result =
          case result do
            :ok -> ArtifactBlobStore.finish(store, upload)
            error -> error
          end

        {capture_result(result), context}
      after
        ArtifactBlobStore.abort(store, upload)
      end
    else
      {capture_result({:error, :invalid_sha256}), context}
    end
  end

  defp read_request(store, upload, conn) do
    case Plug.Conn.read_body(conn, length: 1024 * 1024, read_length: 64 * 1024) do
      {status, bytes, conn} when status in [:ok, :more] ->
        case ArtifactBlobStore.append(store, upload, bytes) do
          :ok when status == :more -> read_request(store, upload, conn)
          result -> {result, conn}
        end

      {:error, reason} ->
        {{:error, reason}, conn}
    end
  end

  defp transfer_origin(db, call, config, store, upload) do
    if Map.has_key?(call.params, :content_base64) do
      with encoded when is_binary(encoded) <- call.params.content_base64,
           {:ok, bytes} <- Base.decode64(encoded),
           ^encoded <- Base.encode64(bytes) do
        ArtifactBlobStore.append(store, upload, bytes)
      else
        _ -> {:error, :invalid_content_base64}
      end
    else
      with {:ok, host, path} <- origin_location(db, call),
           location when not is_nil(location) <- Placement.hosts(config.base_dir, db)[host] do
        case location do
          %{ssh: nil} -> read_local(path, store, upload)
          %{ssh: ssh} -> read_remote(ssh, path, store, upload, config)
        end
      else
        nil -> {:error, :unknown_artifact_host}
        error -> error
      end
    end
  end

  defp origin_location(db, call) do
    case DB.transaction(db, fn txn -> ArtifactOrigins.registration_context(txn, call) end) do
      {:ok, {host, workspace}} ->
        ArtifactOrigins.resolve(%{
          origin_path: call.params[:origin_path],
          origin_host: host,
          origin_workspace: workspace
        })

      error ->
        error
    end
  end

  defp read_local(path, store, upload) do
    case File.stat(path) do
      {:ok, %{type: :regular}} ->
        case File.open(path, [:read, :raw, :binary], &read_file(&1, store, upload)) do
          {:ok, result} -> result
          error -> error
        end

      {:ok, %{type: :directory}} ->
        {:error, :directory_origin}

      {:ok, _} ->
        {:error, :not_a_regular_file}

      error ->
        error
    end
  end

  defp read_file(file, store, upload) do
    case :file.read(file, 1024 * 1024) do
      {:ok, bytes} ->
        with :ok <- ArtifactBlobStore.append(store, upload, bytes),
             do: read_file(file, store, upload)

      :eof ->
        :ok

      error ->
        error
    end
  end

  defmodule RemoteStream do
    @moduledoc false
    defstruct [:store, :upload, result: :ok, chunks: [], size: 0]

    def append(stream, bytes) do
      stream = %{stream | chunks: [bytes | stream.chunks], size: stream.size + byte_size(bytes)}
      if stream.size >= 1024 * 1024, do: flush(stream), else: stream
    end

    def flush(%{result: :ok, size: size} = stream) when size > 0 do
      bytes = stream.chunks |> Enum.reverse() |> IO.iodata_to_binary()
      result = Tightbeam.ArtifactBlobStore.append(stream.store, stream.upload, bytes)
      %{stream | result: result, size: 0, chunks: []}
    end

    def flush(stream), do: stream
  end

  defimpl Collectable, for: RemoteStream do
    def into(stream) do
      {stream,
       fn
         %{result: :ok} = acc, {:cont, bytes} ->
           RemoteStream.append(acc, bytes)

         acc, {:cont, _bytes} ->
           acc

         acc, :done ->
           RemoteStream.flush(acc)

         _acc, :halt ->
           :ok
       end}
    end
  end

  defp read_remote(ssh, path, store, upload, config) do
    quoted = Support.shell_quote(path)
    script = "if [ -d #{quoted} ]; then exit 2; fi; [ -f #{quoted} ] && exec cat #{quoted}"
    command = Support.catalog_probe_argv(ssh, script)
    collect = %RemoteStream{store: store, upload: upload}
    runner = config[:artifact_capture_runner] || (&remote_command/2)

    case Support.bounded_run(fn argv -> runner.(argv, collect) end, command, 120_000) do
      {:ok, {%RemoteStream{result: result}, 0}} ->
        result

      {:ok, {%RemoteStream{}, 2}} ->
        {:error, :directory_origin}

      {:ok, {_, status}} when is_integer(status) ->
        {:error, {:remote_artifact_read_failed, status}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remote_command([command | args], collect), do: System.cmd(command, args, into: collect)

  defp capture_result({:ok, result}), do: result

  defp capture_result({:error, {:capacity, capacity}}) do
    Map.merge(capacity, %{
      code: "artifact_store_full",
      message:
        "artifact store capacity exceeded (#{capacity.free_bytes} bytes free, " <>
          "#{capacity.free_floor_bytes} reserved, #{capacity.effective_limit_bytes} effective limit); " <>
          "pass --allow-unpinned to record a pointer without stored bytes"
    })
  end

  defp capture_result({:error, {:sha_mismatch, expected, observed}}) do
    %{
      code: "content_sha256_mismatch",
      expected_sha256: expected,
      observed_sha256: observed,
      message:
        "supplied SHA-256 does not match captured bytes (expected #{expected}, observed #{observed})"
    }
  end

  defp capture_result({:error, :directory_origin}) do
    %{
      code: "artifact_directory_origin",
      message:
        "artifact origin is a directory; record a file or package the directory into an archive file"
    }
  end

  defp capture_result({:error, reason}) do
    %{code: "artifact_capture_failed", message: "could not capture artifact: #{inspect(reason)}"}
  end
end
