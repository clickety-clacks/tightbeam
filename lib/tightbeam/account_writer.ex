defmodule Tightbeam.AccountWriter do
  @moduledoc false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Harness.Support

  def ensure_schema(db) do
    DB.execute(db, """
    CREATE TABLE IF NOT EXISTS account_writer_leases (
      adapterKey TEXT PRIMARY KEY NOT NULL,
      leaseId TEXT NOT NULL UNIQUE,
      acquiredAt INTEGER NOT NULL
    )
    """)
  end

  def run(db, adapter_key, target, home, argv) when is_list(argv) and argv != [] do
    reconcile(db, adapter_key, target, home)

    with {:ok, {:ok, lease}} <- reserve(db, adapter_key) do
      receipt = receipt_path(home, lease)
      helper = Path.join(target.host_config[:cli_bin] || target.cli_bin, "tightbeam")

      command = [
        helper,
        "harness-exec",
        receipt <> ".identity",
        lease,
        "--writer-lock",
        Tightbeam.Homes.account_writer_lock(home),
        "--writer-receipt",
        receipt,
        "--" | argv
      ]

      result = target.sh.(on_host(target, command))

      with {bytes, 0} <- target.sh.(on_host(target, ["cat", receipt])),
           {:ok, _} <- settle_from_receipt(db, adapter_key, lease, bytes) do
        {:ok, result}
      else
        _ -> {:error, :unconfirmed_writer_settlement}
      end
    else
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def reconcile(db, adapter_key, target, home) do
    with {:ok, [[lease]]} <-
           DB.query(db, "SELECT leaseId FROM account_writer_leases WHERE adapterKey = ?1", [
             adapter_key
           ]),
         {receipt, 0} <- target.sh.(on_host(target, ["cat", receipt_path(home, lease)])),
         {:ok, true} <- settle_from_receipt(db, adapter_key, lease, receipt) do
      :settled
    else
      _ -> :unconfirmed
    end
  end

  defp receipt_path(home, lease),
    do: Path.join([home, ".tightbeam", "account-writers", lease <> ".done"])

  defp on_host(%{host_config: %{ssh: nil}}, command), do: command

  defp on_host(%{host_config: %{ssh: destination}}, command) do
    ["ssh" | Support.ssh_opts()] ++
      [destination, Enum.map_join(command, " ", &Support.shell_quote/1)]
  end

  def reserve(db, adapter_key) do
    lease = Tightbeam.Id.uuid4()

    DB.transaction(db, fn txn ->
      cond do
        reserved?(txn, adapter_key) ->
          {:error, :credential_writer_active}

        Txn.q(
          txn,
          "SELECT 1 FROM harness_processes WHERE adapterKey = ?1 AND resolvedAt IS NULL LIMIT 1",
          [adapter_key]
        ) != [] ->
          {:error, :adapter_unresolved}

        true ->
          Txn.q(txn, "INSERT INTO account_writer_leases VALUES (?1, ?2, ?3)", [
            adapter_key,
            lease,
            System.system_time(:millisecond)
          ])

          {:ok, lease}
      end
    end)
  end

  def reserved?(txn, adapter_key) do
    Txn.q(txn, "SELECT 1 FROM account_writer_leases WHERE adapterKey = ?1", [adapter_key]) != []
  end

  def settle_from_receipt(db, adapter_key, lease, receipt) do
    with ["tightbeam-account-writer-v1", ^lease, status] <- String.split(receipt, "\t"),
         {code, "\n"} when code >= 0 and code <= 255 <- Integer.parse(status) do
      settle(db, adapter_key, lease)
    else
      _ -> {:error, :unconfirmed_writer_settlement}
    end
  end

  # Call only after the owning host proves that the writer is finished or never started.
  def settle(db, adapter_key, lease) do
    DB.transaction(db, fn txn ->
      Txn.q(txn, "DELETE FROM account_writer_leases WHERE adapterKey = ?1 AND leaseId = ?2", [
        adapter_key,
        lease
      ])

      Txn.changes(txn) == 1
    end)
  end
end
