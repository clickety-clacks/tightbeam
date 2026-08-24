defmodule Tightbeam.ClientFleetProof do
  @moduledoc "Canonical host-set and fleet-proof v1 byte codecs."

  @host_prefix "tightbeam-host-set-v1\0"
  @fleet_prefix "tightbeam-fleet-proof-v1\0"
  @host_fields [:name, :ssh, :base_dir, :cli_bin, :adapter_bin_dir]
  @result_fields [:name, :target, :release, :build_commit, :member_sha256]
  @targets ["aarch64-apple-darwin", "x86_64-unknown-linux-gnu"]

  @type host_row :: %{
          required(:name) => String.t(),
          required(:ssh) => String.t() | nil,
          required(:base_dir) => String.t() | nil,
          required(:cli_bin) => String.t() | nil,
          required(:adapter_bin_dir) => String.t() | nil
        }

  @type host_result :: %{
          required(:name) => String.t(),
          required(:target) => String.t(),
          required(:release) => String.t(),
          required(:build_commit) => String.t(),
          required(:member_sha256) => String.t(),
          required(:terminal_protocols) => [non_neg_integer()]
        }

  @doc "Encode persisted registered-host rows in their required canonical order."
  @spec host_set([host_row()]) :: {:ok, %{bytes: binary(), sha256: String.t()}} | {:error, atom()}
  def host_set(rows) when is_list(rows) do
    with :ok <- canonical_rows(rows, @host_fields),
         {:ok, body} <- encode_rows(rows, @host_fields) do
      receipt(@host_prefix <> u64(length(rows)) <> body)
    end
  end

  def host_set(_), do: {:error, :invalid_host_rows}

  @doc "Validate a host-set v1 byte stream and reject every noncanonical form."
  @spec validate_host_set(binary()) :: :ok | {:error, atom()}
  def validate_host_set(bytes) when is_binary(bytes) do
    with {:ok, rest} <- prefix(bytes, @host_prefix),
         {:ok, count, rest} <- take_u64(rest),
         {:ok, rows, <<>>} <- take_rows(rest, count, @host_fields),
         :ok <- canonical_rows(rows, @host_fields) do
      :ok
    else
      {:ok, _rows, _trailing} -> {:error, :trailing_bytes}
      error -> error
    end
  end

  @doc "Encode one canonical fleet proof for the exact persisted host set."
  @spec fleet_proof([host_row()], map()) ::
          {:ok, %{bytes: binary(), sha256: String.t(), host_set_sha256: String.t()}}
          | {:error, atom()}
  def fleet_proof(hosts, proof) when is_list(hosts) and is_map(proof) do
    with {:ok, host_receipt} <- host_set(hosts),
         {:ok, manifest_sha} <- lower_sha(Map.get(proof, :manifest_sha256)),
         {:ok, terminal} <- protocols(Map.get(proof, :terminal_protocols)),
         {:ok, transitions} <- protocols(Map.get(proof, :release_transition_protocols)),
         {:ok, results} <- proof_results(Map.get(proof, :results)),
         :ok <- matching_results(hosts, results),
         {:ok, result_body} <- encode_results(results) do
      bytes =
        @fleet_prefix <>
          tagged(host_receipt.sha256) <>
          tagged(manifest_sha) <>
          encode_protocols(terminal) <>
          encode_protocols(transitions) <>
          u64(length(results)) <>
          result_body

      {:ok, fleet_receipt} = receipt(bytes)
      {:ok, Map.put(fleet_receipt, :host_set_sha256, host_receipt.sha256)}
    else
      false -> {:error, :invalid_proof}
      error -> error
    end
  end

  def fleet_proof(_, _), do: {:error, :invalid_proof}

  defp proof_results(nil), do: {:error, :missing_results}
  defp proof_results(results) when is_list(results), do: {:ok, results}
  defp proof_results(_), do: {:error, :invalid_proof}

  @doc "Validate canonical fleet-proof bytes against the exact persisted registered hosts."
  @spec validate_fleet_proof(binary(), [host_row()]) :: :ok | {:error, atom()}
  def validate_fleet_proof(bytes, hosts) when is_binary(bytes) and is_list(hosts) do
    with {:ok, host_receipt} <- host_set(hosts),
         {:ok, rest} <- prefix(bytes, @fleet_prefix),
         {:ok, host_sha, rest} <- take_tagged(rest),
         true <- host_sha == host_receipt.sha256,
         {:ok, manifest_sha, rest} <- take_tagged(rest),
         {:ok, ^manifest_sha} <- lower_sha(manifest_sha),
         {:ok, _terminal, rest} <- take_protocols(rest),
         {:ok, _transitions, rest} <- take_protocols(rest),
         {:ok, count, rest} <- take_u64(rest),
         true <- count == length(hosts),
         {:ok, results, <<>>} <- take_results(rest, count),
         :ok <- matching_results(hosts, results) do
      :ok
    else
      false -> {:error, :host_set_mismatch}
      {:ok, _results, _trailing} -> {:error, :trailing_bytes}
      error -> error
    end
  end

  def validate_fleet_proof(_, _), do: {:error, :invalid_fleet_proof}

  defp encode_rows(rows, fields) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case encode_fields(row, fields) do
        {:ok, bytes} -> {:cont, {:ok, [acc, bytes]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      error -> error
    end
  end

  defp encode_results(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn result, {:ok, acc} ->
      with {:ok, fixed} <- encode_fields(result, @result_fields),
           :ok <- valid_result(result),
           {:ok, protocols} <- protocols(Map.get(result, :terminal_protocols)) do
        {:cont, {:ok, [acc, fixed, encode_protocols(protocols)]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      error -> error
    end
  end

  defp encode_fields(row, fields) when is_map(row) do
    fields
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, acc} ->
      case Map.fetch(row, field) do
        {:ok, value} ->
          case tagged_value(value) do
            {:ok, bytes} -> {:cont, {:ok, [acc, bytes]}}
            error -> {:halt, error}
          end

        :error ->
          {:halt, {:error, :missing_field}}
      end
    end)
    |> case do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      error -> error
    end
  end

  defp encode_fields(_, _), do: {:error, :invalid_row}

  defp tagged_value(nil), do: {:ok, <<0>>}

  defp tagged_value(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, tagged(value)}, else: {:error, :invalid_utf8}
  end

  defp tagged_value(_), do: {:error, :invalid_string}
  defp tagged(value), do: <<1>> <> u64(byte_size(value)) <> value

  defp canonical_rows(rows, fields) do
    names = Enum.map(rows, &field(&1, :name))

    cond do
      Enum.any?(rows, &(not is_map(&1))) ->
        {:error, :invalid_row}

      Enum.any?(rows, fn row -> Enum.any?(fields, &(not Map.has_key?(row, &1))) end) ->
        {:error, :missing_field}

      Enum.any?(names, &(not is_binary(&1) or not String.valid?(&1))) ->
        {:error, :invalid_name}

      names != Enum.sort(names) ->
        {:error, :noncanonical_order}

      length(names) != length(Enum.uniq(names)) ->
        {:error, :duplicate_name}

      true ->
        :ok
    end
  end

  defp matching_results(hosts, results) do
    with :ok <- canonical_rows(results, @result_fields ++ [:terminal_protocols]),
         true <- Enum.map(hosts, &field(&1, :name)) == Enum.map(results, &field(&1, :name)),
         :ok <- valid_results(results) do
      :ok
    else
      false -> {:error, :host_result_mismatch}
      error -> error
    end
  end

  defp valid_results(results) do
    Enum.reduce_while(results, :ok, fn result, :ok ->
      case valid_result(result) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_result(result) do
    with true <- Map.get(result, :target) in @targets,
         {:ok, _} <- lower_hex(Map.get(result, :build_commit), 40, :invalid_build_commit),
         {:ok, _} <- lower_sha(Map.get(result, :member_sha256)),
         true <- valid_release?(Map.get(result, :release)),
         {:ok, _} <- protocols(Map.get(result, :terminal_protocols)) do
      :ok
    else
      false -> {:error, :invalid_result}
      error -> error
    end
  end

  defp valid_release?(release) when is_binary(release) do
    match?({:ok, _}, Version.parse(release))
  end

  defp valid_release?(_), do: false

  defp protocols(values) when is_list(values) do
    cond do
      Enum.any?(values, &(not is_integer(&1) or &1 < 0 or &1 > 0xFFFFFFFF)) ->
        {:error, :invalid_protocol}

      values != Enum.sort(values) ->
        {:error, :noncanonical_protocol_order}

      length(values) != length(Enum.uniq(values)) ->
        {:error, :duplicate_protocol}

      true ->
        {:ok, values}
    end
  end

  defp protocols(_), do: {:error, :invalid_protocols}

  defp encode_protocols(values) do
    u64(length(values)) <> IO.iodata_to_binary(Enum.map(values, &<<&1::unsigned-big-32>>))
  end

  defp take_rows(bytes, count, fields), do: take_rows(bytes, count, fields, [])
  defp take_rows(bytes, 0, _fields, rows), do: {:ok, Enum.reverse(rows), bytes}

  defp take_rows(bytes, count, fields, rows) when count > 0 do
    with {:ok, row, rest} <- take_fields(bytes, fields) do
      take_rows(rest, count - 1, fields, [row | rows])
    end
  end

  defp take_results(bytes, count), do: take_results(bytes, count, [])
  defp take_results(bytes, 0, rows), do: {:ok, Enum.reverse(rows), bytes}

  defp take_results(bytes, count, rows) when count > 0 do
    with {:ok, row, rest} <- take_fields(bytes, @result_fields),
         {:ok, protocols, rest} <- take_protocols(rest) do
      take_results(rest, count - 1, [Map.put(row, :terminal_protocols, protocols) | rows])
    end
  end

  defp take_fields(bytes, fields) do
    Enum.reduce_while(fields, {:ok, %{}, bytes}, fn field, {:ok, row, rest} ->
      case take_tagged(rest, true) do
        {:ok, value, tail} -> {:cont, {:ok, Map.put(row, field, value), tail}}
        error -> {:halt, error}
      end
    end)
  end

  defp take_protocols(bytes) do
    with {:ok, count, rest} <- take_u64(bytes),
         {:ok, values, rest} <- take_u32s(rest, count, []),
         {:ok, values} <- protocols(values) do
      {:ok, values, rest}
    end
  end

  defp take_u32s(bytes, 0, values), do: {:ok, Enum.reverse(values), bytes}

  defp take_u32s(<<value::unsigned-big-32, rest::binary>>, count, values) when count > 0,
    do: take_u32s(rest, count - 1, [value | values])

  defp take_u32s(_, _, _), do: {:error, :truncated_protocols}

  defp take_tagged(bytes, nullable \\ false)
  defp take_tagged(<<0, rest::binary>>, true), do: {:ok, nil, rest}
  defp take_tagged(<<0, _::binary>>, false), do: {:error, :null_not_allowed}

  defp take_tagged(<<1, length::unsigned-big-64, rest::binary>>, _nullable) do
    if byte_size(rest) >= length do
      <<value::binary-size(length), tail::binary>> = rest
      if String.valid?(value), do: {:ok, value, tail}, else: {:error, :invalid_utf8}
    else
      {:error, :truncated_string}
    end
  end

  defp take_tagged(<<_tag, _::binary>>, _nullable), do: {:error, :invalid_tag}
  defp take_tagged(_, _nullable), do: {:error, :truncated_string}

  defp take_u64(<<value::unsigned-big-64, rest::binary>>), do: {:ok, value, rest}
  defp take_u64(_), do: {:error, :truncated_count}

  defp prefix(bytes, prefix) do
    case bytes do
      <<^prefix::binary, rest::binary>> -> {:ok, rest}
      _ -> {:error, :invalid_prefix}
    end
  end

  defp lower_sha(value), do: lower_hex(value, 64, :invalid_sha256)

  defp lower_hex(value, length, error) when is_binary(value) and byte_size(value) == length do
    if value =~ ~r/\A[0-9a-f]+\z/, do: {:ok, value}, else: {:error, error}
  end

  defp lower_hex(_, _, error), do: {:error, error}
  defp field(row, key) when is_map(row), do: Map.get(row, key)
  defp field(_, _), do: nil
  defp u64(value), do: <<value::unsigned-big-64>>

  defp receipt(bytes) do
    {:ok,
     %{
       bytes: bytes,
       sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
     }}
  end
end
