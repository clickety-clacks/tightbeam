defmodule Tightbeam.Harness.Opencode do
  @moduledoc """
  OpenCode harness — a BINARY-NATIVE ACP harness driven as `opencode acp`.

  The one novelty versus claude/codex is provisioning: OpenCode is an operator-installed binary
  (`cli_binary/0`), not an npm package, so `adapter_provisioning/0` is `:shim` and
  `ensure_adapter/1` writes a shell shim (`Spinup.ensure_shim_adapter/4`) at the adapter path
  instead of npm-installing. Everything downstream — the rails FLOOR (process-group containment
  via `harness-exec`/`harness-group`, binary-agnostic), the launch path, the readiness `.bin`
  check — is inherited unchanged; a shimmed `opencode acp` sits on the identical rails floor.

  RAILS-CRITICAL LAUNCH INVARIANTS enforced here (see `prepare_launch/3`), structural where
  possible because a bypass of any is a rails hole:

    1. Tightbeam owns argv; NEVER `--pure`. `--pure`/`OPENCODE_PURE` empties the external-plugin
       list and drops the gate. The launch argv is `cmd: [shim]` with no extra token; the shim
       bakes in the `acp` subcommand; the only argv added downstream is the rails-exec wrapper +
       a stderr redirect. There is no code path by which `--pure` reaches the CLI.
    2. NEVER `serve`/`--port`/`--hostname`/`--mdns`. Those open an HTTP listener whose
       `POST /session/{id}/shell` route runs commands with NO model and BYPASSES the plugin gate.
       Production launch is `opencode acp`; the argv is held by the same construction as (1) — the
       shim is `exec opencode acp "$@"` and Tightbeam passes no argv.
    3. 0 LISTEN sockets asserted at spawn, fail-closed — enforced AUTOMATICALLY for the whole
       `:shim` class (`Harness.requires_zero_listeners?/1` gates on `adapter_provisioning`), in the
       shared launch seam (`Tightbeam.Acp.Adapter`, post-identity, pgid in hand). This is not
       merely defense-in-depth: `opencode acp` v1.18.18 was found to bind an ungated HTTP server on
       127.0.0.1:4096 (the `/session/{id}/shell` bypass surface), captured live — so the assertion
       currently REFUSES the launch, which is correct and gates go-live until the finding is
       adjudicated (EVIDENCE/RAILS-FINDING-acp-http-listener.md). Any LISTEN socket in the launched
       process group aborts the launch.

  GATE: `prepare_launch/3` points OpenCode at a Tightbeam-owned config (via `OPENCODE_CONFIG`)
  whose `plugin` array references the out-of-tree gate plugin (`priv/opencode_gate/`). The
  plugin's `@opencode-ai/plugin` `tool.execute.before` throw aborts a tool before it runs and
  emits the `[gate: tightbeam-probe]` marker the adapter watches for — the OpenCode analog of the
  codex/claude PreToolUse gate. This build wires + enforces the substrate-reserved wiring-check
  probe; full operator-statute parity is tracked follow-on (rails-parity / HB-05).
  """
  @behaviour Tightbeam.Harness

  alias Tightbeam.Harness.Support
  alias Tightbeam.Model

  # The operator-installed binary is versioned by the operator, not pinned/patched by us (there
  # is no adapter bundle to patch). Recorded for readiness/doctor display; re-probe per host.
  @adapter_version "1.18.18"

  # The gate plugin + its config are materialized out-of-tree under the host base_dir, a
  # directory the agent cannot edit. `prepare_launch/3` points OPENCODE_CONFIG at the config.
  @gate_dir "opencode-gate"
  @gate_config "opencode.json"
  @gate_plugin "tightbeam-gate.js"

  @credential_file "auth.json"
  @rails_file "opencode-rails.json"

  @doc false
  def adapter_version, do: @adapter_version

  @impl true
  def id, do: :opencode

  @impl true
  def wire_name, do: "opencode"

  @impl true
  def credential_provider, do: :opencode

  @impl true
  def credential_env_vars, do: []

  # TODO(HB-04, model-catalog): the OpenCode model vocabulary is `provider/model`
  # (e.g. OpenCode Zen / Kimi K3). The concrete default + selectable set is the catalog decision
  # tracked with `fetch_catalog/1`; this names a documented placeholder until that lands and is
  # not exercised while the harness is unregistered.
  @impl true
  def default_model, do: Model.new("opencode/zen", effort: "medium")

  # For a :shim harness `install_package/0` names the SHIM BINARY (its basename is the adapter
  # filename `adapters/node_modules/.bin/opencode`, where readiness already looks), not an npm
  # package. The shim execs the operator-installed `cli_binary/0`.
  @impl true
  def install_package, do: "opencode"

  @impl true
  def adapter_provisioning, do: :shim

  @impl true
  def cli_binary, do: "opencode"

  # The rails-critical 0-LISTEN assertion (invariant 3) is enforced AUTOMATICALLY for the whole
  # `:shim` class — safe-by-default, gated on `adapter_provisioning/0` in
  # `Harness.requires_zero_listeners?/1` — so OpenCode needs no per-harness declaration. A `:shim`
  # harness would override that default only to opt OUT (a rails-reviewed choice).

  @impl true
  def wire_projection do
    JSON.encode!(%{
      "id" => "opencode",
      "wire_name" => wire_name(),
      "install_package" => install_package(),
      "cli_binary" => cli_binary(),
      # An argv SUBSTRING of the running process (matched in cli/src/probe.rs collect_darwin),
      # verified against a live `ps` of the launched shim: `opencode acp` matches; bare
      # `opencode` (desktop/CLI) does not, and there is no `opencode-acp` binary.
      "process_markers" => ["opencode acp"]
    })
  end

  # Provision the adapter as a shell shim over the operator-installed `opencode`, and materialize
  # the out-of-tree gate plugin + config. No npm package, no bundle to patch.
  @impl true
  def ensure_adapter(target) do
    with {:ok, detail} <-
           Tightbeam.Spinup.ensure_shim_adapter(target, adapter_binary(target), cli_binary(), [
             "acp"
           ]),
         :ok <- ensure_gate(target) do
      {:ok, detail}
    end
  end

  # The gate plugin is static Tightbeam-owned code; its config references it by ABSOLUTE path, so
  # the config is generated per host (base_dir-dependent) while the plugin is copied verbatim from
  # priv. Both live under `<base_dir>/opencode-gate`, out of the agent's reach.
  defp ensure_gate(target) do
    base_dir = target.host_config.base_dir
    dir = gate_dir(base_dir)
    plugin_path = Path.join(dir, @gate_plugin)
    config_path = Path.join(dir, @gate_config)
    plugin_src = gate_plugin_source()
    config_src = gate_config_source(gate_plugin_path(base_dir))

    if Support.local?(target) do
      File.mkdir_p!(dir)
      File.write!(plugin_path, plugin_src)
      File.write!(config_path, config_src)
      :ok
    else
      # Mirror the shim's remote branch (`Spinup.ensure_shim_adapter`): materialize the gate
      # plugin + config over ssh with `mkdir -p` + `printf %s` writes. Refuse loudly on failure
      # rather than silently skip the gate.
      ssh = target.host_config.ssh

      script =
        "mkdir -p #{Support.shell_quote(dir)} && " <>
          "printf %s #{Support.shell_quote(plugin_src)} > #{Support.shell_quote(plugin_path)} && " <>
          "printf %s #{Support.shell_quote(config_src)} > #{Support.shell_quote(config_path)}"

      command = ["ssh" | Support.ssh_opts()] ++ [ssh, "sh", "-c", Support.shell_quote(script)]

      case target.sh.(command) do
        {_out, 0} ->
          :ok

        {out, _exit} ->
          {:error,
           %{
             code: "host_unready",
             message:
               "remote OpenCode gate materialization on #{target.host_name} failed: " <>
                 String.trim(out)
           }}
      end
    end
  end

  @gate_plugin_path Application.app_dir(:tightbeam, "priv/opencode_gate/tightbeam-gate.js")
  @external_resource @gate_plugin_path
  @gate_plugin_source File.read!(@gate_plugin_path)
  defp gate_plugin_source, do: @gate_plugin_source

  defp gate_config_source(plugin_abs_path) do
    JSON.encode!(%{
      "$schema" => "https://opencode.ai/config.json",
      "plugin" => [plugin_abs_path]
    })
  end

  @impl true
  def prepare_launch(target, home, opts) do
    binary = adapter_binary(target)
    base_dir = target.host_config.base_dir
    gate_config = gate_config_path(base_dir)

    # opencode resolves data (auth.json) + config under `$XDG_DATA_HOME/opencode` and
    # `$XDG_CONFIG_HOME/opencode`; pointing both at `dirname(home)` makes opencode's own dir the
    # projected home, so its credential lands at `<home>/auth.json` — the codex home shape. The
    # gate rides in via OPENCODE_CONFIG (out-of-tree, merged); OPENCODE_DISABLE_PROJECT_CONFIG
    # blocks an agent-authored project `opencode.json` from adding config. OPENCODE_PURE is never
    # set. opencode reads its own auth.json, so no credential is injected (kind-invariant).
    xdg = Path.dirname(home)

    oc_env = [
      {"XDG_DATA_HOME", xdg},
      {"XDG_CONFIG_HOME", xdg},
      {"OPENCODE_CONFIG", gate_config},
      {"OPENCODE_DISABLE_PROJECT_CONFIG", "1"}
    ]

    if Support.local?(target) do
      [cmd: [binary], env: oc_env ++ Keyword.fetch!(opts, :common_env)]
    else
      remote_env =
        [
          "XDG_DATA_HOME=#{xdg}",
          "XDG_CONFIG_HOME=#{xdg}",
          "OPENCODE_CONFIG=#{gate_config}",
          "OPENCODE_DISABLE_PROJECT_CONFIG=1"
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

  # TODO(session-semantics): the exact OpenCode ACP `_meta` guidance key, permission mode, and
  # model-switch semantics are not yet ground-truth-verified; these mirror the generic shape and
  # are not exercised while the harness is unregistered. Verify against a live `opencode acp`
  # session before driving real turns.
  @impl true
  def session_config(session, guidance) do
    prefix =
      "Your Tight Beam archetype identity arrives as this OpenCode instruction. " <>
        "It is authoritative and outranks product AGENTS.md instructions on conflict."

    guidance =
      if Map.get(session, :identity) == true and not String.starts_with?(guidance, prefix),
        do: prefix <> "\n\n" <> guidance,
        else: guidance

    %{
      guidance: guidance,
      meta: %{instructions: guidance},
      permission_mode: "full",
      effort_config: "effort",
      resident_model_switch: :in_place,
      model_option_aliases: %{},
      canonical_model_prefixes: ["opencode/"]
    }
  end

  @impl true
  def owned_home_entries,
    do: Support.owned_home_entries(@credential_file, @rails_file)

  @impl true
  def reconcile_home(target, home, desired) do
    # Mirror claude/fixture: pin the desired model into the reserved home rails artifact so the
    # projected home tracks the session's selection; binary rails pass through opaque. The gate
    # itself is delivered out-of-tree (OPENCODE_CONFIG), not from this artifact — the artifact is
    # reserved for the future compiled operator-statute set the plugin will read.
    rails =
      case {desired.rails, Map.get(desired, :default_model)} do
        {bytes, _model} when is_binary(bytes) ->
          bytes

        {map_or_nil, nil} ->
          map_or_nil && JSON.encode!(map_or_nil)

        {map_or_nil, model} ->
          JSON.encode!(Map.put(map_or_nil || %{}, "model", packed_model(model)))
      end

    Tightbeam.Homes.reconcile(target, home, %{desired | rails: rails},
      credential_names: [@credential_file],
      rails_filename: @rails_file
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
      Path.join([".opencode", "skills"])
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

  @impl true
  def harvest_credential(target, home) do
    Tightbeam.Homes.harvest_credential(target, home, @credential_file)
  end

  # Deliberate, RULED design (product-owner decision-4): Tightbeam never probes or stores
  # OpenCode PROVIDER credentials — OpenCode owns provider auth (`opencode auth`), so there is no
  # Tightbeam-side authenticated probe to make, and inventing one would be wrong, not missing.
  # This is a NAMED accept-the-degrade: liveness is :unknown by design, never a false verdict.
  @impl true
  def credential_live?(_target, _home, _opts),
    do: {:unknown, :opencode_owns_provider_auth}

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

  # TODO(HB-04, catalog-source): the production catalog source is `opencode models` (provider-
  # stamped `provider/model` slugs); wiring + provider stamping is the catalog decision. The
  # injected-reader shape (fixture precedent) keeps derivation testable without coupling to a
  # live source; the real reader is tracked follow-on and not exercised while unregistered.
  @impl true
  def fetch_catalog(state) do
    fetch = get_in(state, [:options, :opencode_fetch]) || fn -> {:ok, :valid} end

    case fetch.() do
      {:ok, :valid} ->
        {:ok,
         [
           %{
             family: "opencode/zen",
             context: nil,
             display_name: "OpenCode Zen",
             name: "OpenCode Zen",
             efforts: [],
             max_input_tokens: nil,
             capabilities: %{},
             provider: credential_provider()
           }
         ]}

      {:ok, _malformed} ->
        {:error, :malformed_catalog}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def conformance_vectors do
    valid_entry = %{
      family: "opencode/zen",
      context: nil,
      display_name: "OpenCode Zen",
      name: "OpenCode Zen",
      efforts: [],
      max_input_tokens: nil,
      capabilities: %{},
      provider: credential_provider()
    }

    Support.conformance_vectors(__MODULE__, %{
      wire_name: wire_name(),
      provider: credential_provider(),
      home_scope: "opencode",
      home_env: "XDG_DATA_HOME",
      credential_file: @credential_file,
      # OpenCode owns provider auth (product-owner decision-4), so liveness is :unknown by
      # design with a DEDICATED reason atom + divergence — not fixture's no-probe default.
      credential_live: :unsupported,
      credential_live_unknown_reason: :opencode_owns_provider_auth,
      credential_live_divergence: "DIV-CREDENTIAL-LIVE-OPENCODE-OWNS-AUTH",
      rails_file: @rails_file,
      rails: %{"opencode" => true},
      skills_path: Path.join([".opencode", "skills"]),
      # Kind-invariant: opencode reads its own auth.json, so both kinds render the same plan.
      local_extra_env: %{subscription: [], api_key: []},
      rails_env: nil,
      remote_rails_env: nil,
      railed_probe: false,
      # OpenCode's projected home needs several env vars, not one: XDG_DATA_HOME/XDG_CONFIG_HOME
      # (both `dirname(home)` == base in the vector) plus the out-of-tree OPENCODE_CONFIG gate and
      # the project-config lockout. See `prepare_launch/3`.
      local_home_env: fn base, _home ->
        [
          {"XDG_DATA_HOME", base},
          {"XDG_CONFIG_HOME", base},
          {"OPENCODE_CONFIG", base <> "/opencode-gate/opencode.json"},
          {"OPENCODE_DISABLE_PROJECT_CONFIG", "1"}
        ]
      end,
      remote_prefix: fn base, _home, _kind ->
        [
          "XDG_DATA_HOME=#{base}",
          "XDG_CONFIG_HOME=#{base}",
          "OPENCODE_CONFIG=#{base}/opencode-gate/opencode.json",
          "OPENCODE_DISABLE_PROJECT_CONFIG=1"
        ]
      end,
      # Binary-native (:shim): the adapter is a shell shim over the operator-installed CLI, not an
      # npm package — the ensure_adapter machinery branches on this. `adapter_bin` is the shim's
      # basename (where readiness looks) and `cli_name` the operator binary the shim execs.
      provisioning: :shim,
      adapter_bin: "opencode",
      cli_name: "opencode",
      shim_exec_args: ["acp"],
      session_meta: %{instructions: "vector guidance"},
      cli_version: "opencode vector 1.0",
      probe_path: :discovered,
      auth_events: [
        %{
          case: "positive",
          envelope: %{"authMode" => nil, "planType" => nil},
          expected: :unknown,
          divergence: "DIV-AUTH-OPENCODE-UNSUPPORTED"
        },
        %{case: "negative", envelope: %{"unrelated" => true}, expected: :unknown}
      ],
      subagent_events: [
        %{
          case: "positive_start",
          envelope: %{"opencode" => "start"},
          expected: :skip,
          divergence: "DIV-SUBAGENT-OPENCODE-UNSUPPORTED"
        },
        %{
          case: "positive_stop",
          envelope: %{"opencode" => "stop"},
          expected: :skip,
          divergence: "DIV-SUBAGENT-OPENCODE-UNSUPPORTED"
        },
        %{case: "negative", envelope: %{"unrelated" => true}, expected: :skip}
      ],
      catalog_expected: %{
        "valid" => {:ok, [valid_entry]},
        # No per-kind route: opencode answers identically for both credential kinds.
        "valid_api_key" => {:ok, [valid_entry]},
        "malformed" => {:error, :malformed_catalog},
        "unavailable" => {:error, :opencode_unavailable}
      },
      catalog_state: fn case_name, _base ->
        fetch = fn ->
          case case_name do
            "valid" -> {:ok, :valid}
            "valid_api_key" -> {:ok, :valid}
            "malformed" -> {:ok, :malformed}
            "unavailable" -> {:error, :opencode_unavailable}
          end
        end

        %{credential_kind: :subscription, options: %{opencode_fetch: fetch}}
      end,
      wire_projection: %{
        "id" => "opencode",
        "wire_name" => "opencode",
        "install_package" => "opencode",
        "cli_binary" => "opencode",
        "process_markers" => ["opencode acp"]
      }
    })
  end

  defp adapter_binary(target) do
    Map.get(target, :adapter_binary) ||
      Path.join([
        target.host_config.base_dir,
        "adapters",
        "node_modules",
        ".bin",
        Path.basename(install_package())
      ])
  end

  defp gate_dir(base_dir), do: Path.join(base_dir, @gate_dir)
  defp gate_config_path(base_dir), do: Path.join(gate_dir(base_dir), @gate_config)
  defp gate_plugin_path(base_dir), do: Path.join(gate_dir(base_dir), @gate_plugin)
end
