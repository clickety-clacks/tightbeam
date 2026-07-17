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
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
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
      case "session/new": return send({ id: m.id, result: { sessionId: "sess-1" } });
      case "session/load": return send({ id: m.id, result: {} });
      case "session/set_config_option": return send({ id: m.id, result: { configOptions: [] } });
      case "session/set_mode": return send({ id: m.id, result: {} });
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

  defp start_adapter do
    path = Path.join(System.tmp_dir!(), "fake_harness_#{System.unique_integer([:positive])}.js")
    File.write!(path, @fake)

    start_supervised!(
      {Adapter,
       harness: :claude,
       cmd: [System.find_executable("node"), path],
       home: "/tmp",
       cwd: "/tmp",
       name: :"adapter_#{System.unique_integer([:positive])}"}
    )
  end

  test "new_session applies model then prompt streams+accumulates, permission auto-allowed" do
    a = start_adapter()
    assert {:ok, "sess-1"} = Adapter.new_session(a, "haiku")
    assert {:ok, %{stop_reason: "end_turn", text: "pong[allow-once]"}} = Adapter.prompt(a, "sess-1", "say pong")
  end

  test "load_session then prompt (rule #1 re-apply path)" do
    a = start_adapter()
    assert :ok = Adapter.load_session(a, "sess-1", "haiku")
    assert {:ok, %{stop_reason: "end_turn"}} = Adapter.prompt(a, "sess-1", "again")
  end

  test "consecutive prompts reset the accumulator" do
    a = start_adapter()
    {:ok, _} = Adapter.new_session(a, "haiku")
    assert {:ok, %{text: "pong[allow-once]"}} = Adapter.prompt(a, "sess-1", "one")
    assert {:ok, %{text: "pong[allow-once]"}} = Adapter.prompt(a, "sess-1", "two")
  end
end
