defmodule Tightbeam.Boot do
  @moduledoc """
  One-shot boot step under the tree, after the DB is up: ensure all schemas
  exist (additive-only), open a boot epoch (recording a dirty exit for any
  prior unstamped epoch — review #9), recover any turns left `running` by a
  crash, and stash the epoch for the clean-shutdown stamp on stop.

  Runs as a :transient child that returns :ignore, so it does its work at
  startup and does not linger as a process.
  """

  alias Tightbeam.{Ledger, EventLog}

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker, restart: :transient}
  end

  def start_link do
    :ok = Ledger.ensure_schema()
    :ok = EventLog.ensure_schema()
    epoch = EventLog.boot()
    Application.put_env(:tightbeam, :boot_epoch, epoch)
    # Boot recovery: any 'running' turn from a prior life is UNKNOWN-terminal.
    _ = Ledger.recover_running()
    :ignore
  end
end
