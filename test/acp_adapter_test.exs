defmodule Tightbeam.Acp.AdapterTest do
  use Tightbeam.TestCase, async: false
  import ExUnit.CaptureLog

  doctest Tightbeam.Acp.Adapter

  alias Tightbeam.Acp.Adapter

  defmodule SlowBootAdapter do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    @impl true
    def init(parent) do
      {:ok, parent, {:continue, :boot}}
    end

    @impl true
    def handle_continue(:boot, parent) do
      send(parent, {:adapter_booting, self()})

      receive do
        :finish_boot -> {:noreply, parent}
      end
    end

    @impl true
    def handle_call({:knows_session?, "resident"}, _from, parent),
      do: {:reply, true, parent}
  end

  defmodule AdapterCallingWakeScheduler do
    use GenServer

    def start_link({adapter_slot, owner}) do
      GenServer.start_link(__MODULE__, {adapter_slot, owner}, name: Tightbeam.WakeScheduler)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:fire_matching, fact_id}, _from, {adapter_slot, owner} = state) do
      adapter = Agent.get(adapter_slot, & &1)
      resident? = Tightbeam.Acp.Adapter.knows_session?(adapter, "missing")
      send(owner, {:matching_fired, fact_id, resident?})
      {:reply, :ok, state}
    end
  end

  test "parse_model_ref splits effort" do
    assert Adapter.parse_model_ref("gpt-5.6-sol[medium]") == {"gpt-5.6-sol", "medium"}
    assert Adapter.parse_model_ref("haiku") == {"haiku", nil}
  end

  test "residency waits behind slow adapter boot and dead adapters fail promptly" do
    adapter = start_supervised!({SlowBootAdapter, self()})
    assert_receive {:adapter_booting, ^adapter}

    queued =
      Task.async(fn ->
        try do
          Adapter.knows_session?(adapter, "resident")
        catch
          :exit, reason -> {:exit, reason}
        end
      end)

    # The boot-boundary proof (task #20): a residency call legally queues behind a
    # slow codex boot, and the 5s DEFAULT GenServer.call budget it replaced would
    # have given up. There is no way to observe "did not give up at 5s" in under
    # 5s, so the wait below is the price of the assertion, not slack.
    #
    # The barrier has to prove the call's TIMER is armed, which takes two separate
    # facts. Neither alone is enough, and a marker the task sends about itself is
    # neither: it is sent before `knows_session?/2` is even entered.
    assert call_armed?(adapter, queued.pid, {:knows_session?, "resident"})
    Process.sleep(5_500)
    assert Task.yield(queued, 0) == nil

    send(adapter, :finish_boot)
    assert Task.await(queued) == true

    GenServer.stop(adapter)
    started = System.monotonic_time(:millisecond)

    assert {:error, {:adapter_unavailable, _reason}} =
             Adapter.knows_session?(adapter, "resident")

    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  # Fake adapter that records the method order and streams chunks, mid-turn
  # permission included — mirrors the TS harness fake.
  @fake ~S"""
  const fs = require("node:fs");
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  const capturePath = process.argv[2];
  const failMode = process.argv[3] || "none";
  const gateMode = process.argv[4] || "none";
  // When this harness came up. A deadline the adapter enforces AFTER the spawn can only
  // be timed from here; timing it from before the spawn bills `node` startup to it.
  fs.writeFileSync(capturePath + ".boot", String(Date.now()));
  let newCalls = 0;
  const models = {};
  const efforts = {};
  const configOptions = (sid) => ({ configOptions: [
    { id: "model", currentValue: models[sid] || "haiku" },
    { id: "effort", currentValue: efforts[sid] || "default" },
    { id: "reasoning_effort", currentValue: efforts[sid] || "medium" }
  ] });
  const capture = (m) => fs.appendFileSync(capturePath, JSON.stringify({ method: m.method, mcpServers: m.params.mcpServers, modeId: m.params.modeId, configId: m.params.configId, value: m.params.value, cwd: m.params.cwd, sessionId: m.params.sessionId, prompt: m.params.prompt, meta: m.params._meta }) + "\n");
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
      case "session/new": {
        newCalls += 1;
        capture(m);
        const sid = gateMode !== "none" && newCalls === 1 ? "probe-sess" : "sess-1";
        models[sid] = models[sid] || "haiku";
        return send({ id: m.id, result: { sessionId: sid, ...configOptions(sid) } });
      }
      case "session/load": {
        capture(m);
        models[m.params.sessionId] = failMode === "load-owner" ? "owner-model" : (models[m.params.sessionId] || "haiku");
        return send({ id: m.id, result: configOptions(m.params.sessionId) });
      }
      case "session/close": capture(m); return send({ id: m.id, result: {} });
      case "session/set_config_option": {
        capture(m);
        if (failMode === "model-refusal") {
          return send({ id: m.id, error: { code: -32000, message: "Invalid value for config option model" } });
        }
        if (failMode === "model-invalid-params" && m.params.configId === "model") {
          // Recorded live 2026-07-28: codex-acp's refusal of a model value the
          // catalog advertised (`gpt-5.1-codex`) — JSON-RPC -32602 Invalid params.
          return send({ id: m.id, error: { code: -32602, message: "Invalid params" } });
        }
        if (m.params.configId === "model") models[m.params.sessionId] = m.params.value;
        if (m.params.configId === "effort" || m.params.configId === "reasoning_effort") efforts[m.params.sessionId] = m.params.value;
        return send({ id: m.id, result: configOptions(m.params.sessionId) });
      }
      case "session/set_mode": {
        capture(m);
        if (failMode === "fail") {
          return send({ id: m.id, error: { code: -32000, message: "mode refused" } });
        }
        return send({ id: m.id, result: {} });
      }
      case "session/prompt": {
        const sid = m.params.sessionId;
        capture(m);
        if (gateMode === "stall-turn") return;
        if (sid === "probe-sess") {
          if (gateMode === "pass-message") {
            send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Command blocked [gate: tightbeam-probe]" } } } });
            return send({ id: m.id, result: { stopReason: "end_turn" } });
          }
          if (gateMode === "pass-then-die") {
            send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Command blocked [gate: tightbeam-probe]" } } } });
            send({ id: m.id, result: { stopReason: "end_turn" } });
            return setTimeout(() => {
              process.stderr.write("x".repeat(20000) + "\nadapter exploded: credential socket closed\n");
              process.exit(137);
            }, 25);
          }
          if (gateMode === "pass-tool") {
            send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "tool_call", content: [{ type: "content", content: { type: "text", text: "Command blocked [gate: tightbeam-probe]" } }] } } });
            return send({ id: m.id, result: { stopReason: "end_turn" } });
          }
          if (gateMode === "no-marker") {
            send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "command not found" } } } });
            return send({ id: m.id, result: { stopReason: "end_turn" } });
          }
          if (gateMode === "drift") {
            send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "drifted_shape", zz_payload: { text: "x".repeat(8000) } } } });
            return send({ id: m.id, result: { stopReason: "end_turn" } });
          }
          if (gateMode === "turn-error") {
            process.stderr.write("probe turn failed: adapter transport unavailable\n");
            return send({ id: m.id, error: { code: -32000, message: "probe turn failed" } });
          }
          if (gateMode === "stall") return;
        }
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
    fail_mode = Keyword.get(opts, :fail_mode, "none")
    gate_mode = Keyword.get(opts, :gate_mode, "none")
    probe? = Keyword.get(opts, :probe, gate_mode != "none")
    stderr_path = Path.join(run_dir, "stderr.log")

    adapter_opts =
      [
        harness: harness,
        cmd: [System.find_executable("node"), path, capture_path, fail_mode, gate_mode],
        home: "/tmp",
        cwd: "/tmp",
        name: :"adapter_#{System.unique_integer([:positive])}"
      ]
      |> then(fn adapter_opts ->
        case Keyword.get(opts, :stderr_path, stderr_path) do
          :omit -> adapter_opts
          path -> Keyword.put(adapter_opts, :stderr_path, path)
        end
      end)
      |> then(fn adapter_opts ->
        case Keyword.fetch(opts, :gate_log_path) do
          {:ok, path} -> Keyword.put(adapter_opts, :gate_log_path, path)
          :error -> adapter_opts
        end
      end)
      |> then(fn adapter_opts ->
        if probe? do
          adapter_opts
          |> Keyword.put(:probe_cwd, Keyword.get(opts, :probe_cwd, "/tmp/gate-probe"))
          |> Keyword.put(:probe_model, Keyword.get(opts, :probe_model, "gpt-5.6-sol[medium]"))
          |> Keyword.put(
            :gate_attestation_timeout,
            Keyword.get(opts, :gate_attestation_timeout, 2_000)
          )
        else
          adapter_opts
        end
      end)
      |> then(fn adapter_opts ->
        case Keyword.get(opts, :on_ready) do
          nil -> adapter_opts
          ready -> Keyword.put(adapter_opts, :on_ready, ready)
        end
      end)
      |> then(fn adapter_opts ->
        case Keyword.get(opts, :on_auth_event) do
          nil -> adapter_opts
          handler -> Keyword.put(adapter_opts, :on_auth_event, handler)
        end
      end)
      |> then(fn adapter_opts ->
        case Keyword.get(opts, :on_subagent_event) do
          nil -> adapter_opts
          handler -> Keyword.put(adapter_opts, :on_subagent_event, handler)
        end
      end)

    adapter =
      start_supervised!(%{
        id: {:adapter, System.unique_integer([:positive])},
        start: {Adapter, :start_link, [adapter_opts]},
        restart: :temporary
      })

    {adapter, capture_path}
  end

  # Booting an adapter spawns `node` and round-trips `initialize`, so how long it takes
  # belongs to the machine, not to us: every fixed assert_receive budget over a boot in
  # this file was a bet on the runner's load, and the 4-core CI runner collected (#83).
  # These wait on the two things that can actually happen — the adapter reports, or it
  # dies and says why — with no clock of their own. The reported reason is still matched
  # exactly by the caller, and a death now names itself instead of arriving as a bare
  # "no message after N ms". A genuine hang is ExUnit's per-test timeout to catch.
  defp assert_ready(adapter, message) do
    ref = Process.monitor(adapter)

    receive do
      ^message ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, ^adapter, reason} ->
        flunk("adapter died before reporting ready: #{inspect(reason)}")
    end
  end

  # Is `request` sent AND is its timeout running? Two facts, because a call that is
  # supposed to sit unanswered can be evidenced by neither party alone: the callee
  # cannot reply, and the caller can only speak about itself.
  #
  # `queued_at?` is the send. Matching the `$gen_call` names the specific request
  # rather than counting messages, so an unrelated one cannot satisfy it.
  #
  # `waiting_in_gen_call?` is the timer, and it is the half that matters. OTP runs
  # `erlang:send` and only THEN enters `receive ... after Timeout` (gen.erl:262), so
  # the message can be queued while the caller has not yet armed anything — and a
  # caller descheduled in that gap would push a reverted 5s budget past the 5.5s
  # window below, passing the test on a defect. A process in that gap is `:runnable`;
  # `:waiting` means it is suspended IN a receive, and the only blocking receive in
  # `do_call/4` is the timed one. So `:waiting` there is the `after` clause armed,
  # which is exactly the fact the window needs and the one the gap cannot fake.
  #
  # The MFA is OTP-internal on purpose — nothing public reports it. If a future OTP
  # renames it this stops matching, the barrier exhausts, and the test fails loudly
  # rather than going quietly back to proving nothing.
  defp call_armed?(adapter, caller, request, remaining \\ 500) do
    cond do
      queued_at?(adapter, request) and waiting_in_gen_call?(caller) -> true
      remaining == 0 -> false
      true -> Process.sleep(10) && call_armed?(adapter, caller, request, remaining - 1)
    end
  end

  defp queued_at?(adapter, request) do
    case Process.info(adapter, :messages) do
      {:messages, messages} ->
        Enum.any?(messages, &match?({:"$gen_call", _from, ^request}, &1))

      nil ->
        flunk("adapter died before the call reached it")
    end
  end

  defp waiting_in_gen_call?(caller) do
    case {Process.info(caller, :status), Process.info(caller, :current_function)} do
      {{:status, :waiting}, {:current_function, {:gen, :do_call, _arity}}} -> true
      {nil, _} -> flunk("caller died before its call armed a timer")
      _ -> false
    end
  end

  defp assert_down(adapter, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^adapter, reason} -> reason
    end
  end

  # Wall-clock stamp the fake harness writes for itself as it starts, so a test can time
  # something the adapter does after the spawn without the spawn in the measurement.
  defp harness_started_at(capture_path) do
    path = capture_path <> ".boot"

    case File.read(path) do
      {:ok, stamp} ->
        String.to_integer(String.trim(stamp))

      {:error, reason} ->
        flunk("the fake harness never recorded its start at #{path}: #{inspect(reason)}")
    end
  end

  defp captured_requests(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
    else
      []
    end
  end

  defp session_requests(path) do
    Enum.filter(captured_requests(path), &(&1["method"] in ["session/new", "session/load"]))
  end

  test "new_session applies model then prompt streams+accumulates, permission auto-allowed" do
    {a, capture_path} = start_adapter()

    mcp_servers = [
      %{"name" => "build", "command" => "builder", "args" => [], "env" => []}
    ]

    assert {:ok, "sess-1"} = Adapter.new_session(a, "haiku", "/tmp", mcp_servers, "guidance")

    assert [%{"method" => "session/new", "mcpServers" => ^mcp_servers}] =
             session_requests(capture_path)

    assert {:ok, %{stop_reason: "end_turn", text: "pong[allow-once]"}} =
             Adapter.prompt(a, "sess-1", "say pong")
  end

  test "load_session reads the harness owner without pushing the record model" do
    {a, capture_path} = start_adapter(fail_mode: "load-owner")

    assert {:ok, "owner-model"} =
             Adapter.load_session(a, "sess-1", "stale-record", "/tmp", [], "guidance")

    assert {:ok, "owner-model"} = Adapter.current_model(a, "sess-1")

    refute Enum.any?(
             captured_requests(capture_path),
             &(&1["method"] == "session/set_config_option")
           )
  end

  test "load_session then prompt (owner read path)" do
    {a, capture_path} = start_adapter()

    mcp_servers = [
      %{"name" => "build", "command" => "builder", "args" => ["--fast"], "env" => []}
    ]

    assert {:ok, "haiku"} =
             Adapter.load_session(a, "sess-1", "haiku", "/tmp", mcp_servers, "guidance")

    assert [%{"method" => "session/load", "mcpServers" => ^mcp_servers}] =
             session_requests(capture_path)

    assert {:ok, %{stop_reason: "end_turn"}} = Adapter.prompt(a, "sess-1", "again")
  end

  test "a prompt worker that dies before dispatch returns an error without wedging the adapter" do
    {adapter, _capture_path} = start_adapter()
    dead_conn = spawn(fn -> :ok end)
    monitor = Process.monitor(dead_conn)
    assert_receive {:DOWN, ^monitor, :process, ^dead_conn, :normal}

    :sys.replace_state(adapter, &%{&1 | conn: dead_conn})

    assert {:error, :prompt_dispatch_failed} = Adapter.prompt(adapter, "sess-1", "never sent")
    assert Adapter.conn(adapter) == dead_conn
  end

  test "a missing prompt dispatch acknowledgement times out without wedging the adapter" do
    old_timeout = Application.get_env(:tightbeam, :prompt_dispatch_timeout_ms)

    on_exit(fn ->
      if old_timeout,
        do: Application.put_env(:tightbeam, :prompt_dispatch_timeout_ms, old_timeout),
        else: Application.delete_env(:tightbeam, :prompt_dispatch_timeout_ms)
    end)

    Application.put_env(:tightbeam, :prompt_dispatch_timeout_ms, 25)
    {adapter, _capture_path} = start_adapter()

    inert_conn =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(inert_conn, :stop) end)
    :sys.replace_state(adapter, &%{&1 | conn: inert_conn})

    assert {:error, :prompt_dispatch_failed} =
             Adapter.prompt(adapter, "sess-1", "never acknowledged", 100)

    assert Adapter.conn(adapter) == inert_conn
  end

  test "close_session sends ACP session/close with the harness session id" do
    {adapter, capture_path} = start_adapter()
    assert {:ok, "sess-1"} = Adapter.new_session(adapter, "haiku", "/tmp", [], "guidance")
    assert Adapter.knows_session?(adapter, "sess-1")

    assert :ok = Adapter.close_session(adapter, "sess-1")
    refute Adapter.knows_session?(adapter, "sess-1")

    assert [%{"method" => "session/close", "sessionId" => "sess-1"}] =
             Enum.filter(captured_requests(capture_path), &(&1["method"] == "session/close"))
  end

  test "new_session and load_session still send an empty mcpServers list" do
    {a, capture_path} = start_adapter()
    assert {:ok, "sess-1"} = Adapter.new_session(a, "haiku", "/tmp", [], "guidance")

    assert {:ok, "haiku"} =
             Adapter.load_session(a, "sess-1", "haiku", "/tmp", [], "guidance")

    assert [
             %{"method" => "session/new", "mcpServers" => []},
             %{"method" => "session/load", "mcpServers" => []}
           ] = session_requests(capture_path)
  end

  test "guidance uses the harness-accurate ACP metadata channel on new and load" do
    for {harness, expected} <- [
          {:codex, %{"developerInstructions" => "served guidance"}},
          {:claude,
           %{
             "systemPrompt" => %{
               "type" => "preset",
               "preset" => "claude_code",
               "append" => "served guidance"
             }
           }},
          {:fixture, %{"instructions" => "served guidance"}}
        ] do
      {adapter, capture_path} = start_adapter(harness: harness)

      assert {:ok, "sess-1"} =
               Adapter.new_session(adapter, "haiku", "/tmp", [], "served guidance")

      assert {:ok, _owner_model} =
               Adapter.load_session(
                 adapter,
                 "sess-1",
                 "haiku",
                 "/tmp",
                 [],
                 "served guidance"
               )

      assert Enum.all?(session_requests(capture_path), &(&1["meta"] == expected))
    end
  end

  test "surfaced codex account update reaches the credential callback" do
    owner = self()

    {adapter, _capture_path} =
      start_adapter(
        harness: :codex,
        on_auth_event: &send(owner, {:auth, &1, &2}),
        on_ready: fn -> send(owner, :booted) end
      )

    # The notification below queues behind the boot's handle_continue, so without this
    # barrier the assert_receive budget covers a `node` spawn as well as the dispatch
    # it is actually about.
    assert_ready(adapter, :booted)

    send(
      adapter,
      {:acp_notification, "session/update",
       %{
         "sessionId" => "sess-1",
         "update" => %{
           "sessionUpdate" => "session_info_update",
           "_meta" => %{
             "codex" => %{"accountUpdated" => %{"authMode" => nil, "planType" => nil}}
           }
         }
       }}
    )

    assert_receive {:auth, :terminal,
                    %{
                      "_meta" => %{
                        "codex" => %{
                          "accountUpdated" => %{"authMode" => nil, "planType" => nil}
                        }
                      }
                    }}
  end

  # FAIL-BEFORE: against the tree preceding #99 both calls returned the raw
  # JSON-RPC envelope, which the gateway could only record as an unclassifiable
  # harness error.
  test "the adapter's -32602 model refusal surfaces on new while load adopts the owner" do
    {adapter, _capture} = start_adapter(harness: :codex, fail_mode: "model-invalid-params")

    assert {:error, :model_unavailable} =
             Adapter.new_session(adapter, "gpt-5.1-codex", "/tmp", [], "guidance")

    assert {:ok, "haiku[medium]"} =
             Adapter.load_session(adapter, "sess-1", "gpt-5.1-codex", "/tmp", [], "guidance")

    assert Adapter.knows_session?(adapter, "sess-1")
  end

  test "new surfaces model apply failures while load reads the resident owner" do
    {adapter, _capture} = start_adapter(harness: :claude, fail_mode: "model-refusal")

    assert {:error, %{"message" => "Invalid value for config option model"}} =
             Adapter.new_session(adapter, "fable", "/tmp", [], "guidance")

    assert {:ok, "haiku"} =
             Adapter.load_session(adapter, "sess-1", "fable", "/tmp", [], "guidance")

    assert Adapter.knows_session?(adapter, "sess-1")

    {codex, _capture} = start_adapter(harness: :codex)

    assert {:ok, "haiku[medium]"} =
             Adapter.load_session(codex, "sess-1", "gpt-old[medium]", "/tmp", [], "guidance")

    assert :ok = Adapter.apply_model(codex, "sess-1", "gpt-old[medium]")

    assert {:ok, "gpt-new[high]"} =
             Adapter.apply_model_strict(codex, "sess-1", "gpt-new[high]", "gpt-old[medium]")
  end

  test "strict apply fences a stale requester against the harness-confirmed model" do
    {adapter, capture_path} = start_adapter(harness: :codex)

    assert {:ok, "sess-1"} =
             Adapter.new_session(adapter, "gpt-old[medium]", "/tmp", [], "guidance")

    assert {:ok, "gpt-new[high]"} =
             Adapter.apply_model_strict(adapter, "sess-1", "gpt-new[high]", "gpt-old[medium]")

    assert {:error, {:stale_model, "gpt-new[high]"}} =
             Adapter.apply_model_strict(adapter, "sess-1", "gpt-late", "gpt-old[medium]")

    assert {:ok, "gpt-new[high]"} = Adapter.current_model(adapter, "sess-1")

    model_writes =
      captured_requests(capture_path)
      |> Enum.filter(&(&1["method"] == "session/set_config_option" and &1["configId"] == "model"))
      |> Enum.map(& &1["value"])

    assert model_writes == ["gpt-old", "gpt-new"]
  end

  test "structured compaction is not silently claimed end-to-end" do
    claude_boundary = %{"sessionUpdate" => "compact_boundary"}

    codex_boundary = %{
      "sessionUpdate" => "session_info_update",
      "_meta" => %{"codex" => %{"contextCompaction" => %{}}}
    }

    assert Adapter.progress_status(claude_boundary) == :skip
    assert Adapter.progress_status(codex_boundary) == :skip

    for {harness, boundary} <- [
          {Tightbeam.Harness.Claude, claude_boundary},
          {Tightbeam.Harness.Codex, codex_boundary}
        ] do
      assert harness.classify_auth_event(boundary) == :unknown
      assert harness.classify_subagent_event(boundary) == :skip
    end
  end

  test "auth-event divergence keeps claude unknown while codex classifies terminal and transient" do
    terminal = %{"authMode" => nil, "planType" => nil}
    transient = %{"authMode" => "chatgpt", "planType" => "plus"}

    assert Tightbeam.Harness.Claude.classify_auth_event(terminal) == :unknown
    assert Tightbeam.Harness.Claude.classify_auth_event(transient) == :unknown
    assert Tightbeam.Harness.Codex.classify_auth_event(terminal) == :terminal
    assert Tightbeam.Harness.Codex.classify_auth_event(transient) == :transient
  end

  test "codex account updates preserve terminal parity through the credential path" do
    owner = self()

    base =
      Path.join(
        System.tmp_dir!(),
        "tb-auth-parity-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, credentials} =
      Tightbeam.Credentials.start_link(
        name: nil,
        base_dir: base,
        machine: "testhost",
        park: fn :openai ->
          send(owner, :parked)
          :ok
        end
      )

    on_auth_event = fn
      :terminal, event ->
        Tightbeam.Credentials.mark_terminal(
          :openai,
          event,
          credentials
        )

      _classification, _event ->
        :ok
    end

    {adapter, _capture_path} =
      start_adapter(
        harness: :codex,
        on_auth_event: on_auth_event,
        on_ready: fn -> send(owner, :booted) end
      )

    # The refute below needs this barrier more than any assert_receive does. Both
    # notifications queue behind the boot's handle_continue, and a boot outlasting
    # the 100ms refute window meant the transient event had not been PROCESSED
    # when the window closed — so the test passed whether or not a transient
    # account update wrongly parked the credential.
    assert_ready(adapter, :booted)

    send(
      adapter,
      {:acp_notification, "account/updated", %{"authMode" => nil, "planType" => "plus"}}
    )

    refute_receive :parked

    send(
      adapter,
      {:acp_notification, "account/updated", %{"authMode" => nil, "planType" => nil}}
    )

    assert_receive :parked
  end

  test "placement auth callback does not block the adapter on credential terminal handling" do
    owner = self()

    base =
      Path.join(
        System.tmp_dir!(),
        "tb-auth-callback-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(base) end)
    File.mkdir_p!(base)

    db = :"auth_callback_db_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    :ok = Tightbeam.Placement.ensure_schema(db)
    Tightbeam.Archetypes.load!(base)
    Tightbeam.Rails.load!(base)

    start_supervised!({Task.Supervisor, name: Tightbeam.TurnTaskSupervisor})
    {:ok, adapter_slot} = Agent.start_link(fn -> nil end)

    start_supervised!(
      {Tightbeam.Credentials,
       name: Tightbeam.Credentials,
       base_dir: base,
       machine: "testhost",
       park: fn :openai ->
         adapter = Agent.get(adapter_slot, & &1)
         _ = Adapter.knows_session?(adapter, "missing")
         send(owner, :parked)
         :ok
       end}
    )

    placement_opts =
      Tightbeam.Placement.adapter_opts(
        %{
          base_dir: base,
          db: db,
          cwd: "/tmp",
          cli_bin: Path.join(base, "bin"),
          credential_kind: :subscription
        },
        {:codex, "default", "testhost"}
      )

    {adapter, _capture_path} =
      start_adapter(
        harness: :codex,
        on_auth_event: placement_opts[:on_auth_event],
        on_ready: fn -> send(owner, :booted) end
      )

    Agent.update(adapter_slot, fn nil -> adapter end)
    assert_ready(adapter, :booted)
    monitor = Process.monitor(adapter)

    send(
      adapter,
      {:acp_notification, "account/updated", %{"authMode" => nil, "planType" => nil}}
    )

    receive do
      :parked ->
        :ok

      {:DOWN, ^monitor, :process, ^adapter, reason} ->
        flunk("adapter died while handling the auth event: #{inspect(reason)}")
    end

    Process.demonitor(monitor, [:flush])
    assert {:needs_onboarding, :revoked} = Tightbeam.Credentials.status(:openai)
    assert Process.alive?(adapter)
  end

  test "session updates reach the subagent marker callback with harness session identity" do
    owner = self()

    {adapter, _capture_path} =
      start_adapter(
        on_subagent_event: &send(owner, {:subagent, &1, &2}),
        on_ready: fn -> send(owner, :booted) end
      )

    # Without this the 1s budget below covers a `node` spawn as well as the
    # dispatch it is about — the shape #83 collected on the 4-core runner.
    assert_ready(adapter, :booted)

    update = %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "call-1",
      "_meta" => %{"claudeCode" => %{"toolName" => "Agent"}}
    }

    send(
      adapter,
      {:acp_notification, "session/update", %{"sessionId" => "sess-1", "update" => update}}
    )

    assert_receive {:subagent, "sess-1", ^update}
  end

  test "placement subagent callback does not block the adapter on matching wake delivery" do
    owner = self()

    base =
      Path.join(
        System.tmp_dir!(),
        "tb-subagent-callback-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(base) end)
    File.mkdir_p!(base)

    db = :"subagent_callback_db_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    :ok = Tightbeam.Placement.ensure_schema(db)

    for module <- [
          Tightbeam.EventLog,
          Tightbeam.Idempotency,
          Tightbeam.Ledger,
          Tightbeam.Projection,
          Tightbeam.Org,
          Tightbeam.Roles,
          Tightbeam.ConditionFacts,
          Tightbeam.Wakes,
          Tightbeam.SubagentMarkers
        ],
        do: :ok = module.ensure_schema(db)

    Tightbeam.Archetypes.load!(base)
    Tightbeam.Rails.load!(base)
    start_supervised!({Task.Supervisor, name: Tightbeam.TurnTaskSupervisor})

    session =
      Tightbeam.Org.create(db, %{
        session_key: "parent",
        display_name: "parent",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "fixture"
      })

    Tightbeam.Org.append_pointer(db, session.session_key, "sess-1", "created")

    {:ok, turn_seq} =
      Tightbeam.Ledger.enqueue(db, %{
        session_key: session.session_key,
        message_id: "message-running",
        origin: "user:flynn",
        prompt: "run",
        assignment_id: "assignment-running"
      })

    assert {:ok, %{seq: ^turn_seq}} =
             Tightbeam.Ledger.claim_next(db, session.session_key, "test-owner")

    {:ok, adapter_slot} = Agent.start_link(fn -> nil end)
    start_supervised!({AdapterCallingWakeScheduler, {adapter_slot, self()}})

    placement_opts =
      Tightbeam.Placement.adapter_opts(
        %{
          base_dir: base,
          db: db,
          cwd: "/tmp",
          cli_bin: Path.join(base, "bin"),
          credential_kind: :subscription
        },
        {:codex, "default", "testhost"}
      )

    placement_handler = placement_opts[:on_subagent_event]

    {adapter, _capture_path} =
      start_adapter(
        harness: :codex,
        on_subagent_event: fn sid, update ->
          result = placement_handler.(sid, update)
          send(owner, :subagent_event_captured)
          result
        end,
        on_ready: fn -> send(owner, :booted) end
      )

    Agent.update(adapter_slot, fn nil -> adapter end)
    assert_ready(adapter, :booted)

    update = %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "call-codex-1",
      "status" => "completed",
      "_meta" => %{
        "codex" => %{
          "subagentTerminated" => %{
            "agentThreadId" => "thread-child-1",
            "threadStatus" => %{"type" => "idle"}
          }
        }
      }
    }

    send(
      adapter,
      {:acp_notification, "session/update", %{"sessionId" => "sess-1", "update" => update}}
    )

    assert_receive :subagent_event_captured
    :ok = Tightbeam.Ledger.finish(db, turn_seq, "delivered")
    assert_receive {:matching_fired, fact_id, false}, 2_000
    assert is_integer(fact_id)
    assert [%{assignment_id: "assignment-running"}] = Tightbeam.SubagentMarkers.list(db)
    assert Process.alive?(adapter)
  end

  test "placement reports a failed durable subagent ingestion without retrying" do
    owner = self()

    base =
      Path.join(
        System.tmp_dir!(),
        "tb-subagent-failure-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(base) end)
    File.mkdir_p!(base)

    db = :"subagent_failure_db_#{System.unique_integer([:positive])}"
    db_pid = start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    :ok = Tightbeam.Placement.ensure_schema(db)

    for module <- [
          Tightbeam.EventLog,
          Tightbeam.Idempotency,
          Tightbeam.Ledger,
          Tightbeam.Projection,
          Tightbeam.Org,
          Tightbeam.Roles,
          Tightbeam.ConditionFacts,
          Tightbeam.Wakes,
          Tightbeam.SubagentMarkers
        ],
        do: :ok = module.ensure_schema(db)

    Tightbeam.Archetypes.load!(base)
    Tightbeam.Rails.load!(base)
    start_supervised!({Task.Supervisor, name: Tightbeam.TurnTaskSupervisor})

    session =
      Tightbeam.Org.create(db, %{
        session_key: "parent",
        display_name: "parent",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "fixture"
      })

    Tightbeam.Org.append_pointer(db, session.session_key, "sess-1", "created")

    placement_opts =
      Tightbeam.Placement.adapter_opts(
        %{
          base_dir: base,
          db: db,
          cwd: "/tmp",
          cli_bin: Path.join(base, "bin"),
          credential_kind: :subscription
        },
        {:codex, "default", "testhost"}
      )

    placement_handler = placement_opts[:on_subagent_event]

    {adapter, _capture_path} =
      start_adapter(
        harness: :codex,
        on_subagent_event: fn sid, update ->
          result = placement_handler.(sid, update)

          task =
            case result do
              {:async, _event_ref, pid, _context} -> pid
              _ -> nil
            end

          send(owner, {:subagent_task_captured, self(), task})

          receive do
            :release_subagent_task -> result
          end
        end,
        on_ready: fn -> send(owner, :booted) end
      )

    assert_ready(adapter, :booted)

    update = %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "call-codex-failure",
      "status" => "completed",
      "_meta" => %{
        "codex" => %{
          "subagentTerminated" => %{
            "agentThreadId" => "thread-child-failure",
            "threadStatus" => %{"type" => "idle"}
          }
        }
      }
    }

    log =
      capture_log(fn ->
        send(
          adapter,
          {:acp_notification, "session/update", %{"sessionId" => "sess-1", "update" => update}}
        )

        assert_receive {:subagent_task_captured, ^adapter, task}
        task_ref = Process.monitor(task)
        GenServer.stop(db_pid)
        send(adapter, :release_subagent_task)
        assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}
        assert wait_for_subagent_tasks(adapter)
      end)

    assert log =~ "subagent event ingestion failed"
    assert log =~ "source_event_ref"
    assert log =~ "subagent_ref"
    assert log =~ "classification: :permanent"
    assert Process.alive?(adapter)
  end

  test "consecutive prompts reset the accumulator" do
    {a, _capture_path} = start_adapter()
    {:ok, _} = Adapter.new_session(a, "haiku", "/tmp", [], "guidance")
    assert {:ok, %{text: "pong[allow-once]"}} = Adapter.prompt(a, "sess-1", "one")
    assert {:ok, %{text: "pong[allow-once]"}} = Adapter.prompt(a, "sess-1", "two")
  end

  defp wait_for_subagent_tasks(adapter, attempts \\ 100)
  defp wait_for_subagent_tasks(_adapter, 0), do: false

  defp wait_for_subagent_tasks(adapter, attempts) do
    if map_size(:sys.get_state(adapter).subagent_tasks) == 0 do
      true
    else
      receive after: (10 -> wait_for_subagent_tasks(adapter, attempts - 1))
    end
  end

  test "turn timeout config reaches the session prompt request" do
    old_timeout = Application.get_env(:tightbeam, :turn_timeout_ms)

    on_exit(fn ->
      if old_timeout,
        do: Application.put_env(:tightbeam, :turn_timeout_ms, old_timeout),
        else: Application.delete_env(:tightbeam, :turn_timeout_ms)
    end)

    Application.put_env(:tightbeam, :turn_timeout_ms, 25)

    {adapter, _capture_path} = start_adapter(gate_mode: "stall-turn", probe: false)
    assert {:ok, sid} = Adapter.new_session(adapter, "haiku", "/tmp", [], "guidance")
    assert {:error, :timeout} = Adapter.prompt(adapter, sid, "stall")
  end

  test "preset modes are pinned for both harnesses" do
    for {harness, expected} <- [claude: "bypassPermissions", codex: "agent-full-access"] do
      {adapter, capture_path} = start_adapter(harness: harness)
      assert {:ok, "sess-1"} = Adapter.new_session(adapter, "haiku", "/tmp", [], "guidance")

      assert [%{"method" => "session/set_mode", "modeId" => ^expected}] =
               Enum.filter(captured_requests(capture_path), &(&1["method"] == "session/set_mode"))
    end
  end

  test "load does not assert mode" do
    {plain, plain_capture} = start_adapter()

    assert {:ok, "haiku"} =
             Adapter.load_session(plain, "sess-1", "haiku", "/tmp", [], "guidance")

    refute Enum.any?(captured_requests(plain_capture), &(&1["method"] == "session/set_mode"))
  end

  test "new session mode set stays best effort" do
    {plain, _capture} = start_adapter(fail_mode: "fail")
    assert {:ok, "sess-1"} = Adapter.new_session(plain, "haiku", "/tmp", [], "guidance")
  end

  test "gate wiring-check passes on message or tool content and discards the probe session" do
    for gate_mode <- ["pass-message", "pass-tool"] do
      parent = self()

      {adapter, capture_path} =
        start_adapter(
          harness: :codex,
          gate_mode: gate_mode,
          probe_cwd: "/tmp/gate-probe",
          on_ready: fn -> send(parent, {:gate_ready, gate_mode}) end
        )

      assert_ready(adapter, {:gate_ready, gate_mode})
      refute Adapter.knows_session?(adapter, "probe-sess")

      assert [probe_new] =
               captured_requests(capture_path)
               |> Enum.filter(&(&1["method"] == "session/new"))

      assert probe_new["cwd"] == "/tmp/gate-probe"
      assert probe_new["mcpServers"] == []

      assert [probe_prompt] =
               captured_requests(capture_path)
               |> Enum.filter(&(&1["method"] == "session/prompt"))

      assert probe_prompt["sessionId"] == "probe-sess"

      assert probe_prompt["prompt"] == [
               %{
                 "type" => "text",
                 "text" =>
                   "Run exactly this command with your shell tool (no other arguments): tightbeam-gate-probe . If the command is refused or blocked by anything, report the exact refusal message you received, verbatim, then stop; do not retry or work around it."
               }
             ]

      assert {:ok, "sess-1"} = Adapter.new_session(adapter, "haiku", "/tmp", [], "guidance")
      refute Adapter.knows_session?(adapter, "probe-sess")

      assert capture_path |> Path.dirname() |> Path.join("stderr.log.gate.log") |> File.read!() =~
               "gate wiring-check PASS [gate: tightbeam-probe]"

      refute capture_path |> Path.dirname() |> Path.join("stderr.log.gate.log") |> File.read!() =~
               "[gate-drift]"
    end
  end

  test "gate wiring-check logs bounded raw updates only when an update shape drifts" do
    {adapter, capture_path} = start_adapter(harness: :codex, gate_mode: "drift")
    monitor = Process.monitor(adapter)

    assert assert_down(adapter, monitor) == {:gate_attestation_failed, :no_marker}

    log = capture_path |> Path.dirname() |> Path.join("stderr.log.gate.log") |> File.read!()
    assert log =~ "[gate-drift] raw_updates="
    assert log =~ ~s("sessionUpdate":"drifted_shape")
    assert byte_size(log) < 5_000
  end

  test "gate log is omitted without real stderr and honors an explicit path" do
    parent = self()

    {adapter, _capture_path} =
      start_adapter(
        harness: :codex,
        gate_mode: "pass-message",
        stderr_path: :omit,
        on_ready: fn -> send(parent, :sentinel_gate_ready) end
      )

    assert_ready(adapter, :sentinel_gate_ready)
    assert Process.alive?(adapter)

    explicit_path =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-explicit-gate-#{System.unique_integer([:positive])}.log"
      )

    on_exit(fn -> File.rm(explicit_path) end)

    {explicit_adapter, _capture_path} =
      start_adapter(
        harness: :codex,
        gate_mode: "pass-message",
        stderr_path: :omit,
        gate_log_path: explicit_path,
        on_ready: fn -> send(parent, :explicit_gate_ready) end
      )

    assert_ready(explicit_adapter, :explicit_gate_ready)
    assert File.read!(explicit_path) =~ "gate wiring-check PASS [gate: tightbeam-probe]"
  end

  test "gate wiring-check fails closed without the marker or on a probe turn error" do
    for {gate_mode, detail} <- [{"no-marker", :no_marker}, {"turn-error", :turn_error}] do
      {adapter, capture_path} = start_adapter(harness: :codex, gate_mode: gate_mode)
      monitor = Process.monitor(adapter)

      queued =
        Task.async(fn -> Adapter.new_session(adapter, "haiku", "/tmp", [], "guidance") end)

      reason = assert_down(adapter, monitor)

      expected_reason =
        case gate_mode do
          "turn-error" ->
            {:adapter_fault,
             %{
               reason: {:gate_attestation_failed, detail},
               stderr: "probe turn failed: adapter transport unavailable"
             }}

          "no-marker" ->
            {:gate_attestation_failed, detail}
        end

      assert reason == expected_reason

      # S4 defect 1: the queued call gets the DESIGNED reason, not an exit the
      # lane can only report as :task_crash.
      # WHICH reason depends on a race the contract covers both sides of: the call
      # either queued behind the boot (carrying the gate failure) or arrived after
      # the adapter was already gone (:noproc, which the gateway enriches from the
      # coordinator's attempt-scoped record). Asserting only `not {:ok, _}` would
      # pass on a bare exit too — and a bare exit IS the defect.
      assert {:error, {:adapter_unavailable, queued_reason}} = Task.await(queued)

      case queued_reason do
        :noproc ->
          :ok

        text when is_binary(text) ->
          assert text =~ "gate_attestation_failed"

          if gate_mode == "turn-error",
            do: assert(text =~ "probe turn failed: adapter transport unavailable")
      end

      assert capture_path |> Path.dirname() |> Path.join("stderr.log.gate.log") |> File.read!() =~
               "gate wiring-check FAIL detail=#{detail}"
    end
  end

  test "a gate-passing adapter that dies reports only its real stderr tail" do
    {adapter, capture_path} = start_adapter(harness: :codex, gate_mode: "pass-then-die")
    monitor = Process.monitor(adapter)

    assert assert_down(adapter, monitor) ==
             {:adapter_fault,
              %{
                reason: {:acp_exit, 137},
                stderr: "adapter exploded: credential socket closed"
              }}

    stderr_path = Path.join(Path.dirname(capture_path), "stderr.log")
    gate_path = stderr_path <> ".gate.log"
    assert File.read!(gate_path) =~ "gate wiring-check PASS [gate: tightbeam-probe]"
    refute File.read!(stderr_path) =~ "gate wiring-check"
  end

  test "adapter status redacts accumulating chunks and a raising call's guidance message" do
    chunk_marker = "CHUNK_PAYLOAD_MARKER_DO_NOT_LOG"
    guidance_marker = "GUIDANCE_PAYLOAD_MARKER_DO_NOT_LOG"
    {adapter, _capture_path} = start_adapter(harness: :codex, probe: false)

    :sys.replace_state(adapter, fn state ->
      state
      |> put_in([Access.key(:chunks), "sensitive-session"], [chunk_marker])
      |> Map.put(:harness, :missing_harness)
    end)

    monitor = Process.monitor(adapter)

    log =
      capture_log(fn ->
        assert {:error, {:adapter_unavailable, _reason}} =
                 Adapter.new_session(adapter, "haiku", "/tmp", [], guidance_marker)

        assert_receive {:DOWN, ^monitor, :process, ^adapter, _reason}
        Logger.flush()
      end)

    refute log =~ chunk_marker
    refute log =~ guidance_marker
    assert log =~ "State: :redacted"
    assert log =~ ~r/Last message(?: \(from .+?\))?: :redacted/
  end

  test "gate wiring-check enforces one absolute deadline and serves no queued session" do
    {adapter, capture_path} =
      start_adapter(
        harness: :codex,
        gate_mode: "stall",
        gate_attestation_timeout: 75
      )

    monitor = Process.monitor(adapter)

    queued =
      Task.async(fn -> Adapter.new_session(adapter, "haiku", "/tmp", [], "guidance") end)

    assert assert_down(adapter, monitor) == {:gate_attestation_failed, :deadline}
    died_at = System.system_time(:millisecond)

    # The claim is that the 75ms attestation deadline is ABSOLUTE — so the clock starts
    # where that deadline does, once the harness is up. Timing from before start_adapter/1
    # billed a `node` spawn to the deadline, and a spawn's duration is the runner's load,
    # not the adapter's behavior (#83).
    #
    # MEASURED 2026-07-29 under a four-file load on an idle 16-core mac: 83, 85,
    # 95, 101, 140 ms — the 75ms deadline plus 10-65ms of harness startup and two
    # round trips. ~7x headroom, so this budget stays; the `.boot` stamp is what
    # keeps it that tight, and widening it would only hide a regression in the
    # deadline itself.
    assert died_at - harness_started_at(capture_path) < 1_000

    assert {:error, {:adapter_unavailable, reason}} = Task.await(queued)

    # Same either-side-of-the-race contract as the fails-closed test above.
    case reason do
      :noproc -> :ok
      text when is_binary(text) -> assert text =~ "deadline"
    end
  end

  test "boot without probe opts sends no probe request" do
    parent = self()

    {adapter, capture_path} =
      start_adapter(
        harness: :codex,
        gate_mode: "stall",
        probe: false,
        on_ready: fn -> send(parent, :plain_ready) end
      )

    assert_ready(adapter, :plain_ready)
    assert captured_requests(capture_path) == []
  end
end
