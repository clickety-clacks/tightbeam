defmodule Tightbeam.Capacity.StoreTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Capacity.{Observation, Store}
  alias Tightbeam.DB

  @now 1_800_000_000_000

  test "latest usage and provider hold survive SQLite reopen", %{test: test} do
    base = Path.join(System.tmp_dir!(), "#{test}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    path = Path.join(base, "state.db")
    payload = Path.join(base, "payload")
    File.mkdir_p!(Path.join(payload, "ebin"))
    File.mkdir_p!(Path.join(payload, "priv"))
    File.write!(Path.join([payload, "priv", "fixture"]), "capacity store fixture")

    {:ok, manifest} =
      Tightbeam.LiveBaseGuard.generate_manifest(Tightbeam.LiveBasePayload.files!(payload))

    File.write!(Path.join(payload, "build-manifest.json"), JSON.encode!(manifest))

    db = start_supervised!({DB, path: path, name: nil, guard_inputs: [], payload_root: payload})
    :ok = Tightbeam.Schema.ensure_all(db)

    assert {:ok, :ok} =
             Tightbeam.ProviderAccounts.record_existing_shared(
               db,
               "test-host",
               "openai",
               "codex",
               "subscription",
               "signed_in",
               "ok",
               @now
             )

    id = Tightbeam.ProviderAccounts.shared_id(db, "codex", "test-host")
    :ok = Store.ensure_schema(db)
    assert Store.entry(db, id) == Observation.empty()

    sample = %{
      observed_at: @now - 30,
      plan: "plus",
      subscription: %{},
      diagnostics: [],
      windows: [
        %{
          id: "primary",
          name: "Primary",
          scope: "account",
          model: nil,
          used_percent: 42,
          resets_at: nil,
          window_seconds: 18_000
        }
      ]
    }

    assert {:ok, {:ok, _, %{sample: %{observed_at: @now}}}} =
             DB.transaction(db, &Store.record_in_txn(&1, id, {:ok, sample}, @now - 40, @now))

    rate_limit = {:error, %{code: "UPSTREAM_RATE_LIMITED", retry_after_seconds: 120}}

    assert {:ok, {:ok, _, %{retry_at: retry_at}}} =
             DB.transaction(db, &Store.record_in_txn(&1, id, rate_limit, @now + 1, @now + 2))

    stop_supervised!(DB)
    db = start_supervised!({DB, path: path, name: nil, guard_inputs: [], payload_root: payload})
    :ok = Store.ensure_schema(db)
    assert entry = Store.entry(db, id)
    assert entry.retry_at == retry_at
    assert entry.sample == %{sample | observed_at: @now}
    assert [%{observed_at: @now}] = Store.history(db, id, @now + 3)
    assert Store.history(db, id, @now + :timer.hours(169)) == []

    assert {:error, _} =
             DB.transaction(db, fn txn ->
               :ok = Store.delete_in_txn(txn, id)
               raise "rollback"
             end)

    assert Store.entry(db, id) == entry
  end
end
