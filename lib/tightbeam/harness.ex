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
  The vendor CLI this harness invokes directly.

  An operator prerequisite, never something Tightbeam installs: assimilation puts
  Tightbeam's own plumbing on a satellite -- adapters, CLI, base dir -- and enabling
  a harness there presupposes this binary is already on that machine's PATH. It is
  projected on the wire so the satellite probe can check for it by name.
  """
  @callback cli_binary() :: binary()
  @callback identity_apply_capabilities() :: map()
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

  @callback install_cli_projection(String.t()) :: :ok
  @callback probe_cli(target()) ::
              {:ok, %{bin: String.t(), version: String.t()}}
              | {:error, :not_found | {:exec_failed, String.t()}}
  @callback classify_auth_event(map()) :: :terminal | :transient | :unknown
  @callback classify_subagent_event(map()) ::
              {:subagent_start | :subagent_stop, map()} | :skip
  @callback fetch_catalog(map()) :: {:ok, [map()]} | {:error, term()}
  @optional_callbacks warm_home: 2

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
