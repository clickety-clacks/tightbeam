defmodule Tightbeam.Harness.Claude do
  @moduledoc false
  @behaviour Tightbeam.Harness

  @credential_file ".credentials.json"

  alias Tightbeam.Harness.Support
  alias Tightbeam.Model

  @doc false
  @impl true
  def local_client_model_authority?(%Model{family: "claude-" <> _rest}), do: true
  def local_client_model_authority?(%Model{}), do: false

  @adapter_version "0.79.0"
  @adapter_package "claude-agent-acp"
  @adapter_bundle "acp-agent.js"
  @warm_timeout_ms 30_000
  @credential_env_vars %{
    subscription: "CLAUDE_CODE_OAUTH_TOKEN",
    api_key: "ANTHROPIC_API_KEY"
  }

  @api_base "https://api.anthropic.com"

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
    credential_path = Path.join(home, @credential_file)

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
  # own. The exact harness home is its only location.
  #
  # It is still deliberately NOT read as evidence of the kind -- `credential.json` is the
  # authority. A subscription credential is the OAuth record Claude Code refreshes in place;
  # an API key is a bare secret that never expires. Same path, different contents, and only
  # the subscription one is ever handed to the harness as a file.
  @impl true
  def ensure_adapter(target) do
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
      effort_config: "effort",
      resident_model_switch: :fork,
      canonical_model_prefixes: ["claude-"]
    }
  end

  @impl true
  def owned_home_entries,
    do: Support.owned_home_entries("settings.json")

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

    Tightbeam.Homes.reconcile(target, home, desired, rails_filename: "settings.json")
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
  def credential_ready?(target, home) do
    Tightbeam.Homes.credential_ready?(target, home, [@credential_file])
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
  def classify_auth_event(%{"authStatus" => %{"kind" => "none"}}), do: :terminal

  def classify_auth_event(%{"authStatus" => %{"kind" => kind}})
      when kind in ["account", "api_key", "gateway", "external"],
      do: :transient

  def classify_auth_event(_event), do: :unknown

  @impl true
  def classify_subagent_event(%{
        "sessionUpdate" => "subagent_spawned",
        "subagentSessionId" => subagent
      }) do
    {:subagent_start, %{source_event_ref: subagent, subagent_ref: subagent}}
  end

  def classify_subagent_event(%{
        "sessionUpdate" => "subagent_state_update",
        "subagentSessionId" => subagent,
        "state" => state
      })
      when state in ["completed", "failed", "cancelled", "disconnected"] do
    {:subagent_stop, %{source_event_ref: subagent, subagent_ref: subagent}}
  end

  def classify_subagent_event(_update), do: :skip

  @impl true
  def fetch_catalog(state) do
    with {:ok, get} <- catalog_getter(state),
         {:ok, body} <- get.("/v1/models?limit=100"),
         {:ok, models} <- decode_catalog(body),
         {:ok, models} <- fill_capabilities(models, get),
         {:ok, entries} <- derive_catalog_entries(models),
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

    credential_path =
      Tightbeam.Credentials.credential_path(
        state.base_dir,
        Map.get(state, :host_name, Tightbeam.Placement.local_host_name()),
        credential_provider()
      )

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

  @impl true
  def conformance_vectors do
    source = "stock claude adapter fixture"

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
      remote_prefix: fn _base, home, kind ->
        case kind do
          :subscription ->
            ["CLAUDE_CONFIG_DIR=#{home}"]

          :api_key ->
            [
              "#{credential_env_var(kind)}=$(cat #{Path.join(home, @credential_file)} 2>/dev/null)",
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
      patched: source,
      remote_patch_detail: "",
      stock_adapter: true,
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
          envelope: %{"authStatus" => %{"kind" => "none"}},
          expected: :terminal
        },
        %{case: "negative", envelope: %{"unrelated" => true}, expected: :unknown}
      ],
      subagent_events: [
        %{
          case: "positive_start",
          envelope: %{
            "sessionUpdate" => "subagent_spawned",
            "subagentSessionId" => "claude-child"
          },
          expected:
            {:subagent_start, %{source_event_ref: "claude-child", subagent_ref: "claude-child"}}
        },
        %{
          case: "positive_stop",
          envelope: %{
            "sessionUpdate" => "subagent_state_update",
            "subagentSessionId" => "claude-child",
            "state" => "completed"
          },
          expected:
            {:subagent_stop, %{source_event_ref: "claude-child", subagent_ref: "claude-child"}}
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
        token = Path.join([base, "homes", "vector", "claude", @credential_file])
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
          host_name: "vector",
          credential_kind: kind,
          options: %{claude_fetch: fetch}
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
      {:error, reason} -> {:error, {:malformed_json, reason}}
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
end
