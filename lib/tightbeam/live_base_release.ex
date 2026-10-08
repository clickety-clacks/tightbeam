defmodule Tightbeam.LiveBaseRelease do
  @moduledoc false

  @format "tightbeam-release-provenance/v1"
  @repository "clickety-clacks/tightbeam"
  @tag_pattern ~r/^v(?<version>[0-9]+\.[0-9]+\.[0-9]+)(?:\+[0-9]+)?$/

  defmodule Refusal do
    defexception [:message]
  end

  @doc false
  def automatic_transition_candidate?(payload_root) do
    with :packaged <- package_kind(payload_root),
         {:ok, _provenance} <- read_provenance(payload_root) do
      true
    else
      :not_packaged -> false
      :missing -> false
      :unsupported -> false
      {:error, message} -> raise Refusal, message: message
    end
  end

  @doc false
  def automatic_transition(payload_root, base, target, stamp, source_marker \\ :absent) do
    with :packaged <- package_kind(payload_root),
         {:ok, _provenance} <- read_provenance(payload_root),
         {:ok, source, expected_schema} <- validate_source_stamp(stamp, source_marker, target) do
      transition = %{"base" => base, "source" => source, "target" => target}

      transition =
        if expected_schema do
          Map.put(transition, "expectedSchema", expected_schema)
        else
          transition
        end

      {:ok, transition}
    else
      :not_packaged -> :none
      :missing -> :none
      :unsupported -> :none
      {:error, message} -> raise Refusal, message: message
    end
  end

  @doc false
  def provenance_path(payload_root) do
    case package_kind(payload_root) do
      :packaged -> Path.join(package_root(payload_root), "release-provenance.json")
      :not_packaged -> nil
    end
  end

  defp package_kind(payload_root) do
    app = Path.expand(payload_root)
    lib = Path.dirname(app)
    release = Path.dirname(lib)

    if Path.basename(lib) == "lib" and Path.basename(release) == "release" do
      :packaged
    else
      :not_packaged
    end
  end

  defp package_root(payload_root) do
    payload_root
    |> Path.expand()
    |> Path.dirname()
    |> Path.dirname()
    |> Path.dirname()
  end

  defp read_provenance(payload_root) do
    path = provenance_path(payload_root)

    case File.lstat(path) do
      {:error, :enoent} ->
        :missing

      {:ok, %{type: :regular}} ->
        decode_provenance(path, app_version(payload_root))

      other ->
        {:error, "release provenance refused: #{path} is not a regular file (#{inspect(other)})"}
    end
  end

  defp decode_provenance(path, expected_version) do
    value = path |> File.read!() |> JSON.decode!()

    if is_map(value) and Enum.sort(Map.keys(value)) == ["commit", "format", "repository", "tag"] do
      validate_provenance(value, expected_version)
    else
      {:error, "release provenance refused: expected exact format/repository/tag/commit fields"}
    end
  rescue
    _ -> {:error, "release provenance refused: invalid JSON"}
  end

  defp validate_provenance(
         %{"format" => @format, "repository" => @repository, "tag" => tag, "commit" => commit},
         expected_version
       ) do
    with {:ok, version} <- release_version(tag),
         :ok <- validate_commit(commit),
         :ok <- validate_app_version(version, expected_version) do
      {:ok,
       %{format: @format, repository: @repository, tag: tag, commit: commit, version: version}}
    else
      {:error, message} -> {:error, "release provenance refused: #{message}"}
    end
  end

  defp validate_provenance(_, _),
    do: {:error, "release provenance has an unknown format or repository"}

  defp release_version(tag) when is_binary(tag) do
    case Regex.named_captures(@tag_pattern, tag) do
      %{"version" => version} -> {:ok, version}
      _ -> {:error, "tag must be v<semver> with an optional numeric release suffix"}
    end
  end

  defp release_version(_), do: {:error, "tag must be a string"}

  defp validate_commit(commit) when is_binary(commit) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, commit),
      do: :ok,
      else: {:error, "commit must be a full lower-case Git SHA"}
  end

  defp validate_commit(_), do: {:error, "commit must be a string"}

  defp validate_app_version(version, expected_version) do
    if version == expected_version,
      do: :ok,
      else:
        {:error, "tag version #{version} does not match application version #{expected_version}"}
  end

  defp app_version(payload_root) do
    case Regex.run(
           ~r/^tightbeam-(?<version>[0-9]+\.[0-9]+\.[0-9]+)$/,
           Path.basename(payload_root),
           capture: :all_names
         ) do
      [version] ->
        version

      _ ->
        raise Refusal,
          message: "release provenance refused: application payload has no version"
    end
  end

  defp validate_source_stamp([[stamp]], :absent, _target) do
    if stamp == Tightbeam.Schema.live_base_upgrade_predecessor(),
      do: {:ok, "unmarked", stamp},
      else: :unsupported
  end

  defp validate_source_stamp(
         [[stamp]],
         %{"format" => "tightbeam-build-owner/v1", "buildIdentity" => source} = marker,
         target
       ) do
    valid_marker =
      Enum.sort(Map.keys(marker)) == ["buildIdentity", "format"] and
        identity?(source) and source != target

    if valid_marker and stamp in Tightbeam.Schema.guard_compatible_stamps(),
      do: {:ok, source, nil},
      else: :unsupported
  end

  defp validate_source_stamp(_, _, _), do: :unsupported

  defp identity?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
end
