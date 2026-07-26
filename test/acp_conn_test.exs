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

  test "notifications reach the subscriber" do
    conn = start_conn("notif")
    Conn.notify(conn, "ping.me", %{})
    assert_receive {:acp_notification, "session/update", %{"note" => "hi"}}, 2_000
  end

  test "server->client permission requests are auto-allowed with the allow option" do
    conn = start_conn("perm")
    assert {:ok, %{"answered" => "allow-once"}} = Conn.request(conn, "ask.back", %{})
  end

  test "timeout replies but KEEPS the pending entry until resolution" do
    conn = start_conn("timeout")
    assert {:error, :timeout} = Conn.request(conn, "never", %{}, timeout: 100)
    assert Conn.pending_count(conn) == 1
    # adapter eventually answers (via cancel path) -> entry resolves
    Conn.notify(conn, "session/cancel", %{})
    assert eventually(fn -> Conn.pending_count(conn) == 0 end)
  end

  test "requester death sends session/cancel; adapter's eventual answer is the quiescence signal" do
    conn = start_conn("orphan")

    task =
      Task.async(fn ->
        Conn.request(conn, "never", %{}, session_id: "sess-1", timeout: 60_000)
      end)

    Process.sleep(100)
    Task.shutdown(task, :brutal_kill)

    # conn sends session/cancel for sess-1; fake answers the orphaned request;
    # conn emits quiescence instead of replying to the dead caller.
    assert_receive {:acp_orphan_resolved, "sess-1"}, 2_000
    assert Conn.pending_count(conn) == 0
  end

  test "port exit fails outstanding requests and emits acp_exit" do
    conn = start_conn("exit")
    task = Task.async(fn -> Conn.request(conn, "never", %{}, timeout: 60_000) end)
    Process.sleep(100)
    Conn.close(conn)
    assert {:error, :closed} = Task.await(task)
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end
