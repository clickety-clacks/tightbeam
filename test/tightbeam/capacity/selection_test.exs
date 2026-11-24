defmodule Tightbeam.Capacity.SelectionTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Capacity.{Observation, Selection, Store}
  alias Tightbeam.{DB, ProviderAccounts, Schema}

  @now 1_800_000_000_000

  test "selection evidence retains both clocks and the omitted-window and failure semantics" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    :ok = ProviderAccounts.ensure_schema(db)
    :ok = Store.ensure_schema(db)

    assert {:ok, :ok} =
             ProviderAccounts.record_existing_shared(
               db,
               "test-host",
               "openai",
               "codex",
               "subscription",
               "signed_in",
               "ok",
               @now
             )

    account_id = ProviderAccounts.shared_id(db, "codex", "test-host")

    windows = [
      %{
        id: "primary",
        name: "Primary",
        scope: "account",
        model: nil,
        used_percent: 42,
        window_seconds: 18000,
        resets_at: nil
      },
      %{
        id: "additional:unnamed:1",
        name: "Unnamed",
        scope: "model",
        model: nil,
        used_percent: 20,
        window_seconds: nil,
        resets_at: @now - 1
      }
    ]

    sample = %{
      observed_at: @now,
      plan: "plus",
      windows: windows,
      diagnostics: [],
      subscription: %{}
    }

    first = Observation.record(Observation.empty(), {:ok, sample}, @now - 10, @now)
    assert {:ok, :ok} = DB.transaction(db, &Selection.put_in_txn(&1, account_id, first))

    query = """
    SELECT windowId, model, usedPercent, observedAt, readAttemptAt, freshness
    FROM capacity_windows ORDER BY windowId
    """

    sent = @now - 10

    assert {:ok,
            [
              ["additional:unnamed:1", nil, 20.0, @now, ^sent, "reset_passed"],
              ["primary", nil, 42.0, @now, ^sent, "current"]
            ]} = DB.query(db, query, [])

    failed = Observation.record(first, {:error, %{code: "UPSTREAM_TIMEOUT"}}, @now + 1, @now + 2)
    assert {:ok, :ok} = DB.transaction(db, &Selection.put_in_txn(&1, account_id, failed))

    assert {:ok,
            [
              ["additional:unnamed:1", nil, 20.0, @now, ^sent, "UPSTREAM_TIMEOUT"],
              ["primary", nil, 42.0, @now, ^sent, "UPSTREAM_TIMEOUT"]
            ]} = DB.query(db, query, [])

    next =
      Observation.record(failed, {:ok, %{sample | windows: [hd(windows)]}}, @now + 3, @now + 4)

    assert {:ok, :ok} = DB.transaction(db, &Selection.put_in_txn(&1, account_id, next))
    observed = @now + 4
    sent = @now + 3
    assert {:ok, [["primary", nil, 42.0, ^observed, ^sent, "current"]]} = DB.query(db, query, [])
  end
end
