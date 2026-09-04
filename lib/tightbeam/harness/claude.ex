defmodule Tightbeam.Harness.Claude do
  @moduledoc false
  @behaviour Tightbeam.Harness

  alias Tightbeam.Harness.Support
  alias Tightbeam.{Model, ModelManifest}

  require Logger

  @adapter_version "0.73.0"
  @adapter_package "claude-agent-acp"
  @adapter_bundle "acp-agent.js"
  @warm_timeout_ms 30_000
  @credential_env_vars %{
    subscription: "CLAUDE_CODE_OAUTH_TOKEN",
    api_key: "ANTHROPIC_API_KEY"
  }

  # The hosted manifest is the sole Claude offered-set authority. Unknown slugs
  # still pass through to the adapter, whose turn-time refusal remains final.

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
  def credential_env_vars, do: @credential_env_vars |> Map.values() |> Enum.sort()

  @impl true
  def default_model, do: ModelManifest.default_model(wire_name())

  @doc false
  @impl true
  def unknown_model_passthrough?, do: true

  @impl true
  def install_package, do: "@agentclientprotocol/claude-agent-acp"

  @impl true
  def cli_binary, do: "claude"

  @impl true
  def wire_projection do
    JSON.encode!(%{
      "id" => "claude",
      "wire_name" => wire_name(),
      "install_package" => install_package(),
      "cli_binary" => cli_binary(),
      "process_markers" => ["claude-agent-acp"]
    })
  end

  # A SUBSCRIPTION credential is not injected, and that is the difference between the two
  # kinds rather than an omission. It is an OAuth record with a refresh token, and Claude
  # Code refreshes it IN PLACE in its config dir -- so it is linked into the home and the
  # harness owns its lifecycle, exactly as codex owns `auth.json`. Passing the access token
  # through an environment variable would work until it lapsed and then fail with no way
  # back, because an env var has nowhere to put the refresh token.
  #
  # An API key has no refresh and no expiry, so it stays an environment variable. Same
  # provider, two shapes, because the credentials genuinely are two different things.
  @impl true
  def prepare_launch(target, home, opts) do
    binary = adapter_binary(target)
    common = Keyword.fetch!(opts, :common_env)
    kind = Keyword.fetch!(opts, :credential_kind)
    credential_path = credential_path(target.host_config.base_dir)

    if Support.local?(target) do
      credential_env =
        case {kind, File.read(credential_path)} do
          {:subscription, _} -> []
          {:api_key, {:ok, credential}} -> [{credential_env_var(kind), String.trim(credential)}]
          {:api_key, _} -> []
        end

      [cmd: [binary], env: [{"CLAUDE_CONFIG_DIR", home} | common ++ credential_env]]
    else
      remote_env =
        case kind do
          :subscription ->
            ["CLAUDE_CONFIG_DIR=#{home}" | Keyword.fetch!(opts, :remote_env)]

          :api_key ->
            [
              "#{credential_env_var(kind)}=$(cat #{credential_path} 2>/dev/null)",
              "CLAUDE_CONFIG_DIR=#{home}"
              | Keyword.fetch!(opts, :remote_env)
            ]
        end

      [
        cmd:
          ["ssh" | Support.ssh_opts()] ++
            [target.host_config.ssh, "exec", "env" | remote_env] ++ [binary],
        env: [{"TIGHTBEAM_LINEAGE", Keyword.fetch!(opts, :lineage)}]
      ]
    end
  end

  # Claude takes its credential from the environment, and the VARIABLE NAMES THE
  # KIND: a setup-token in ANTHROPIC_API_KEY is rejected, and an API key in
  # CLAUDE_CODE_OAUTH_TOKEN is rejected. Exactly one is ever set -- never both,
  # never an empty one -- so a wrong kind fails as an authentication error naming
  # the credential rather than as a precedence puzzle between two variables.
  #
  # `fetch!` and no default: a launch that cannot say which kind it is launching
  # is a programming error, and defaulting it would quietly run part of the fleet
  # on the wrong variable.
  defp credential_env_var(kind), do: Map.fetch!(@credential_env_vars, kind)

  # ONE file per provider, holding whichever kind is active, and the name is Claude Code's
  # own: the file is LINKED into the harness home, where the harness reads it directly.
  # `Homes.reconcile` uses a single name for both the store and the home entry, so the store
  # takes the harness's name rather than the harness taking ours.
  #
  # It is still deliberately NOT read as evidence of the kind -- `credential.json` is the
  # authority. A subscription credential is the OAuth record Claude Code refreshes in place;
  # an API key is a bare secret that never expires. Same path, different contents, and only
  # the subscription one is ever handed to the harness as a file.
  @credential_file ".credentials.json"

  defp credential_path(base_dir),
    do: Path.join([base_dir, "auth", "claude", @credential_file])

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
      "Your Tightbeam archetype identity arrives as this Claude system prompt. " <>
        "It is authoritative and outranks product CLAUDE.md instructions on conflict."

    guidance =
      if Map.get(session, :identity) == true and not String.starts_with?(guidance, prefix),
        do: prefix <> "\n\n" <> guidance,
        else: guidance

    %{
      guidance: guidance,
      meta: %{systemPrompt: %{type: "preset", preset: "claude_code", append: guidance}},
      permission_mode: "bypassPermissions",
      effort_config: "effort",
      resident_model_switch: :fork,
      model_option_aliases: ModelManifest.aliases(wire_name()),
      canonical_model_prefixes: ModelManifest.prefixes(wire_name())
    }
  end

  @impl true
  def owned_home_entries,
    do: Support.owned_home_entries(@credential_file, "settings.json")

  @impl true
  def reconcile_home(target, home, desired) do
    # THE FABLE FIX (ops-hardening-v1 §3): claude's offered-model list is
    # environment-dependent — the same home and auth offers fable at a cwd whose
    # settings file pins it and not at a bare one (JOURNAL.md:804) — so every
    # projected home pins the org's default model, making the offered list
    # deterministic. Harness-owned, because WHICH config key means "model" and
    # how a model is spelled there is this harness's business and nobody
    # else's (the seam scan enforces exactly that). Merged with the rails hooks
    # because both land in the same file; either side may be absent.
    #
    # Hash consequence: homes regenerate once on the deploy that first carries
    # this (identity change — context-reset markers will show; expected).
    # Binary rails are OPAQUE — the pre-map contract, still used by tests — and
    # pass through untouched (no pin can be merged into bytes we do not parse).
    # The production path always arrives here as a map (Rails.hook_settings/0)
    # or nil, and those take the pin.
    rails =
      case {desired.rails, Map.get(desired, :default_model)} do
        {bytes, _model} when is_binary(bytes) ->
          bytes

        {map_or_nil, nil} ->
          map_or_nil && JSON.encode!(map_or_nil)

        {map_or_nil, model} ->
          JSON.encode!(Map.put(map_or_nil || %{}, "model", packed_model(model)))
      end

    desired = %{desired | rails: rails}

    Tightbeam.Homes.reconcile(target, home, desired,
      credential_names: [@credential_file],
      rails_filename: "settings.json"
    )
  end

  defp packed_model(%Model{} = model), do: ModelManifest.render(wire_name(), model)

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

    Tightbeam.Homes.credential_ready?(target, store, [@credential_file])
  end

  # One real turn, so the harness asks the server what this account may use and caches the
  # answer where its own picker reads it. Cold, Claude Code offers four aliases; after a
  # single run its `additionalModelOptionsCache` carries the account's extras -- measured:
  # `claude-fable-5[1m]` appears only after the home has been used once.
  #
  # `-p` with a trivial prompt because the CHEAPEST real turn is the point: we are not
  # checking the answer, only that the harness has spoken to the server once. Failure is
  # returned to the onboarding caller, which logs it and continues because the credential
  # has already validated.
  @impl true
  def warm_home(target, home) do
    # Through the target's injected runner, never `System.cmd` directly. This callback
    # SPAWNS THE VENDOR CLI, so a version that reaches for the real binary runs it in every
    # test that reconciles a home -- which is what the first version did, and it broke a
    # hundred tests that had no business talking to a provider.
    sh = Map.get(target, :sh, &Support.system_cmd_out/1)

    timeout = Map.get(target, :warm_timeout_ms, @warm_timeout_ms)

    # THE HOME IS DELIVERED BY ENV, NOT BY A FLAG. This passed `--config-dir <home>`,
    # which Claude Code has no such option for -- it exits 2 with "unknown option", so
    # the warm has never once succeeded. Being best-effort, the failure was swallowed
    # every time, and the cold-catalog deadlock this exists to break was never broken;
    # it only looked fixed because a real turn warms the home by another route.
    # `prepare_launch/2` had it right all along: `CLAUDE_CONFIG_DIR`.
    #
    # Via `env` rather than the runner's environment because `Support.system_cmd_out/1`
    # takes only argv, and because it then reads the same local and remote -- an `env`
    # word survives `shell_quote` over ssh, where a bare `FOO=bar` prefix would be
    # quoted into a command name and not recognized as an assignment at all.
    warm = ["env", "CLAUDE_CONFIG_DIR=#{home}", cli_binary(), "-p", "ok", "--model", "sonnet"]

    argv =
      if Support.local?(target) do
        warm
      else
        # The same turn, over the channel the credential itself just travelled. A remote
        # home has to warm on the host that owns it -- the cache is written by the harness
        # into ITS filesystem -- and the credential install already proved this route works.
        # Skipping it left a satellite holding a good credential whose harness had never
        # asked what it may run, which reads as a weak account rather than a missing step.
        ["ssh" | Support.ssh_opts()] ++
          [
            target.host_config.ssh,
            Enum.map_join(warm, " ", &Support.shell_quote/1)
          ]
      end

    case Support.bounded_run(sh, argv, timeout) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} when is_integer(status) ->
        {:error, {:warm_failed, status, String.trim(to_string(output))}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def harvest_credential(target, home) do
    Tightbeam.Homes.harvest_credential(target, home, @credential_file)
  end

  @impl true
  def credential_live?(target, home, opts) do
    kind = Keyword.fetch!(opts, :credential_kind)
    {header, scheme} = credential_header(kind)

    script = """
    const fs = require("node:fs");
    const raw = fs.readFileSync(process.argv[1], "utf8");
    const credential = process.argv[4] === "subscription"
      ? JSON.parse(raw).claudeAiOauth.accessToken.trim()
      : raw.trim();
    fetch("https://api.anthropic.com/v1/models?limit=1", {
      headers: {
        [process.argv[2]]: process.argv[3] + credential,
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
      // NAME WHAT ACTUALLY FAILED. `error.code || error.message` reported the string
      // "fetch failed" for every transport failure there is: on a fetch rejection undici
      // leaves `code` UNDEFINED on the outer error and puts the real reason -- ENOTFOUND,
      // ECONNRESET, UND_ERR_CONNECT_TIMEOUT, a TLS failure -- in `error.cause`. So the
      // fallback always won, and a refusal that exists to report dirt named none of it.
      // Measured 2026-08-04: a client-e2e leg blocked twice at two SHAs on
      // `{:transport_exit, 70, "fetch failed"}` with a credential proven live by a 200
      // from this same endpoint, and the message could not say which transport failed.
      const cause = error.cause;
      process.stderr.write(
        [cause && cause.code, cause && cause.message, error.code, error.message]
          .filter(Boolean)
          .join(": ") || "unknown transport failure"
      );
      process.exitCode = 70;
    });
    """

    # The header NAME and its scheme ride in argv; the credential never does --
    # it is read from disk inside the script, on the host that owns it.
    request = %{
      command: [
        "node",
        "--no-warnings",
        "-e",
        script,
        Path.join(home, @credential_file),
        header,
        scheme,
        Atom.to_string(kind)
      ]
    }

    Support.credential_live_result(target, request, opts)
  end

  defp credential_header(:subscription), do: {"Authorization", "Bearer "}
  defp credential_header(:api_key), do: {"x-api-key", ""}

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
    with {:ok, provider, manifest_health} <- manifest_provider(state),
         {:ok, version} <- claude_code_version(state),
         {:ok, entries, version_blocks} <- manifest_entries(provider, version) do
      {:ok, entries,
       %{
         manifest_health: manifest_health,
         claude_code_version: version,
         version_blocks: version_blocks
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp manifest_provider(state) do
    case Map.get(state.options, :model_manifest, ModelManifest) do
      fun when is_function(fun, 0) -> provider_from_snapshot(fun.())
      %{} = snapshot -> provider_from_snapshot(snapshot)
      server -> ModelManifest.provider("claude", server)
    end
  end

  defp provider_from_snapshot({:error, _reason} = error), do: error

  defp provider_from_snapshot(%{document: document, health: health}) do
    case get_in(document, ["providers", "claude"]) do
      provider when is_map(provider) -> {:ok, provider, health}
      _ -> {:error, {:manifest_provider_absent, "claude"}}
    end
  end

  defp provider_from_snapshot(_snapshot), do: {:error, :malformed_manifest_snapshot}

  defp claude_code_version(state) do
    case Map.get(state.options, :claude_code_version) do
      version when is_binary(version) -> normalize_version(version)
      fun when is_function(fun, 1) -> normalize_version_result(fun.(state))
      nil -> probe_claude_code_version(state)
    end
  end

  defp normalize_version_result({:ok, version}), do: normalize_version(version)
  defp normalize_version_result({:error, _reason} = error), do: error
  defp normalize_version_result(version), do: normalize_version(version)

  defp normalize_version(version) when is_binary(version) do
    case Regex.run(~r/\d+\.\d+\.\d+/, version) do
      [value] -> {:ok, value}
      _ -> {:error, {:claude_code_version_unavailable, String.trim(version)}}
    end
  end

  defp normalize_version(version), do: {:error, {:claude_code_version_unavailable, version}}

  # Probe the Claude Code bundled by the adapter SDK on the host that owns the
  # catalog. CLAUDE_CODE_EXECUTABLE remains the SDK's explicit override seam.
  defp probe_claude_code_version(state) do
    sh = Map.get(state.options, :sh, &Support.system_cmd_out/1)
    host_config = Map.get(state, :host_config, %{ssh: nil})
    sdk_root = Path.join([state.base_dir, "adapters", "node_modules"])

    script = """
    set -eu
    if [ -n "${CLAUDE_CODE_EXECUTABLE:-}" ]; then
      exec "$CLAUDE_CODE_EXECUTABLE" --version
    fi
    for candidate in \
      #{Support.shell_quote(sdk_root)}/@anthropic-ai/claude-agent-sdk-*/claude \
      #{Support.shell_quote(sdk_root)}/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-*/claude
    do
      if [ -x "$candidate" ]; then exec "$candidate" --version; fi
    done
    echo "bundled Claude Code executable not found under #{sdk_root}" >&2
    exit 127
    """

    argv = Support.catalog_probe_argv(Map.get(host_config, :ssh), script)

    case Support.bounded_run(sh, argv, 2_000) do
      {:ok, {output, 0}} ->
        normalize_version(to_string(output))

      {:ok, {output, status}} ->
        {:error, {:claude_code_version_probe_failed, status, String.trim(to_string(output))}}

      {:error, reason} ->
        {:error, {:claude_code_version_probe_failed, reason}}
    end
  end

  defp manifest_entries(provider, version) do
    profiles = Map.get(provider, "profiles", %{})

    {allowed, blocked} =
      provider
      |> Map.get("models", [])
      |> Enum.split_with(&version_allowed?(&1, version))

    entries = Enum.flat_map(allowed, &model_entries(&1, profiles))

    if entries == [] do
      {:error, {:empty_manifest_inventory, version_blocks(blocked, version)}}
    else
      {:ok, entries, version_blocks(blocked, version)}
    end
  end

  defp version_allowed?(model, version) do
    gate = get_in(model, ["adapter", "claudeCode"]) || %{}
    min = Map.get(gate, "minVersion")
    max = Map.get(gate, "maxVersionExclusive")

    (is_nil(min) or Version.compare(version, min) in [:eq, :gt]) and
      (is_nil(max) or Version.compare(version, max) == :lt)
  end

  defp version_blocks(models, version) do
    Enum.map(models, fn model ->
      gate = get_in(model, ["adapter", "claudeCode"]) || %{}

      %{
        slug: model["slug"],
        name: model["name"] || model["slug"],
        aliases: Map.get(model, "aliases", []),
        current_version: version,
        min_version: gate["minVersion"],
        max_version_exclusive: gate["maxVersionExclusive"]
      }
    end)
  end

  defp model_entries(model, profiles) do
    profile_name = Map.get(model, "profile")
    profile = Map.get(profiles, profile_name, %{})
    suffixes = get_in(profile, ["adapter", "claudeCode", "contextSuffix"]) || %{}

    [nil | Map.keys(suffixes)]
    |> Enum.uniq()
    |> Enum.map(fn context ->
      %{
        family: model["slug"],
        context: context,
        display_name: model["name"] || model["slug"],
        name: model["name"] || model["slug"],
        efforts: Map.get(profile, "efforts", []),
        max_input_tokens: context_tokens(profile, context),
        capabilities: %{
          "profile" => profile,
          "status" => model["status"],
          "badge" => model["badge"],
          "adapter" => model["adapter"]
        },
        provider: :anthropic,
        aliases: Map.get(model, "aliases", []),
        status: model["status"],
        profile: profile_name
      }
    end)
  end

  defp context_tokens(profile, nil) do
    default = Map.get(profile, "defaultContext")
    get_in(profile, ["contextWindowTokens", default])
  end

  defp context_tokens(profile, context),
    do: get_in(profile, ["contextWindowTokens", context])

  @impl true
  def conformance_vectors do
    source = Enum.map_join(@adapter_replacements, "\n", &elem(&1, 0))

    valid_entry = %{
      family: "claude-vector",
      context: nil,
      display_name: "Claude Vector",
      name: "Claude Vector",
      efforts: ["low"],
      max_input_tokens: 1_000,
      capabilities: %{
        "profile" => %{
          "efforts" => ["low"],
          "defaultContext" => "1k",
          "contextWindowTokens" => %{"1k" => 1_000},
          "adapter" => %{"claudeCode" => %{"contextSuffix" => %{}}}
        },
        "status" => "current",
        "badge" => nil,
        "adapter" => %{"claudeCode" => %{"minVersion" => "1.0.0"}}
      },
      provider: :anthropic,
      aliases: [],
      status: "current",
      profile: "vector"
    }

    Support.conformance_vectors(__MODULE__, %{
      wire_name: wire_name(),
      provider: credential_provider(),
      home_scope: wire_name(),
      home_env: "CLAUDE_CONFIG_DIR",
      credential_file: @credential_file,
      credential_live: %{
        live_fixture: Application.app_dir(:tightbeam, "priv/credential_live/claude-live.json"),
        dead_fixture: Application.app_dir(:tightbeam, "priv/credential_live/claude-dead.json")
      },
      rails_file: "settings.json",
      rails: %{"hooks" => %{"PreToolUse" => []}},
      skills_path: Path.join([".claude", "skills"]),
      # A subscription contributes NO credential env: the harness reads its own
      # `.credentials.json` out of the home and refreshes it there.
      local_extra_env: %{
        subscription: [],
        api_key: [{"ANTHROPIC_API_KEY", "vector-token"}]
      },
      rails_env: nil,
      remote_prefix: fn base, home, kind ->
        case kind do
          :subscription ->
            ["CLAUDE_CONFIG_DIR=#{home}"]

          :api_key ->
            [
              "#{credential_env_var(kind)}=$(cat #{Path.join([base, "auth", "claude", @credential_file])} 2>/dev/null)",
              "CLAUDE_CONFIG_DIR=#{home}"
            ]
        end
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
        "valid" =>
          {:ok, [valid_entry],
           %{manifest_health: :fresh, claude_code_version: "1.0.0", version_blocks: []}},
        "valid_api_key" =>
          {:ok, [valid_entry],
           %{manifest_health: :fresh, claude_code_version: "1.0.0", version_blocks: []}},
        "malformed" => {:error, {:manifest_provider_absent, "claude"}},
        "unavailable" => {:error, :unavailable}
      },
      catalog_state: fn case_name, base ->
        token = Path.join([base, "auth", "claude", @credential_file])
        File.mkdir_p!(Path.dirname(token))
        kind = if(case_name == "valid_api_key", do: :api_key, else: :subscription)

        credential =
          case kind do
            :api_key ->
              "vector-token"

            :subscription ->
              JSON.encode!(%{"claudeAiOauth" => %{"accessToken" => "vector-token"}})
          end

        File.write!(token, credential)

        provider = %{
          "profiles" => %{
            "vector" => %{
              "efforts" => ["low"],
              "defaultContext" => "1k",
              "contextWindowTokens" => %{"1k" => 1_000},
              "adapter" => %{"claudeCode" => %{"contextSuffix" => %{}}}
            }
          },
          "models" => [
            %{
              "slug" => "claude-vector",
              "name" => "Claude Vector",
              "aliases" => [],
              "status" => "current",
              "profile" => "vector",
              "adapter" => %{"claudeCode" => %{"minVersion" => "1.0.0"}}
            }
          ]
        }

        manifest = fn ->
          case case_name do
            name when name in ["valid", "valid_api_key"] ->
              %{document: %{"providers" => %{"claude" => provider}}, health: :fresh}

            "malformed" ->
              %{document: %{}, health: {:unavailable, :malformed}}

            "unavailable" ->
              {:error, :unavailable}
          end
        end

        %{
          base_dir: base,
          credential_kind: kind,
          options: %{model_manifest: manifest, claude_code_version: "1.0.0"}
        }
      end,
      wire_projection: %{
        "id" => "claude",
        "wire_name" => "claude",
        "install_package" => "@agentclientprotocol/claude-agent-acp",
        "cli_binary" => "claude",
        "process_markers" => ["claude-agent-acp"]
      }
    })
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
        "claude-agent-acp"
      ])
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
