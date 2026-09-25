defmodule Tightbeam.LocalOpenAi.Providers do
  @moduledoc false

  alias Tightbeam.ErrorDiagnostic
  alias Tightbeam.Harness.Support

  @reserved_names ~w(opencode-go)
  @name_pattern ~r/^[a-z][a-z0-9-]*$/
  @remote_timeout_ms 30_000

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
  def read_all_target(%{host_config: %{ssh: nil}} = target) do
    read_all(Map.get(target.host_config, :base_dir) || Map.fetch!(target, :base_dir))
  end

  def read_all_target(%{host_config: %{ssh: destination}} = target)
      when is_binary(destination) do
    base_dir = Map.get(target.host_config, :base_dir) || Map.fetch!(target, :base_dir)

    with {:ok, ssh} <- absolute_executable(target, "ssh"),
         {:ok, files} <- remote_provider_files(target, ssh, providers_dir(base_dir)) do
      Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
        name = Path.rootname(file)
        path = Path.join(providers_dir(base_dir), file)

        case remote_read_redacted(target, ssh, name, path) do
          {:ok, record} -> {:cont, {:ok, [record | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.sort_by(records, & &1.name)}
        error -> error
      end
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
    with {:ok, decoded} <- decode_json(bytes),
         {:ok, record} <- normalize_record(decoded, expected_name) do
      {:ok, record}
    else
      {:error, reason} ->
        label = if path, do: " at #{path}", else: ""
        {:error, "the local-openai provider record#{label} is invalid: #{reason}"}
    end
  end

  # JSON.decode reasons are tuples, which cannot be interpolated. Keep the
  # parser's offset but not the offending bytes: the record carries an apiKey.
  defp decode_json(bytes) do
    case JSON.decode(bytes) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, "not valid JSON: #{json_error_text(reason)}"}
    end
  end

  defp json_error_text({:invalid_byte, offset, _byte}), do: "invalid byte at offset #{offset}"
  defp json_error_text({:unexpected_end, offset}), do: "unexpected end at offset #{offset}"

  defp json_error_text({:unexpected_sequence, offset, _bytes}),
    do: "unexpected sequence at offset #{offset}"

  defp remote_provider_files(target, ssh, dir) do
    script =
      "if /bin/test -d #{Support.shell_quote(dir)}; then " <>
        "/bin/ls -1 #{Support.shell_quote(dir)}; fi"

    case remote_run(target, ssh, script) do
      {:ok, output} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.filter(fn file -> match?({:ok, _}, validate_name(Path.rootname(file))) end)
          |> Enum.sort()

        {:ok, files}

      {:error, reason} ->
        {:error, {:remote_provider_list_failed, reason}}
    end
  end

  defp remote_read_redacted(target, ssh, name, path) do
    with {:ok, node} <- remote_node(target, ssh),
         script = remote_redactor_script(node, path),
         {:ok, output} <- remote_run(target, ssh, script),
         {:ok, bytes, key_present?} <- split_remote_record(output),
         {:ok, record} <- decode_record(bytes, name, path) do
      {:ok,
       record
       |> Map.put(:api_key, nil)
       |> Map.put(:api_key_file, if(key_present?, do: path, else: nil))}
    else
      {:error, reason} ->
        {:error, {:remote_provider_read_failed, name, redaction_failure(reason)}}
    end
  end

  # The remote command must never put a descriptor in the error tuple. A failed
  # parser can leave stdout populated in a test double or in a shell diagnostic,
  # and that output may contain the provider's apiKey.
  #
  # Every other reason is Tightbeam's own text (a decode or shape refusal of the
  # already-redacted record, a timeout) or a transport failure term. Neither is
  # remote stdout, so it is kept, redacted, instead of erased.
  defp redaction_failure({:exit, status, _output}), do: {:exit, status}
  defp redaction_failure({:error, reason}) when is_atom(reason), do: reason
  defp redaction_failure(reason) when is_atom(reason), do: reason
  # remote_run already reduced its transport reason.
  defp redaction_failure({:transport, _reduced} = reason), do: reason
  defp redaction_failure({:timeout, ms} = reason) when is_integer(ms), do: reason
  defp redaction_failure(reason) when is_binary(reason), do: ErrorDiagnostic.redact_text(reason)

  defp redaction_failure({:transport_exception, message}) when is_binary(message),
    do: {:transport_exception, ErrorDiagnostic.redact_text(message)}

  defp redaction_failure(reason), do: ErrorDiagnostic.encode_term(reason)

  defp remote_node(target, ssh) do
    configured =
      target.host_config
      |> Map.get(:toolchain_dirs, [])
      |> Enum.map(&Path.join(&1, "node"))

    candidates =
      (configured ++ ["/usr/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node"])
      |> Enum.filter(&(Path.type(&1) == :absolute))
      |> Enum.uniq()

    Enum.find_value(candidates, fn node ->
      case remote_run(target, ssh, "/bin/test -x #{Support.shell_quote(node)}") do
        {:ok, _output} -> {:ok, node}
        {:error, _reason} -> nil
      end
    end) || {:error, :remote_node_unavailable}
  end

  defp remote_redactor_script(node, path) do
    javascript = """
    const fs = require("fs");
    try {
      const source = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (!source || typeof source !== "object" || Array.isArray(source)) process.exit(65);
      for (const key of ["name", "type", "endpoint"]) {
        if (typeof source[key] !== "string" || source[key].trim() === "") process.exit(65);
      }
      const hasKey = Object.prototype.hasOwnProperty.call(source, "apiKey");
      if (hasKey && (typeof source.apiKey !== "string" || source.apiKey.trim() === "")) process.exit(65);
      const record = {name: source.name, type: source.type, endpoint: source.endpoint};
      process.stdout.write(JSON.stringify(record) + "\\n" +
        (hasKey ? "__TIGHTBEAM_API_KEY_PRESENT__" : "__TIGHTBEAM_API_KEY_ABSENT__") + "\\n");
    } catch (_) {
      process.exit(65);
    }
    """

    "#{Support.shell_quote(node)} -e #{Support.shell_quote(javascript)} #{Support.shell_quote(path)}"
  end

  defp split_remote_record(output) do
    cond do
      String.ends_with?(output, "\n__TIGHTBEAM_API_KEY_PRESENT__\n") ->
        {:ok, String.replace_suffix(output, "\n__TIGHTBEAM_API_KEY_PRESENT__\n", ""), true}

      String.ends_with?(output, "\n__TIGHTBEAM_API_KEY_ABSENT__\n") ->
        {:ok, String.replace_suffix(output, "\n__TIGHTBEAM_API_KEY_ABSENT__\n", ""), false}

      true ->
        {:error, :missing_key_presence_marker}
    end
  end

  defp remote_run(target, ssh, script) do
    argv =
      [ssh | Support.ssh_opts()] ++
        [target.host_config.ssh, "/bin/sh", "-c", Support.shell_quote(script)]

    case Support.bounded_run(sh(target), argv, @remote_timeout_ms) do
      {:ok, {output, 0}} when is_binary(output) ->
        {:ok, output}

      {:ok, {output, exit}} when is_integer(exit) and is_binary(output) ->
        {:error, {:exit, exit, String.trim(output)}}

      {:ok, {:error, reason}} ->
        {:error, {:transport, redaction_failure(reason)}}

      {:ok, _other} ->
        {:error, :remote_command_failed}

      {:error, reason} ->
        {:error, reason}
    end
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

  defp sh(%{options: %{sh: sh}}) when is_function(sh, 1), do: sh
  defp sh(%{sh: sh}) when is_function(sh, 1), do: sh
  defp sh(_target), do: &Support.system_cmd_out/1

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
