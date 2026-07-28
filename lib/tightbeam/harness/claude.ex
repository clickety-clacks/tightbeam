defmodule Tightbeam.Harness.Claude do
  @moduledoc false
  @behaviour Tightbeam.Harness

  alias Tightbeam.Harness.Support

  require Logger

  @adapter_version "0.59.0"
  @adapter_package "claude-agent-acp"
  @adapter_bundle "acp-agent.js"

  @api_base "https://api.anthropic.com"

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
  # together.
  #
  # ALSO GRANT- AND HOME-DEPENDENT, not only version-dependent. A smoke run recorded
  # opus-5 and fable-5 "refused on this grant", and JOURNAL.md:804 records the offered
  # list changing with the home's `settings.json` and the session cwd. So this table
  # pins THREE things at once, and a different account may legitimately accept more.
  # That is why the set is injectable (`claude_selectable_models` in the catalog's
  # options, `:all` to disable) rather than only editable here.
  #
  # ON CODEX, qualified: codex's catalog comes from the same account endpoint the
  # CLI itself consults, filtered by that CLI's own version (codex.ex), so its two
  # vocabularies share one source and divergence is structurally unlikely. But
  # acceptance still happens in the external
  # ACP/CLI process (`acp/adapter.ex` set_config_option), which this repo does not
  # observe, so "cannot diverge" is NOT proven here — it is unprobed analysis. Nobody
  # has run the equivalent probe against codex-acp.
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

  @impl true
  def prepare_launch(target, home, opts) do
    binary = adapter_binary(target)
    common = Keyword.fetch!(opts, :common_env)
    variable = credential_env_var(Keyword.fetch!(opts, :credential_kind))
    credential_path = credential_path(target.host_config.base_dir)

    if Support.local?(target) do
      credential_env =
        case File.read(credential_path) do
          {:ok, credential} -> [{variable, String.trim(credential)}]
          _ -> []
        end

      [cmd: [binary], env: [{"CLAUDE_CONFIG_DIR", home} | common ++ credential_env]]
    else
      remote_env =
        [
          "#{variable}=$(cat #{credential_path} 2>/dev/null)",
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

  # Claude takes its credential from the environment, and the VARIABLE NAMES THE
  # KIND: a setup-token in ANTHROPIC_API_KEY is rejected, and an API key in
  # CLAUDE_CODE_OAUTH_TOKEN is rejected. Exactly one is ever set -- never both,
  # never an empty one -- so a wrong kind fails as an authentication error naming
  # the credential rather than as a precedence puzzle between two variables.
  #
  # `fetch!` and no default: a launch that cannot say which kind it is launching
  # is a programming error, and defaulting it would quietly run part of the fleet
  # on the wrong variable.
  defp credential_env_var(:subscription), do: "CLAUDE_CODE_OAUTH_TOKEN"
  defp credential_env_var(:api_key), do: "ANTHROPIC_API_KEY"

  # ONE file per provider, holding whichever kind is active. The name is
  # historical -- it predates API-key support -- and is deliberately NOT read as
  # evidence of the kind by anything: `credential.json` is the authority.
  defp credential_path(base_dir), do: Path.join([base_dir, "auth", "claude", "oauth-token"])

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
    {header, scheme} = credential_header(Keyword.fetch!(opts, :credential_kind))

    script = """
    const fs = require("node:fs");
    const credential = fs.readFileSync(process.argv[1], "utf8").trim();
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
      process.stderr.write(error.code || error.message);
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
        Path.join(home, "oauth-token"),
        header,
        scheme
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
    with {:ok, get} <- catalog_getter(state),
         {:ok, body} <- get.("/v1/models?limit=100"),
         {:ok, models} <- decode_catalog(body),
         {:ok, models} <- fill_capabilities(models, get),
         {:ok, entries} <- derive_catalog_entries(models),
         entries <- keep_selectable(entries, selectable_models(state)),
         entries when entries != [] <- entries do
      {:ok, entries}
    else
      {:error, reason} -> {:error, reason}
      [] -> {:error, :empty_inventory}
      _ -> {:error, :malformed_catalog}
    end
  end

  # A catalog is an account's entitlements, so it is derived on the host whose
  # account it describes. This is a plain vendor HTTPS GET with a bearer token
  # read off local disk — NOT an ACP or harness surface — which is exactly why
  # it can run remotely at all.
  #
  # Local: read the token, call the API from here. Remote: one bounded ssh whose
  # script reads the token with `$(cat …)` in the REMOTE shell, the same pattern
  # turn launch uses (`prepare_launch/3`). No token byte is interpolated into any
  # command line, so none appears in a process table on either machine, and no
  # credential moves between them — only the model list comes back.
  defp catalog_getter(state) do
    kind = Map.fetch!(state, :credential_kind)
    credential_path = credential_path(state.base_dir)

    case Map.get(state, :host_config, %{ssh: nil}).ssh do
      nil -> local_getter(state, credential_path, kind)
      dest -> {:ok, remote_getter(state, dest, credential_path, kind)}
    end
  end

  defp local_getter(state, credential_path, kind) do
    fetch = Map.get(state.options, :claude_fetch, &http_get/2)

    with {:ok, raw} <- read_token(credential_path),
         credential = String.trim(raw),
         true <- credential != "" do
      {:ok, fn path -> fetch.(path, catalog_headers(kind, credential)) end}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :missing_token}
    end
  end

  # Both kinds read the SAME route; only the header differs. Recorded live
  # 2026-07-28 with deliberately invalid credentials, which is what pins the two
  # names apart: `x-api-key` answers 401 "API key is invalid." while
  # `Authorization: Bearer` answers 401 "Invalid bearer token" -- two distinct
  # code paths on one route, so the header is not interchangeable.
  #
  # Charlists because this is httpc's header shape, not ours.
  defp catalog_headers(:subscription, credential) do
    [
      {~c"authorization", String.to_charlist("Bearer " <> credential)},
      {~c"anthropic-version", ~c"2023-06-01"}
    ]
  end

  defp catalog_headers(:api_key, credential) do
    [
      {~c"x-api-key", String.to_charlist(credential)},
      {~c"anthropic-version", ~c"2023-06-01"}
    ]
  end

  defp remote_getter(state, dest, credential_path, kind) do
    sh = Map.get(state.options, :sh, &Support.system_cmd_out/1)

    fn path ->
      # The script's own stderr is folded into its stdout so a failure carries a
      # reason; ssh's is NOT, because an ssh warning on a SUCCESSFUL connection
      # would land in the middle of the JSON body.
      script = """
      exec 2>&1
      set -eu
      credential=$(cat #{credential_path})
      exec #{Support.catalog_curl("#{@api_base}#{path}", curl_headers(kind))}
      """

      case Support.catalog_probe(sh, Support.catalog_probe_argv(dest, script)) do
        {:ok, body, _trailer} -> {:ok, body}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # `$credential` is expanded by the REMOTE shell, so no credential byte is
  # interpolated into a command line on either machine -- the property the
  # subscription probe already had, kept for the API key, which is equally a
  # secret.
  defp curl_headers(:subscription),
    do: ["authorization: Bearer $credential", "anthropic-version: 2023-06-01"]

  defp curl_headers(:api_key),
    do: ["x-api-key: $credential", "anthropic-version: 2023-06-01"]

  # The catalog must not advertise what the adapter will refuse. A PURE FILTER over
  # the already-derived entries — no probe, no extra fetch, nothing at boot; the
  # journal records this path being reverted once for adding live I/O, so it stays
  # a filter. Effort suffixes are preserved: only the base ref is matched.
  #
  # This is a PIN, and it pins three things at once — the CLI version, the grant
  # (a smoke run recorded opus-5 "refused on this grant"), and any model pins in
  # the projected home's settings.json. When claude ships a version that accepts
  # more, or a different grant offers more, THE TABLE is what to re-probe and
  # update; nothing here discovers it. See the note on @adapter_selectable_models.
  # Injectable through the same `state.options` seam as claude_fetch/codex_read/
  # credential_status, for two reasons: a test must be able to exercise catalog
  # derivation without being coupled to this table, and an operator on a DIFFERENT
  # GRANT (the accepted set is grant-dependent — a smoke run recorded opus-5
  # "refused on this grant") must be able to lift the ceiling without editing code.
  # `:all` disables the filter entirely.
  defp selectable_models(state),
    do: Map.get(state.options, :claude_selectable_models, @adapter_selectable_models)

  defp keep_selectable(entries, :all), do: entries

  defp keep_selectable(entries, selectable) do
    {kept, dropped} =
      Enum.split_with(entries, fn entry ->
        entry.ref |> base_ref() |> Kernel.in(selectable)
      end)

    if dropped != [] do
      Logger.info(
        "claude catalog: #{length(dropped)} model(s) the API offers are not selectable by " <>
          "claude-agent-acp #{@adapter_version} and were withheld: " <>
          Enum.map_join(dropped, ", ", & &1.ref) <>
          " — re-probe @adapter_selectable_models in harness/claude.ex if this looks wrong"
      )
    end

    kept
  end

  defp base_ref(ref) do
    case Regex.run(~r/^(.*?)\[(.*?)\]$/, ref) do
      [_, base, _effort] -> base
      _ -> ref
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
      local_extra_env: %{
        subscription: [{"CLAUDE_CODE_OAUTH_TOKEN", "vector-token"}],
        api_key: [{"ANTHROPIC_API_KEY", "vector-token"}]
      },
      rails_env: nil,
      remote_prefix: fn base, home, kind ->
        [
          "#{credential_env_var(kind)}=$(cat #{Path.join([base, "auth", "claude", "oauth-token"])} 2>/dev/null)",
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
        # Same route and same response shape for both kinds, so the api-key case
        # derives the same entry. What it exists to pin is the HEADER, which the
        # fetch stand-in below asserts.
        "valid_api_key" => {:ok, [valid_entry]},
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

        # The stand-in asserts the header it was called with, so a case cannot
        # pass while sending the other kind's.
        fetch = fn _path, headers ->
          names = Enum.map(headers, fn {name, _value} -> to_string(name) end)
          expected = if case_name == "valid_api_key", do: "x-api-key", else: "authorization"

          if expected not in names do
            raise "claude catalog probe sent #{inspect(names)}, expected #{expected}"
          end

          case case_name do
            "valid" -> {:ok, body}
            "valid_api_key" -> {:ok, body}
            "malformed" -> {:ok, "{}"}
            "unavailable" -> {:error, :unavailable}
          end
        end

        # The vector's subject is catalog DERIVATION — provider stamping and the
        # exact source error — using a synthetic model id. The selectable pin is a
        # separate concern with its own tests, so it is disabled here; leaving it on
        # would filter `claude-vector` away and turn a derivation vector into a test
        # of the table.
        %{
          base_dir: base,
          credential_kind: if(case_name == "valid_api_key", do: :api_key, else: :subscription),
          options: %{claude_fetch: fetch, claude_selectable_models: :all}
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

  defp decode_catalog(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{"data" => models}} when is_list(models) -> {:ok, models}
      {:ok, _} -> {:error, :malformed_catalog}
      {:error, _} -> {:error, :malformed_json}
    end
  end

  defp decode_catalog(_body), do: {:error, :malformed_catalog}

  # Reads the active credential of EITHER kind. The name and its two reasons are
  # load-bearing -- doctor and the catalog tests match on them -- so they stay.
  defp read_token(path) do
    case File.read(path) do
      {:ok, token} -> {:ok, token}
      {:error, :enoent} -> {:error, :missing_token}
      {:error, reason} -> {:error, {:token_read_failed, reason}}
    end
  end

  defp fill_capabilities(models, get) do
    Enum.reduce_while(models, {:ok, []}, fn model, {:ok, acc} ->
      if is_map(get_in(model, ["capabilities", "effort"])) do
        {:cont, {:ok, [model | acc]}}
      else
        case model["id"] do
          id when is_binary(id) ->
            path = "/v1/models/" <> URI.encode(id, &URI.char_unreserved?/1)

            with {:ok, body} <- get.(path),
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
    url = String.to_charlist(@api_base <> path)

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    # One ceiling either side of the ssh seam, so a wedged vendor endpoint costs
    # the same locally as remotely and never strands a refresh in flight.
    timeout = Support.catalog_probe_timeout_s() * 1_000

    case :httpc.request(:get, {url, headers}, [ssl: ssl, timeout: timeout], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _response_headers, body}} when status in 200..299 ->
        {:ok, body}

      # The BODY, not just the code: a 401 here says the grant needs signing in
      # again, which is the sentence the operator acts on (#81's subject).
      {:ok, {{_version, status, _reason}, _response_headers, body}} ->
        {:error, {:http_status, status, String.trim(to_string(body))}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
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
