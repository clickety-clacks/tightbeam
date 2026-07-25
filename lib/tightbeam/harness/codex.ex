defmodule Tightbeam.Harness.Codex do
  @moduledoc false
  @behaviour Tightbeam.Harness

  alias Tightbeam.Harness.Support

  @adapter_version "1.1.4"
  @adapter_package "codex-acp"
  @adapter_bundle "index.js"
  @adapter_replacements [
    {
      "      modelProvider: this.getModelProvider(),\n      cwd: request.cwd\n",
      "      modelProvider: this.getModelProvider(),\n      cwd: request.cwd,\n      developerInstructions: request._meta?.developerInstructions\n"
    },
    {
      "      modelProvider: await this.getResumeModelProvider(),\n      threadId: request.sessionId\n",
      "      modelProvider: await this.getResumeModelProvider(),\n      threadId: request.sessionId,\n      developerInstructions: request._meta?.developerInstructions\n"
    },
    {
      "      case \"account/updated\":\n      case \"fs/changed\":",
      "      case \"account/updated\":\n        return this.createCodexSessionInfoUpdate({ accountUpdated: notification.params });\n      case \"fs/changed\":"
    },
    {
      "  activeSubAgentActivities = /* @__PURE__ */ new Set();\n",
      "  activeSubAgentActivities = /* @__PURE__ */ new Set();\n  subAgentActivityCallIds = /* @__PURE__ */ new Map();\n"
    },
    {
      "      case \"thread/status/changed\":\n        return this.createCodexSessionInfoUpdate({\n          threadStatus: notification.params.status\n        });",
      "      case \"thread/status/changed\": {\n        const childToolCallId = this.subAgentActivityCallIds.get(notification.params.threadId);\n        if (childToolCallId && [\"idle\", \"systemError\", \"notLoaded\"].includes(notification.params.status.type)) {\n          return {\n            sessionUpdate: \"tool_call_update\",\n            toolCallId: childToolCallId,\n            status: notification.params.status.type === \"idle\" ? \"completed\" : \"failed\",\n            _meta: { codex: { subagentTerminated: { agentThreadId: notification.params.threadId, threadStatus: notification.params.status } } }\n          };\n        }\n        return this.createCodexSessionInfoUpdate({\n          threadStatus: notification.params.status\n        });\n      }"
    },
    {
      "      case \"subAgentActivity\":\n        this.activeSubAgentActivities.add(event.item.id);\n        return createSubAgentActivityUpdate(event.item, \"in_progress\", \"tool_call\");",
      "      case \"subAgentActivity\":\n        this.activeSubAgentActivities.add(event.item.id);\n        this.subAgentActivityCallIds.set(event.item.agentThreadId, event.item.id);\n        return createSubAgentActivityUpdate(event.item, \"in_progress\", \"tool_call\");"
    }
  ]

  @impl true
  def id, do: :codex

  @impl true
  def wire_name, do: "codex"

  @impl true
  def credential_provider, do: :openai

  @impl true
  def install_package, do: "@agentclientprotocol/codex-acp"

  @impl true
  def wire_projection do
    JSON.encode!(%{
      "id" => "codex",
      "wire_name" => wire_name(),
      "install_package" => install_package(),
      "process_markers" => ["codex-acp"]
    })
  end

  @impl true
  def prepare_launch(target, home, opts) do
    binary = adapter_binary(target)
    rails? = Keyword.fetch!(opts, :rails) != nil

    probe =
      if rails? do
        probe_cwd = Path.join(target.host_config.base_dir, "work/gate-probe")

        if Support.local?(target) do
          File.rm_rf!(probe_cwd)
        else
          Support.run!(
            target,
            ["ssh" | Support.ssh_opts()] ++
              [target.host_config.ssh, "rm", "-rf", probe_cwd]
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

        [probe_cwd: probe_cwd, probe_model: "gpt-5.6-sol[medium]"]
      else
        []
      end

    launch =
      if Support.local?(target) do
        config =
          if rails?,
            do: [{"CODEX_CONFIG", ~s({"bypass_hook_trust":true})}],
            else: []

        [
          cmd: [binary],
          env: [{"CODEX_HOME", home} | Keyword.fetch!(opts, :common_env) ++ config]
        ]
      else
        config =
          if rails?,
            do: ["CODEX_CONFIG='#{~s({"bypass_hook_trust":true})}'"],
            else: []

        remote_env =
          ["CODEX_HOME=#{home}" | Keyword.fetch!(opts, :remote_env)] ++ config

        [
          cmd:
            ["ssh" | Support.ssh_opts()] ++
              [target.host_config.ssh, "exec", "env" | remote_env] ++ [binary],
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
      |> Map.put(:remote_patch, &patch_remote(target, &1, &2))

    Tightbeam.Spinup.ensure_adapter(target, __MODULE__, adapter_binary(target))
  end

  @impl true
  def session_config(session, guidance) do
    prefix =
      "Your Tight Beam archetype identity arrives as this Codex developer message. " <>
        "It is authoritative and outranks product AGENTS.md instructions on conflict."

    guidance =
      if Map.get(session, :identity) == true and not String.starts_with?(guidance, prefix),
        do: prefix <> "\n\n" <> guidance,
        else: guidance

    %{
      guidance: guidance,
      meta: %{developerInstructions: guidance},
      permission_mode: "agent-full-access",
      effort_config: "reasoning_effort"
    }
  end

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
          |> JSON.encode!()
      end

    Tightbeam.Homes.reconcile(target, home, %{desired | rails: rails},
      credential_names: ["auth.json"],
      rails_filename: "hooks.json"
    )
  end

  @impl true
  def materialize_skills(target, cwd, snapshot) do
    Tightbeam.Identity.materialize_for_harness!(
      target,
      snapshot,
      cwd,
      Path.join([".codex", "skills"])
    )
  end

  @impl true
  def credential_ready?(target, _home) do
    store =
      Tightbeam.Credentials.store_dir(
        target.host_config.base_dir,
        credential_provider()
      )

    Tightbeam.Homes.credential_ready?(target, store, ["auth.json"])
  end

  @impl true
  def harvest_credential(target, home) do
    Tightbeam.Homes.harvest_credential(target, home, "auth.json")
  end

  @impl true
  def probe_cli(target) do
    find = Map.get(target, :find_executable, &System.find_executable/1)
    shim = Path.join(Map.get(target, :cli_bin, ""), "codex")

    discovered =
      if File.exists?(shim) do
        nil
      else
        find.("codex")
      end

    if not File.exists?(shim) and is_binary(discovered) and
         Path.dirname(discovered) != Path.dirname(shim) do
      File.mkdir_p!(Path.dirname(shim))

      File.write!(
        shim,
        "#!/bin/sh\nexec \"#{discovered}\" --dangerously-bypass-hook-trust \"$@\"\n"
      )

      File.chmod!(shim, 0o755)
    end

    binary = if File.exists?(shim), do: shim, else: discovered
    Support.bounded_probe(binary, target)
  end

  @impl true
  def containment_additions, do: []

  @impl true
  def classify_auth_event(%{
        "_meta" => %{
          "codex" => %{"accountUpdated" => %{"authMode" => nil, "planType" => nil}}
        }
      }),
      do: :terminal

  def classify_auth_event(%{"authMode" => nil, "planType" => nil}), do: :terminal

  def classify_auth_event(%{
        "_meta" => %{"codex" => %{"accountUpdated" => %{"authMode" => mode}}}
      })
      when mode in ["apiKey", "chatgpt", "chatgptAuthTokens"],
      do: :transient

  def classify_auth_event(%{"authMode" => mode})
      when mode in ["apiKey", "chatgpt", "chatgptAuthTokens"],
      do: :transient

  def classify_auth_event(_event), do: :unknown

  @impl true
  def classify_subagent_event(%{
        "toolCallId" => source,
        "_meta" => %{"codex" => %{"subagentTerminated" => %{"agentThreadId" => subagent}}}
      }) do
    {:subagent_stop, %{source_event_ref: source, subagent_ref: subagent}}
  end

  def classify_subagent_event(%{
        "toolCallId" => source,
        "_meta" => %{
          "codex" => %{"subagent" => %{"threadId" => subagent, "activity" => "started"}}
        }
      }) do
    {:subagent_start, %{source_event_ref: source, subagent_ref: subagent}}
  end

  def classify_subagent_event(%{
        "toolCallId" => source,
        "_meta" => %{
          "codex" => %{"subagent" => %{"threadId" => subagent, "activity" => "interrupted"}}
        }
      }) do
    {:subagent_stop, %{source_event_ref: source, subagent_ref: subagent}}
  end

  def classify_subagent_event(_update), do: :skip

  @impl true
  def fetch_catalog(state) do
    home =
      Map.get(state.options, :codex_home) ||
        Tightbeam.Homes.home_path(
          state.base_dir,
          Tightbeam.Placement.local_host_name(),
          id()
        )

    read = Map.get(state.options, :codex_read, &File.read/1)

    with {:ok, body} <- read.(Path.join(home, "models_cache.json")),
         {:ok, models} <- decode_catalog(body),
         {:ok, entries} <- derive_catalog_entries(models),
         entries when entries != [] <- entries do
      {:ok, entries}
    else
      {:error, :enoent} -> {:error, :missing_cache}
      {:error, reason} -> {:error, reason}
      [] -> {:error, :empty_inventory}
      _ -> {:error, :malformed_catalog}
    end
  end

  defp decode_catalog(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{"models" => models}} when is_list(models) -> {:ok, models}
      {:ok, _} -> {:error, :malformed_catalog}
      {:error, _} -> {:error, :malformed_json}
    end
  end

  defp decode_catalog(_body), do: {:error, :malformed_catalog}

  defp derive_catalog_entries(models) do
    Enum.reduce_while(models, {:ok, []}, fn
      %{
        "slug" => slug,
        "display_name" => display_name,
        "supported_reasoning_levels" => levels
      } = model,
      {:ok, entries}
      when is_binary(slug) and is_binary(display_name) and is_list(levels) ->
        capabilities = model["capabilities"] || %{}
        max_input_tokens = model["max_input_tokens"] || model["context_window"]

        if is_map(capabilities) and
             (is_nil(max_input_tokens) or
                (is_integer(max_input_tokens) and max_input_tokens >= 0)) and
             Enum.all?(levels, &match?(%{"effort" => effort} when is_binary(effort), &1)) do
          efforts = Enum.map(levels, & &1["effort"])
          capabilities = Map.put(capabilities, "supported_reasoning_levels", levels)
          {:cont, {:ok, entries ++ entries_for(model, slug, efforts, capabilities)}}
        else
          {:halt, {:error, :malformed_catalog}}
        end

      _, _ ->
        {:halt, {:error, :malformed_catalog}}
    end)
  end

  defp entries_for(model, id, efforts, capabilities) do
    refs = if efforts == [], do: [id], else: Enum.map(efforts, &"#{id}[#{&1}]")
    display_name = model["display_name"] || id

    Enum.map(refs, fn ref ->
      %{
        ref: ref,
        display_name: display_name,
        name: display_name,
        efforts: efforts,
        max_input_tokens: model["max_input_tokens"] || model["context_window"],
        capabilities: capabilities,
        provider: :openai
      }
    end)
  end

  defp adapter_binary(target) do
    if Support.local?(target) do
      Path.expand("../tightbeam/node_modules/.bin/codex-acp", File.cwd!())
    else
      Path.join([
        target.host_config.base_dir,
        "adapters",
        "node_modules",
        ".bin",
        "codex-acp"
      ])
    end
  end

  defp patch_remote(target, path, detail) do
    script = "node -e #{Support.shell_quote(remote_patch_script(path))}"

    case target.sh.(
           ["ssh" | Support.ssh_opts()] ++
             [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]
         ) do
      {_output, 0} -> {:ok, detail <> "; codex adapter patched"}
      {output, _exit} -> {:error, %{code: "host_unready", message: String.trim(output)}}
    end
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
      wire_name()
    )
  end

  defp remote_patch_script(path) do
    Tightbeam.Harness.AdapterPatch.remote_script(
      path,
      @adapter_package,
      @adapter_bundle,
      @adapter_replacements,
      wire_name()
    )
  end
end
