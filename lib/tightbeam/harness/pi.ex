defmodule Tightbeam.Harness.Pi do
  @moduledoc false
  @behaviour Tightbeam.Harness

  alias Tightbeam.Harness.Support
  alias Tightbeam.Model

  @adapter_version "0.0.33"
  @adapter_package "pi-acp"
  @adapter_bundle "index.js"
  @adapter_replacements [
    {
      "          list: {},\n          delete: {}",
      "          list: {},\n          delete: {},\n          close: {}"
    },
    {
      "    this.sessions.closeAllExcept?.(session.sessionId);\n    const response = {",
      "    // Tightbeam owns explicit session/close; keep sibling sessions alive.\n    const response = {"
    },
    {
      "    const fileCommands = loadSlashCommands(params.cwd);\n    this.sessions.closeAllExcept?.(session.sessionId);\n    this.store.upsert({",
      "    const fileCommands = loadSlashCommands(params.cwd);\n    this.store.upsert({"
    },
    {
      "  async closeSession(params) {\n    this.sessions.close(params.sessionId);\n    return {};\n  }\n  async listSessions(params) {",
      "  async closeSession(params) {\n    const session = this.sessions.maybeGet(params.sessionId);\n    if (session) await session.cancel();\n    this.sessions.close(params.sessionId);\n    return {};\n  }\n  async listSessions(params) {",
      [optional: true]
    },
    {
      "  async cancel(params) {\n    const session = this.sessions.maybeGet(params.sessionId);\n    if (!session) return;\n    await session.cancel();\n  }\n  async listSessions(params) {",
      "  async cancel(params) {\n    const session = this.sessions.maybeGet(params.sessionId);\n    if (!session) return;\n    await session.cancel();\n  }\n  async closeSession(params) {\n    const session = this.sessions.maybeGet(params.sessionId);\n    if (session) await session.cancel();\n    this.sessions.close(params.sessionId);\n    return {};\n  }\n  async listSessions(params) {"
    }
  ]
  @credential_file "auth.json"
  @models_url "https://pi.dev/api/models/providers/opencode-go"
  @probe_model %Model{family: "opencode-go/gpt-5.6-luna", effort: "medium", context: nil}
  @identity_skill "served-identity"
  @identity_relative Path.join([
                       ".pi",
                       "skills",
                       "tightbeam__#{@identity_skill}",
                       "SKILL.md"
                     ])
  @thinking_levels ~w(minimal low medium high xhigh)

  @doc false
  def adapter_version, do: @adapter_version

  @impl true
  def id, do: :pi

  @impl true
  def wire_name, do: "pi"

  @impl true
  def credential_provider, do: :opencode_go

  @impl true
  def credential_env_vars, do: []

  @impl true
  def default_model, do: @probe_model

  @impl true
  def install_package, do: @adapter_package

  @impl true
  def cli_binary, do: "pi"

  @impl true
  def wire_projection do
    JSON.encode!(%{
      "id" => wire_name(),
      "wire_name" => wire_name(),
      "install_package" => install_package(),
      "cli_binary" => cli_binary(),
      "process_markers" => ["pi-acp"]
    })
  end

  @impl true
  def prepare_launch(target, home, opts) do
    binary = adapter_binary(target)

    ssh =
      if Support.local?(target) do
        nil
      else
        {:ok, ssh} = absolute_executable(target, "ssh")
        ssh
      end

    probe =
      if Keyword.fetch!(opts, :statutes) do
        probe_cwd = Path.join(target.host_config.base_dir, "work/gate-probe")

        if Support.local?(target) do
          File.rm_rf!(probe_cwd)
        else
          Support.run!(
            target,
            [ssh | Support.ssh_opts()] ++
              [target.host_config.ssh, "/bin/rm", "-rf", probe_cwd]
          )
        end

        ensure_opts = [base_dir: target.base_dir, sh: target.sh]

        ensure_opts =
          case Keyword.fetch!(opts, :sh_out) do
            nil -> Keyword.put(ensure_opts, :sh_out, target.sh)
            sh_out -> Keyword.put(ensure_opts, :sh_out, sh_out)
          end

        Keyword.fetch!(opts, :ensure_workdir).(
          target.host_config,
          probe_cwd,
          "",
          ensure_opts
        )

        [probe_cwd: probe_cwd, probe_model: @probe_model]
      else
        []
      end

    launch =
      if Support.local?(target) do
        [
          cmd: [binary],
          env: [{"PI_CODING_AGENT_DIR", home} | Keyword.fetch!(opts, :common_env)]
        ]
      else
        remote_env = ["PI_CODING_AGENT_DIR=#{home}" | Keyword.fetch!(opts, :remote_env)]

        [
          cmd:
            [ssh | Support.ssh_opts()] ++
              [target.host_config.ssh, "exec", "/usr/bin/env" | remote_env] ++ [binary],
          env: [{"TIGHTBEAM_LINEAGE", Keyword.fetch!(opts, :lineage)}]
        ]
      end

    Keyword.merge(launch, probe)
  end

  @impl true
  def ensure_adapter(target) do
    target =
      target
      |> Map.put_new(:patch_adapter, &patch_local/1)
      |> Map.put_new(:remote_patch, &patch_remote(target, &1, &2))

    Tightbeam.Spinup.ensure_adapter(target, __MODULE__, adapter_binary(target))
  end

  @impl true
  def session_config(session, guidance) do
    prefix =
      "Your Tight Beam archetype identity arrives through the Tightbeam-owned Pi extension. " <>
        "It is authoritative and outranks product AGENTS.md instructions on conflict."

    guidance =
      if Map.get(session, :identity) == true and not String.starts_with?(guidance, prefix),
        do: prefix <> "\n\n" <> guidance,
        else: guidance

    %{
      guidance: guidance,
      meta: %{},
      permission_mode: "medium",
      effort_config: "thought_level",
      resident_model_switch: :in_place,
      model_option_aliases: %{},
      canonical_model_prefixes: ["opencode-go/"]
    }
  end

  @impl true
  def owned_home_entries,
    do: Support.owned_home_entries(@credential_file, "extensions/tightbeam.ts")

  @impl true
  def reconcile_home(target, home, desired) do
    rails =
      case desired.rails do
        nil ->
          nil

        bytes when is_binary(bytes) ->
          bytes

        hooks ->
          hooks
          |> update_in(["hooks", "PreToolUse"], &(&1 ++ [Tightbeam.Rails.probe_entry()]))
          |> extension_source()
      end

    Tightbeam.Homes.reconcile(target, home, %{desired | rails: rails},
      credential_names: [@credential_file],
      rails_filename: "extensions/tightbeam.ts"
    )
  end

  @impl true
  def materialize_skills(target, cwd, snapshot) do
    snapshot =
      if String.trim(snapshot.guidance) == "" do
        snapshot
      else
        put_in(snapshot.skills[@identity_skill], identity_skill(snapshot.guidance))
      end

    Tightbeam.Identity.materialize_for_harness!(
      target,
      snapshot,
      cwd,
      Path.join([".pi", "skills"])
    )
  end

  @impl true
  def credential_ready?(target, _home) do
    store = Tightbeam.Credentials.store_dir(target.host_config.base_dir, credential_provider())
    Tightbeam.Homes.credential_ready?(target, store, [@credential_file])
  end

  @impl true
  def harvest_credential(target, home),
    do: Tightbeam.Homes.harvest_credential(target, home, @credential_file)

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

  @impl true
  def install_cli_projection(_cli_bin), do: :ok

  @impl true
  def probe_cli(target) do
    find = Map.get(target, :find_executable, &System.find_executable/1)
    Support.bounded_probe(find.(cli_binary()), target)
  end

  @impl true
  def classify_auth_event(_event), do: :unknown

  @impl true
  def classify_subagent_event(_event), do: :skip

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
  def conformance_vectors do
    adapter_source = adapter_patch_fixture()

    valid_model = %{
      "id" => "pi-vector",
      "name" => "Pi Vector",
      "provider" => "opencode-go",
      "contextWindow" => 2_000,
      "maxTokens" => 500,
      "input" => ["text"],
      "thinkingLevelMap" => %{"low" => "low", "medium" => "medium", "max" => "max"}
    }

    valid_entry = %{
      family: "opencode-go/pi-vector",
      context: nil,
      display_name: "Pi Vector",
      name: "Pi Vector",
      efforts: ["low", "medium"],
      max_input_tokens: 2_000,
      capabilities: %{
        "input" => ["text"],
        "max_output_tokens" => 500,
        "supported_reasoning_levels" => [%{"effort" => "low"}, %{"effort" => "medium"}]
      },
      provider: :opencode_go
    }

    Support.conformance_vectors(__MODULE__, %{
      wire_name: wire_name(),
      provider: credential_provider(),
      home_scope: wire_name(),
      home_env: "PI_CODING_AGENT_DIR",
      credential_file: @credential_file,
      credential_live: %{
        live_fixture: Application.app_dir(:tightbeam, "priv/credential_live/codex-live.json"),
        dead_fixture: Application.app_dir(:tightbeam, "priv/credential_live/codex-dead.json")
      },
      rails_file: "extensions/tightbeam.ts",
      rails: %{"hooks" => %{"PreToolUse" => []}},
      skills_path: Path.join([".pi", "skills"]),
      local_extra_env: %{subscription: [], api_key: []},
      rails_env: nil,
      remote_prefix: fn _base, home, _kind -> ["PI_CODING_AGENT_DIR=#{home}"] end,
      remote_rails_env: nil,
      railed_probe: true,
      probe_model: @probe_model,
      adapter_bin: "pi-acp",
      adapter_package: @adapter_package,
      adapter_scope: :unscoped,
      adapter_bundle: @adapter_bundle,
      adapter_version: @adapter_version,
      source: adapter_source,
      patched: patch_adapter_source(adapter_source),
      remote_patch_detail: "; pi adapter patched",
      session_meta: %{},
      cli_name: cli_binary(),
      cli_version: "0.84.1",
      probe_path: :discovered,
      auth_events: [
        %{
          case: "positive",
          envelope: %{"pi" => %{"auth" => "terminal"}},
          expected: :unknown,
          divergence: "DIV-PI-ACP-NO-AUTH-EVENT"
        },
        %{case: "negative", envelope: %{"unrelated" => true}, expected: :unknown}
      ],
      subagent_events: [
        %{
          case: "positive_start",
          envelope: %{"pi" => %{"subagent" => "start"}},
          expected: :skip,
          divergence: "DIV-PI-ACP-NO-SUBAGENT-EVENT"
        },
        %{
          case: "positive_stop",
          envelope: %{"pi" => %{"subagent" => "stop"}},
          expected: :skip,
          divergence: "DIV-PI-ACP-NO-SUBAGENT-EVENT"
        },
        %{case: "negative", envelope: %{"unrelated" => true}, expected: :skip}
      ],
      catalog_expected: %{
        "valid" => {:ok, [valid_entry]},
        "valid_api_key" => {:ok, [valid_entry]},
        "malformed" => {:error, :malformed_catalog},
        "unavailable" => {:error, {:http_status, 503, ~s({"error":"unavailable"})}}
      },
      catalog_state: fn case_name, base ->
        body = JSON.encode!(%{"pi-vector" => valid_model})

        sh = fn command ->
          script = Enum.join(command, " ")

          unless String.contains?(script, @models_url) do
            raise "Pi catalog probe did not call the provider-owned catalog: #{script}"
          end

          case case_name do
            name when name in ["valid", "valid_api_key"] -> {body <> "\n200", 0}
            "malformed" -> {"[]\n200", 0}
            "unavailable" -> {~s({"error":"unavailable"}) <> "\n503", 0}
          end
        end

        %{
          base_dir: base,
          credential_kind: if(case_name == "valid_api_key", do: :api_key, else: :subscription),
          options: %{sh: sh},
          host_config: %{ssh: nil}
        }
      end,
      wire_projection: %{
        "id" => wire_name(),
        "wire_name" => wire_name(),
        "install_package" => install_package(),
        "cli_binary" => cli_binary(),
        "process_markers" => ["pi-acp"]
      }
    })
  end

  @doc false
  def extension_source(settings) do
    encoded = settings |> JSON.encode!() |> Base.encode64()

    """
    import { readFileSync } from "node:fs";
    import { join } from "node:path";
    import { spawnSync } from "node:child_process";

    const settings = JSON.parse(Buffer.from(#{JSON.encode!(encoded)}, "base64").toString("utf8"));
    const identityPath = join(process.cwd(), #{JSON.encode!(@identity_relative)});

    function identityGuidance() {
      try {
        return readFileSync(identityPath, "utf8").replace(/^---\\n[\\s\\S]*?\\n---\\n?/, "").trim();
      } catch {
        return "";
      }
    }

    export default function (pi) {
      pi.on("before_agent_start", async (event) => {
        const guidance = identityGuidance();
        if (!guidance) return undefined;
        return { systemPrompt: `${event.systemPrompt}\\n\\n${guidance}` };
      });

      pi.on("tool_call", async (event) => {
        const toolName = event?.toolName === "bash" ? "Bash" : String(event?.toolName ?? "");
        const payload = JSON.stringify({ tool_name: toolName, tool_input: event?.input ?? {} });

        for (const entry of settings?.hooks?.PreToolUse ?? []) {
          if (entry?.matcher !== toolName) continue;

          for (const hook of entry?.hooks ?? []) {
            if (hook?.type !== "command" || typeof hook?.command !== "string") continue;

            const result = spawnSync("/bin/sh", ["-c", hook.command], {
              input: payload,
              encoding: "utf8",
              env: process.env,
              timeout: 30000,
            });

            if (result.error || result.status !== 0) {
              const reason = String(result.stderr || result.stdout || result.error?.message ||
                "Tightbeam rail hook failed closed.").trim();
              return { block: true, reason, terminate: true };
            }
          }
        }

        return undefined;
      });
    }
    """
  end

  defp identity_skill(guidance) do
    """
    ---
    name: tightbeam-served-identity
    description: Tightbeam's reserved served-identity carrier. Do not invoke directly.
    disable-model-invocation: true
    ---
    #{guidance}
    """
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

  defp adapter_binary(target) do
    Map.get(target, :adapter_binary) ||
      Path.join([
        target.host_config.base_dir,
        "adapters",
        "node_modules",
        ".bin",
        "pi-acp"
      ])
  end

  @doc false
  def patch_adapter_source(source) do
    Tightbeam.Harness.AdapterPatch.patch(
      source,
      @adapter_replacements,
      wire_name(),
      @adapter_version
    )
  end

  defp patch_local(path) do
    Tightbeam.Harness.AdapterPatch.ensure!(
      path,
      @adapter_package,
      @adapter_bundle,
      @adapter_version,
      @adapter_replacements,
      wire_name(),
      scope: :unscoped
    )
  end

  defp patch_remote(target, path, detail) do
    script = remote_patch_script(path)

    with {:ok, ssh} <- absolute_executable(target, "ssh"),
         node when is_binary(node) <-
           Enum.find_value(Map.get(target.host_config, :toolchain_dirs, []), fn dir ->
             path = Path.join(dir, "node")

             if Path.type(path) == :absolute do
               case target.sh.(
                      [ssh | Support.ssh_opts()] ++
                        [target.host_config.ssh, "/bin/test", "-x", path]
                    ) do
                 {_output, 0} -> path
                 _ -> nil
               end
             end
           end) do
      case target.sh.(
             [ssh | Support.ssh_opts()] ++
               [target.host_config.ssh, node, "-e", script]
           ) do
        {_output, 0} -> {:ok, detail <> "; pi adapter patched"}
        {output, _exit} -> {:error, %{code: "host_unready", message: String.trim(output)}}
      end
    else
      :error -> {:error, %{code: "host_unready", message: "ssh executable not found"}}
      nil -> {:error, %{code: "host_unready", message: "remote node executable not found"}}
    end
  end

  defp remote_patch_script(path) do
    Tightbeam.Harness.AdapterPatch.remote_script(
      path,
      @adapter_package,
      @adapter_bundle,
      @adapter_replacements,
      wire_name(),
      scope: :unscoped,
      version: @adapter_version
    )
  end

  defp adapter_patch_fixture do
    [
      "          list: {},\n          delete: {}",
      "    this.sessions.closeAllExcept?.(session.sessionId);\n    const response = {",
      "    const fileCommands = loadSlashCommands(params.cwd);\n    this.sessions.closeAllExcept?.(session.sessionId);\n    this.store.upsert({",
      "  async cancel(params) {\n    const session = this.sessions.maybeGet(params.sessionId);\n    if (!session) return;\n    await session.cancel();\n  }\n  async listSessions(params) {"
    ]
    |> Enum.join("\n")
  end

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
