defmodule Tightbeam.HarnessProcess.Recovery do
  @moduledoc false
  alias Tightbeam.{DB, EventLog, HarnessProcess}

  # The detecting settlement route: observe the row and the exact fence
  # instance, evaluate proof with no transaction open (helper and SSH probes
  # may hold five-second timeouts, and the database owner must not wait on
  # them), then settle in one short transaction that re-checks the row, the
  # successor set and the fence instance. A write that lands between
  # observation and settlement makes settlement change nothing and name the
  # failed guard; the caller may retry against a fresh observation.
  def settle(db, launch_id, adapter_key, requester, receipt) do
    with {:ok, row, fence} <- observe(db, launch_id, adapter_key),
         {:ok, proof} <- proof(row, receipt) do
      commit(db, row, fence, proof, requester)
    end
  end

  defp observe(db, launch_id, adapter_key) do
    case DB.transaction(db, fn txn ->
           with {:ok, row} <- HarnessProcess.fetch_in_txn(txn, launch_id),
                :ok <- guard_row(row, adapter_key),
                :ok <- guard_successor(txn, row),
                {:ok, fence} <- fence_instance(txn, adapter_key) do
             {:ok, row, fence}
           end
         end) do
      {:ok, observed} -> observed
      {:error, reason} -> {:error, {:settlement_persistence_failed, reason}}
    end
  end

  defp commit(db, observed, fence, proof, requester) do
    result =
      DB.transaction(db, fn txn ->
        with {:ok, row} <- HarnessProcess.fetch_in_txn(txn, observed.launch_id),
             :ok <- guard_row(row, observed.adapter_key),
             :ok <- guard_unchanged(observed, row),
             :ok <- guard_successor(txn, row),
             :ok <- guard_fence(txn, observed.adapter_key, fence) do
          DB.Txn.q(
            txn,
            "UPDATE harness_processes SET state='exited',resolvedAt=?2 WHERE launchId=?1 AND resolvedAt IS NULL",
            [row.launch_id, System.system_time(:millisecond)]
          )

          1 = DB.Txn.changes(txn)

          remove_observed_fence(txn, observed.adapter_key, fence)

          :ok =
            EventLog.lifecycle_in_txn(
              txn,
              "harness_launch_settled",
              row.adapter_key,
              inspect(%{
                launch_id: row.launch_id,
                adapter_key: row.adapter_key,
                proof: proof,
                requester: requester
              })
            )

          {:settled, row, proof}
        end
      end)

    case result do
      {:ok, {:settled, row, proof}} ->
        case HarnessProcess.remove_identity(row) do
          :ok ->
            :ok

          {:error, reason} ->
            EventLog.lifecycle(
              db,
              "identity_remove_failed",
              row.adapter_key,
              inspect(%{launch_id: row.launch_id, reason: reason})
            )
        end

        {:ok, %{launch_id: row.launch_id, proof: proof}}

      {:ok, other} ->
        other

      {:error, reason} ->
        {:error, {:settlement_persistence_failed, reason}}
    end
  end

  defp guard_row(row, key) do
    cond do
      row.adapter_key != key ->
        {:error, :adapter_key_mismatch}

      not is_nil(row.resolved_at) ->
        :already_resolved

      row.state not in ~w(launching running park_requested kill_failed) ->
        {:error, :state_not_recoverable}

      true ->
        :ok
    end
  end

  # The proof was evaluated against these fields; settlement holds only
  # while they are unchanged at commit.
  @proof_fields ~w(state ssh helper_path identity_path os_pid process_group_id
                   boot_identity identity_token preparation_boot_identity)a

  defp guard_unchanged(observed, current) do
    if Map.take(observed, @proof_fields) == Map.take(current, @proof_fields),
      do: :ok,
      else: {:error, :row_changed_since_observation}
  end

  defp guard_successor(txn, row) do
    case DB.Txn.q(
           txn,
           "SELECT launchId FROM harness_processes WHERE adapterKey=?1 AND launchSequence>?2 LIMIT 1",
           [row.adapter_key, row.launch_sequence]
         ) do
      [] -> :ok
      [_ | _] -> {:error, :successor_exists}
    end
  end

  # Each fence row carries a generation written once at creation, so a
  # removal and reinsertion is a different instance even when every other
  # column is identical. A fence without one cannot prove instance identity.
  defp fence_instance(txn, adapter_key) do
    case DB.Txn.q(txn, "SELECT generation FROM harness_park_fences WHERE adapterKey=?1", [
           adapter_key
         ]) do
      [] -> {:ok, :none}
      [[generation]] when is_binary(generation) and generation != "" -> {:ok, generation}
      [_] -> {:error, :fence_identity_unproved}
    end
  end

  defp guard_fence(txn, adapter_key, observed) do
    with {:ok, current} <- fence_instance(txn, adapter_key) do
      if current == observed, do: :ok, else: {:error, :fence_changed_since_observation}
    end
  end

  defp remove_observed_fence(_txn, _adapter_key, :none), do: :ok

  defp remove_observed_fence(txn, adapter_key, generation) do
    # Preserve the existing rate-limit incident fence, which has a separate owner.
    incident_guard =
      if DB.Txn.q(
           txn,
           "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='harness_health_incidents'"
         ) == [[1]] do
        "AND NOT EXISTS (SELECT 1 FROM harness_health_incidents WHERE state='open' AND failureClass='rate-limit-dead' AND harness || ':shared@' || host = harness_park_fences.adapterKey)"
      else
        ""
      end

    DB.Txn.q(
      txn,
      """
      DELETE FROM harness_park_fences WHERE adapterKey=?1 AND generation=?2
        AND NOT EXISTS (SELECT 1 FROM harness_processes WHERE adapterKey=?1 AND resolvedAt IS NULL)
        #{incident_guard}
      """,
      [adapter_key, generation]
    )

    :ok
  end

  defp proof(row, receipt) do
    with :ok <- receipt_matches(row, receipt) do
      case terminal_record(row) do
        {:ok, %{status: status}} ->
          if is_map(receipt) and receipt.status != status,
            do: {:error, :launcher_exit_mismatch},
            else: {:ok, :terminal_pre_identity}

        _ ->
          other_proof(row, receipt)
      end
    end
  end

  defp receipt_matches(_row, nil), do: :ok

  defp receipt_matches(row, %{launch_id: id, status: status})
       when id == row.launch_id and is_integer(status), do: :ok

  defp receipt_matches(_, _), do: {:error, :launcher_exit_mismatch}

  defp other_proof(row, receipt) do
    cond do
      reboot_since_preparation?(row) ->
        {:ok, :reboot_since_preparation}

      never_started?(row, receipt) ->
        {:ok, :launcher_exited_without_start}

      true ->
        case HarnessProcess.read_proved_identity(row) do
          {:ok, identity} ->
            cond do
              identity.ssh == nil and changed_boot?(identity, identity.boot_identity) ->
                {:ok, :identity_boot_ended}

              HarnessProcess.check_identity(identity) == {:ok, :gone} ->
                {:ok, :process_group_absent}

              true ->
                {:error, :termination_unproved}
            end

          {:error, reason} ->
            {:error, {:termination_unproved, reason}}
        end
    end
  end

  defp reboot_since_preparation?(%{ssh: nil, preparation_boot_identity: boot} = row)
       when is_binary(boot) and boot != "",
       do: changed_boot?(row, boot)

  defp reboot_since_preparation?(_), do: false

  defp changed_boot?(row, recorded) do
    case HarnessProcess.local_boot_identity(row) do
      {:ok, current} -> current != recorded
      _ -> false
    end
  end

  defp never_started?(%{ssh: nil, os_pid: nil} = row, %{direct_launcher: true, launch_id: id})
       when id == row.launch_id do
    File.lstat(row.identity_path) == {:error, :enoent} and
      File.lstat(row.identity_path <> ".authority") == {:error, :enoent}
  end

  defp never_started?(_, _), do: false

  def terminal_record(row) do
    case HarnessProcess.read_identity_file(
           %{row | identity_path: row.identity_path <> ".failed"},
           1_000
         ) do
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

          _ ->
            {:error, :terminal_record_invalid}
        end

      {:error, _} = error ->
        error
    end
  end
end
