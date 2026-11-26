defmodule Tightbeam.Capacity.RoutesTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.Capacity.{Collector, Store}
  alias Tightbeam.{DB, Devices, ProviderAccounts, Schema}
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    :ok = Store.ensure_schema(db)
    Devices.add_user(db, "admin", true)
    Devices.add_user(db, "reader", false)

    %{
      db: db,
      options: [
        db: db,
        cli_token: "synthetic-capacity-auth",
        provider_accounts_enabled: true,
        capacity_server: :unused
      ]
    }
  end

  test "disabled and non-admin callers cannot see capacity", %{options: options} do
    assert {404, %{"error" => %{"code" => "not_found"}}} =
             get(
               "/api/capacity?refresh=cache",
               Keyword.put(options, :provider_accounts_enabled, false)
             )

    assert {404, _} = get("/api/capacity?refresh=cache&asUser=reader", options)
    assert {401, _} = get("/api/capacity?refresh=cache", options, "wrong")
  end

  test "cache snapshots use stored data only, including empty and missing cases",
       %{db: db, options: options} do
    assert {200, %{"results" => [], "counts" => %{"cache" => 0}}} =
             get("/api/capacity?refresh=cache", options)

    assert {409, %{"error" => %{"code" => "NO_ACCOUNTS_ONBOARDED"}}} =
             get("/api/capacity?refresh=wait", options)

    now = System.system_time(:millisecond)

    {:ok, :ok} =
      ProviderAccounts.record_existing_shared(
        db,
        "test-host",
        "openai",
        "codex",
        "subscription",
        "signed_in",
        "ok",
        now
      )

    id = ProviderAccounts.shared_id(db, "codex", "test-host")

    assert {200, %{"sample" => nil, "summary" => %{"usageFreshness" => "none"}}} =
             get("/api/capacity/#{id}?refresh=cache", options)

    assert {404, %{"error" => %{"code" => "ACCOUNT_NOT_FOUND"}}} =
             get("/api/capacity/missing?refresh=cache", options)

    sample = %{
      observed_at: now,
      plan: "pro",
      diagnostics: [],
      subscription: %{},
      windows: [
        %{
          id: "primary",
          name: "Primary",
          used_percent: 42,
          window_seconds: 18000,
          scope: "account",
          model: nil,
          resets_at: now + 60_000
        }
      ]
    }

    account = ProviderAccounts.get(db, id)
    assert {:ok, _, _} = Collector.record(db, account, {:ok, sample}, now, now)

    assert {200,
            %{
              "accountId" => ^id,
              "sample" => %{
                "serving" => true,
                "observedAt" => ^now,
                "windows" => [%{"usedPercent" => 42, "resetsAt" => reset}]
              }
            }} =
             get("/api/capacity/#{id}?refresh=cache", options)

    assert reset == now + 60_000

    assert {200, %{"accountId" => ^id, "samples" => [_]}} =
             get("/api/capacity/#{id}/history", options)

    assert {200, %{"accountId" => ^id, "windows" => [_]}} =
             get("/api/capacity/#{id}/forecast", options)

    assert {200, %{"accounts" => [%{"accountId" => ^id}], "pools" => [_]}} =
             get("/api/capacity/forecast", options)

    assert {200, %{"providers" => %{"openai" => %{"accounts" => %{"total" => 1, "ready" => 1}}}}} =
             get("/api/capacity/health", options)
  end

  test "capacity observation invalidates its opaque account after commit", %{db: db} do
    hub = start_supervised!({Hub, name: nil, db: db})
    Hub.register(hub)
    now = System.system_time(:millisecond)

    {:ok, :ok} =
      ProviderAccounts.record_existing_shared(
        db,
        "test-host",
        "openai",
        "codex",
        "subscription",
        "signed_in",
        "ok",
        now
      )

    id = ProviderAccounts.shared_id(db, "codex", "test-host")
    account = ProviderAccounts.get(db, id)

    sample = %{
      observed_at: now,
      plan: "pro",
      diagnostics: [],
      subscription: %{},
      windows: [
        %{
          id: "primary",
          name: "Primary",
          used_percent: 42,
          window_seconds: 18000,
          scope: "account",
          model: nil,
          resets_at: now + 60_000
        }
      ]
    }

    assert {:ok, _, _} = Collector.record(db, account, {:ok, sample}, now, now, hub: hub)

    assert_receive {:firehose_notice,
                    %{
                      "class" => "capacity.changed",
                      "refs" => %{"accountId" => ^id},
                      "payload" => %{"sourceVersion" => ^now}
                    } = notice}

    refute Tightbeam.StateVisibility.visible?(db, notice, "reader", false)
    assert Tightbeam.StateVisibility.visible?(db, notice, "admin", true)
    assert map_size(notice["payload"]) == 1

    assert :ok = Hub.register(hub, self(), %{mode: :filtered, is_admin: false})

    assert :ok =
             Hub.subscribe(hub, self(), "capacity", %{
               "classes" => ["capacity.changed"],
               "accountId" => id
             })

    later = now + 1
    assert {:ok, _, _} = Collector.record(db, account, {:ok, sample}, later, later, hub: hub)
    refute_receive {:firehose_notice, %{"class" => "capacity.changed"}}
    assert Hub.sequence(hub, self()) == 0

    assert :ok = Hub.register(hub, self(), %{mode: :filtered, is_admin: true})
    later = now + 2
    assert {:ok, _, _} = Collector.record(db, account, {:ok, sample}, later, later, hub: hub)

    assert_receive {:firehose_notice,
                    %{
                      "class" => "capacity.changed",
                      "seq" => 1,
                      "payload" => %{"sourceVersion" => ^later}
                    }}
  end

  defp get(path, options, token \\ "synthetic-capacity-auth") do
    response =
      conn(:get, path)
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init(options))

    {response.status, JSON.decode!(response.resp_body)}
  end
end
