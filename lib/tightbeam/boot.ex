defmodule Tightbeam.Boot do
  @moduledoc """
  One-shot boot step under the tree, after the DB is up: ensure all schemas
  exist (additive-only), open a boot epoch (recording a dirty exit for any
  prior unstamped epoch), recover any turns left `running` by a crash, and
  stash the epoch for the clean-shutdown stamp at prep_stop.

  Runs as a :transient child that returns :ignore, so it does its work at
  startup and does not linger as a process.
  """

  require Logger

  alias Tightbeam.{Escalation, EventLog, Ledger, Schema}

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(base_dir) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [base_dir]},
      type: :worker,
      restart: :transient
    }
  end

  @doc "Run the boot sequence; returns :ignore so no process lingers."
  @spec start_link(String.t()) :: :ignore
  def start_link(base_dir) do
    ensure_schema!()
    epoch = EventLog.boot()
    Application.put_env(:tightbeam, :boot_epoch, epoch)
    # Boot recovery: any 'running' turn from a prior life is UNKNOWN-terminal.
    _ = Ledger.recover_running()
    :ok = Escalation.recover_retired()

    projections =
      "[" <> Enum.map_join(Tightbeam.Harness.all(), ",", & &1.wire_projection()) <> "]"

    write_harnesses!(base_dir, projections)
    :ignore
  end

  defp ensure_schema! do
    Schema.ensure_all(Tightbeam.DB)
  rescue
    error in Schema.ShapeError ->
      invariant =
        case Regex.run(~r/^incompatible_cold_start_v1: ([^;]+)/, error.message) do
          [_, value] -> value
          _ -> "unknown"
        end

      Logger.error("cold-start schema is incompatible",
        code: "incompatible_cold_start_v1",
        invariant: invariant,
        recoverySection: "Recover an unusable fresh database"
      )

      reraise error, __STACKTRACE__
  end

  @doc false
  def write_harnesses!(base_dir, projections) do
    path = Path.join(base_dir, "harnesses.json")
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(temporary, projections)
    File.rename!(temporary, path)
  end
end
