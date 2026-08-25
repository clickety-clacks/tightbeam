defmodule Tightbeam.PiProvider.OpenCodeGo do
  @moduledoc false
  @behaviour Tightbeam.PiProvider

  alias Tightbeam.Harness.Support

  @models_url "https://pi.dev/api/models/providers/opencode-go"
  @credential_file "auth.json"
  @thinking_levels ~w(minimal low medium high xhigh)

  @impl true
  def id, do: :opencode_go

  @impl true
  def wire_name, do: "opencode-go"

  @impl true
  def model_prefix, do: "opencode-go/"

  @doc false
  def models_url, do: @models_url

  @impl true
  def fetch_catalog(state) do
    sh = Map.get(state.options, :sh, &Support.system_cmd_out/1)
    destination = Map.get(state, :host_config, %{ssh: nil}).ssh

    with {:ok, paths} <- catalog_executables(state, destination) do
      script = Support.catalog_curl(@models_url, [], "", paths.curl)

      case Support.catalog_probe(
             sh,
             Support.catalog_probe_argv(destination, script, paths)
           ) do
        {:ok, body, _trailer} -> decode_catalog(body)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, executable} -> {:error, {:executable_not_found, executable}}
    end
  end

  @impl true
  def credential_live?(target, home, opts) do
    with {:ok, node} <- absolute_executable(target, "node") do
      request = %{
        command: [
          node,
          "--no-warnings",
          "-e",
          liveness_script(),
          Path.join(home, @credential_file)
        ]
      }

      Support.credential_live_result(target, request, opts)
    else
      :error -> {:unknown, {:executable_not_found, "node"}}
    end
  end

  defp liveness_script do
    """
    const fs = require("node:fs");
    const auth = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const key = auth["opencode-go"]?.key;
    if (!key) { process.stderr.write("missing opencode-go api key"); process.exit(66); }
    const requestId = `tightbeam-liveness-${process.pid}-${Date.now()}`;
    fetch("https://opencode.ai/zen/go/v1/responses", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${key}`,
        "Content-Type": "application/json",
        "x-opencode-client": "pi",
        "x-opencode-session": requestId,
        "x-client-request-id": requestId
      },
      body: JSON.stringify({
        model: "gpt-5.6-luna",
        input: [{
          role: "user",
          content: [{type: "input_text", text: "Reply with OK."}]
        }],
        max_output_tokens: 16,
        stream: false,
        store: false
      })
    }).then(async response => {
      process.stdout.write(JSON.stringify({
        status: response.status,
        headers: {"content-type": response.headers.get("content-type")},
        body: await response.text()
      }));
    }).catch(error => {
      const cause = error.cause;
      process.stderr.write(
        [cause && cause.code, cause && cause.message, error.code, error.message]
          .filter(Boolean).join(": ") || "unknown transport failure"
      );
      process.exitCode = 70;
    });
    """
  end

  defp decode_catalog(body) when is_binary(body) do
    with {:ok, models} when is_map(models) <- JSON.decode(body),
         {:ok, entries} <- derive_entries(models),
         true <- entries != [] do
      {:ok, entries}
    else
      _ -> {:error, :malformed_catalog}
    end
  end

  defp decode_catalog(_body), do: {:error, :malformed_catalog}

  defp derive_entries(models) do
    models
    |> Enum.reduce_while({:ok, []}, fn {_key, model}, {:ok, entries} ->
      case catalog_entry(model) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        :error -> {:halt, {:error, :malformed_catalog}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, & &1.family)}
      error -> error
    end
  end

  defp catalog_entry(
         %{
           "id" => id,
           "name" => name,
           "provider" => "opencode-go",
           "contextWindow" => context_window,
           "maxTokens" => max_tokens
         } = model
       )
       when is_binary(id) and id != "" and is_binary(name) and name != "" and
              is_integer(context_window) and context_window > 0 and is_integer(max_tokens) and
              max_tokens > 0 do
    efforts = supported_efforts(model["thinkingLevelMap"])

    {:ok,
     %{
       family: "opencode-go/#{id}",
       context: nil,
       display_name: name,
       name: name,
       efforts: efforts,
       max_input_tokens: context_window,
       capabilities: %{
         "input" => Map.get(model, "input", []),
         "max_output_tokens" => max_tokens,
         "supported_reasoning_levels" => Enum.map(efforts, &%{"effort" => &1})
       },
       provider: :opencode_go
     }}
  end

  defp catalog_entry(_model), do: :error

  defp supported_efforts(levels) when is_map(levels) do
    Enum.filter(@thinking_levels, &is_binary(Map.get(levels, &1)))
  end

  defp supported_efforts(_levels), do: []

  defp catalog_executables(state, nil) do
    with {:ok, sh} <- absolute_executable(state, "sh"),
         {:ok, curl} <- absolute_executable(state, "curl") do
      {:ok, %{sh: sh, curl: curl}}
    else
      :error -> {:error, "sh or curl"}
    end
  end

  defp catalog_executables(state, _destination) do
    with {:ok, ssh} <- absolute_executable(state, "ssh") do
      {:ok, %{ssh: ssh, sh: "/bin/sh", curl: "/usr/bin/curl"}}
    else
      :error -> {:error, "ssh"}
    end
  end

  defp absolute_executable(container, name) do
    find =
      Map.get(container, :find_executable) ||
        get_in(container, [:options, :find_executable]) ||
        (&System.find_executable/1)

    case find.(name) do
      path when is_binary(path) ->
        if Path.type(path) == :absolute, do: {:ok, path}, else: :error

      _ ->
        :error
    end
  end
end
