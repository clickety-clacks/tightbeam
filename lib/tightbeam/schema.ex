defmodule Tightbeam.Schema do
  @moduledoc "The single production-owned schema bootstrap for a Tightbeam database."

  alias Tightbeam.DB

  @schema_modules [
    Tightbeam.Ledger,
    Tightbeam.EventLog,
    Tightbeam.Assets,
    Tightbeam.Artifacts,
    Tightbeam.CausalEvents,
    Tightbeam.Adjudication,
    Tightbeam.Devices,
    Tightbeam.Idempotency,
    Tightbeam.ConditionFacts,
    Tightbeam.SubagentMarkers,
    Tightbeam.Escalation,
    Tightbeam.Wakes,
    Tightbeam.Projection,
    Tightbeam.Org,
    Tightbeam.CriticalLeases,
    Tightbeam.Roles,
    Tightbeam.WorkItems,
    Tightbeam.Assignments,
    Tightbeam.EffortCheckin,
    Tightbeam.Placement,
    Tightbeam.RailRemedy,
    Tightbeam.Supervision,
    Tightbeam.WorkState,
    Tightbeam.HarnessProcess,
    Tightbeam.AdapterCoordinator
  ]

  @doc "Create every production schema in dependency-safe order."
  @spec ensure_all(DB.server()) :: :ok
  def ensure_all(db) do
    Enum.each(@schema_modules, fn module ->
      :ok = module.ensure_schema(db)
    end)

    :ok
  end
end
