defmodule Tightbeam.DiagnosticSinkTest do
  use Tightbeam.TestCase, async: false
  import Plug.Test
  alias Tightbeam.Diagnostics
  alias Tightbeam.Wire.Router

  setup do
    start_supervised!({Diagnostics, name: Diagnostics, notify: self()})
    :ok
  end

  test "a failed sink write counts on gateway-owned state and never carries the record" do
    dir = Path.join(System.tmp_dir!(), "tightbeam-sink-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "db-gateway-v1.log")
    on_exit(fn -> File.rm_rf(dir) end)

    sink = unique_name(:failing_sink)
    start_supervised!(%{id: sink, start: {Diagnostics, :start_link, [[name: sink, path: path]]}})

    # Startup is degraded, so the directory and the active segment are the first
    # write's work, not the supervisor's. One record establishes both, with the
    # modes the sink is responsible for.
    refute File.exists?(dir)

    assert Diagnostics.emit(%{event: "db_call_abandoned", db_call_id: "dbc_prime"}, sink) ==
             :accepted

    Diagnostics.records(sink)

    assert rem(File.stat!(dir).mode, 0o1000) == 0o700
    assert rem(File.stat!(path).mode, 0o1000) == 0o600

    # Removing the directory under a prepared sink is the deterministic write
    # failure: no permission juggling, no timing, and the append cannot succeed.
    File.rm_rf!(dir)
    sentinel = "private-operation-sentinel"

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Diagnostics.emit(
                 %{event: "http_response_terminal", operation: sentinel},
                 sink
               ) == :accepted

        # A call is answered in mailbox order, so the cast has run by now.
        Diagnostics.records(sink)
      end)

    assert %{"event" => "diagnostic_sink_unavailable", "actor" => "process:tightbeam"} =
             JSON.decode!(String.trim(stderr))

    refute stderr =~ sentinel

    health = Diagnostics.health()
    assert health.write_failures == 1
    assert is_integer(health.last_failure_at)
    assert health.dropped_records == 0
  end

  test "a sink that can never write starts anyway and takes no dependent down with it" do
    # A regular file where a directory must go: `mkdir_p` fails with `:enotdir`
    # every time, with no permission juggling and no way for the path to start
    # working halfway through the test.
    blocker =
      Path.join(System.tmp_dir!(), "tightbeam-blocked-#{System.unique_integer([:positive])}")

    File.write!(blocker, "")
    path = Path.join([blocker, "diagnostics", "db-gateway-v1.log"])
    on_exit(fn -> File.rm_rf(blocker) end)

    sink = unique_name(:unstartable_sink)
    dependent = unique_name(:sink_dependent)

    # The production shape, small: `rest_for_one` with the sink first, so a sink
    # that refused to start would stop everything after it. In the real tree
    # that is the database, the wake scheduler, and the listener.
    {:ok, root} =
      Supervisor.start_link(
        [
          %{id: sink, start: {Diagnostics, :start_link, [[name: sink, path: path]]}},
          %{id: dependent, start: {Agent, :start_link, [fn -> :up end, [name: dependent]]}}
        ],
        strategy: :rest_for_one
      )

    assert Supervisor.count_children(root).active == 2
    started = Process.whereis(dependent)
    assert is_pid(started)

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        for index <- 1..2 do
          assert Diagnostics.emit(
                   %{event: "db_call_abandoned", db_call_id: "dbc_blocked_#{index}"},
                   sink
                 ) == :accepted
        end

        Diagnostics.records(sink)
      end)

    # Two records, two failures: preparation is retried per record, so a sink
    # whose directory appears later starts writing without a restart. A one-shot
    # that gave up would report the first failure and go quiet.
    assert Enum.count(String.split(stderr, "\n", trim: true)) == 2
    assert Diagnostics.health().write_failures == 2

    # Degraded, not blind. The records the file cannot hold are still readable
    # from memory, which is what /version and a live investigation use.
    assert length(Diagnostics.records(sink)) == 2

    # Nothing after the sink was restarted, and the sink itself is still up.
    assert Process.whereis(dependent) == started
    assert Process.alive?(Process.whereis(sink))
    assert Supervisor.count_children(root).active == 2
  end

  test "a full ingress drops the new record instead of blocking the observed operation" do
    sink = unique_name(:ingress_sink)
    start_supervised!(%{id: sink, start: {Diagnostics, :start_link, [[name: sink]]}})
    writer = Process.whereis(sink)

    # Suspending the writer is the only way to hold the full ingress at once: a
    # draining writer keeps the depth near zero, so the bound would never be hit.
    :sys.suspend(writer)
    on_exit(fn -> if Process.alive?(writer), do: :sys.resume(writer) end)

    for index <- 1..8_192 do
      assert Diagnostics.emit(%{event: "db_call_abandoned", db_call_id: "dbc_#{index}"}, sink) ==
               :accepted
    end

    assert Diagnostics.emit(%{event: "db_call_abandoned", db_call_id: "dbc_overflow"}, sink) ==
             :dropped

    health = Diagnostics.health()
    assert health.dropped_records == 1
    assert is_integer(health.last_drop_at)
    assert health.write_failures == 0

    :sys.resume(writer)
    assert length(Diagnostics.records(sink)) == 8_192

    assert Diagnostics.emit(%{event: "db_call_abandoned", db_call_id: "dbc_after"}, sink) ==
             :accepted
  end

  test "free text is clamped and an unrepresentable record is dropped, not written long" do
    sink = unique_name(:bounded_sink)

    start_supervised!(%{
      id: sink,
      start: {Diagnostics, :start_link, [[name: sink, notify: self()]]}
    })

    assert Diagnostics.emit(
             %{
               event: "http_response_terminal",
               operation: String.duplicate("o", 10_000),
               cause: String.duplicate("c", 10_000),
               principal_ref: String.duplicate("€", 5_000)
             },
             sink
           ) == :accepted

    assert_receive {:diagnostic, record}
    assert byte_size(record.operation) == 256
    assert byte_size(record.cause) == 256

    # 256 splits a 3-byte codepoint, so the clamp backs off to the last whole one
    # rather than emitting a broken string.
    assert byte_size(record.principal_ref) == 255
    assert String.valid?(record.principal_ref)
    assert byte_size(JSON.encode!(record)) <= 4_096

    # request_id is not free text, so nothing clamps it; the 4,096-byte bound is
    # checked rather than assumed, and the record is refused at submission.
    assert Diagnostics.emit(
             %{event: "http_response_terminal", request_id: String.duplicate("r", 5_000)},
             sink
           ) == :dropped

    refute_receive {:diagnostic, %{request_id: _}}
    assert Diagnostics.health().dropped_records == 1
  end

  test "the wrap log rotates on the record bound and retains exactly four segments" do
    # No DB is started here. If any diagnostic write reached Tightbeam.DB the
    # sink would crash instead of rotating, so A6's "no diagnostic write invoked
    # Tightbeam.DB" holds by construction rather than by inspection.
    dir = Path.join(System.tmp_dir!(), "tightbeam-rotate-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "db-gateway-v1.log")
    on_exit(fn -> File.rm_rf(dir) end)

    sink = unique_name(:rotate_sink)
    start_supervised!(%{id: sink, start: {Diagnostics, :start_link, [[name: sink, path: path]]}})

    # 20,480 records cross the 4,096-record segment bound four times, so the
    # oldest segment must be discarded rather than accumulate a fifth file.
    # Batches stay under the 8,192 ingress bound and each sync drains the
    # writer: the pacing is what keeps this a rotation test and not a drop test.
    for _batch <- 1..10 do
      for index <- 1..2_048 do
        assert Diagnostics.emit(%{event: "db_call_abandoned", db_call_id: "dbc_#{index}"}, sink) ==
                 :accepted
      end

      _drained = :sys.get_state(Process.whereis(sink))
    end

    assert Diagnostics.health().dropped_records == 0

    segments = [path, path <> ".1", path <> ".2", path <> ".3"]
    assert Enum.all?(segments, &File.exists?/1)
    refute File.exists?(path <> ".4")

    # Modes are exact on the directory and on every retained segment, covering
    # both the files rotation renamed and the active file it recreated.
    assert File.stat!(dir).mode == 0o40700
    assert Enum.all?(segments, &(File.stat!(&1).mode == 0o100600))

    # The record bound is the binding one: at the 4,096-byte per-record maximum
    # a full segment is exactly 16 MiB, so four segments cannot exceed 64 MiB.
    assert Enum.sum(Enum.map(segments, &File.stat!(&1).size)) <= 64 * 1024 * 1024

    # Every retained line parses, the discarded segment is really gone, and
    # in-memory retention honours its own bound instead of growing with files.
    lines = Enum.flat_map(segments, &String.split(File.read!(&1), "\n", trim: true))
    assert length(lines) == 16_384
    assert Enum.all?(lines, &(JSON.decode!(&1)["schema_version"] == "db-gateway-v1"))
    assert length(Diagnostics.records(sink)) == 16_384
  end

  test "the wrap log also rotates on the byte bound, independently of the record bound" do
    dir = Path.join(System.tmp_dir!(), "tightbeam-bytes-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "db-gateway-v1.log")
    on_exit(fn -> File.rm_rf(dir) end)

    # One byte short of the 16 MiB segment bound and containing one newline,
    # so the record bound cannot be what fires. Both bounds are real; a
    # test that only ever crosses the record count leaves the byte one unproven.
    File.mkdir_p!(dir)
    File.write!(path, String.duplicate("x", 16 * 1024 * 1024 - 2) <> "\n")

    sink = unique_name(:byte_sink)
    start_supervised!(%{id: sink, start: {Diagnostics, :start_link, [[name: sink, path: path]]}})

    assert Diagnostics.emit(%{event: "db_call_abandoned", db_call_id: "dbc_bytes"}, sink) ==
             :accepted

    _drained = :sys.get_state(Process.whereis(sink))

    assert File.exists?(path <> ".1")
    assert File.stat!(path <> ".1").size == 16 * 1024 * 1024 - 1
    assert length(:binary.matches(File.read!(path <> ".1"), "\n")) == 1

    assert String.split(File.read!(path), "\n", trim: true) |> length() == 1
    assert Diagnostics.health().write_failures == 0
  end

  test "a restarted sink inherits the active segment's occupancy instead of starting at zero" do
    dir = Path.join(System.tmp_dir!(), "tightbeam-reopen-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "db-gateway-v1.log")
    on_exit(fn -> File.rm_rf(dir) end)

    sink = unique_name(:reopen_sink)
    child = %{id: sink, start: {Diagnostics, :start_link, [[name: sink, path: path]]}}

    start_supervised!(child)
    fill_segment(sink, 4_000)
    assert segment_lines(path) == 4_000
    stop_supervised!(sink)

    # The file survives the writer. A sink that starts its counters at zero over
    # a preserved segment carries it past both bounds, and repeated restarts
    # grow one file without limit.
    start_supervised!(child)

    fill_segment(sink, 96)
    refute File.exists?(path <> ".1")
    assert segment_lines(path) == 4_096

    fill_segment(sink, 1)
    assert File.exists?(path <> ".1")
    assert segment_lines(path <> ".1") == 4_096
    assert segment_lines(path) == 1
    assert Diagnostics.health().write_failures == 0
  end

  test "a rotation that cannot complete is reported as a write failure and nothing else" do
    dir = Path.join(System.tmp_dir!(), "tightbeam-norotate-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "db-gateway-v1.log")

    on_exit(fn ->
      File.chmod(dir, 0o700)
      File.rm_rf(dir)
    end)

    sink = unique_name(:unrotatable_sink)
    start_supervised!(%{id: sink, start: {Diagnostics, :start_link, [[name: sink, path: path]]}})
    writer = Process.whereis(sink)
    ref = Process.monitor(writer)

    fill_segment(sink, 4_096)

    # Dropping write permission on the directory fails rename and create while
    # leaving an append to the existing file possible, which isolates rotation
    # as the failing step. The next record is the one that must rotate.
    File.chmod!(dir, 0o500)
    sentinel = "private-rotation-sentinel"

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Diagnostics.emit(
                 %{event: "http_response_terminal", operation: sentinel},
                 sink
               ) == :accepted

        Diagnostics.records(sink)
      end)

    assert %{"event" => "diagnostic_sink_unavailable", "actor" => "process:tightbeam"} =
             JSON.decode!(String.trim(stderr))

    refute stderr =~ sentinel

    health = Diagnostics.health()
    assert health.write_failures == 1
    assert health.dropped_records == 0

    # Principle 9: the sink failure restarts no child and loses no record. The
    # counters still describe the unrotated file, so the writer has not been
    # told it may append past the bound it failed to clear.
    refute_receive {:DOWN, ^ref, :process, ^writer, _reason}
    refute File.exists?(path <> ".1")
    assert segment_lines(path) == 4_096
    assert length(Diagnostics.records(sink)) == 4_097
  end

  test "/version reports sink health while the writer is backlogged" do
    # The fields matter most when the writer cannot answer, so the surface is
    # proven under exactly that condition.
    writer = Process.whereis(Diagnostics)
    :sys.suspend(writer)
    on_exit(fn -> if Process.alive?(writer), do: :sys.resume(writer) end)

    response = conn(:get, "/version") |> Router.call(Router.init([]))

    :sys.resume(writer)

    assert response.status == 200

    assert %{"diagnostics" => diagnostics} = JSON.decode!(response.resp_body)

    assert diagnostics == %{
             "writeFailures" => 0,
             "lastFailureAt" => nil,
             "droppedRecords" => 0,
             "lastDropAt" => nil
           }
  end

  test "restart preserves valid records before a short torn tail and subsequent records" do
    dir = Path.join(System.tmp_dir!(), "tightbeam-torn-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "db-gateway-v1.log")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    valid = JSON.encode!(%{schema_version: "db-gateway-v1", request_id: "req_before"}) <> "\n"
    torn = ~s|{"request_id":"torn|
    File.write!(path, valid <> torn)
    sink = unique_name(:torn_sink)
    start_supervised!(%{id: sink, start: {Diagnostics, :start_link, [[name: sink, path: path]]}})

    assert :accepted =
             Diagnostics.emit(%{event: "http_response_terminal", request_id: "req_after"}, sink)

    Diagnostics.records(sink)
    assert File.read!(path <> ".1") == valid <> torn
    assert JSON.decode!(String.trim(File.read!(path)))["request_id"] == "req_after"
    assert Diagnostics.health().write_failures == 0
  end

  # Batches stay under the 8,192 ingress bound and each call drains the writer,
  # so the caller knows every record has been written before it measures.
  defp fill_segment(sink, records) do
    for index <- 1..records do
      assert Diagnostics.emit(%{event: "db_call_abandoned", db_call_id: "dbc_#{index}"}, sink) ==
               :accepted
    end

    _drained = :sys.get_state(Process.whereis(sink))
    :ok
  end

  defp segment_lines(path),
    do: path |> File.read!() |> String.split("\n", trim: true) |> length()

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
