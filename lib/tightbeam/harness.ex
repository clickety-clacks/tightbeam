defmodule Tightbeam.Harness do
  @bundle_path Application.app_dir(:tightbeam, "priv/harness_bundle.json")
  @external_resource @bundle_path
  @bundle @bundle_path |> File.read!() |> JSON.decode!()
  @registry_path Application.app_dir(:tightbeam, "priv/harness_registry.json")
  @external_resource @registry_path
  @production_registry @registry_path
                       |> File.read!()
                       |> JSON.decode!()
                       |> Enum.map(fn row ->
                         row["module"] |> String.split(".") |> Module.concat()
                       end)
  @bundle_checklist Enum.map_join(@bundle["obligations"], "\n", fn obligation ->
                      "- `#{obligation["id"]}` — #{obligation["title"]}: " <>
                        obligation["description"]
                    end)

  @moduledoc """
  Stateless adapter boundary for every supported agent harness.

  Callers select a module from this registry and state intent. Harness
  implementations own their literals and perform the harness-shaped effects.

  Adding a harness is one bundle satisfaction surface:

  #{@bundle_checklist}
  """

  alias Tightbeam.Harness.Fixture

  @type target :: map()
  @type launch_plan :: keyword()
  @type desired_home :: map()
  @type credential_liveness ::
          :live | {:dead, term()} | {:unknown, term()}

  @callback id() :: atom()
  @callback wire_name() :: String.t()
  @callback credential_provider() :: atom()
  @callback credential_env_vars() :: [String.t()]

  @doc """
  The model a fresh org runs on this harness when nobody has chosen one.

  A CONSTANT in the boot path used to name claude-sonnet-5 whatever harness was
  in play, so a codex-only box defaulted to a model its harness cannot run and
  failed on the first turn naming a vendor the operator never installed
  (Flynn, 2026-08-04). Each harness names its own.
  """
  @callback default_model() :: Tightbeam.Model.t()
  @callback install_package() :: binary()
  @doc """
  How this harness's ACP adapter is provisioned onto a host.

  `:npm` — the adapter is an npm package. Its pinned `install_package()@adapter_version()`
  joins the ONE shared `npm install` line (`Spinup.install_command/3`) into the shared
  `adapters/node_modules` tree, and the readiness/patch machinery expects that layout.

  `:shim` — the adapter is a shell shim over a binary the operator already installed
  (`cli_binary()`). `ensure_adapter/1` writes `#!/bin/sh\\nexec "<cli>" <sub> "$@"\\n` at the
  adapter path via `Spinup.ensure_shim_adapter/4` and NEVER npm-installs; such a harness is
  excluded from the shared npm line (`Harness.npm_provisioned/0`). For a shim harness
  `install_package()` names the shim binary (its basename is the adapter filename), not an npm
  package. Binary-native by construction — the same seam a future non-npm harness (e.g. cursor)
  reuses by returning `:shim` and supplying its own binary + subcommand.
  """
  @callback adapter_provisioning() :: :npm | :shim
  @doc """
  The vendor CLI this harness invokes directly.

  An operator prerequisite, never something Tight Beam installs: assimilation puts
  Tight Beam's own plumbing on a satellite -- adapters, CLI, base dir -- and enabling
  a harness there presupposes this binary is already on that machine's PATH. It is
  projected on the wire so the satellite probe can check for it by name.
  """
  @callback cli_binary() :: binary()
  @callback wire_projection() :: binary()
  @callback prepare_launch(target(), String.t(), keyword()) :: launch_plan()
  @callback ensure_adapter(target()) :: {:ok, String.t()} | {:error, map()}
  @callback session_config(map(), binary()) :: map()
  @doc "The harness-owned leaf entries of a projected home."
  @callback owned_home_entries() :: [String.t()]
  @callback reconcile_home(target(), String.t(), desired_home()) :: map()
  @callback materialize_skills(target(), String.t(), map()) :: map()
  @callback credential_ready?(target(), String.t()) :: boolean()
  @callback harvest_credential(target(), String.t()) :: binary() | nil
  @callback credential_live?(target(), String.t(), keyword()) :: credential_liveness()
  @doc """
  Give the harness one real run against a freshly banked credential.

  Some harnesses learn what an account is entitled to only by ASKING the server, and cache
  the answer in their own home. Claude Code does: its extra model options -- a 1M-context
  Opus, Fable -- arrive in `additionalModelOptionsCache` on first use and are absent from a
  cold home, so a catalog derived before anything has run reports a subset and reports it as
  the truth.

  That is a deadlock, not a delay: an incomplete catalog means no model can be placed, so no
  session spawns, so the cache never fills, so the catalog stays incomplete. Nothing about it
  self-heals. One run at onboarding, when the credential has just been proven anyway, is what
  breaks it.

  Optional: a harness that keeps no such state need not implement it.
  """
  @callback warm_home(target(), String.t()) :: :ok | {:error, term()}

  @doc """
  Optional OVERRIDE of the default zero-LISTEN-socket launch assertion (rails-critical invariant).

  The default is SAFE-BY-DEFAULT per provisioning class — every `:shim` harness is asserted
  automatically (see `requires_zero_listeners?/1`) — so this callback exists only to override that
  default DELIBERATELY: a `:shim` harness that legitimately needs a network listener opts OUT by
  returning `false` (a rails-reviewed choice, never a silent default), and it also allows a future
  `:npm` harness to opt IN by returning `true`. A harness that does not implement it takes the
  class default.
  """
  @callback requires_zero_listeners?() :: boolean()

  @callback install_cli_projection(String.t()) :: :ok
  @callback probe_cli(target()) ::
              {:ok, %{bin: String.t(), version: String.t()}}
              | {:error, :not_found | {:exec_failed, String.t()}}
  @callback classify_auth_event(map()) :: :terminal | :transient | :unknown
  @callback classify_subagent_event(map()) ::
              {:subagent_start | :subagent_stop, map()} | :skip
  @callback fetch_catalog(map()) :: {:ok, [map()]} | {:error, term()}
  @optional_callbacks warm_home: 2, requires_zero_listeners?: 0

  @doc """
  Whether the shared launch seam asserts the launched process group has ZERO LISTEN sockets,
  aborting fail-closed otherwise (rails-critical launch invariant 3).

  SAFE-BY-DEFAULT for the binary-native (`:shim`) harness class: every `:shim` harness is enforced
  automatically, because a shimmed CLI (e.g. `opencode acp`) can expose an ungated network route
  under a bypass flag, and a new shim harness must NOT be able to ship without this protection by
  merely forgetting an opt-in — wrong default direction. The `:npm` path (claude/codex) is not
  enforced here (a universal-including-npm assertion is a separate, later hardening that would need
  its own zero-listener verification of those harnesses).

  A harness OVERRIDES the class default only by implementing `requires_zero_listeners?/0`
  explicitly: a `:shim` harness that needs a listener opts OUT with `false`; a `:npm` harness could
  opt IN with `true`. Never a silent default off.
  """
  @spec requires_zero_listeners?(module()) :: boolean()
  def requires_zero_listeners?(module) do
    if function_exported?(module, :requires_zero_listeners?, 0) do
      module.requires_zero_listeners?()
    else
      module.adapter_provisioning() == :shim
    end
  end

  @callback conformance_vectors() :: %{
              required(String.t()) => [
                %{
                  required(:case) => String.t(),
                  required(:expected) => term(),
                  required(:input) => map(),
                  required(:support) => :supported | {:unsupported, String.t()}
                }
              ]
            }

  @registry @production_registry ++
              if(Application.compile_env(:tightbeam, :fixture_harness, false),
                do: [Fixture],
                else: []
              )

  @doc "The ordered harness registry. Its order is the product fallback order."
  @spec all() :: [module()]
  def all, do: @registry

  @doc """
  The harnesses whose ACP adapter is an npm package (`adapter_provisioning/0 == :npm`).

  The one shared `npm install` line and the node_modules/.bin patch machinery iterate THIS
  list, not `all/0`: a binary-native (`:shim`) harness has no npm package, and joining a
  non-existent spec into the shared install would fail provisioning for every npm harness too.
  """
  @spec npm_provisioned() :: [module()]
  def npm_provisioned, do: Enum.filter(all(), &(&1.adapter_provisioning() == :npm))

  @doc "The configured default harness module, or the first registry entry."
  @spec default() :: module()
  def default do
    case Application.get_env(:tightbeam, :default_harness) do
      nil -> hd(all())
      value when is_atom(value) -> module!(value)
      value when is_binary(value) -> parse!(value)
    end
  end

  @doc "Resolve a harness id or module, raising at every unknown boundary."
  @spec module!(atom() | module()) :: module()
  def module!(module) when module in @registry, do: module

  def module!(id) when is_atom(id) do
    Enum.find(all(), &(&1.id() == id)) ||
      raise ArgumentError, "unknown harness: #{inspect(id)}"
  end

  @doc "Parse a wire harness name, raising instead of selecting another harness."
  @spec parse!(binary()) :: module()
  def parse!(wire_name) when is_binary(wire_name) do
    Enum.find(all(), &(&1.wire_name() == wire_name)) ||
      raise ArgumentError,
            "unknown harness #{inspect(wire_name)}; expected one of: " <>
              Enum.map_join(all(), ", ", & &1.wire_name())
  end
end
