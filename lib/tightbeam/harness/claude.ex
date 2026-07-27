defmodule Tightbeam.Harness.Claude do
  @moduledoc false
  @behaviour Tightbeam.Harness

  alias Tightbeam.Harness.Support

  @adapter_version "0.59.0"
  @adapter_package "claude-agent-acp"
  @adapter_bundle "acp-agent.js"

  # NOTE FOR FUTURE AGENTS — the claude model vocabulary is NARROWER than the catalog.
  #
  # The derived catalog for claude comes from the Anthropic API (`fetch_catalog/1` hits
  # `/v1/models`), which currently lists 11 models. The claude ACP adapter's
  # `session/set_config_option {configId: "model"}` accepts only SEVEN values, and
  # `Acp.Adapter.parse_model_ref/1` strips nothing but an `[effort]` suffix — the base
  # string goes to the adapter verbatim, so there is NO translation layer to fix. A model
  # the adapter refuses fails the apply, which runs after EVERY `session/new` and every
  # `session/load` (never-trust-the-advertised-model), so it recurs on resume, not just
  # spawn.
  #
  # RECORDED LIVE 2026-07-26 against: claude CLI 2.1.220, claude-agent-acp 0.59.0,
  # @anthropic-ai/claude-agent-sdk 0.3.207. Probe each value with
  # `session/set_config_option` before trusting this table — it WILL rot, because the
  # accepted set is whatever the installed CLI currently offers.
  #
  #   ACCEPTED  alias `default`  -> Sonnet 5      (same as `sonnet`)
  #   ACCEPTED  alias `sonnet`   -> Sonnet 5
  #   ACCEPTED  alias `opus`     -> Opus 4.8      (NOT Opus 5 — see below)
  #   ACCEPTED  alias `haiku`    -> Haiku 4.5
  #   ACCEPTED  id `claude-sonnet-5`
  #   ACCEPTED  id `claude-opus-4-8`
  #   ACCEPTED  id `claude-haiku-4-5-20251001`
  #   REJECTED  claude-opus-5, claude-fable-5, claude-opus-4-7, claude-sonnet-4-6,
  #             claude-opus-4-6, claude-opus-4-5-20251101, claude-sonnet-4-5-20250929,
  #             claude-opus-4-1-20250805, and the bare alias `fable`
  #
  # The accepted ids are EXACTLY the three models the aliases currently resolve to. So
  # this is not an API-vs-CLI version lag that a mapping table can paper over: the
  # adapter only accepts the models it is presently offering, by either name.
  #
  # WHY THERE IS NO SUBSTITUTION MAP HERE, deliberately: every candidate substitution is
  # a silent downgrade. `claude-opus-5` -> `opus` delivers Opus 4.8, a different and
  # older model. `claude-fable-5` has NO equivalent on this adapter version at all.
  # Mapping either would make a request appear to succeed while delivering something
  # else, which is the one outcome worse than failing. If a requested claude model is not
  # in the ACCEPTED list above, it must fail and say so — do not quietly rewrite it.
  #
  # WHEN THIS ROTS (a new alias appears, or an accepted value stops being accepted):
  # re-probe the adapter rather than editing from a changelog. Boot
  # `node <adapters>/claude-agent-acp`, `initialize`, `session/new`, then read the
  # `model` entry of the returned `configOptions` for the offered set, and confirm each
  # candidate with `session/set_config_option`. Update this table and the version stamp
  # together. Codex does NOT have this problem and needs no equivalent table: its
  # catalog is read from the CLI's own `models_cache.json`, so catalog and accepted set
  # come from one artifact and cannot diverge. This asymmetry is the actual finding.
  @adapter_selectable_models ~w(default sonnet opus haiku claude-sonnet-5 claude-opus-4-8
                                claude-haiku-4-5-20251001)

  @doc """
  Model values this adapter version accepts at `session/set_config_option`.

  Narrower than the derived catalog — see the note above the attribute. Anything outside
  this list is refused by the adapter; it is never silently substituted.
  """
  def adapter_selectable_models, do: @adapter_selectable_models

  @adapter_replacements [
    {
      "                            case \"task_notification\":\n                                // The task settled — no further tool calls can originate\n                                // from it, so its registry entry can be dropped.\n                                session.liveBackgroundTasks.delete(message.task_id);\n                                break;",
      "                            case \"task_notification\": {\n                                // The task settled — emit the correlated child-termination\n                                // carrier before dropping its parent tool-use bookkeeping.\n                                const record = session.liveBackgroundTasks.get(message.task_id);\n                                if (record?.isSubagent) {\n                                    await sendUpdate({\n                                        sessionId: message.session_id,\n                                        update: {\n                                            sessionUpdate: \"tool_call_update\",\n                                            toolCallId: record.parentToolUseId,\n                                            status: \"completed\",\n                                            _meta: { claudeCode: { subagentTerminated: { taskId: message.task_id, status: \"completed\" } } },\n                                        },\n                                    });\n                                }\n                                session.liveBackgroundTasks.delete(message.task_id);\n                                break;\n                            }"
    },
    {
      "                                if (message.patch.status === \"completed\" ||\n                                    message.patch.status === \"failed\" ||\n                                    message.patch.status === \"killed\") {\n                                    session.liveBackgroundTasks.delete(message.task_id);\n                                }",
      "                                if (message.patch.status === \"completed\" ||\n                                    message.patch.status === \"failed\" ||\n                                    message.patch.status === \"killed\") {\n                                    const record = session.liveBackgroundTasks.get(message.task_id);\n                                    if (record?.isSubagent) {\n                                        await sendUpdate({\n                                            sessionId: message.session_id,\n                                            update: {\n                                                sessionUpdate: \"tool_call_update\",\n                                                toolCallId: record.parentToolUseId,\n                                                status: message.patch.status === \"completed\" ? \"completed\" : \"failed\",\n                                                _meta: { claudeCode: { subagentTerminated: { taskId: message.task_id, status: message.patch.status } } },\n                                            },\n                                        });\n                                    }\n                                    session.liveBackgroundTasks.delete(message.task_id);\n                                }"
    }
  ]

  @doc false
  def adapter_version, do: @adapter_version

  @impl true
  def id, do: :claude

  @impl true
  def wire_name, do: "claude"

  @impl true
  def credential_provider, do: :anthropic

  @impl true
  def install_package, do: "@agentclientprotocol/claude-agent-acp"

  @impl true
  def wire_projection do
    JSON.encode!(%{
      "id" => "claude",
      "wire_name" => wire_name(),
      "install_package" => install_package(),
      "process_markers" => ["claude-agent-acp"]
    })
  end

  @impl true
  def prepare_launch(target, home, opts) do
    binary = adapter_binary(target)
    common = Keyword.fetch!(opts, :common_env)

    if Support.local?(target) do
      token_env =
        case File.read(Path.join([target.host_config.base_dir, "auth", "claude", "oauth-token"])) do
          {:ok, token} -> [{"CLAUDE_CODE_OAUTH_TOKEN", String.trim(token)}]
          _ -> []
        end

      [cmd: [binary], env: [{"CLAUDE_CONFIG_DIR", home} | common ++ token_env]]
    else
      token_path = Path.join([target.host_config.base_dir, "auth", "claude", "oauth-token"])

      remote_env =
        [
          "CLAUDE_CODE_OAUTH_TOKEN=$(cat #{token_path} 2>/dev/null)",
          "CLAUDE_CONFIG_DIR=#{home}"
          | Keyword.fetch!(opts, :remote_env)
        ]

      [
        cmd:
          ["ssh" | Support.ssh_opts()] ++
            [target.host_config.ssh, "exec", "env" | remote_env] ++ [binary],
        env: [{"TIGHTBEAM_LINEAGE", Keyword.fetch!(opts, :lineage)}]
      ]
    end
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
      "Your Tight Beam archetype identity arrives as this Claude system prompt. " <>
        "It is authoritative and outranks product CLAUDE.md instructions on conflict."

    guidance =
      if Map.get(session, :identity) == true and not String.starts_with?(guidance, prefix),
        do: prefix <> "\n\n" <> guidance,
        else: guidance

    %{
      guidance: guidance,
      meta: %{systemPrompt: %{type: "preset", preset: "claude_code", append: guidance}},
      permission_mode: "bypassPermissions",
      effort_config: "effort"
    }
  end

  @impl true
  def owned_home_entries,
    do: Support.owned_home_entries("oauth-token", "settings.json")

  @impl true
  def reconcile_home(target, home, desired) do
    rails =
      case desired.rails do
        nil -> nil
        bytes when is_binary(bytes) -> bytes
        settings -> JSON.encode!(settings)
      end

    desired = %{desired | rails: rails}

    Tightbeam.Homes.reconcile(target, home, desired,
      credential_names: ["oauth-token"],
      rails_filename: "settings.json"
    )
  end

  @impl true
  def materialize_skills(target, cwd, snapshot) do
    Tightbeam.Identity.materialize_for_harness!(
      target,
      snapshot,
      cwd,
      Path.join([".claude", "skills"])
    )
  end

  @impl true
  def credential_ready?(target, _home) do
    store =
      Tightbeam.Credentials.store_dir(
        target.host_config.base_dir,
        credential_provider()
      )

    Tightbeam.Homes.credential_ready?(target, store, ["oauth-token"])
  end

  @impl true
  def harvest_credential(target, home) do
    Tightbeam.Homes.harvest_credential(target, home, "oauth-token")
  end

  @impl true
  def credential_live?(target, home, opts) do
    script = """
    const fs = require("node:fs");
    const token = fs.readFileSync(process.argv[1], "utf8").trim();
    fetch("https://api.anthropic.com/v1/models?limit=1", {
      headers: {
        "Authorization": `Bearer ${token}`,
        "anthropic-version": "2023-06-01",
        "User-Agent": "claude-cli/2.1.220"
      }
    }).then(async response => {
      process.stdout.write(JSON.stringify({
        status: response.status,
        headers: {"content-type": response.headers.get("content-type")},
        body: await response.text()
      }));
    }).catch(error => {
      process.stderr.write(error.code || error.message);
      process.exitCode = 70;
    });
    """

    request = %{
      command: ["node", "--no-warnings", "-e", script, Path.join(home, "oauth-token")]
    }

    Support.credential_live_result(target, request, opts)
  end

  @impl true
  def install_cli_projection(_cli_bin), do: :ok

  @impl true
  def probe_cli(target) do
    find = Map.get(target, :find_executable, &System.find_executable/1)
    Support.bounded_probe(find.("claude"), target)
  end

  @impl true
  def containment_additions do
    [
      {"/private/tmp", "claude Terminal per-command workdir"},
      {"/dev", "claude session-new PTY allocation"}
    ]
  end

  @impl true
  def classify_auth_event(_event), do: :unknown

  @impl true
  def classify_subagent_event(%{
        "toolCallId" => tool_call_id,
        "_meta" => %{"claudeCode" => %{"subagentTerminated" => _}}
      }) do
    {:subagent_stop, %{source_event_ref: tool_call_id, subagent_ref: tool_call_id}}
  end

  def classify_subagent_event(%{
        "sessionUpdate" => "tool_call",
        "toolCallId" => tool_call_id,
        "_meta" => %{"claudeCode" => %{"toolName" => tool_name}}
      })
      when tool_name in ["Agent", "Task"] do
    {:subagent_start, %{source_event_ref: tool_call_id, subagent_ref: tool_call_id}}
  end

  def classify_subagent_event(_update), do: :skip

  @impl true
  def fetch_catalog(state) do
    fetch = Map.get(state.options, :claude_fetch, &http_get/2)

    with {:ok, token} <- read_token(Path.join([state.base_dir, "auth", "claude", "oauth-token"])),
         token <- String.trim(token),
         true <- token != "",
         headers = [
           {~c"authorization", String.to_charlist("Bearer " <> token)},
           {~c"anthropic-version", ~c"2023-06-01"}
         ],
         {:ok, body} <- fetch.("/v1/models?limit=100", headers),
         {:ok, models} <- decode_catalog(body),
         {:ok, models} <- fill_capabilities(models, headers, fetch),
         {:ok, entries} <- derive_catalog_entries(models),
         entries when entries != [] <- entries do
      {:ok, entries}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :missing_token}
      [] -> {:error, :empty_inventory}
      _ -> {:error, :malformed_catalog}
    end
  end

  @impl true
  def conformance_vectors do
    source = Enum.map_join(@adapter_replacements, "\n", &elem(&1, 0))

    valid_entry = %{
      ref: "claude-vector[low]",
      display_name: "Claude Vector",
      name: "Claude Vector",
      efforts: ["low"],
      max_input_tokens: 1_000,
      capabilities: %{"effort" => %{"low" => %{"supported" => true}}},
      provider: :anthropic
    }

    Support.conformance_vectors(__MODULE__, %{
      wire_name: wire_name(),
      provider: credential_provider(),
      home_scope: wire_name(),
      home_env: "CLAUDE_CONFIG_DIR",
      credential_file: "oauth-token",
      credential_live: %{
        live_fixture: Application.app_dir(:tightbeam, "priv/credential_live/claude-live.json"),
        dead_fixture: Application.app_dir(:tightbeam, "priv/credential_live/claude-dead.json")
      },
      rails_file: "settings.json",
      rails: %{"hooks" => %{"PreToolUse" => []}},
      skills_path: Path.join([".claude", "skills"]),
      local_extra_env: [{"CLAUDE_CODE_OAUTH_TOKEN", "vector-token"}],
      rails_env: nil,
      remote_prefix: fn base, home ->
        [
          "CLAUDE_CODE_OAUTH_TOKEN=$(cat #{Path.join([base, "auth", "claude", "oauth-token"])} 2>/dev/null)",
          "CLAUDE_CONFIG_DIR=#{home}"
        ]
      end,
      remote_rails_env: nil,
      railed_probe: false,
      adapter_bin: "claude-agent-acp",
      adapter_package: @adapter_package,
      adapter_bundle: @adapter_bundle,
      adapter_version: @adapter_version,
      source: source,
      patched: patch_adapter_source(source),
      remote_patch_detail: "; claude adapter patched",
      session_meta: %{
        systemPrompt: %{
          type: "preset",
          preset: "claude_code",
          append: "vector guidance"
        }
      },
      containment: [
        {"/private/tmp", "claude Terminal per-command workdir"},
        {"/dev", "claude session-new PTY allocation"}
      ],
      cli_name: "claude",
      cli_version: "claude vector 1.0",
      probe_path: :discovered,
      auth_events: [
        %{
          case: "positive",
          envelope: %{"authMode" => nil, "planType" => nil},
          expected: :unknown,
          divergence: "DIV-AUTH-CLAUDE-UNKNOWN"
        },
        %{case: "negative", envelope: %{"unrelated" => true}, expected: :unknown}
      ],
      subagent_events: [
        %{
          case: "positive_start",
          envelope: %{
            "sessionUpdate" => "tool_call",
            "toolCallId" => "claude-call",
            "_meta" => %{"claudeCode" => %{"toolName" => "Agent"}}
          },
          expected:
            {:subagent_start, %{source_event_ref: "claude-call", subagent_ref: "claude-call"}}
        },
        %{
          case: "positive_stop",
          envelope: %{
            "toolCallId" => "claude-call",
            "_meta" => %{"claudeCode" => %{"subagentTerminated" => %{}}}
          },
          expected:
            {:subagent_stop, %{source_event_ref: "claude-call", subagent_ref: "claude-call"}}
        },
        %{case: "negative", envelope: %{"sessionUpdate" => "tool_call"}, expected: :skip}
      ],
      catalog_expected: %{
        "valid" => {:ok, [valid_entry]},
        "malformed" => {:error, :malformed_catalog},
        "unavailable" => {:error, :unavailable}
      },
      catalog_state: fn case_name, base ->
        token = Path.join([base, "auth", "claude", "oauth-token"])
        File.mkdir_p!(Path.dirname(token))
        File.write!(token, "vector-token")

        body =
          JSON.encode!(%{
            "data" => [
              %{
                "id" => "claude-vector",
                "display_name" => "Claude Vector",
                "max_input_tokens" => 1_000,
                "capabilities" => %{
                  "effort" => %{"low" => %{"supported" => true}}
                }
              }
            ]
          })

        fetch = fn _path, _headers ->
          case case_name do
            "valid" -> {:ok, body}
            "malformed" -> {:ok, "{}"}
            "unavailable" -> {:error, :unavailable}
          end
        end

        %{base_dir: base, options: %{claude_fetch: fetch}}
      end,
      wire_projection: %{
        "id" => "claude",
        "wire_name" => "claude",
        "install_package" => "@agentclientprotocol/claude-agent-acp",
        "process_markers" => ["claude-agent-acp"]
      }
    })
  end

  defp decode_catalog(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{"data" => models}} when is_list(models) -> {:ok, models}
      {:ok, _} -> {:error, :malformed_catalog}
      {:error, _} -> {:error, :malformed_json}
    end
  end

  defp decode_catalog(_body), do: {:error, :malformed_catalog}

  defp read_token(path) do
    case File.read(path) do
      {:ok, token} -> {:ok, token}
      {:error, :enoent} -> {:error, :missing_token}
      {:error, reason} -> {:error, {:token_read_failed, reason}}
    end
  end

  defp fill_capabilities(models, headers, fetch) do
    Enum.reduce_while(models, {:ok, []}, fn model, {:ok, acc} ->
      if is_map(get_in(model, ["capabilities", "effort"])) do
        {:cont, {:ok, [model | acc]}}
      else
        case model["id"] do
          id when is_binary(id) ->
            path = "/v1/models/" <> URI.encode(id, &URI.char_unreserved?/1)

            with {:ok, body} <- fetch.(path, headers),
                 {:ok, detail} <- JSON.decode(body),
                 true <- is_map(detail) do
              {:cont, {:ok, [Map.merge(model, detail) | acc]}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
              _ -> {:halt, {:error, :malformed_catalog}}
            end

          _ ->
            {:halt, {:error, :malformed_catalog}}
        end
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp derive_catalog_entries(models) do
    Enum.reduce_while(models, {:ok, []}, fn
      %{
        "id" => id,
        "display_name" => display_name,
        "max_input_tokens" => max_input_tokens,
        "capabilities" => capabilities
      } = model,
      {:ok, entries}
      when is_binary(id) and is_binary(display_name) and is_integer(max_input_tokens) and
             max_input_tokens >= 0 and is_map(capabilities) ->
        case efforts(capabilities) do
          {:ok, effort_names} ->
            {:cont, {:ok, entries ++ entries_for(model, id, effort_names, capabilities)}}

          :error ->
            {:halt, {:error, :malformed_catalog}}
        end

      _, _ ->
        {:halt, {:error, :malformed_catalog}}
    end)
  end

  defp efforts(capabilities) do
    values = Map.get(capabilities, "effort", %{})

    if is_map(values) and
         Enum.all?(values, fn
           {effort, %{"supported" => supported}}
           when is_binary(effort) and is_boolean(supported) ->
             true

           {"supported", supported} when is_boolean(supported) ->
             true

           _ ->
             false
         end) do
      {:ok, for({effort, %{"supported" => true}} <- values, do: effort)}
    else
      :error
    end
  end

  defp entries_for(model, id, effort_names, capabilities) do
    refs =
      if effort_names == [],
        do: [id],
        else: Enum.map(effort_names, &"#{id}[#{&1}]")

    display_name = model["display_name"] || id

    Enum.map(refs, fn ref ->
      %{
        ref: ref,
        display_name: display_name,
        name: display_name,
        efforts: effort_names,
        max_input_tokens: model["max_input_tokens"],
        capabilities: capabilities,
        provider: :anthropic
      }
    end)
  end

  defp http_get(path, headers) do
    url = String.to_charlist("https://api.anthropic.com" <> path)

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:get, {url, headers}, [ssl: ssl, timeout: 10_000], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _response_headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_version, status, _reason}, _response_headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp adapter_binary(target) do
    Map.get(target, :adapter_binary) ||
      if Support.local?(target) do
        Path.expand("../tightbeam/node_modules/.bin/claude-agent-acp", File.cwd!())
      else
        Path.join([
          target.host_config.base_dir,
          "adapters",
          "node_modules",
          ".bin",
          "claude-agent-acp"
        ])
      end
  end

  defp patch_remote(target, path, detail) do
    script = "node -e #{Support.shell_quote(remote_patch_script(path))}"

    case target.sh.(
           ["ssh" | Support.ssh_opts()] ++
             [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]
         ) do
      {_output, 0} -> {:ok, detail <> "; claude adapter patched"}
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
