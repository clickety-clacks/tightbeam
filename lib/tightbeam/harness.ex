defmodule Tightbeam.Harness do
  @bundle_path Application.app_dir(:tightbeam, "priv/harness_bundle.json")
  @external_resource @bundle_path
  @bundle @bundle_path |> File.read!() |> JSON.decode!()
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

  alias Tightbeam.Harness.{Claude, Codex, Fixture}

  @type target :: map()
  @type launch_plan :: keyword()
  @type desired_home :: map()
  @type credential_liveness ::
          :live | {:dead, term()} | {:unknown, term()}

  @callback id() :: atom()
  @callback wire_name() :: String.t()
  @callback credential_provider() :: atom()
  @callback install_package() :: binary()
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
  @callback install_cli_projection(String.t()) :: :ok
  @callback probe_cli(target()) ::
              {:ok, %{bin: String.t(), version: String.t()}}
              | {:error, :not_found | {:exec_failed, String.t()}}
  @callback classify_auth_event(map()) :: :terminal | :transient | :unknown
  @callback classify_subagent_event(map()) ::
              {:subagent_start | :subagent_stop, map()} | :skip
  @callback fetch_catalog(map()) :: {:ok, [map()]} | {:error, term()}
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

  @registry [Claude, Codex] ++
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
