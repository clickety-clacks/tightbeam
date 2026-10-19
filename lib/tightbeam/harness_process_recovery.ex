defmodule Tightbeam.HarnessProcess.Recovery do
  @moduledoc false
  alias Tightbeam.{DB, EventLog, HarnessProcess}

  # Proof, row/fence observation and settlement share the database's excluding
  # transaction. In particular an equal-content fence replacement cannot sneak
  # between observation and deletion. External reads are bounded and read-only.
  def settle(db, launch_id, adapter_key, requester, receipt) do
    result = DB.transaction(db, fn txn ->
      with {:ok, row} <- HarnessProcess.fetch_in_txn(txn, launch_id),
           :ok <- guard_row(row, adapter_key),
           [] <- DB.Txn.q(txn, "SELECT launchId FROM harness_processes WHERE adapterKey=?1 AND launchSequence>?2 LIMIT 1", [adapter_key, row.launch_sequence]),
           _fence <- DB.Txn.q(txn, "SELECT requestedAt FROM harness_park_fences WHERE adapterKey=?1", [adapter_key]),
           {:ok, proof} <- proof(row, receipt) do
        DB.Txn.q(txn, "UPDATE harness_processes SET state='exited',resolvedAt=?2 WHERE launchId=?1 AND resolvedAt IS NULL", [launch_id, System.system_time(:millisecond)])
        1 = DB.Txn.changes(txn)
        DB.Txn.q(txn, """
        DELETE FROM harness_park_fences WHERE adapterKey=?1
          AND NOT EXISTS (SELECT 1 FROM harness_processes WHERE adapterKey=?1 AND resolvedAt IS NULL)
        """, [adapter_key])
        :ok = EventLog.lifecycle_in_txn(txn, "harness_launch_settled", adapter_key,
          inspect(%{launch_id: launch_id, adapter_key: adapter_key, proof: proof, requester: requester}))
        {:settled, row, proof}
      else
        :already_resolved -> :already_resolved
        {:error, _} = error -> error
        [_ | _] -> {:error, :successor_exists}
      end
    end)

    case result do
      {:ok, {:settled, row, proof}} ->
        case HarnessProcess.remove_identity(row) do
          :ok -> :ok
          {:error, reason} ->
            EventLog.lifecycle(db, "identity_remove_failed", row.adapter_key,
              inspect(%{launch_id: row.launch_id, reason: reason}))
        end
        {:ok, %{launch_id: launch_id, proof: proof}}
      {:ok, other} -> other
      {:error, reason} -> {:error, {:settlement_persistence_failed, reason}}
    end
  end

  defp guard_row(row, key) do
    cond do
      row.adapter_key != key -> {:error, :adapter_key_mismatch}
      not is_nil(row.resolved_at) -> :already_resolved
      row.state not in ~w(launching running park_requested kill_failed) -> {:error, :state_not_recoverable}
      true -> :ok
    end
  end

  defp proof(row, receipt) do
    with :ok <- receipt_matches(row, receipt) do
      case terminal_record(row) do
        {:ok, %{status: status}} ->
          if is_map(receipt) and receipt.status != status,
            do: {:error, :launcher_exit_mismatch}, else: {:ok, :terminal_pre_identity}
        _ -> other_proof(row, receipt)
      end
    end
  end

  defp receipt_matches(_row, nil), do: :ok
  defp receipt_matches(row, %{launch_id: id, status: status}) when id == row.launch_id and is_integer(status), do: :ok
  defp receipt_matches(_, _), do: {:error, :launcher_exit_mismatch}

  defp other_proof(row, receipt) do
    cond do
      reboot_since_preparation?(row) -> {:ok, :reboot_since_preparation}
      never_started?(row, receipt) -> {:ok, :launcher_exited_without_start}
      true ->
        case HarnessProcess.read_proved_identity(row) do
          {:ok, identity} ->
            cond do
              identity.ssh == nil and changed_boot?(identity, identity.boot_identity) -> {:ok, :identity_boot_ended}
              HarnessProcess.check_identity(identity) == {:ok, :gone} -> {:ok, :process_group_absent}
              true -> {:error, :termination_unproved}
            end
          {:error, reason} -> {:error, {:termination_unproved, reason}}
        end
    end
  end

  defp reboot_since_preparation?(%{ssh: nil, preparation_boot_identity: boot} = row) when is_binary(boot) and boot != "",
    do: changed_boot?(row, boot)
  defp reboot_since_preparation?(_), do: false

  defp changed_boot?(row, recorded) do
    case HarnessProcess.local_boot_identity(row) do
      {:ok, current} -> current != recorded
      _ -> false
    end
  end

  defp never_started?(%{ssh: nil, os_pid: nil} = row, %{direct_launcher: true, launch_id: id}) when id == row.launch_id do
    File.lstat(row.identity_path) == {:error, :enoent} and
      File.lstat(row.identity_path <> ".authority") == {:error, :enoent}
  end
  defp never_started?(_, _), do: false

  def terminal_record(row) do
    case HarnessProcess.read_identity_file(%{row | identity_path: row.identity_path <> ".failed"}, 1_000) do
      {:ok, bytes} ->
        case String.split(bytes, "\t") do
          ["tightbeam-launch-failed-v1", launch, step, status] when launch == row.launch_id ->
            with true <- step in ~w(fork session leader boot start_time write),
                 true <- String.ends_with?(status, "\n"),
                 {code, "\n"} when code > 0 <- Integer.parse(status) do
              {:ok, %{step: step, status: code}}
            else
              _ -> {:error, :terminal_record_invalid}
            end
          _ -> {:error, :terminal_record_invalid}
        end
      {:error, _} = error -> error
    end
  end
end
