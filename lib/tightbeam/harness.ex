defmodule Tightbeam.Harness do
  @moduledoc """
  Stateless adapter boundary for every supported agent harness.

  Callers select a module from this registry and state intent. Harness
  implementations own their literals and perform the harness-shaped effects.
  """

  alias Tightbeam.Harness.{Claude, Codex, Fixture}

  @type target :: map()
  @type launch_plan :: keyword()
  @type desired_home :: map()

  @callback id() :: atom()
  @callback wire_name() :: String.t()
  @callback credential_provider() :: atom()
  @callback install_package() :: binary()
  @callback wire_projection() :: binary()
  @callback prepare_launch(target(), String.t(), keyword()) :: launch_plan()
  @callback ensure_adapter(target()) :: {:ok, String.t()} | {:error, map()}
  @callback session_config(map(), binary()) :: map()
  @callback reconcile_home(target(), String.t(), desired_home()) :: map()
  @callback materialize_skills(target(), String.t(), map()) :: map()
  @callback credential_ready?(target(), String.t()) :: boolean()
  @callback harvest_credential(target(), String.t()) :: binary() | nil
  @callback probe_cli(target()) ::
              {:ok, %{bin: String.t(), version: String.t()}}
              | {:error, :not_found | {:exec_failed, String.t()}}
  @callback containment_additions() :: [{String.t(), String.t() | nil}]
  @callback classify_auth_event(map()) :: :terminal | :transient | :unknown
  @callback classify_subagent_event(map()) ::
              {:subagent_start | :subagent_stop, map()} | :skip
  @callback fetch_catalog(map()) :: {:ok, [map()]} | {:error, term()}

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
