defmodule Tightbeam.Capacity.Service do
  @moduledoc false

  alias Tightbeam.{Credentials, Placement, ProviderAccounts}
  alias Tightbeam.Capacity.{Collector, ReadPolicy, Refresh, Store, View}
  alias Tightbeam.Harness.{CapacityProbe, Support}

  def start_link(config) do
    db = config.db

    case Refresh.start_link(
           name: __MODULE__,
           task_supervisor: Tightbeam.TurnTaskSupervisor,
           entry: &Store.entry(db, &1),
           collect: &collect(config, &1, &2)
         ) do
      {:ok, server} ->
        track(db, server)
        {:ok, server}

      error ->
        error
    end
  end

  def child_spec(config) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}}
  end

  def track(db, server \\ __MODULE__) do
    Refresh.track(server, Enum.map(accounts(db), & &1["id"]))
  end

  def accounts(db) do
    Enum.filter(ProviderAccounts.list(db), fn account ->
      account["kind"] == "subscription" and account["loginState"] != "removed"
    end)
  end

  def usage(db, server, mode) do
    case accounts(db) do
      [] when mode != :snapshot ->
        {:error, %{code: "NO_ACCOUNTS_ONBOARDED"}}

      accounts ->
        results =
          if mode == :snapshot do
            Enum.map(accounts, &usage(db, server, &1, mode))
          else
            accounts
            |> Task.async_stream(&usage(db, server, &1, mode),
              ordered: true,
              timeout: :infinity,
              max_concurrency: max(1, length(accounts))
            )
            |> Enum.map(fn {:ok, result} -> result end)
          end

        {:ok, View.aggregate_usage(results, now())}
    end
  end

  def usage(db, server, account, mode) do
    id = account["id"]
    entry = Store.entry(db, id)

    result =
      if mode == :snapshot do
        source = if ReadPolicy.cache_fresh?(entry.sample, now()), do: :snapshot, else: :retained
        ReadPolicy.result(id, entry.sample, entry.error, source)
      else
        Refresh.read(server, id, mode)
      end

    result =
      update_in(result.error, fn
        %{code: code} = error -> Map.put(error, :message, error_message(code))
        nil -> nil
      end)

    serving = ProviderAccounts.serving(db, account["harness"], account["host"])

    View.usage(
      account,
      result,
      List.last(entry.history),
      (serving && serving["accountId"] == id) || false,
      now()
    )
  end

  def history(db, account),
    do: View.history(account, Store.entry(db, account["id"]).history, now())

  def forecast(db, account), do: View.forecast(account, Store.entry(db, account["id"]), now())

  def forecast(db) do
    accounts(db)
    |> Enum.map(&{&1, Store.entry(db, &1["id"])})
    |> View.aggregate_forecast(now())
  end

  def health(db) do
    inputs = Enum.map(accounts(db), &{&1, Store.entry(db, &1["id"])})
    View.health(inputs, CapacityProbe.local_cli_availability())
  end

  def error_message(code) do
    case code do
      "NO_ACCOUNTS_ONBOARDED" -> "There are no subscription accounts to read."
      "CREDENTIAL_EXPIRED" -> "The credential is expired and could not safely be refreshed."
      "UPSTREAM_TIMEOUT" -> "The capacity request timed out."
      "UPSTREAM_RATE_LIMITED" -> "The provider asked Tightbeam to delay another read."
      "HISTORY_PERSISTENCE_ERROR" -> "Capacity observations could not be saved."
      _ -> "Capacity could not be read. Check the account and try again."
    end
  end

  defp collect(config, id, _requested_at) do
    case ProviderAccounts.get(config.db, id) do
      %{"loginState" => state} = account when state != "removed" ->
        attempted_at = now()
        outcome = read_only(config, account)

        case Collector.record(config.db, account, outcome, attempted_at, max(attempted_at, now()),
               hub: Tightbeam.Firehose.Hub
             ) do
          {:ok, _, current} -> {:ok, current}
          :superseded -> {:error, %{code: "CREDENTIAL_CHANGED"}}
          error -> error
        end

      _ ->
        {:error, %{code: "ACCOUNT_NOT_FOUND"}}
    end
  end

  # Track A provides the authoritative account_target seam with its writer
  # lifecycle. Until then only the already-established shared path is eligible.
  defp read_only(config, %{"slot" => "shared", "host" => host, "provider" => provider}) do
    case Map.fetch(Placement.hosts(config.base_dir, config.db), host) do
      {:ok, host_config} ->
        target = %{host_config: host_config, sh: config[:sh_out] || (&Support.system_cmd_out/1)}
        executable = host_config.cli_bin || Path.join([host_config.base_dir, "bin", "tightbeam"])
        name = CapacityProbe.provider_atom(provider)
        path = Credentials.credential_path(host_config.base_dir, host, name)
        CapacityProbe.read(target, executable, provider, path)

      :error ->
        {:error, %{code: "HOST_UNREACHABLE"}}
    end
  end

  defp read_only(_, _), do: {:error, %{code: "CREDENTIAL_STORE_BUSY"}}
  defp now, do: System.system_time(:millisecond)
end
