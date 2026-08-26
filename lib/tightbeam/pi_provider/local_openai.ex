defmodule Tightbeam.PiProvider.LocalOpenAi do
  @moduledoc false

  alias Tightbeam.Harness.Support

  @default_max_output 32_768

  @doc false
  def fetch_catalog(state, %{name: name} = record) do
    case fetch_models_body(state, record) do
      {:ok, body} -> decode_catalog(body, name)
      {:error, {:executable_not_found, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:local_openai_catalog_failed, name, reason}}
    end
  end

  @doc false
  def fetch_models_body(state, record) do
    with {:ok, paths} <- catalog_executables(state, destination(state), record),
         {:ok, script, cleanup} <- catalog_script(state, record, paths) do
      try do
        case Support.catalog_probe(
               sh(state),
               Support.catalog_probe_argv(destination(state), script, paths)
             ) do
          {:ok, body, _trailer} -> {:ok, body}
          {:error, reason} -> {:error, reason}
        end
      after
        cleanup.()
      end
    else
      {:error, executable} when is_binary(executable) ->
        {:error, {:executable_not_found, executable}}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  def credential_live?(target, %{name: name} = record, opts) do
    with {:ok, paths} <- catalog_executables(target, destination(target), record),
         {:ok, script, cleanup} <- catalog_script(target, record, paths) do
      try do
        request = %{
          command: Support.catalog_probe_argv(nil, script, paths),
          response: :catalog
        }

        case Support.credential_live_result(target, request, opts) do
          :live -> :live
          other -> tag_liveness(name, other)
        end
      after
        cleanup.()
      end
    else
      {:error, executable} when is_binary(executable) ->
        {:unknown, {:executable_not_found, executable}}

      {:error, reason} ->
        {:unknown, reason}
    end
  end

  @doc false
  def models_url(endpoint) when is_binary(endpoint), do: endpoint <> "/models"

  @doc false
  def parse_model_ids(body) when is_binary(body) do
    with {:ok, decoded} <- JSON.decode(body),
         ids when is_list(ids) <- model_ids(decoded) do
      ids
    else
      _ -> []
    end
  end

  @doc false
  def pi_models_json_entry(record, models_body) do
    {:ok, decoded} = JSON.decode(models_body)

    models =
      decoded
      |> model_entries()
      |> Enum.map(&pi_model_entry(record.name, &1))

    base_url =
      if String.ends_with?(record.endpoint, "/v1") do
        record.endpoint
      else
        record.endpoint <> "/v1"
      end

    compat = %{
      "supportsDeveloperRole" => false,
      "supportsReasoningEffort" => false,
      "maxTokensField" => "max_tokens",
      "supportsStrictMode" => false
    }

    compat =
      if models != [] and Enum.all?(models, & &1["reasoning"]) do
        Map.put(compat, "thinkingFormat", "qwen-chat-template")
      else
        compat
      end

    provider = %{
      "baseUrl" => base_url,
      "api" => "openai-completions",
      "compat" => compat,
      "models" => models
    }

    provider =
      if is_binary(record.api_key) and record.api_key != "" do
        Map.put(provider, "apiKey", record.api_key)
      else
        # Pi requires an apiKey field before it will run a provider. "local" is
        # its conventional non-secret sentinel for a keyless local endpoint;
        # authHeader=false makes explicit that it is configuration, not a grant.
        provider
        |> Map.put("apiKey", "local")
        |> Map.put("authHeader", false)
      end

    {record.name, provider}
  end

  defp decode_catalog(body, name) when is_binary(body) do
    with {:ok, decoded} <- JSON.decode(body),
         entries when entries != [] <- catalog_entries(decoded, name) do
      {:ok, entries}
    else
      [] -> {:error, {:malformed_catalog, :no_usable_model_ids, name}}
      _ -> {:error, {:malformed_catalog, name}}
    end
  end

  defp catalog_entries(decoded, name) do
    decoded
    |> model_entries()
    |> Enum.map(&catalog_entry(name, &1))
  end

  defp model_entries(decoded) do
    decoded
    |> model_ids()
    |> Enum.map(fn id ->
      max_len = max_model_len(decoded, id)
      %{id: id, max_model_len: max_len}
    end)
  end

  defp model_ids(%{"data" => data}) when is_list(data) do
    data
    |> Enum.flat_map(fn
      %{"id" => id} when is_binary(id) ->
        trimmed = String.trim(id)
        if trimmed != "", do: [trimmed], else: []

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp model_ids(_), do: []

  defp max_model_len(%{"data" => data}, id) when is_list(data) do
    data
    |> Enum.find_value(fn
      %{"id" => ^id, "max_model_len" => len} when is_integer(len) and len > 0 -> len
      _ -> nil
    end)
  end

  defp max_model_len(_decoded, _id), do: nil

  defp catalog_entry(name, %{id: id, max_model_len: max_model_len}) do
    context_window = max_model_len || 131_072
    proven? = proven_spark_model?(name, id)

    %{
      family: "#{name}/#{id}",
      context: nil,
      display_name: id,
      name: id,
      efforts: [],
      max_input_tokens: context_window,
      capabilities: %{
        "input" => ["text"],
        "max_output_tokens" => @default_max_output,
        "tool_use" => proven?,
        "developer_role" => false,
        "reasoning_effort" => false,
        "supported_reasoning_levels" => []
      },
      provider: :local_openai,
      local_provider: name
    }
  end

  defp pi_model_entry(name, %{id: id, max_model_len: max_model_len}) do
    context_window = max_model_len || 131_072

    %{
      "id" => id,
      "name" => id,
      "reasoning" => proven_spark_model?(name, id),
      "input" => ["text"],
      "contextWindow" => context_window,
      "maxTokens" => @default_max_output,
      "cost" => %{"input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0}
    }
  end

  defp proven_spark_model?("spark", "qwen3.5-35b"), do: true
  defp proven_spark_model?(_provider, _model), do: false

  defp catalog_script(_state, %{api_key: key, endpoint: endpoint}, paths)
       when is_binary(key) and key != "" do
    path =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-pi-auth-#{System.unique_integer([:positive, :monotonic])}"
      )

    case File.write(path, "Authorization: Bearer #{key}\n", [:binary, :exclusive]) do
      :ok ->
        case File.chmod(path, 0o600) do
          :ok ->
            script =
              Support.catalog_curl(models_url(endpoint), ["@#{path}"], "", paths.curl)

            {:ok, script, fn -> File.rm(path) end}

          {:error, reason} ->
            File.rm(path)
            {:error, {:auth_file_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:auth_file_failed, reason}}
    end
  end

  defp catalog_script(_state, %{api_key_file: path, endpoint: endpoint}, paths)
       when is_binary(path) do
    header = path <> ".header-#{System.unique_integer([:positive, :monotonic])}"

    prepare =
      "umask 077; " <>
        "/usr/bin/plutil -extract apiKey raw -o - #{Support.shell_quote(path)} | " <>
        "/usr/bin/sed 's/^/Authorization: Bearer /' > #{Support.shell_quote(header)} && " <>
        "/bin/chmod 600 #{Support.shell_quote(header)} && "

    curl = Support.catalog_curl(models_url(endpoint), ["@#{header}"], "", paths.curl)

    script =
      prepare <> curl <> "; status=$?; /bin/rm -f #{Support.shell_quote(header)}; exit $status"

    {:ok, script, fn -> :ok end}
  end

  defp catalog_script(_state, %{endpoint: endpoint}, paths) do
    {:ok, Support.catalog_curl(models_url(endpoint), [], "", paths.curl), fn -> :ok end}
  end

  defp catalog_executables(state, nil, _record) do
    with {:ok, sh} <- absolute_executable(state, "sh"),
         {:ok, curl} <- absolute_executable(state, "curl") do
      {:ok, %{sh: sh, curl: curl}}
    end
  end

  defp catalog_executables(state, _destination, record) do
    required =
      ["/bin/sh", "/usr/bin/curl"] ++
        if(is_binary(Map.get(record, :api_key_file)),
          do: ["/usr/bin/plutil", "/usr/bin/sed", "/bin/chmod", "/bin/rm"],
          else: []
        )

    with {:ok, ssh} <- absolute_executable(state, "ssh"),
         :ok <- remote_executables(state, ssh, required) do
      {:ok, %{ssh: ssh, sh: "/bin/sh", curl: "/usr/bin/curl"}}
    end
  end

  defp remote_executables(state, ssh, paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      argv =
        [ssh | Support.ssh_opts()] ++
          [destination(state), "/bin/test", "-x", path]

      case Support.bounded_run(sh(state), argv, 5_000) do
        {:ok, {_output, 0}} -> {:cont, :ok}
        _ -> {:halt, {:error, path}}
      end
    end)
  end

  defp absolute_executable(container, name) do
    find =
      Map.get(container, :find_executable) ||
        get_in(container, [:options, :find_executable]) ||
        (&System.find_executable/1)

    case find.(name) do
      path when is_binary(path) ->
        if Path.type(path) == :absolute, do: {:ok, path}, else: {:error, name}

      _ ->
        {:error, name}
    end
  end

  defp destination(%{host_config: %{ssh: ssh}}), do: ssh
  defp destination(_), do: nil

  defp sh(%{options: %{sh: sh}}) when is_function(sh, 1), do: sh
  defp sh(%{sh: sh}) when is_function(sh, 1), do: sh
  defp sh(_), do: &Support.system_cmd_out/1

  defp tag_liveness(name, {:dead, reason}), do: {:dead, {:local_openai, name, reason}}
  defp tag_liveness(name, {:unknown, reason}), do: {:unknown, {:local_openai, name, reason}}
  defp tag_liveness(_name, other), do: other
end
