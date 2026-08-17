defmodule Tightbeam.Harness.Claude do
  @moduledoc false
  @behaviour Tightbeam.Harness

  alias Tightbeam.Harness.Support
  alias Tightbeam.Model

  require Logger

  @adapter_version "0.66.0"
  @adapter_package "claude-agent-acp"
  @adapter_bundle "acp-agent.js"
  @warm_timeout_ms 30_000
  @credential_env_vars %{
    subscription: "CLAUDE_CODE_OAUTH_TOKEN",
    api_key: "ANTHROPIC_API_KEY"
  }

  @api_base "https://api.anthropic.com"

  # NOTE FOR FUTURE AGENTS — the claude model vocabulary is NARROWER than the catalog.
  #
  # The derived catalog for claude comes from the Anthropic API (`fetch_catalog/1` hits
  # `/v1/models`), which currently lists 11 models. The claude ACP adapter's
  # `session/set_config_option {configId: "model"}` accepts only TEN values, and the
  # adapter seam renders the identity verbatim — family plus the vendor's context variant,
  # with our effort on its own config option — so there is NO translation layer to fix. A model
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
  #   ACCEPTED  alias `fable` / id `claude-fable-5`  (re-measured 2026-08-05; July
  #             refusal was environmental — the projected-home pin offers it)
  #   ACCEPTED  id `claude-opus-5`  (re-measured 2026-08-06; the REJECTED row below
  #             measured the DEFAULT-PIN vocabulary, not the grant — a pin-probed
  #             home offered+accepted it and a live prompt answered as Opus 5)
  #   REJECTED  claude-opus-4-7, claude-sonnet-4-6, claude-opus-4-6,
  #             claude-opus-4-5-20251101, claude-sonnet-4-5-20250929,
  #             claude-opus-4-1-20250805
  #
  # The accepted ids were EXACTLY the models the aliases resolved to until the pin
  # lesson (fable, then opus-5) showed the offered set follows the HOME PIN. So
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
  # ON CODEX, kind-scoped: the shared-source argument holds only for the
  # SUBSCRIPTION kind, whose catalog comes from the same account endpoint the
  # CLI itself consults (codex.ex). The API-KEY kind derives from the platform
  # route — the account's whole model universe — and the 2026-07-28 api-key
  # exercise (#99) proved live that codex-acp refuses platform ids at
  # set_config_option (-32602 for `gpt-5.1-codex`) while accepting codex-native
  # slugs (`gpt-5.6-sol` ran a real turn). Codex's api-key catalog now carries
  # its own `@adapter_selectable_models` guard on this precedent.
  # RE-MEASURED 2026-08-05 on gibson (claude CLI 2.1.221, the production grant):
  # `claude -p --model claude-fable-5` answered a real prompt — the 2026-07-26
  # REJECTED row for fable was one environment's snapshot, not a property of the
  # account or the CLI (Flynn was literally talking to Fable while this table
  # said his account could not). The offered list is environment-dependent
  # (JOURNAL.md:804); the projected-home model pin (ops-hardening-v1 §3) is what
  # makes it deterministic. Keep re-probing per the note above before trusting
  # any row here, in either direction.
  # RE-MEASURED 2026-08-06 on gibson (adapter 0.59.0, the production grant):
  # a pin-probe home (settings.json model=claude-opus-5) OFFERED and ACCEPTED
  # claude-opus-5, and a live prompt through the production adapter+credential
  # answered as Opus 5 — the 2026-07-26 REJECTED row for opus-5 was, like
  # fable's, one environment's snapshot ("refused on this grant" measured a
  # default-pin vocabulary, not the grant; the operator's own picker offered
  # Opus 5 all along). Same lesson, second occurrence: re-probe from a second
  # vantage before trusting any row here, in either direction.
  # UPGRADED 2026-08-08 on gibson to claude-agent-acp 0.66.0 / SDK 0.3.220.
  # Its public picker still exposes aliases, but their meaning changed: opus[1m]
  # now identifies Opus 5. Tightbeam therefore tries a requested canonical id
  # first and treats this table only as fallback candidates. The selected
  # configOption's public currentValue plus init-derived name/description is the
  # switch-time authority; a real next-turn modelUsage probe is the release gate.

  @adapter_selectable_models ~w(default sonnet opus haiku fable claude-sonnet-5
                                claude-opus-4-8 claude-haiku-4-5-20251001 claude-fable-5
                                claude-opus-5)

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
  def credential_env_vars, do: @credential_env_vars |> Map.values() |> Enum.sort()

  @impl true
  def default_model, do: Tightbeam.Model.new("claude-sonnet-5", effort: "medium")

  @impl true
  def install_package, do: "@agentclientprotocol/claude-agent-acp"

  @impl true
  def adapter_provisioning, do: :npm

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
      "Your Tight Beam archetype identity arrives as this Claude system prompt. " <>
        "It is authoritative and outranks product CLAUDE.md instructions on conflict."

    guidance =
      if Map.get(session, :identity) == true and not String.starts_with?(guidance, prefix),
        do: prefix <> "\n\n" <> guidance,
        else: guidance

    # Candidate vocabulary only. Adapter readback, never this static map,
    # decides which canonical model an alias means in the running version.
    # Keeping the 0.59 mappings here preserves fallback on old satellites.

    %{
      guidance: guidance,
      meta: %{systemPrompt: %{type: "preset", preset: "claude_code", append: guidance}},
      permission_mode: "bypassPermissions",
      effort_config: "effort",
      resident_model_switch: :fork,
      model_option_aliases: %{
        "sonnet" => "claude-sonnet-5",
        "haiku" => "claude-haiku-4-5-20251001",
        "opus" => "claude-opus-4-8",
        "opus[1m]" => "claude-opus-4-8[1m]",
        "fable" => "claude-fable-5",
        "fable[1m]" => "claude-fable-5[1m]"
      },
      canonical_model_prefixes: ["claude-"]
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

  defp packed_model(%Model{family: family, context: nil}), do: family
  defp packed_model(%Model{family: family, context: context}), do: "#{family}[#{context}]"

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
         {:ok, credential} <- bearer_secret(kind, raw),
         true <- credential != "" do
      {:ok, fn path -> fetch.(path, catalog_headers(kind, credential)) end}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :missing_token}
    end
  end

  # The two kinds are two file FORMATS now, and anything sending this credential over the
  # wire has to know which it holds.
  #
  # A subscription is Claude Code's own `.credentials.json` -- an OAuth record it refreshes
  # in place -- so the bearer token is a field inside it. An API key is the bare secret and
  # the file is just its container. Sending the JSON blob as a bearer token is what a naive
  # read does, and the provider answers 401 "Invalid bearer token", which reads like a bad
  # credential rather than a bad reader.
  defp bearer_secret(:api_key, raw), do: {:ok, String.trim(raw)}

  defp bearer_secret(:subscription, raw) do
    case JSON.decode(raw) do
      {:ok, %{"claudeAiOauth" => %{"accessToken" => token}}} when is_binary(token) ->
        {:ok, String.trim(token)}

      _ ->
        {:error, :malformed_credential}
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

  # The tightbeam binary on the host that owns the credential. `assimilate` installs it and
  # the gateway already execs it there, so this names an existing artifact rather than
  # introducing one.
  defp cli_path(state), do: Path.join([state.base_dir, "bin", "tightbeam"])

  defp remote_getter(state, dest, credential_path, kind) do
    sh = Map.get(state.options, :sh, &Support.system_cmd_out/1)

    fn path ->
      # The script's own stderr is folded into its stdout so a failure carries a
      # reason; ssh's is NOT, because an ssh warning on a SUCCESSFUL connection
      # would land in the middle of the JSON body.
      # The CLI reads the credential, not this shell. It is already installed on every
      # assimilated host and the gateway already execs it there for `harness-group`, so
      # this is the same transport with the credential reader moved into the binary that
      # WROTE the file. What it replaced was a `python3` one-liner parsing a vendor JSON
      # shape -- a runtime dependency added to every satellite, and a third copy of an
      # extraction that already existed twice.
      script = """
      exec 2>&1
      set -eu
      exec #{Support.shell_quote(cli_path(state))} catalog-probe anthropic #{kind} \
        #{Support.shell_quote(credential_path)} #{Support.shell_quote("#{@api_base}#{path}")}
      """

      case Support.catalog_probe(sh, Support.catalog_probe_argv(dest, script)) do
        {:ok, body, _trailer} -> {:ok, body}
        {:error, reason} -> {:error, reason}
      end
    end
  end

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
  # What the adapter will actually accept, asked of the harness rather than remembered.
  #
  # The static list alone is a frozen snapshot of somebody's entitlements, and it starved:
  # the API stopped returning the concrete ids in it, so the intersection went empty and a
  # correctly onboarded claude reported ZERO models. The account's real extras -- a
  # 1M-context Opus, Fable -- live in the harness's own `additionalModelOptionsCache`, which
  # Claude Code fills from the server on first use. That is why onboarding warms the home:
  # cold, this reads nothing and the catalog is a subset; warmed, it reads what the account
  # actually has.
  #
  # The static aliases stay as the floor. They are SDK aliases rather than account
  # entitlements, so they are true for every account and cost nothing to keep.
  #
  # Remote homes are not read here -- that needs the ssh path -- so a satellite falls back to
  # the floor until someone teaches this to read over ssh. Stated rather than silent: the
  # symptom is a satellite offering fewer models than the gateway, not a failure.
  defp selectable_models(state) do
    case Map.get(state.options, :claude_selectable_models) do
      nil -> @adapter_selectable_models ++ home_offered_models(state)
      override -> override
    end
  end

  defp home_offered_models(%{host_config: %{ssh: ssh}}) when not is_nil(ssh), do: []

  defp home_offered_models(state) do
    home = Tightbeam.Homes.home_path(state.base_dir, state.host_name, id())

    with {:ok, body} <- File.read(Path.join(home, ".claude.json")),
         {:ok, %{"additionalModelOptionsCache" => options}} when is_list(options) <-
           JSON.decode(body) do
      options
      |> Enum.map(&Map.get(&1, "value"))
      |> Enum.filter(&is_binary/1)
    else
      _ -> []
    end
  end

  defp keep_selectable(entries, :all), do: entries

  defp keep_selectable(entries, selectable) do
    {kept, dropped} =
      Enum.split_with(entries, &(vendor_ref(&1) in selectable))

    if dropped != [] do
      Logger.info(
        "claude catalog: #{length(dropped)} model(s) the API offers are not selectable by " <>
          "claude-agent-acp #{@adapter_version} and were withheld: " <>
          Enum.map_join(dropped, ", ", &vendor_ref/1) <>
          " — if an expected model is here, the harness home has not been used yet and its " <>
          "model cache is empty; onboarding warms it, and first use fills it"
      )
    end

    kept
  end

  defp vendor_ref(entry),
    do: Model.to_ref(Model.new(entry.family, context: entry.context))

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
      capabilities: %{"effort" => %{"low" => %{"supported" => true}}},
      provider: :anthropic
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
        "valid" => {:ok, [valid_entry]},
        # Same route and same response shape for both kinds, so the api-key case
        # derives the same entry. What it exists to pin is the HEADER, which the
        # fetch stand-in below asserts.
        "valid_api_key" => {:ok, [valid_entry]},
        "malformed" => {:error, :malformed_catalog},
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
          headers = Map.new(headers, fn {name, value} -> {to_string(name), to_string(value)} end)

          {expected, value} =
            if case_name == "valid_api_key",
              do: {"x-api-key", "vector-token"},
              else: {"authorization", "Bearer vector-token"}

          if headers[expected] != value do
            raise "claude catalog probe sent #{inspect(headers)}, expected #{expected}: #{value}"
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
          credential_kind: kind,
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
            {:cont, {:ok, entries ++ [entry_for(model, id, effort_names, capabilities)]}}

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

  # ONE entry per vendor model, carrying the efforts it offers. The vendor's id
  # may itself name a context variant (`claude-fable-5[1m]`), which is parsed
  # into its own field here rather than being mistaken for one of our efforts.
  defp entry_for(model, id, effort_names, capabilities) do
    identity = Model.parse_ref(id)
    display_name = model["display_name"] || id

    %{
      family: identity.family,
      context: identity.context,
      display_name: display_name,
      name: display_name,
      efforts: effort_names,
      max_input_tokens: model["max_input_tokens"],
      capabilities: capabilities,
      provider: :anthropic
    }
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
