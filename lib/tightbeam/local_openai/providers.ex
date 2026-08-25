defmodule Tightbeam.LocalOpenAi.Providers do
  @moduledoc false

  @reserved_names ~w(opencode-go)
  @name_pattern ~r/^[a-z][a-z0-9-]*$/

  @type record :: %{
          required(:name) => String.t(),
          required(:type) => String.t(),
          required(:endpoint) => String.t(),
          optional(:api_key) => String.t() | nil
        }

  @doc false
  def providers_dir(base_dir) when is_binary(base_dir) do
    Path.join([base_dir, "auth", "pi-local", "providers"])
  end

  @doc false
  def provider_path(base_dir, name) when is_binary(base_dir) and is_binary(name) do
    Path.join(providers_dir(base_dir), "#{name}.json")
  end

  @doc false
  def validate_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, "local-openai provider name must be nonblank"}

      String.downcase(trimmed) in @reserved_names ->
        {:error, "local-openai provider name #{inspect(trimmed)} is reserved"}

      not Regex.match?(@name_pattern, trimmed) ->
        {:error,
         "local-openai provider name must match #{inspect(@name_pattern.source)}; got #{inspect(trimmed)}"}

      true ->
        {:ok, trimmed}
    end
  end

  @doc false
  def list(base_dir) when is_binary(base_dir) do
    dir = providers_dir(base_dir)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.rootname/1)
        |> Enum.sort()

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise "could not list local-openai providers at #{dir}: #{inspect(reason)}"
    end
  end

  @doc false
  def read(base_dir, name) when is_binary(base_dir) and is_binary(name) do
    with {:ok, name} <- validate_name(name) do
      path = provider_path(base_dir, name)

      case File.read(path) do
        {:ok, bytes} -> decode_record(bytes, name, path)
        {:error, :enoent} -> {:error, {:missing_provider, name}}
        {:error, reason} -> {:error, {:unreadable_provider, path, reason}}
      end
    end
  end

  @doc false
  def read_all(base_dir) when is_binary(base_dir) do
    base_dir
    |> list()
    |> Enum.reduce({:ok, []}, fn name, {:ok, acc} ->
      case read(base_dir, name) do
        {:ok, record} -> {:ok, [record | acc]}
        {:error, _} = error -> error
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.sort_by(records, & &1.name)}
      error -> error
    end
  end

  @doc false
  def encode_record(name, endpoint, api_key \\ nil) do
    with {:ok, name} <- validate_name(name) do
      record = %{
        "name" => name,
        "type" => "local-openai",
        "endpoint" => endpoint
      }

      record =
        if is_binary(api_key) and String.trim(api_key) != "" do
          Map.put(record, "apiKey", api_key)
        else
          record
        end

      {:ok, JSON.encode!(record)}
    end
  end

  @doc false
  def hollow_reason(bytes) when is_binary(bytes) do
    case decode_record(bytes, nil, nil) do
      {:ok, _record} -> nil
      {:error, reason} when is_binary(reason) -> reason
      {:error, _} -> "the local-openai provider record is not usable"
    end
  end

  defp decode_record(bytes, expected_name, path) do
    with {:ok, decoded} <- JSON.decode(bytes),
         {:ok, record} <- normalize_record(decoded, expected_name) do
      {:ok, record}
    else
      {:error, reason} ->
        label = if path, do: " at #{path}", else: ""
        {:error, "the local-openai provider record#{label} is invalid: #{reason}"}
    end
  end

  defp normalize_record(
         %{"name" => name, "type" => type, "endpoint" => endpoint} = raw,
         expected_name
       )
       when is_binary(name) and is_binary(type) and is_binary(endpoint) do
    with {:ok, name} <- validate_name(name),
         true <- expected_name == nil or name == expected_name,
         true <- type == "local-openai" do
      endpoint = String.trim(endpoint)

      cond do
        endpoint == "" ->
          {:error, "endpoint is empty"}

        not String.starts_with?(endpoint, "http://") and
            not String.starts_with?(endpoint, "https://") ->
          {:error, "endpoint must be an http(s) URL"}

        Map.has_key?(raw, "apiKey") and blank?(Map.get(raw, "apiKey")) ->
          {:error, "apiKey is present but empty"}

        true ->
          {:ok,
           %{
             name: name,
             type: type,
             endpoint: String.trim_trailing(endpoint, "/"),
             api_key: Map.get(raw, "apiKey")
           }}
      end
    else
      false -> {:error, "name mismatch or unsupported type"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_record(_other, _expected_name),
    do: {:error, "record shape is not name/type/endpoint"}

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true
end
