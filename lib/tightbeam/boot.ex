defmodule Tightbeam.Boot do
  @moduledoc """
  One-shot boot step under the tree, after the DB is up: ensure all schemas
  exist (additive-only), open a boot epoch (recording a dirty exit for any
  prior unstamped epoch), recover any turns left `running` by a crash, and
  stash the epoch for the clean-shutdown stamp at prep_stop.

  Runs as a :transient child that returns :ignore, so it does its work at
  startup and does not linger as a process.
  """

  alias Tightbeam.{Escalation, Ledger, EventLog}

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker, restart: :transient}
  end

  @doc "Run the boot sequence; returns :ignore so no process lingers."
  @spec start_link() :: :ignore
  def start_link do
    :ok = Ledger.ensure_schema()
    :ok = EventLog.ensure_schema()
    :ok = Escalation.ensure_schema()
    epoch = EventLog.boot()
    Application.put_env(:tightbeam, :boot_epoch, epoch)
    # Boot recovery: any 'running' turn from a prior life is UNKNOWN-terminal.
    _ = Ledger.recover_running()
    :ok = Escalation.recover_retired()
    :ignore
  end
end