defmodule Tightbeam.DiagnosticRetentionTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Diagnostics

  test "slow transactions and refusals outlive ordinary traffic in memory and JSON segments" do
    dir = Path.join(System.tmp_dir!(), "retention-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "db-gateway-v1.log")
    on_exit(fn -> File.rm_rf!(dir) end)
    sink = start_supervised!({Diagnostics, name: :retention_sink, path: path})

    slow = %{
      event: "db_server_completed",
      operation: "db.transaction",
      callback_ms: 1_000,
      queue_ms: 12,
      total_ms: 1_012,
      request_id: "int_slow",
      db_call_id: "dbc_slow",
      caller: "internal:test",
      observed_at_ms: 1
    }

    refused = %{
      event: "db_caller_completed",
      operation: "db.execute",
      result_class: "db_overloaded",
      queue_ms: 0,
      total_ms: 0,
      request_id: "req_refused",
      db_call_id: "dbc_refused",
      caller: "POST /agent/dispatch"
    }

    queued = %{
      event: "db_caller_completed",
      operation: "db.query",
      queue_ms: 1_000,
      total_ms: 1_001,
      db_call_id: "dbc_queued"
    }

    for record <- [slow, refused, queued], do: assert(Diagnostics.emit(record, sink) == :accepted)

    for batch <- 1..12 do
      for index <- 1..4_096 do
        assert Diagnostics.emit(
                 %{
                   event: "db_caller_completed",
                   operation: "db.query",
                   total_ms: 1,
                   queue_ms: 0,
                   db_call_id: "dbc_fast_#{batch}_#{index}"
                 },
                 sink
               ) == :accepted
      end

      Diagnostics.records(sink)
    end

    records = Diagnostics.records(sink)

    for id <- ["dbc_slow", "dbc_refused", "dbc_queued"] do
      assert Enum.any?(records, &(&1.db_call_id == id))
    end

    assert length(records) == 16_387

    assert [persisted] =
             path
             |> Kernel.<>(".slow")
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&JSON.decode!/1)

    assert persisted["db_call_id"] == "dbc_slow"
    assert persisted["observed_at_ms"] == 1
    assert persisted["caller"] == "internal:test"
    assert File.read!(path <> ".pressure") =~ "dbc_refused"
    refute File.read!(path) =~ "dbc_slow"

    # Even a sustained refusal burst cannot evict the slow writer history.
    for _batch <- 1..5 do
      for _ <- 1..4_096, do: Diagnostics.emit(refused, sink)
      Diagnostics.records(sink)
    end

    assert Enum.any?(Diagnostics.records(sink), &(&1.db_call_id == "dbc_slow"))
    segments = Path.wildcard(path <> ".pressure*")
    assert length(segments) == 4
    assert Enum.all?(segments, &(length(String.split(File.read!(&1), "\n", trim: true)) <= 4_096))
    assert Diagnostics.health().dropped_records == 0
  end
end
