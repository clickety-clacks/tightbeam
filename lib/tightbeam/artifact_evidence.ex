defmodule Tightbeam.ArtifactEvidence do
  @moduledoc false

  alias Tightbeam.{ArtifactArchive, ArtifactBlobStore, ArtifactContent, Artifacts}

  def prepare(db, call) do
    case {call.params[:verdict_kind], call.params[:artifact_id]} do
      {"verified", id} when is_binary(id) ->
        config = call[:artifact_evidence_config] || %{}
        primary = snapshot(db, id, config, ArtifactArchive.inline_limit(config))

        supporting =
          primary
          |> manifest_references()
          |> Map.new(fn id -> {id, snapshot(db, id, config, 0)} end)

        Map.put(call, :artifact_evidence, Map.put(supporting, id, primary))

      _ ->
        call
    end
  end

  # Compare the preflight with the current row under the write transaction.
  # Attest validation still owns attribution and the cited digest.
  def get(call, row) do
    case get_in(call, [:artifact_evidence, row.artifact_id]) do
      %{recorded: recorded, custody: custody} = snapshot
      when recorded == row.content_sha256 ->
        if custody == row[:custody], do: snapshot

      _ ->
        nil
    end
  end

  defp snapshot(db, id, config, limit) do
    case Artifacts.get(db, id) do
      %{custody: "pinned", content_sha256: digest} = row ->
        base =
          Application.get_env(:tightbeam, :base_dir, Path.join(System.user_home!(), ".tightbeam"))

        root = config[:artifact_blob_root] || ArtifactBlobStore.options(base)[:root]

        case ArtifactBlobStore.inspect_blob(root, digest, limit) do
          {:ok, blob} -> evidence(row, digest, blob.sha256, blob.bytes)
          {:error, _} -> nil
        end

      nil ->
        nil

      row ->
        case ArtifactContent.fetch(db, id) do
          nil ->
            nil

          %{content: bytes, content_sha256: digest} ->
            actual = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
            evidence(row, digest, actual, if(limit > 0, do: bytes))
        end
    end
  end

  defp evidence(row, digest, actual, bytes) do
    %{
      recorded: row.content_sha256,
      custody: row[:custody],
      digest: digest,
      actual: actual,
      bytes: bytes
    }
  end

  defp manifest_references(%{bytes: bytes, recorded: hash, actual: hash}) when is_binary(bytes) do
    case JSON.decode(bytes) do
      {:ok, %{"schema" => "file-effect-evidence/v1"} = manifest} ->
        observations = manifest["observations"]

        entries =
          [manifest["before"], manifest["after"]] ++
            if(is_list(observations), do: observations, else: [])

        Enum.flat_map(entries, fn
          %{"artifactId" => id} when is_binary(id) -> [id]
          _ -> []
        end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp manifest_references(_), do: []
end
