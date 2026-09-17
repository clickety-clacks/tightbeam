defmodule Tightbeam.LiveBaseGuard do
  @moduledoc """
  Pure build admission and payload identity decisions. No filesystem or DB access.

  The integration owner supplies a canonical base, observed marker, and the complete
  payload file set. A successful decision is NOT a DB admission token: the DB owner
  must retain its own admission context and perform mandatory schema validation.
  """
  @marker_format "tightbeam-build-owner/v1"
  @payload_format "tightbeam-payload/v1"

  def decode_marker(bytes), do: decode(bytes, &valid_marker?/1, "invalid_build_marker")

  def decode_transition(bytes),
    do: decode(bytes, &valid_transition?/1, "invalid_build_transition")

  def admit_build(base, target, marker, state, transition) do
    cond do
      not canonical_path?(base) or not identity?(target) ->
        refuse("invalid_build_identity", target, "canonical base and SHA-256 identity")

      state not in [:new_empty, :existing] ->
        refuse("invalid_base_observation", state, [:new_empty, :existing])

      marker != :absent and not valid_marker?(marker) ->
        refuse("invalid_build_marker", marker, @marker_format)

      transition != nil and not valid_transition?(transition) ->
        refuse("invalid_build_transition", transition, "exact base/source/target")

      true ->
        source = if marker == :absent, do: "unmarked", else: marker["buildIdentity"]

        exact =
          transition != nil and transition["base"] == base and
            transition["source"] == source and transition["target"] == target

        cond do
          transition != nil and not exact ->
            refuse("build_transition_mismatch", transition, %{
              base: base,
              source: source,
              target: target
            })

          state == :new_empty and marker != :absent ->
            refuse("invalid_base_observation", state, "existing marked base")

          exact or source == target or (state == :new_empty and marker == :absent) ->
            {:ok,
             %{
               base: base,
               source: source,
               target: target,
               expected_schema: transition && transition["expectedSchema"]
             }}

          true ->
            refuse("build_transition_required", source, target)
        end
    end
  end

  # Compatibility comes from Schema's exact declarations, never the operator input.
  # Structural schema checks and transactional revalidation remain mandatory.
  def qualify_schema(%{expected_schema: expected}, stamp, compatible) when is_list(compatible) do
    cond do
      not nonblank?(stamp) or stamp not in compatible ->
        refuse("incompatible_schema", stamp, compatible)

      expected != nil and expected != stamp ->
        refuse("legacy_schema_mismatch", stamp, expected)

      true ->
        :ok
    end
  end

  def generate_manifest(files) when is_list(files) do
    if Enum.all?(files, fn
         {path, bytes} -> payload_path?(path) and is_binary(bytes)
         _ -> false
       end) and length(Enum.uniq_by(files, &elem(&1, 0))) == length(files) and files != [] do
      entries =
        files
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {path, bytes} ->
          %{"path" => path, "sha256" => digest(bytes)}
        end)

      encoded =
        Enum.map(entries, fn %{"path" => path, "sha256" => hash} ->
          [Integer.to_string(byte_size(path)), ":", path, ":", hash, "\n"]
        end)

      {:ok,
       %{
         "format" => @payload_format,
         "files" => entries,
         "buildIdentity" => digest([@payload_format, "\n", encoded])
       }}
    else
      refuse("invalid_payload_files", nil, "nonempty unique normalized paths and binary bytes")
    end
  end

  def generate_manifest(_), do: refuse("invalid_payload_files", nil, "file list")

  # The manifest must not choose the observed set: caller independently enumerates
  # all behavior inputs and rejects symlinks/escapes before passing their bytes.
  def verify_manifest(manifest, files) do
    with {:ok, actual} <- generate_manifest(files) do
      if manifest == actual do
        {:ok, actual["buildIdentity"]}
      else
        refuse("payload_manifest_mismatch", manifest, actual)
      end
    end
  end

  defp valid_marker?(m) when is_map(m) do
    Enum.sort(Map.keys(m)) == ["buildIdentity", "format"] and
      m["format"] == @marker_format and identity?(m["buildIdentity"])
  end

  defp valid_marker?(_), do: false

  defp valid_transition?(t) when is_map(t) do
    keys =
      if t["source"] == "unmarked",
        do: ["base", "expectedSchema", "source", "target"],
        else: ["base", "source", "target"]

    Enum.sort(Map.keys(t)) == keys and canonical_path?(t["base"]) and
      identity?(t["target"]) and
      ((t["source"] == "unmarked" and nonblank?(t["expectedSchema"])) or identity?(t["source"]))
  end

  defp valid_transition?(_), do: false

  defp decode(bytes, validator, code) when is_binary(bytes) do
    case JSON.decode(bytes) do
      {:ok, value} ->
        if validator.(value), do: {:ok, value}, else: refuse(code, nil, "strict object")

      {:error, _} ->
        refuse(code, nil, "valid JSON")
    end
  end

  defp decode(_, _, code), do: refuse(code, nil, "JSON bytes")

  defp identity?(x), do: is_binary(x) and Regex.match?(~r/\A[0-9a-f]{64}\z/, x)
  defp nonblank?(x), do: is_binary(x) and String.valid?(x) and String.trim(x) != ""

  defp canonical_path?(x) do
    nonblank?(x) and String.starts_with?(x, "/") and
      not String.contains?(x, <<0>>) and Path.expand(x) == x
  end

  defp payload_path?(x) do
    nonblank?(x) and not String.contains?(x, ["\\", <<0>>]) and
      Enum.all?(String.split(x, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp refuse(code, observed, expected),
    do: {:error, %{code: code, observed: observed, expected: expected}}
end
