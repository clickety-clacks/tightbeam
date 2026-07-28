defmodule Tightbeam.Harness.Codex do
  @moduledoc false
  @behaviour Tightbeam.Harness

  alias Tightbeam.Harness.Support

  @adapter_version "1.1.4"
  @adapter_package "codex-acp"
  # Recorded live 2026-07-28 against codex-cli 0.145.0. The platform route
  # (api.openai.com/v1/models) is CLOSED to this token — 403, missing scope
  # `api.model.read` — so do not "fix" this to the obvious URL.
  @models_url "https://chatgpt.com/backend-api/codex/models"
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

  @doc false
  def adapter_version, do: @adapter_version

  @impl true
  def id, do: :codex

  @impl true
  def wire_name, do: "codex"

  @impl true
  def credential_provider, do: :openai

  @impl true
  def install_package, do: "@agentclientprotocol/codex-acp"

  @impl true
  def cli_binary, do: "codex"

  @impl true
  def wire_projection do
    JSON.encode!(%{
      "id" => "codex",
      "wire_name" => wire_name(),
      "install_package" => install_package(),
      "cli_binary" => cli_binary(),
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
      |> Map.put_new(:remote_patch, &patch_remote(target, &1, &2))

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
  def owned_home_entries,
    do: Support.owned_home_entries("auth.json", "hooks.json")

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
  def credential_live?(target, home, opts) do
    script = """
    const fs = require("node:fs");
    const auth = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    fetch("https://chatgpt.com/backend-api/wham/accounts/check", {
      headers: {
        "Authorization": `Bearer ${auth.tokens.access_token}`,
        "ChatGPT-Account-ID": auth.tokens.account_id,
        "User-Agent": "codex_cli_rs/0.145.0"
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

    request = %{command: ["node", "--no-warnings", "-e", script, Path.join(home, "auth.json")]}
    Support.credential_live_result(target, request, opts)
  end

  @impl true
  def install_cli_projection(cli_bin) do
    shim = Path.join(cli_bin, cli_binary())
    discovered = System.find_executable(cli_binary())

    if not File.exists?(shim) and is_binary(discovered) and
         Path.dirname(discovered) != Path.dirname(shim) do
      File.write!(
        shim,
        "#!/bin/sh\nexec \"#{discovered}\" --dangerously-bypass-hook-trust \"$@\"\n"
      )

      File.chmod!(shim, 0o755)
    end

    :ok
  end

  @impl true
  def probe_cli(target) do
    find = Map.get(target, :find_executable, &System.find_executable/1)
    shim = Path.join(Map.get(target, :cli_bin, ""), cli_binary())
    binary = if File.exists?(shim), do: shim, else: find.(cli_binary())
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

  # The catalog is the ACCOUNT's, so it is derived on the host that holds the
  # account — one HTTPS call made BY that host. This replaced reading codex's
  # `models_cache.json`, which was only ever a copy of this answer, and only on a
  # host where codex had already run (#67). Nothing reads that file now.
  #
  # Two facts the probe needs exist only on the owning host, and both are taken
  # there: the access token out of `auth.json`, and the version of the `codex`
  # binary. Neither is interpolated into a command line by us — the remote shell
  # expands both — so no credential transits and none appears in a process table.
  @impl true
  def fetch_catalog(state) do
    case probe(state) do
      {:ok, body, trailer} ->
        with {:ok, models} <- decode_catalog(body),
             {:ok, entries} <- derive_catalog_entries(models),
             entries when entries != [] <- entries do
          {:ok, entries}
        else
          {:error, reason} -> {:error, reason}
          [] -> {:error, {:empty_catalog_for_client_version, client_version(trailer)}}
          _ -> {:error, :malformed_catalog}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp probe(state) do
    sh = Map.get(state.options, :sh, &Support.system_cmd_out/1)
    auth = Path.join([state.base_dir, "auth", "codex", "auth.json"])

    sh
    |> Support.catalog_probe(
      Support.catalog_probe_argv(
        Map.get(state, :host_config, %{ssh: nil}).ssh,
        probe_script(auth)
      )
    )
    |> classify_extraction(auth)
  end

  # Codex owns `auth.json` and rewrites it IN PLACE as it rotates (established
  # empirically 2026-07-28: the inode survives a forced rotation, so the store's
  # symlink stays coherent). This probe is a second, read-only reader of that
  # file, so a read can land mid-rewrite and see torn JSON. That is a RETRYABLE
  # accident of timing, not a verdict on the grant — the next refresh reads a
  # whole file — and it must never be reported as a bad credential, because the
  # repair it would imply (re-onboard) is both wrong and destructive of a working
  # login. The extraction step exits on a distinct code per state so the three
  # cannot collapse into one opaque failure.
  defp classify_extraction({:error, {:probe_failed, 66, _output}}, auth),
    do: {:error, {:missing_credential, auth}}

  defp classify_extraction({:error, {:probe_failed, 75, _output}}, _auth),
    do: {:error, {:credential_read_torn, :retry_next_refresh}}

  defp classify_extraction({:error, {:probe_failed, 67, _output}}, auth),
    do: {:error, {:credential_missing_access_token, auth}}

  defp classify_extraction(result, _auth), do: result

  # `client_version` is a SILENT filter: every model carries a
  # `minimal_client_version` and the server drops the ones the caller is too old
  # for — returning 200 with an EMPTY list, not an error. So the version must be
  # the one the `codex` binary on THAT host reports (it is an operator
  # prerequisite there, #76). A constant in our source would filter the catalog
  # to nothing and blame the account. It rides back on the status line so the
  # refusal can name the version that produced an empty answer.
  defp probe_script(auth_path) do
    # Exit codes are sysexits: 66 EX_NOINPUT (no readable auth.json — a real
    # "this host holds no grant"), 75 EX_TEMPFAIL (present but unparseable — a
    # torn read, transient), 67 EX_NOUSER (parsed, but carries no access token —
    # a real credential-shape problem). `set -e` propagates the substitution's
    # status, so the script exits with whichever one node chose.
    node_program =
      ~s|const fs=require("fs");let raw;| <>
        ~s|try{raw=fs.readFileSync("#{auth_path}","utf8")}catch(e){process.exit(66)}| <>
        ~s|let d;try{d=JSON.parse(raw)}catch(e){process.exit(75)}| <>
        ~s|const t=d&&d.tokens?d.tokens.access_token:undefined;| <>
        ~s|if(!(typeof t==="string"&&t.length)){process.exit(67)}process.stdout.write(t)|

    curl =
      Support.catalog_curl(
        "#{@models_url}?client_version=${raw##* }",
        [~s|authorization: Bearer $token|],
        " ${raw##* }"
      )

    """
    exec 2>&1
    set -eu
    token=$(node -e '#{node_program}')
    raw=$(codex --version)
    exec #{curl}
    """
  end

  defp client_version([version | _]), do: version
  defp client_version(_), do: :unknown

  @impl true
  def conformance_vectors do
    source = Enum.map_join(@adapter_replacements, "\n", &elem(&1, 0))
    levels = [%{"effort" => "medium"}]

    valid_entry = %{
      ref: "codex-vector[medium]",
      display_name: "Codex Vector",
      name: "Codex Vector",
      efforts: ["medium"],
      max_input_tokens: 2_000,
      capabilities: %{"supported_reasoning_levels" => levels},
      provider: :openai
    }

    Support.conformance_vectors(__MODULE__, %{
      wire_name: wire_name(),
      provider: credential_provider(),
      home_scope: wire_name(),
      home_env: "CODEX_HOME",
      credential_file: "auth.json",
      credential_live: %{
        live_fixture: Application.app_dir(:tightbeam, "priv/credential_live/codex-live.json"),
        dead_fixture: Application.app_dir(:tightbeam, "priv/credential_live/codex-dead.json")
      },
      rails_file: "hooks.json",
      rails: %{"hooks" => %{"PreToolUse" => []}},
      skills_path: Path.join([".codex", "skills"]),
      local_extra_env: [],
      rails_env: {"CODEX_CONFIG", ~s({"bypass_hook_trust":true})},
      remote_prefix: fn _base, home -> ["CODEX_HOME=#{home}"] end,
      remote_rails_env: "CODEX_CONFIG='#{~s({"bypass_hook_trust":true})}'",
      railed_probe: true,
      adapter_bin: "codex-acp",
      adapter_package: @adapter_package,
      adapter_bundle: @adapter_bundle,
      adapter_version: @adapter_version,
      source: source,
      patched: patch_adapter_source(source),
      remote_patch_detail: "; codex adapter patched",
      session_meta: %{developerInstructions: "vector guidance"},
      containment: [],
      cli_name: "codex",
      cli_version: "codex vector 1.0",
      probe_path: :discovered,
      auth_events: [
        %{
          case: "positive",
          envelope: %{
            "_meta" => %{
              "codex" => %{
                "accountUpdated" => %{"authMode" => nil, "planType" => nil}
              }
            }
          },
          expected: :terminal
        },
        %{case: "negative", envelope: %{"unrelated" => true}, expected: :unknown}
      ],
      subagent_events: [
        %{
          case: "positive_start",
          envelope: %{
            "toolCallId" => "codex-call",
            "_meta" => %{
              "codex" => %{
                "subagent" => %{
                  "threadId" => "codex-thread",
                  "activity" => "started"
                }
              }
            }
          },
          expected:
            {:subagent_start, %{source_event_ref: "codex-call", subagent_ref: "codex-thread"}}
        },
        %{
          case: "positive_stop",
          envelope: %{
            "toolCallId" => "codex-call",
            "_meta" => %{
              "codex" => %{
                "subagentTerminated" => %{"agentThreadId" => "codex-thread"}
              }
            }
          },
          expected:
            {:subagent_stop, %{source_event_ref: "codex-call", subagent_ref: "codex-thread"}}
        },
        %{case: "negative", envelope: %{"toolCallId" => "codex-call"}, expected: :skip}
      ],
      catalog_expected: %{
        "valid" => {:ok, [valid_entry]},
        "malformed" => {:error, :malformed_catalog},
        # The vendor's own sentence for a grant that needs signing in again — the
        # probe carries the 401 BODY, not just the code, because that is what the
        # operator acts on.
        "unavailable" =>
          {:error,
           {:http_status, 401,
            ~s({"detail":"Could not parse your authentication token. Please try signing in again."})}}
      },
      catalog_state: fn case_name, base ->
        body =
          JSON.encode!(%{
            "models" => [
              %{
                "slug" => "codex-vector",
                "display_name" => "Codex Vector",
                "supported_reasoning_levels" => levels,
                "max_input_tokens" => 2_000
              }
            ]
          })

        # One HTTPS call made BY the owning host, so the seam is the runner and
        # the vector is a RESPONSE: body, then curl's status on a trailing line,
        # then the `codex --version` that decided what the server would list.
        sh = fn _command ->
          case case_name do
            "valid" ->
              {body <> "\n200 0.145.0", 0}

            "malformed" ->
              {"{}\n200 0.145.0", 0}

            "unavailable" ->
              {~s({"detail":"Could not parse your authentication token. Please try signing in again."}) <>
                 "\n401 0.145.0", 0}
          end
        end

        %{base_dir: base, options: %{sh: sh}}
      end,
      wire_projection: %{
        "id" => "codex",
        "wire_name" => "codex",
        "install_package" => "@agentclientprotocol/codex-acp",
        "cli_binary" => "codex",
        "process_markers" => ["codex-acp"]
      }
    })
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
    # One path for both localities, as fixture.ex already does: the adapter lives
    # under the host's own base_dir. The local branch used to point at a sibling
    # checkout of the RETIRED TypeScript project, so the gateway's turn path
    # depended on a directory nothing in this repo owns or installs.
    Map.get(target, :adapter_binary) ||
      Path.join([
        target.host_config.base_dir,
        "adapters",
        "node_modules",
        ".bin",
        "codex-acp"
      ])
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
