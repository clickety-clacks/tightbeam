defmodule Tightbeam.Acp.ConnTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Acp.Conn

  # Scripted fake adapter (node, same protocol as the TS fakes): responds to
  # initialize/echo/fail; "never" never answers; "slow" answers after a delay;
  # emits a notification on ping.me; issues a permission request on ask.back;
  # on session/cancel notification, ANSWERS the outstanding "never" request
  # (the quiescence signal).
  @fake ~S"""
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  let neverId = null;
  rl.on("line", (line) => {
    if (!line.trim()) return;
    const m = JSON.parse(line);
    if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1 } });
    else if (m.method === "echo") send({ id: m.id, result: m.params });
    else if (m.method === "fail") send({ id: m.id, error: { code: -32000, message: "nope" } });
    else if (m.method === "never") { neverId = m.id; }
    else if (m.method === "slow") setTimeout(() => send({ id: m.id, result: { slow: true } }), 150);
    else if (m.method === "ping.me") send({ method: "session/update", params: { note: "hi" } });
    else if (m.method === "ask.back") {
      send({ id: 900, method: "session/request_permission", params: { options: [
        { optionId: "reject", kind: "reject_once" }, { optionId: "allow-once", kind: "allow_once" } ] } });
      rl.once("line", (ans) => send({ id: m.id, result: { answered: JSON.parse(ans).result.outcome.optionId } }));
    }
    else if (m.method === "session/cancel" && neverId !== null) {
      send({ id: neverId, error: { code: -32800, message: "canceled" } });
      neverId = null;
    }
  });
  """

  defp start_conn(ctx_name) do
    script_path = Path.join(System.tmp_dir!(), "fake_adapter_#{ctx_name}.js")
    File.write!(script_path, @fake)

    start_supervised!(
      {Conn, cmd: [System.find_executable("node"), script_path], subscriber: self()}
    )
  end

  test "request/response over ndjson; errors surface as tuples" do
    conn = start_conn("basic")
    assert {:ok, %{"protocolVersion" => 1}} = Conn.request(conn, "initialize", %{})
    assert {:ok, %{"a" => 1}} = Conn.request(conn, "echo", %{a: 1})
    assert {:error, %{"code" => -32000}} = Conn.request(conn, "fail", %{})
  end

  test "dispatch notification follows the port write and carries the ACP request id" do
    conn = start_conn("dispatch")
    assert {:ok, %{"protocolVersion" => 1}} = Conn.request(conn, "initialize", %{})
    owner = self()
    ref = make_ref()

    request =
      Task.async(fn ->
        Conn.request(conn, "echo", %{boundary: true}, notify_dispatched: {owner, ref})
      end)

    assert_receive {:acp_request_dispatched, ^ref, 2}
    assert {:ok, %{"boundary" => true}} = Task.await(request)

    Conn.close(conn)
    closed_ref = make_ref()

    assert {:error, :closed} =
             Conn.request(conn, "echo", %{}, notify_dispatched: {owner, closed_ref})

    assert_receive {:acp_request_not_dispatched, ^closed_ref, :closed}
    refute_receive {:acp_request_dispatched, ^closed_ref, _request_id}
  end

  test "a port that dies before its exit message is handled reports not dispatched" do
    conn = start_conn("closed_port_race")
    assert {:ok, %{"protocolVersion" => 1}} = Conn.request(conn, "initialize", %{})

    port = :sys.get_state(conn).port
    :ok = :sys.suspend(conn)
    owner = self()
    ref = make_ref()

    request =
      Task.async(fn ->
        Conn.request(conn, "echo", %{boundary: true}, notify_dispatched: {owner, ref})
      end)

    assert eventually(fn ->
             Process.info(conn, :message_queue_len) == {:message_queue_len, 1}
           end)

    true = Port.close(port)
    :ok = :sys.resume(conn)

    assert {:error, :closed} = Task.await(request)
    assert_receive {:acp_request_not_dispatched, ^ref, :closed}
    refute_receive {:acp_request_dispatched, ^ref, _request_id}
    assert :sys.get_state(conn).closed
  end

  test "notifications reach the subscriber" do
    conn = start_conn("notif")
    # `notify` is fire-and-forget, so with nothing waited on first the budget below covers
    # a `node` spawn as well as the round trip it is about — which is how this went red on
    # the 4-core runner (#59). `initialize` returns on the harness's own reply, so it ends
    # when the boot ends rather than on a clock of ours, and the budget then measures the
    # notification alone.
    assert {:ok, %{"protocolVersion" => 1}} = Conn.request(conn, "initialize", %{})
    Conn.notify(conn, "ping.me", %{})
    assert_receive {:acp_notification, "session/update", %{"note" => "hi"}}, 2_000
  end

  test "server->client permission requests are auto-allowed with the allow option" do
    conn = start_conn("perm")
    assert {:ok, %{"answered" => "allow-once"}} = Conn.request(conn, "ask.back", %{})
  end

  test "timeout replies but KEEPS the pending entry until resolution" do
    conn = start_conn("timeout")
    # Same boot barrier as the notification test, and here it also fixes WHY the
    # request below times out: with a cold harness the 100ms expires because
    # `node` has not started, not because "never" went unanswered. The timeout
    # only means what the test says it means once the harness is up.
    assert {:ok, %{"protocolVersion" => 1}} = Conn.request(conn, "initialize", %{})
    assert {:error, :timeout} = Conn.request(conn, "never", %{}, timeout: 100)
    assert map_size(:sys.get_state(conn).pending) == 1
    # adapter eventually answers (via cancel path) -> entry resolves
    Conn.notify(conn, "session/cancel", %{})
    assert eventually(fn -> map_size(:sys.get_state(conn).pending) == 0 end)
  end

  test "an unbounded prompt request stays pending until an event resolves it" do
    conn = start_conn("unbounded")
    assert {:ok, %{"protocolVersion" => 1}} = Conn.request(conn, "initialize", %{})

    task =
      Task.async(fn ->
        Conn.request(conn, "never", %{}, session_id: "sess-unbounded", timeout: :infinity)
      end)

    assert eventually(fn -> map_size(:sys.get_state(conn).pending) == 1 end)
    assert Task.yield(task, 150) == nil

    Task.shutdown(task, :brutal_kill)
    assert_receive {:acp_orphan_resolved, "sess-unbounded"}, 2_000
    assert map_size(:sys.get_state(conn).pending) == 0
  end

  test "requester death sends session/cancel; adapter's eventual answer is the quiescence signal" do
    conn = start_conn("orphan")
    # Same boot barrier as the notification test: everything below is sub-millisecond once
    # the harness is up, and a `node` spawn does not fit anyone's budget under load.
    assert {:ok, %{"protocolVersion" => 1}} = Conn.request(conn, "initialize", %{})

    task =
      Task.async(fn ->
        Conn.request(conn, "never", %{}, session_id: "sess-1", timeout: 60_000)
      end)

    # The request must be REGISTERED before the requester dies, or there is no
    # orphan to resolve and the assertion below waits on something nobody will
    # ever send. Waiting on the pending entry itself is that fact; the sleep it
    # replaces was a guess at how long a Task takes to start.
    assert eventually(fn -> map_size(:sys.get_state(conn).pending) == 1 end)
    Task.shutdown(task, :brutal_kill)

    # conn sends session/cancel for sess-1; fake answers the orphaned request;
    # conn emits quiescence instead of replying to the dead caller.
    assert_receive {:acp_orphan_resolved, "sess-1"}, 2_000
    assert map_size(:sys.get_state(conn).pending) == 0
  end

  test "port exit fails outstanding requests and emits acp_exit" do
    conn = start_conn("exit")
    assert {:ok, %{"protocolVersion" => 1}} = Conn.request(conn, "initialize", %{})
    task = Task.async(fn -> Conn.request(conn, "never", %{}, timeout: 60_000) end)

    # There has to BE an outstanding request for the close to fail one. The boot
    # barrier above means the count can only be the "never" below it.
    assert eventually(fn -> map_size(:sys.get_state(conn).pending) == 1 end)
    Conn.close(conn)
    assert {:error, :closed} = Task.await(task)
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end
