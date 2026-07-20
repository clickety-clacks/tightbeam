defmodule Tightbeam.Acp.AdapterTest do
  use ExUnit.Case, async: false

  doctest Tightbeam.Acp.Adapter

  alias Tightbeam.Acp.Adapter

  test "parse_model_ref splits effort" do
    assert Adapter.parse_model_ref("gpt-5.6-sol[medium]") == {"gpt-5.6-sol", "medium"}
    assert Adapter.parse_model_ref("haiku") == {"haiku", nil}
  end

  # Fake adapter that records the method order and streams chunks, mid-turn
  # permission included — mirrors the TS harness fake.
  @fake ~S"""
  const fs = require("node:fs");
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  const capturePath = process.argv[2];
  const failMode = process.argv[3] || "none";
  let modeCalls = 0;
  const capture = (m) => fs.appendFileSync(capturePath, JSON.stringify({ method: m.method, mcpServers: m.params.mcpServers, modeId: m.params.modeId }) + "\n");
  let pendingPrompt = null;
  rl.on("line", (line) => {
    if (!line.trim()) return;
    const m = JSON.parse(line);
    if (m.id !== undefined && m.method === undefined) {
      if (pendingPrompt !== null) {
        const opt = m.result && m.result.outcome ? m.result.outcome.optionId : "none";
        send({ method: "session/update", params: { sessionId: "sess-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "[" + opt + "]" } } } });
        send({ id: pendingPrompt, result: { stopReason: "end_turn" } });
        pendingPrompt = null;
      }
      return;
    }
    switch (m.method) {
      case "initialize": return send({ id: m.id, result: { protocolVersion: 1 } });
      case "session/new": capture(m); return send({ id: m.id, result: { sessionId: "sess-1" } });
      case "session/load": capture(m); return send({ id: m.id, result: {} });
      case "session/set_config_option": return send({ id: m.id, result: { configOptions: [] } });
      case "session/set_mode": {
        capture(m);
        modeCalls += 1;
        if (failMode === "fail" || (failMode === "fail-second" && modeCalls === 2)) {
          return send({ id: m.id, error: { code: -32000, message: "mode refused" } });
        }
        return send({ id: m.id, result: {} });
      }
      case "session/prompt": {
        const sid = m.params.sessionId;
        send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "po" } } } });
        send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "ng" } } } });
        pendingPrompt = m.id;
        send({ id: 500, method: "session/request_permission", params: { options: [ { optionId: "reject", kind: "reject_once" }, { optionId: "allow-once", kind: "allow_once" } ] } });
        return;
      }
    }
  });
  """

  defp start_adapter(opts \\ []) do
    # Per-run private dir: unique_integer resets across VM restarts, so
    # bare /tmp names collide with stale files from prior/concurrent runs.
    run_dir =
      Path.join(
        System.tmp_dir!(),
        "tb-acp-#{:os.getpid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(run_dir)
    on_exit(fn -> File.rm_rf!(run_dir) end)

    path = Path.join(run_dir, "fake_harness.js")
    capture_path = Path.join(run_dir, "capture.jsonl")

    File.write!(path, @fake)

    harness = Keyword.get(opts, :harness, :claude)
    contained = Keyword.get(opts, :contained, false)
    fail_mode = Keyword.get(opts, :fail_mode, "none")

    adapter_opts =
      [
        harness: harness,
        cmd: [System.find_executable("node"), path, capture_path, fail_mode],
        home: "/tmp",
        cwd: "/tmp",
        name: :"adapter_#{System.unique_integer([:positive])}"
      ]
      |> then(fn adapter_opts ->
        if contained, do: Keyword.put(adapter_opts, :contained, true), else: adapter_opts
      end)

    adapter =
      start_supervised!(%{
        id: {:adapter, System.unique_integer([:positive])},
        start: {Adapter, :start_link, [adapter_opts]}
      })

    {adapter, capture_path}
  end

  defp captured_requests(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp session_requests(path) do
    Enum.filter(captured_requests(path), &(&1["method"] in ["session/new", "session/load"]))
  end

  test "new_session applies model then prompt streams+accumulates, permission auto-allowed" do
    {a, capture_path} = start_adapter()

    mcp_servers = [
      %{"name" => "build", "command" => "builder", "args" => [], "env" => []}
    ]

    assert {:ok, "sess-1"} = Adapter.new_session(a, "haiku", "/tmp", mcp_servers)

    assert [%{"method" => "session/new", "mcpServers" => ^mcp_servers}] =
             session_requests(capture_path)

    assert {:ok, %{stop_reason: "end_turn", text: "pong[allow-once]"}} =
             Adapter.prompt(a, "sess-1", "say pong")
  end

  test "load_session then prompt (rule #1 re-apply path)" do
    {a, capture_path} = start_adapter()

    mcp_servers = [
      %{"name" => "build", "command" => "builder", "args" => ["--fast"], "env" => []}
    ]

    assert :ok = Adapter.load_session(a, "sess-1", "haiku", "/tmp", mcp_servers)

    assert [%{"method" => "session/load", "mcpServers" => ^mcp_servers}] =
             session_requests(capture_path)

    assert {:ok, %{stop_reason: "end_turn"}} = Adapter.prompt(a, "sess-1", "again")
  end

  test "new_session and load_session still send an empty mcpServers list" do
    {a, capture_path} = start_adapter()
    assert {:ok, "sess-1"} = Adapter.new_session(a, "haiku", "/tmp", [])
    assert :ok = Adapter.load_session(a, "sess-1", "haiku", "/tmp", [])

    assert [
             %{"method" => "session/new", "mcpServers" => []},
             %{"method" => "session/load", "mcpServers" => []}
           ] = session_requests(capture_path)
  end

  test "consecutive prompts reset the accumulator" do
    {a, _capture_path} = start_adapter()
    {:ok, _} = Adapter.new_session(a, "haiku", "/tmp", [])
    assert {:ok, %{text: "pong[allow-once]"}} = Adapter.prompt(a, "sess-1", "one")
    assert {:ok, %{text: "pong[allow-once]"}} = Adapter.prompt(a, "sess-1", "two")
  end

  test "preset modes are pinned for both harnesses" do
    for {harness, expected} <- [claude: "bypassPermissions", codex: "agent-full-access"] do
      {adapter, capture_path} = start_adapter(harness: harness)
      assert {:ok, "sess-1"} = Adapter.new_session(adapter, "haiku", "/tmp", [])

      assert [%{"method" => "session/set_mode", "modeId" => ^expected}] =
               Enum.filter(captured_requests(capture_path), &(&1["method"] == "session/set_mode"))
    end
  end

  test "load asserts mode only when contained" do
    {plain, plain_capture} = start_adapter()
    assert :ok = Adapter.load_session(plain, "sess-1", "haiku", "/tmp", [])
    refute Enum.any?(captured_requests(plain_capture), &(&1["method"] == "session/set_mode"))

    {contained, contained_capture} = start_adapter(contained: true)
    assert :ok = Adapter.load_session(contained, "sess-1", "haiku", "/tmp", [])
    assert Adapter.knows_session?(contained, "sess-1")

    assert [%{"method" => "session/set_mode", "modeId" => "bypassPermissions"}] =
             Enum.filter(
               captured_requests(contained_capture),
               &(&1["method"] == "session/set_mode")
             )
  end

  test "contained mode failures are structured while uncontained new remains best effort" do
    {plain, _capture} = start_adapter(fail_mode: "fail")
    assert {:ok, "sess-1"} = Adapter.new_session(plain, "haiku", "/tmp", [])

    {contained_new, _capture} = start_adapter(contained: true, fail_mode: "fail")

    assert {:error, :contained_sandbox_disable_failed} =
             Adapter.new_session(contained_new, "haiku", "/tmp", [])

    refute Adapter.knows_session?(contained_new, "sess-1")

    {contained_load, _capture} = start_adapter(contained: true, fail_mode: "fail")

    assert {:error, :contained_sandbox_disable_failed} =
             Adapter.load_session(contained_load, "sess-1", "haiku", "/tmp", [])

    refute Adapter.knows_session?(contained_load, "sess-1")
  end

  test "contained load mode failure evicts prior known residency" do
    {adapter, _capture} = start_adapter(contained: true, fail_mode: "fail-second")
    assert :ok = Adapter.load_session(adapter, "sess-1", "haiku", "/tmp", [])
    assert Adapter.knows_session?(adapter, "sess-1")

    assert {:error, :contained_sandbox_disable_failed} =
             Adapter.load_session(adapter, "sess-1", "haiku", "/tmp", [])

    refute Adapter.knows_session?(adapter, "sess-1")
  end
end
