defmodule Tightbeam.Harness.Codex do
  @moduledoc false
  @behaviour Tightbeam.Harness

  require Logger

  alias Tightbeam.Harness.Support
  alias Tightbeam.Model

  @adapter_version "1.1.4"
  @adapter_package "codex-acp"
  # Two routes, one per credential kind, because they are two different accounts'
  # worth of entitlement expressed two different ways.
  #
  # SUBSCRIPTION — recorded live 2026-07-28 against codex-cli 0.145.0. The
  # platform route is CLOSED to a ChatGPT token: 403, missing scope
  # `api.model.read`. Do not "fix" this to the obvious URL.
  @models_url "https://chatgpt.com/backend-api/codex/models"

  # API KEY — the platform route, which the subscription token was refused for by
  # name. Recorded 2026-07-28 with a deliberately invalid key: 401
  # `invalid_api_key`, an AUTHENTICATION failure, not the subscription token's
  # 403 authorization failure. That contrast is the evidence the route treats API
  # keys as first-class.
  #
  # VERIFIED WITH A VALID KEY 2026-07-28 (the #89 api-key exercise, throwaway
  # org): the route answered 200 with 125 bare ids in the platform shape
  # `derive_platform_entries/1` decodes, and codex-acp ran a real turn on
  # api-key auth (gpt-5.6-sol[medium]). What the exercise DISPROVED is that the
  # adapter accepts everything this route lists — see
  # `@adapter_selectable_models` below.
  @api_models_url "https://api.openai.com/v1/models"

  # Model values codex-acp @adapter_version accepts at `session/set_config_option
  # {configId: "model"}` — the API-KEY catalog is filtered to this set, because
  # the platform route lists the account's whole model universe and the adapter
  # accepts almost none of it.
  #
  # RECORDED LIVE 2026-07-28 (the #89 api-key exercise, throwaway org,
  # codex-acp 1.1.4): GET /v1/models answered 125 bare ids; the adapter REFUSED
  # the platform id `gpt-5.1-codex` with -32602 Invalid params, and ACCEPTED
  # `gpt-5.6-sol`, which ran a real turn (effort medium) on the same adapter and
  # auth. `gpt-5.1-codex` is spelled exactly like a codex slug and was refused
  # anyway, so a platform id is NOT translatable into the adapter's vocabulary
  # by any mapping this repo can compute from spelling — substituting a
  # near-miss would be the silent-downgrade `harness/claude.ex` refuses. Hence a
  # FILTER to the demonstrably-selectable set, claude's `@adapter_selectable_models`
  # precedent exactly.
  #
  # Injectable (`codex_selectable_models` in the catalog's options, `:all` to
  # disable): the accepted set is the ADAPTER VERSION's, and an operator on a
  # newer adapter — or with acceptance evidence for more slugs — must be able to
  # widen it without editing code.
  #
  # WHEN THIS ROTS (a new codex model ships, or an accepted slug stops being
  # accepted): re-probe codex-acp rather than editing from a changelog — boot
  # the adapter, `initialize`, `session/new`, then confirm each candidate with
  # `session/set_config_option {configId: "model"}`. Update this table and
  # `@adapter_version` together.
  @adapter_selectable_models ~w(gpt-5.6-sol)

  # The gate probe's own model, as fields — it crosses the adapter seam like any
  # other selection.
  @probe_model %Tightbeam.Model{family: "gpt-5.6-sol", effort: "medium", context: nil}

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

  @doc """
  Model values this adapter version accepts at `session/set_config_option`.

  Narrower than the platform-derived api-key catalog — see the note above the
  attribute. Anything outside this list is refused by the adapter; it is never
  silently substituted.
  """
  def adapter_selectable_models, do: @adapter_selectable_models

  @impl true
  def id, do: :codex

  @impl true
  def wire_name, do: "codex"

  @impl true
  def credential_provider, do: :openai

  @impl true
  def credential_env_vars, do: []

  @impl true
  def default_model, do: Tightbeam.Model.new("gpt-5.6-sol", effort: "medium")

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
    # Two different questions. `rails?` — is a PreToolUse map projected at all —
    # decides the trust seed, and is now always true because the substrate's own
    # observation entry rides in that map; seeding an env var costs nothing and
    # can fail nothing. `statutes?` — is there org LAW — decides the wiring-check
    # probe, which FAILS THE BOOT when hooks are not arming. Only a denial is
    # worth refusing to boot over; an observation that silently degrades to a
    # weaker evidence class is not, and gating the probe on the map would have
    # turned a hook-trust regression into a dead adapter for orgs with no law.
    rails? = Keyword.fetch!(opts, :rails) != nil
    statutes? = Keyword.fetch!(opts, :statutes)

    probe =
      if statutes? do
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

        [probe_cwd: probe_cwd, probe_model: @probe_model]
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
      effort_config: "reasoning_effort",
      resident_model_switch: :in_place,
      model_option_aliases: %{},
      canonical_model_prefixes: ["gpt-"]
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
    script = liveness_script(Keyword.fetch!(opts, :credential_kind))
    request = %{command: ["node", "--no-warnings", "-e", script, Path.join(home, "auth.json")]}
    Support.credential_live_result(target, request, opts)
  end

  # The cheapest authenticated call each kind CAN make. A subscription cannot
  # reach the platform route (403, missing `api.model.read`) and an API key
  # cannot reach the ChatGPT account route, so there is no single probe that
  # serves both — liveness is kind-shaped all the way down. This is what
  # docs/SMOKE.md P2 promises; the two must move together.
  defp liveness_script(:subscription) do
    """
    const fs = require("node:fs");
    const auth = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    fetch("https://chatgpt.com/backend-api/wham/accounts/check", {
      headers: {
        "Authorization": `Bearer ${auth.tokens.access_token}`,
        "ChatGPT-Account-ID": auth.tokens.account_id,
        "User-Agent": "codex_cli_rs/0.145.0"
      }
    })#{liveness_tail()}
    """
  end

  defp liveness_script(:api_key) do
    """
    const fs = require("node:fs");
    const auth = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    fetch("#{@api_models_url}", {
      headers: {
        "Authorization": `Bearer ${auth.OPENAI_API_KEY}`,
        "User-Agent": "codex_cli_rs/0.145.0"
      }
    })#{liveness_tail()}
    """
  end

  defp liveness_tail do
    """
    .then(async response => {
      process.stdout.write(JSON.stringify({
        status: response.status,
        headers: {"content-type": response.headers.get("content-type")},
        body: await response.text()
      }));
    }).catch(error => {
      // Same defect as claude.ex's probe, fixed the same way: undici leaves `code`
      // undefined on a fetch rejection and puts the real reason in `error.cause`, so
      // `error.code || error.message` reported "fetch failed" for every transport
      // failure and named none of them.
      const cause = error.cause;
      process.stderr.write(
        [cause && cause.code, cause && cause.message, error.code, error.message]
          .filter(Boolean)
          .join(": ") || "unknown transport failure"
      );
      process.exitCode = 70;
    });
    """
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
    kind = Map.fetch!(state, :credential_kind)

    case probe(state, kind) do
      {:ok, body, trailer} ->
        with {:ok, models} <- decode_catalog(kind, body),
             {:ok, entries} <- derive_catalog_entries(kind, models),
             entries <- keep_selectable(entries, selectable_models(state, kind)),
             entries when entries != [] <- entries do
          {:ok, entries}
        else
          {:error, reason} -> {:error, reason}
          [] -> {:error, empty_catalog_reason(kind, trailer)}
          _ -> {:error, :malformed_catalog}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An empty answer means two different things on the two routes, and saying the
  # wrong one sends the operator after the wrong fix. Only the account route
  # filters by client version (see `probe_script/2`); the platform route has no
  # such filter, so blaming a version there would be a fabricated diagnosis.
  defp empty_catalog_reason(:subscription, trailer),
    do: {:empty_catalog_for_client_version, client_version(trailer)}

  defp empty_catalog_reason(:api_key, _trailer), do: :empty_inventory

  defp probe(state, kind) do
    sh = Map.get(state.options, :sh, &Support.system_cmd_out/1)
    auth = Path.join([state.base_dir, "auth", "codex", "auth.json"])

    sh
    |> Support.catalog_probe(
      Support.catalog_probe_argv(
        Map.get(state, :host_config, %{ssh: nil}).ssh,
        probe_script(kind, auth)
      )
    )
    |> classify_extraction(kind, auth)
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
  defp classify_extraction({:error, {:probe_failed, 66, _output}}, _kind, auth),
    do: {:error, {:missing_credential, auth}}

  # 75 is structurally near-impossible on an api-key host, and the branch stays
  # anyway. A torn read needs a concurrent in-place REWRITER, and an API key has
  # none: it is static, with no refresh and no single-writer constraint — the
  # same fact that removes codex's shared-runtime anchor on such a host. A
  # hand-run `codex login` is still a writer, so the state stays reachable and
  # stays retryable.
  defp classify_extraction({:error, {:probe_failed, 75, _output}}, _kind, _auth),
    do: {:error, {:credential_read_torn, :retry_next_refresh}}

  # The 67 reason names the field the host was supposed to hold. An api-key host
  # has no `access_token` to be missing, and saying it did would send the
  # operator hunting the wrong key in the right file.
  defp classify_extraction({:error, {:probe_failed, 67, _output}}, :subscription, auth),
    do: {:error, {:credential_missing_access_token, auth}}

  defp classify_extraction({:error, {:probe_failed, 67, _output}}, :api_key, auth),
    do: {:error, {:credential_missing_api_key, auth}}

  defp classify_extraction(result, _kind, _auth), do: result

  # `client_version` is a SILENT filter ON THIS BRANCH ONLY: every model carries
  # a `minimal_client_version` and the account route drops the ones the caller is
  # too old for — returning 200 with an EMPTY list, not an error. So the version
  # must be the one the `codex` binary on THAT host reports (it is an operator
  # prerequisite there, #76). A constant in our source would filter the catalog
  # to nothing and blame the account. It rides back on the status line so the
  # refusal can name the version that produced an empty answer. The platform
  # route has no such filter — see the api-key clause below.
  defp probe_script(:subscription, auth_path) do
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

  # No `codex --version` here, and no trailer: `client_version` is the ACCOUNT
  # route's silent filter and the platform route does not have it. Asking the
  # host for a version it will not use would turn "codex is not on this PATH"
  # into a catalog failure.
  #
  # The key comes from `auth.json`'s own `OPENAI_API_KEY` — the native field
  # codex writes and reads in api-key mode, null under a subscription. Same
  # sysexits contract as the subscription branch (66 no readable file, 75 torn,
  # 67 parsed but no usable key), so the three states stay apart here too; an
  # api-key host must not be the one place a torn read reports as a bad
  # credential. As on the other branch the credential is expanded by the REMOTE
  # shell and never appears in a command line on either machine.
  defp probe_script(:api_key, auth_path) do
    node_program =
      ~s|const fs=require("fs");let raw;| <>
        ~s|try{raw=fs.readFileSync("#{auth_path}","utf8")}catch(e){process.exit(66)}| <>
        ~s|let d;try{d=JSON.parse(raw)}catch(e){process.exit(75)}| <>
        ~s|const k=d?d.OPENAI_API_KEY:undefined;| <>
        ~s|if(!(typeof k==="string"&&k.length)){process.exit(67)}process.stdout.write(k)|

    curl = Support.catalog_curl(@api_models_url, [~s|authorization: Bearer $token|])

    """
    exec 2>&1
    set -eu
    token=$(node -e '#{node_program}')
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
      family: "codex-vector",
      context: nil,
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
      # Identical under both kinds on purpose: codex reads its credential out of
      # auth.json itself, so its launch plan does not vary by kind. The vector
      # exists to keep that true.
      local_extra_env: %{subscription: [], api_key: []},
      rails_env: {"CODEX_CONFIG", ~s({"bypass_hook_trust":true})},
      remote_prefix: fn _base, home, _kind -> ["CODEX_HOME=#{home}"] end,
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
        # A DIFFERENT route answering in a DIFFERENT shape, so a different
        # derivation: bare id, no effort tiers, no context window — everything
        # the platform route does not tell us. See `derive_platform_entries/1`.
        "valid_api_key" =>
          {:ok,
           [
             %{
               family: "codex-vector",
               context: nil,
               display_name: "codex-vector",
               name: "codex-vector",
               efforts: [],
               max_input_tokens: nil,
               capabilities: %{},
               provider: :openai
             }
           ]},
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
        sh = fn command ->
          script = Enum.join(command, " ")

          case case_name do
            "valid" ->
              {body <> "\n200 0.145.0", 0}

            # Asserting the SCRIPT, not just the parse: this case exists to pin
            # the route and the credential field, and a stand-in that answered
            # regardless would pass while the probe called the wrong endpoint.
            "valid_api_key" ->
              unless String.contains?(script, "api.openai.com/v1/models") do
                raise "codex api-key probe did not call the platform route: #{script}"
              end

              unless String.contains?(script, "OPENAI_API_KEY") do
                raise "codex api-key probe did not read the native api-key field: #{script}"
              end

              if String.contains?(script, "codex --version") do
                raise "codex api-key probe asked for a client_version the route ignores"
              end

              {~s({"data":[{"id":"codex-vector","object":"model"}]}) <> "\n200", 0}

            "malformed" ->
              {"{}\n200 0.145.0", 0}

            "unavailable" ->
              {~s({"detail":"Could not parse your authentication token. Please try signing in again."}) <>
                 "\n401 0.145.0", 0}
          end
        end

        # The vector's subject is catalog DERIVATION — route, credential field,
        # shape — using a synthetic model id. The selectable pin is a separate
        # concern with its own tests, so it is disabled here; leaving it on
        # would filter the synthetic id out and fail the case for the wrong
        # reason.
        %{
          base_dir: base,
          credential_kind: if(case_name == "valid_api_key", do: :api_key, else: :subscription),
          options: %{sh: sh, codex_selectable_models: :all}
        }
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

  defp decode_catalog(kind, body) when is_binary(body) do
    envelope = catalog_envelope(kind)

    case JSON.decode(body) do
      {:ok, %{^envelope => models}} when is_list(models) -> {:ok, models}
      {:ok, _} -> {:error, :malformed_catalog}
      {:error, _} -> {:error, :malformed_json}
    end
  end

  defp decode_catalog(_kind, _body), do: {:error, :malformed_catalog}

  defp catalog_envelope(:subscription), do: "models"
  defp catalog_envelope(:api_key), do: "data"

  defp derive_catalog_entries(:subscription, models), do: derive_account_entries(models)
  defp derive_catalog_entries(:api_key, models), do: derive_platform_entries(models)

  defp derive_account_entries(models) do
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
          {:cont, {:ok, entries ++ [entry_for(model, slug, efforts, capabilities)]}}
        else
          {:halt, {:error, :malformed_catalog}}
        end

      _, _ ->
        {:halt, {:error, :malformed_catalog}}
    end)
  end

  # ONE entry per vendor model, carrying the efforts it offers.
  defp entry_for(model, id, efforts, capabilities) do
    identity = Model.parse_ref(id)
    display_name = model["display_name"] || id

    %{
      family: identity.family,
      context: identity.context,
      display_name: display_name,
      name: display_name,
      efforts: efforts,
      max_input_tokens: model["max_input_tokens"] || model["context_window"],
      capabilities: capabilities,
      provider: :openai
    }
  end

  # The platform route answers in the PLATFORM's shape, not the codex account
  # route's: `{"data": [{"id": …, "object": "model", …}]}`. No display name, no
  # `supported_reasoning_levels`, no context window. So this is a SECOND
  # derivation, not a second decoder feeding one, and the catalog it produces is
  # honestly thinner: bare ids, no effort tiers, no token ceiling. A session on
  # such a catalog reports `canChangeReasoning: false`, which is correct —
  # nothing here knows what efforts the model offers, and inventing tiers would
  # advertise a control that does not work.
  #
  # OBSERVED LIVE 2026-07-28 (the #89 api-key exercise): 125 entries in exactly
  # this shape, bare ids under "data".
  defp derive_platform_entries(models) do
    Enum.reduce_while(models, {:ok, []}, fn
      %{"id" => id}, {:ok, entries} when is_binary(id) and id != "" ->
        {:cont,
         {:ok,
          entries ++
            [
              %{
                family: id,
                context: nil,
                display_name: id,
                name: id,
                efforts: [],
                max_input_tokens: nil,
                capabilities: %{},
                provider: :openai
              }
            ]}}

      _model, _entries ->
        {:halt, {:error, :malformed_catalog}}
    end)
  end

  # The catalog must not advertise what the adapter will refuse (#99, the #41
  # problem's codex/api-key edition). The platform route returns the whole
  # account's model universe — 125 ids observed live 2026-07-28 — and codex-acp
  # refuses almost all of it at `session/set_config_option` (-32602 for
  # `gpt-5.1-codex`, recorded on the same adapter+auth that accepted and ran
  # `gpt-5.6-sol`). So the api-key kind defaults to the pinned
  # `@adapter_selectable_models` set — a PURE FILTER over the already-derived
  # entries, claude's precedent exactly: no probe, no extra fetch, nothing at
  # boot, and never a substitution.
  #
  # The SUBSCRIPTION kind stays unfiltered: its catalog comes from the account
  # route the CLI itself consults, so the two vocabularies share one source
  # there. That claim is now kind-scoped — it was once believed to cover codex
  # wholesale (see the note on claude's `@adapter_selectable_models`), and the
  # api-key exercise disproved it for the platform route.
  #
  # Injectable through the same `state.options` seam claude's pin uses
  # (`:all` disables): the accepted set is the adapter version's, and a test
  # must be able to exercise derivation without coupling to the table.
  defp selectable_models(state, :subscription),
    do: Map.get(state.options, :codex_selectable_models, :all)

  defp selectable_models(state, :api_key),
    do: Map.get(state.options, :codex_selectable_models, @adapter_selectable_models)

  defp keep_selectable(entries, :all), do: entries

  defp keep_selectable(entries, selectable) do
    {kept, dropped} =
      Enum.split_with(entries, &(vendor_ref(&1) in selectable))

    if dropped != [] do
      Logger.info(
        "codex catalog: #{length(dropped)} model(s) the platform lists are not selectable by " <>
          "codex-acp #{@adapter_version} and were withheld: " <>
          Enum.map_join(dropped, ", ", &vendor_ref/1) <>
          " — re-probe @adapter_selectable_models in harness/codex.ex if this looks wrong"
      )
    end

    kept
  end

  defp vendor_ref(entry),
    do: Model.to_ref(Model.new(entry.family, context: entry.context))

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
