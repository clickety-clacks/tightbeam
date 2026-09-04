defmodule Tightbeam.Acp.AdapterTest do
  use Tightbeam.TestCase, async: false
  import ExUnit.CaptureLog

  doctest Tightbeam.Acp.Adapter

  alias Tightbeam.Acp.Adapter
  alias Tightbeam.Model

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

  # The defect this refactor exists to fix, in one assertion. A vendor
  # identifier whose bracket is a CONTEXT WINDOW (`claude-fable-5[1m]`) must
  # reach the harness intact; before the seam knew the difference it parsed the
  # bracket as one of OUR reasoning levels, sent `claude-fable-5` as the model
  # and `1m` as the effort, and the 1M-context model was unreachable.
  test "a vendor context variant crosses the adapter seam without loss" do
    {adapter, capture_path} = start_adapter()

    fable_1m = Model.new("claude-fable-5", context: "1m", effort: "high")

    assert :ok = Adapter.apply_model(adapter, "sess-1", fable_1m)

    config = fn id ->
      capture_path
      |> captured_requests()
      |> Enum.filter(&(&1["method"] == "session/set_config_option" and &1["configId"] == id))
      |> Enum.map(& &1["value"])
    end

    assert config.("model") == ["claude-fable-5[1m]"]
    assert config.("effort") == ["high"]

    assert {:ok, %Model{family: "claude-fable-5", context: "1m", effort: "high"}} =
             Adapter.current_model(adapter, "sess-1")
  end

  # Effort is never rendered into the model value: it is a separate config
  # option, so an effort-bearing selection sends a BARE family as the model.
  test "the model value the harness receives never carries our effort" do
    {adapter, capture_path} = start_adapter()

    assert :ok = Adapter.apply_model(adapter, "sess-1", Model.new("haiku", effort: "medium"))

    assert ["haiku"] =
             capture_path
             |> captured_requests()
             |> Enum.filter(
               &(&1["method"] == "session/set_config_option" and &1["configId"] == "model")
             )
             |> Enum.map(& &1["value"])
  end

  test "Fast is normalized from Claude fast and Codex fast-mode live options" do
    {claude, _capture_path} = start_adapter(fail_mode: "fast-live")
    assert {:ok, "sess-1"} = Adapter.new_session(claude, nil, "/tmp", [], "guidance")
    assert {:ok, %{fast: "off", option_id: "fast"}} = Adapter.fast_status(claude, "sess-1")
    assert {:ok, %{fast: "on", option_id: "fast"}} = Adapter.apply_fast(claude, "sess-1", "on")

    {codex, capture_path} = start_adapter(harness: :codex, fail_mode: "fast-live-codex")
    assert {:ok, "sess-1"} = Adapter.new_session(codex, nil, "/tmp", [], "guidance")

    assert {:ok, %{fast: "off", option_id: "fast-mode"}} =
             Adapter.fast_status(codex, "sess-1")

    assert {:ok, %{fast: "on", option_id: "fast-mode"}} =
             Adapter.apply_fast(codex, "sess-1", "on")

    assert [true] =
             capture_path
             |> captured_requests()
             |> Enum.filter(
               &(&1["method"] == "session/set_config_option" and &1["configId"] == "fast-mode")
             )
             |> Enum.map(& &1["value"])
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
  let forkCalls = 0;
  const models = {};
  const efforts = {};
  const fastValues = {};
  const offeredModels = {};
  const defaultOfferedModels = [
    "default", "opus[1m]", "claude-fable-5[1m]", "sonnet", "haiku",
    "gpt-old", "gpt-new", "gpt-blocking", "gpt-5.6-sol"
  ];
  const publicModelOption = (value) => {
    const opus5Vocabulary = failMode === "canonical-opus5-alias" || failMode === "opus-alias-drift";
    switch (value) {
      case "default":
        return { value, name: "Default", description: opus5Vocabulary ? "Opus 5 with 1M context" : "Sonnet 5" };
      case "opus[1m]":
        return { value, name: "Opus (1M context)", description: opus5Vocabulary ? "Opus 5 with 1M context" : "Opus 4.8 with 1M context" };
      case "sonnet":
        return { value, name: "Sonnet", description: "Sonnet 5" };
      case "haiku":
        return { value, name: "Haiku", description: "Haiku 4.5" };
      case "claude-fable-5[1m]":
        return { value, name: "Fable", description: "Fable 5 with 1M context" };
      default:
        return { value, name: value };
    }
  };
  const configOptions = (sid) => ({ configOptions: [
    ...(failMode.startsWith("fast-") ? [{
      id: failMode === "fast-live-codex" ? "fast-mode" : "fast",
      name: "Fast mode",
      type: failMode === "fast-live-codex" ? "boolean" : "select",
      currentValue: Object.hasOwn(fastValues, sid)
        ? fastValues[sid]
        : (failMode === "fast-live-codex" ? false : "off"),
      options: failMode === "fast-live-codex"
        ? [{ value: true, name: "On" }, { value: false, name: "Off" }]
        : [{ value: "on", name: "On" }, { value: "off", name: "Off" }]
    }] : []),
    {
      id: "model",
      currentValue: models[sid] || "haiku",
      options: (offeredModels[sid] || defaultOfferedModels).map(publicModelOption)
    },
    { id: "effort", currentValue: efforts[sid] || "default" },
    { id: "reasoning_effort", currentValue: efforts[sid] || "medium" }
  ] });
  const capture = (m) => fs.appendFileSync(capturePath, JSON.stringify({ method: m.method, mcpServers: m.params.mcpServers, modeId: m.params.modeId, configId: m.params.configId, value: m.params.value, cwd: m.params.cwd, sessionId: m.params.sessionId, prompt: m.params.prompt, meta: m.params._meta }) + "\n");
  let pendingPrompt = null;
  let stalledPrompt = null;
  let stalledSession = null;
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
      case "initialize":
        if (gateMode === "delay-setup") return setTimeout(() => send({ id: m.id, result: { protocolVersion: 1 } }), 75);
        return send({ id: m.id, result: { protocolVersion: 1 } });
      case "session/new": {
        newCalls += 1;
        capture(m);
        const sid = gateMode !== "none" && gateMode !== "delay-setup" && newCalls === 1 ? "probe-sess" : "sess-1";
        models[sid] = models[sid] || "haiku";
        offeredModels[sid] = [...defaultOfferedModels];
        if (gateMode === "delay-setup") return setTimeout(() => send({ id: m.id, result: { sessionId: sid, ...configOptions(sid) } }), 75);
        return send({ id: m.id, result: { sessionId: sid, ...configOptions(sid) } });
      }
      case "session/load": {
        capture(m);
        models[m.params.sessionId] = failMode === "load-owner" ? "owner-model" : (models[m.params.sessionId] || "haiku");
        offeredModels[m.params.sessionId] = [...defaultOfferedModels];
        return send({ id: m.id, result: configOptions(m.params.sessionId) });
      }
      case "session/fork": {
        capture(m);
        if (failMode === "fork-unprompted-owner") {
          return send({ id: m.id, error: { code: -32002, message: "Resource not found" } });
        }
        forkCalls += 1;
        const sid = "sess-fork-" + forkCalls;
        models[sid] = models[m.params.sessionId] || "haiku";
        offeredModels[sid] = [...defaultOfferedModels];
        return send({ id: m.id, result: { sessionId: sid, ...configOptions(sid) } });
      }
      case "session/close": capture(m); return send({ id: m.id, result: {} });
      case "session/set_config_option": {
        capture(m);
        if (gateMode === "delay-setup") {
          if (m.params.configId === "model") models[m.params.sessionId] = m.params.value;
          if (m.params.configId === "effort" || m.params.configId === "reasoning_effort") efforts[m.params.sessionId] = m.params.value;
          return setTimeout(() => send({ id: m.id, result: configOptions(m.params.sessionId) }), 75);
        }
        if (failMode === "slow-strict-success" &&
            m.params.configId === "model" &&
            m.params.value === "gpt-new") {
          models[m.params.sessionId] = m.params.value;
          return setTimeout(() => send({ id: m.id, result: configOptions(m.params.sessionId) }), 26000);
        }
        if (failMode === "slow-apply-before-strict" &&
            m.params.configId === "model" &&
            m.params.value === "gpt-blocking") {
          return setTimeout(() => send({ id: m.id, result: configOptions(m.params.sessionId) }), 30600);
        }
        if (failMode === "slow-apply-before-strict" &&
            m.params.configId === "model" &&
            m.params.value === "gpt-new") {
          return;
        }
        if (failMode === "model-refusal") {
          return send({ id: m.id, error: { code: -32000, message: "Invalid value for config option model" } });
        }
        if (failMode === "model-invalid-params" && m.params.configId === "model") {
          // Recorded live 2026-07-28: codex-acp's refusal of a model value the
          // catalog advertised (`gpt-5.1-codex`) — JSON-RPC -32602 Invalid params.
          return send({ id: m.id, error: { code: -32602, message: "Invalid params" } });
        }
        if (failMode === "fast-refusal" && m.params.configId === "fast") {
          return send({ id: m.id, error: { code: -32000, message: "fast refused" } });
        }
        if (failMode === "fast-mismatch" && m.params.configId === "fast") {
          return send({ id: m.id, result: configOptions(m.params.sessionId) });
        }
        if (failMode === "strict-partial-apply" &&
            m.params.configId === "reasoning_effort" &&
            m.params.value === "high") {
          return send({ id: m.id, result: configOptions(m.params.sessionId) });
        }
        if (failMode === "strict-effort-hang" &&
            m.params.configId === "reasoning_effort" &&
            m.params.value === "high") {
          return setTimeout(() => send({ id: m.id, result: configOptions(m.params.sessionId) }), 200);
        }
        if (failMode === "apply-effort-failure" &&
            m.params.configId === "reasoning_effort" &&
            m.params.value === "high") {
          return send({ id: m.id, error: { code: -32000, message: "effort refused" } });
        }
        if ((failMode === "canonical-no-take-then-alias" || failMode === "opus-alias-drift") &&
            m.params.configId === "model" &&
            m.params.value === "claude-opus-4-8[1m]") {
          return send({ id: m.id, result: configOptions(m.params.sessionId) });
        }
        if (failMode === "canonical-opus5-unavailable" &&
            m.params.configId === "model" &&
            m.params.value === "claude-opus-5") {
          return send({ id: m.id, result: configOptions(m.params.sessionId) });
        }
        if (failMode === "canonical-opus5-alias" &&
            m.params.configId === "model" &&
            m.params.value === "claude-opus-5") {
          models[m.params.sessionId] = "opus[1m]";
          return send({ id: m.id, result: configOptions(m.params.sessionId) });
        }

        if (failMode === "silent-model-no-take" && m.params.configId === "model") {
          return send({ id: m.id, result: configOptions(m.params.sessionId) });
        }
        if (m.params.configId === "model") models[m.params.sessionId] = m.params.value;
        if (m.params.configId === "effort" || m.params.configId === "reasoning_effort") efforts[m.params.sessionId] = m.params.value;
        if (m.params.configId === "fast" || m.params.configId === "fast-mode") fastValues[m.params.sessionId] = m.params.value;
        return send({ id: m.id, result: configOptions(m.params.sessionId) });
      }
      case "session/set_mode": {
        capture(m);
        if (gateMode === "delay-setup") return setTimeout(() => send({ id: m.id, result: {} }), 75);
        if (failMode === "fail") {
          return send({ id: m.id, error: { code: -32000, message: "mode refused" } });
        }
        return send({ id: m.id, result: {} });
      }
      case "session/prompt": {
        const sid = m.params.sessionId;
        capture(m);
        const text = m.params.prompt?.[0]?.text;
        if (gateMode === "stall-turn") {
          stalledPrompt = m.id;
          stalledSession = sid;
          return;
        }
        if (gateMode === "delay-turn") {
          return setTimeout(() => {
            send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "delayed" } } } });
            send({ id: m.id, result: { stopReason: "end_turn" } });
          }, 75);
        }
        if (gateMode === "progress-turn") {
          send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_thought_chunk" } } });
          send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "tool_call", title: "Read config/runtime.exs" } } });
          send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "progressed" } } } });
          return setTimeout(() => send({ id: m.id, result: { stopReason: "end_turn" } }), 75);
        }
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
          if (gateMode === "pass-tool-pi-bash-meta") {
            send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "tool_call_update", _meta: { terminal_output: { data: "Command blocked [gate: tightbeam-probe]" } } } } });
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
        if (gateMode === "message-boundaries") {
          send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", messageId: "msg-1", content: { type: "text", text: "first " } } } });
          send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "tool_call", title: "boundary-preserving tool" } } });
          send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", messageId: "msg-1", content: { type: "text", text: "message" } } } });
          send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", messageId: "msg-2", content: { type: "text", text: "second message" } } } });
          return send({ id: m.id, result: { stopReason: "end_turn" } });
        }
        send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "po" } } } });
        send({ method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "ng" } } } });
        pendingPrompt = m.id;
        send({ id: 500, method: "session/request_permission", params: { options: [ { optionId: "reject", kind: "reject_once" }, { optionId: "allow-once", kind: "allow_once" } ] } });
        return;
      }
      case "session/cancel": {
        capture(m);
        if (stalledPrompt !== null && m.params.sessionId === stalledSession) {
          send({ id: stalledPrompt, error: { code: -32800, message: "canceled" } });
          stalledPrompt = null;
          stalledSession = null;
        }
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
          |> Keyword.put(
            :probe_model,
            Keyword.get(opts, :probe_model, Model.new("gpt-5.6-sol", effort: "medium"))
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

  defp pending_count?(conn, expected, remaining \\ 500) do
    cond do
      map_size(:sys.get_state(conn).pending) == expected -> true
      remaining == 0 -> false
      true -> Process.sleep(10) && pending_count?(conn, expected, remaining - 1)
    end
  end

  defp prompt_requester(conn) do
    conn
    |> :sys.get_state()
    |> Map.fetch!(:pending)
    |> Map.values()
    |> List.first()
    |> Map.fetch!(:from)
    |> elem(0)
  end

  defp assert_down(adapter, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^adapter, reason} -> reason
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

  defp assert_request_captured(path, config_id, value, attempts \\ 500) do
    captured? =
      Enum.any?(captured_requests(path), fn request ->
        request["method"] == "session/set_config_option" and
          request["configId"] == config_id and request["value"] == value
      end)

    cond do
      captured? -> :ok
      attempts == 0 -> flunk("request #{config_id}=#{value} was not captured")
      true -> Process.sleep(10) && assert_request_captured(path, config_id, value, attempts - 1)
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

    assert {:ok, "sess-1"} =
             Adapter.new_session(a, Model.new("haiku"), "/tmp", mcp_servers, "guidance")

    assert [%{"method" => "session/new", "mcpServers" => ^mcp_servers}] =
             session_requests(capture_path)

    assert {:ok,
            %{
              stop_reason: "end_turn",
              text: "pong[allow-once]",
              messages: [%{message_id: nil, text: "pong[allow-once]"}]
            }} = Adapter.prompt(a, "sess-1", "say pong")
  end

  test "new_session with an unknown record keeps and captures the harness default" do
    {adapter, capture_path} = start_adapter()

    assert {:ok, "sess-1"} = Adapter.new_session(adapter, nil, "/tmp", [], "guidance")
    assert {:ok, %Model{family: "haiku", effort: nil}} = Adapter.current_model(adapter, "sess-1")

    refute Enum.any?(
             captured_requests(capture_path),
             &(&1["method"] == "session/set_config_option" and &1["configId"] == "model")
           )
  end

  test "load_session pushes the known canonical record model" do
    {a, capture_path} = start_adapter(fail_mode: "load-owner")

    assert {:ok, %Model{family: "stale-record", effort: nil}} =
             Adapter.load_session(a, "sess-1", Model.new("stale-record"), "/tmp", [], "guidance")

    assert {:ok, %Model{family: "stale-record", effort: nil}} = Adapter.current_model(a, "sess-1")

    assert Enum.any?(captured_requests(capture_path), fn request ->
             request["method"] == "session/set_config_option" and
               request["configId"] == "model" and request["value"] == "stale-record"
           end)
  end

  test "load_session leaves the harness untouched when the record model is unknown" do
    {a, capture_path} = start_adapter(fail_mode: "load-owner")

    assert {:ok, :unknown} =
             Adapter.load_session(a, "sess-1", nil, "/tmp", [], "guidance")

    assert Adapter.knows_session?(a, "sess-1")
    assert {:error, :model_readback_unavailable} = Adapter.current_model(a, "sess-1")

    refute Enum.any?(
             captured_requests(capture_path),
             &(&1["method"] == "session/set_config_option")
           )
  end

  test "load_session then prompt (canonical push path)" do
    {a, capture_path} = start_adapter()

    mcp_servers = [
      %{"name" => "build", "command" => "builder", "args" => ["--fast"], "env" => []}
    ]

    assert {:ok, %Model{family: "haiku", effort: nil}} =
             Adapter.load_session(
               a,
               "sess-1",
               Model.new("haiku"),
               "/tmp",
               mcp_servers,
               "guidance"
             )

    assert [%{"method" => "session/load", "mcpServers" => ^mcp_servers}] =
             session_requests(capture_path)

    assert {:ok, %{stop_reason: "end_turn"}} = Adapter.prompt(a, "sess-1", "again")
  end

  test "Claude model switch forks the conversation and applies the model to the new session" do
    {adapter, capture_path} =
      start_adapter(harness: :claude, fail_mode: "canonical-no-take-then-alias")

    assert {:ok, "sess-1"} =
             Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "old guidance")

    assert {:ok, %{stop_reason: "end_turn"}} =
             Adapter.prompt(adapter, "sess-1", "persist this conversation")

    switched_model = Model.new("claude-opus-4-8", context: "1m", effort: "high")

    assert {:ok, "sess-fork-1"} =
             Adapter.switch_model_session(
               adapter,
               "sess-1",
               switched_model,
               "/tmp",
               [],
               "new guidance"
             )

    assert Adapter.knows_session?(adapter, "sess-1")
    assert Adapter.knows_session?(adapter, "sess-fork-1")

    assert {:ok, ^switched_model} = Adapter.current_model(adapter, "sess-fork-1")

    assert {:ok, switchable} = Adapter.switchable_models(adapter, "sess-fork-1")
    assert Model.new("claude-opus-4-8", context: "1m") in switchable
    assert Model.new("claude-sonnet-5") in switchable
    refute Model.new("claude-opus-5") in switchable

    requests = captured_requests(capture_path)

    assert Enum.any?(requests, fn request ->
             request["method"] == "session/fork" and request["sessionId"] == "sess-1" and
               request["cwd"] == "/tmp"
           end)

    model_writes =
      Enum.filter(requests, fn request ->
        request["method"] == "session/set_config_option" and
          request["sessionId"] == "sess-fork-1" and request["configId"] == "model"
      end)

    assert Enum.map(model_writes, & &1["value"]) == ["claude-opus-4-8[1m]", "opus[1m]"]
  end

  test "Claude model switch accepts canonical Opus 5 only when public readback identifies Opus 5" do
    {adapter, capture_path} =
      start_adapter(harness: :claude, fail_mode: "canonical-opus5-alias")

    assert {:ok, "sess-1"} =
             Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")

    assert {:ok, _turn} = Adapter.prompt(adapter, "sess-1", "persist this conversation")

    switched_model = Model.new("claude-opus-5")

    assert {:ok, "sess-fork-1"} =
             Adapter.switch_model_session(
               adapter,
               "sess-1",
               switched_model,
               "/tmp",
               [],
               "guidance"
             )

    assert {:ok, ^switched_model} = Adapter.current_model(adapter, "sess-fork-1")
    assert {:ok, switchable} = Adapter.switchable_models(adapter, "sess-fork-1")
    assert switched_model in switchable
    refute Model.new("claude-opus-4-8", context: "1m") in switchable

    model_writes =
      captured_requests(capture_path)
      |> Enum.filter(fn request ->
        request["method"] == "session/set_config_option" and
          request["sessionId"] == "sess-fork-1" and request["configId"] == "model"
      end)

    assert Enum.map(model_writes, & &1["value"]) == ["claude-opus-5"]
  end

  test "Claude model switch rejects an alias whose public meaning drifted" do
    {adapter, capture_path} = start_adapter(harness: :claude, fail_mode: "opus-alias-drift")

    assert {:ok, "sess-1"} =
             Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")

    assert {:ok, _turn} = Adapter.prompt(adapter, "sess-1", "persist this conversation")

    assert {:error, {:model_apply_failed, :model_unavailable}} =
             Adapter.switch_model_session(
               adapter,
               "sess-1",
               Model.new("claude-opus-4-8", context: "1m"),
               "/tmp",
               [],
               "guidance"
             )

    model_writes =
      captured_requests(capture_path)
      |> Enum.filter(fn request ->
        request["method"] == "session/set_config_option" and
          request["sessionId"] == "sess-fork-1" and request["configId"] == "model"
      end)

    assert Enum.map(model_writes, & &1["value"]) == ["claude-opus-4-8[1m]", "opus[1m]"]
    assert {:error, :model_readback_unavailable} = Adapter.current_model(adapter, "sess-fork-1")

    assert Enum.any?(captured_requests(capture_path), fn request ->
             request["method"] == "session/close" and request["sessionId"] == "sess-fork-1"
           end)
  end

  test "Claude model switch refuses a canonical model absent from the fork vocabulary" do
    {adapter, capture_path} =
      start_adapter(harness: :claude, fail_mode: "canonical-opus5-unavailable")

    assert {:ok, "sess-1"} =
             Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")

    assert {:ok, _turn} = Adapter.prompt(adapter, "sess-1", "persist this conversation")

    assert {:error, {:model_apply_failed, :model_unavailable}} =
             Adapter.switch_model_session(
               adapter,
               "sess-1",
               Model.new("claude-opus-5", effort: "high"),
               "/tmp",
               [],
               "guidance"
             )

    model_writes =
      captured_requests(capture_path)
      |> Enum.filter(fn request ->
        request["method"] == "session/set_config_option" and
          request["sessionId"] == "sess-fork-1" and request["configId"] == "model"
      end)

    assert Enum.map(model_writes, & &1["value"]) == ["claude-opus-5"]

    assert Enum.any?(captured_requests(capture_path), fn request ->
             request["method"] == "session/close" and
               request["sessionId"] == "sess-fork-1"
           end)
  end

  test "Claude model switch rejects a success-shaped response that did not take" do
    {adapter, capture_path} =
      start_adapter(harness: :claude, fail_mode: "silent-model-no-take")

    assert {:ok, "sess-1"} =
             Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")

    assert {:ok, _turn} = Adapter.prompt(adapter, "sess-1", "persist this conversation")

    assert {:error, {:model_apply_failed, :model_unavailable}} =
             Adapter.switch_model_session(
               adapter,
               "sess-1",
               Model.new("claude-opus-4-8", context: "1m", effort: "high"),
               "/tmp",
               [],
               "guidance"
             )

    assert {:error, :model_readback_unavailable} =
             Adapter.current_model(adapter, "sess-fork-1")

    assert Enum.any?(captured_requests(capture_path), fn request ->
             request["method"] == "session/close" and
               request["sessionId"] == "sess-fork-1"
           end)
  end

  test "Claude model switch guards a fresh parent with no persisted turn" do
    {adapter, capture_path} = start_adapter(harness: :claude)

    assert {:ok, "sess-1"} =
             Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")

    assert {:error, :fork_requires_prompted_session} =
             Adapter.switch_model_session(
               adapter,
               "sess-1",
               Model.new("claude-sonnet-5"),
               "/tmp",
               [],
               "guidance"
             )

    refute Enum.any?(captured_requests(capture_path), &(&1["method"] == "session/fork"))
  end

  test "Claude model switch names a loaded parent's -32002 fork precondition" do
    {adapter, capture_path} =
      start_adapter(harness: :claude, fail_mode: "fork-unprompted-owner")

    assert {:ok, %Model{}} =
             Adapter.load_session(
               adapter,
               "loaded-session",
               Model.new("haiku"),
               "/tmp",
               [],
               "guidance"
             )

    assert {:error, :fork_requires_prompted_session} =
             Adapter.switch_model_session(
               adapter,
               "loaded-session",
               Model.new("claude-sonnet-5"),
               "/tmp",
               [],
               "guidance"
             )

    assert Enum.any?(captured_requests(capture_path), &(&1["method"] == "session/fork"))
  end

  test "Codex model switch updates the resident session without forking" do
    {adapter, capture_path} = start_adapter(harness: :codex)

    assert {:ok, "sess-1"} =
             Adapter.new_session(adapter, Model.new("gpt-old"), "/tmp", [], "guidance")

    assert {:ok, "sess-1"} =
             Adapter.switch_model_session(
               adapter,
               "sess-1",
               Model.new("gpt-new", effort: "high"),
               "/tmp",
               [],
               "guidance"
             )

    refute Enum.any?(captured_requests(capture_path), &(&1["method"] == "session/fork"))
  end

  test "Codex model switch rejects a success-shaped response that did not take" do
    {adapter, capture_path} =
      start_adapter(harness: :codex, fail_mode: "silent-model-no-take")

    assert {:ok, "sess-1"} =
             Adapter.new_session(adapter, Model.new("gpt-old"), "/tmp", [], "guidance")

    assert {:error,
            {:runtime_config_mismatch, %Model{family: "haiku", effort: "medium", context: nil}}} =
             Adapter.switch_model_session(
               adapter,
               "sess-1",
               Model.new("gpt-new", effort: "high"),
               "/tmp",
               [],
               "guidance"
             )

    assert {:ok, %Model{family: "haiku", effort: "medium", context: nil}} =
             Adapter.current_model(adapter, "sess-1")

    refute Enum.any?(captured_requests(capture_path), &(&1["method"] == "session/fork"))
  end

  test "Codex model switch preserves the model-unavailable refusal vocabulary" do
    {adapter, _capture_path} =
      start_adapter(harness: :codex, fail_mode: "model-invalid-params")

    assert {:ok, "sess-1"} = Adapter.new_session(adapter, nil, "/tmp", [], "guidance")

    assert {:error, :model_unavailable} =
             Adapter.switch_model_session(
               adapter,
               "sess-1",
               Model.new("gpt-new"),
               "/tmp",
               [],
               "guidance"
             )
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

  test "a missing prompt dispatch acknowledgement stays live until the connection dies" do
    {adapter, _capture_path} = start_adapter()

    inert_conn =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(inert_conn, :stop) end)
    :sys.replace_state(adapter, &%{&1 | conn: inert_conn})

    prompt = Task.async(fn -> Adapter.prompt(adapter, "sess-1", "never acknowledged") end)
    assert Task.yield(prompt, 50) == nil

    send(inert_conn, :stop)
    assert {:error, :prompt_dispatch_failed} = Task.await(prompt)

    assert Adapter.conn(adapter) == inert_conn
  end

  test "caller death preserves existing monitor ownership and requires explicit cancel" do
    {adapter, capture_path} = start_adapter(gate_mode: "stall-turn", probe: false)
    assert {:ok, sid} = Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")
    conn = Adapter.conn(adapter)

    caller = Task.async(fn -> Adapter.prompt(adapter, sid, "stall") end)
    assert pending_count?(conn, 1)
    Task.shutdown(caller, :brutal_kill)

    assert pending_count?(conn, 1)
    refute Enum.any?(captured_requests(capture_path), &(&1["method"] == "session/cancel"))

    Tightbeam.Acp.Conn.notify(conn, "session/cancel", %{sessionId: sid})
    assert pending_count?(conn, 0)
    assert Enum.any?(captured_requests(capture_path), &(&1["method"] == "session/cancel"))
  end

  test "prompt worker death preserves existing monitor ownership and quiesces on explicit cancel" do
    {adapter, capture_path} = start_adapter(gate_mode: "stall-turn", probe: false)
    assert {:ok, sid} = Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")
    conn = Adapter.conn(adapter)

    caller = Task.async(fn -> Adapter.prompt(adapter, sid, "stall") end)
    assert pending_count?(conn, 1)
    Process.exit(prompt_requester(conn), :kill)

    assert pending_count?(conn, 1)
    refute Enum.any?(captured_requests(capture_path), &(&1["method"] == "session/cancel"))

    Tightbeam.Acp.Conn.notify(conn, "session/cancel", %{sessionId: sid})
    assert pending_count?(conn, 0)
    assert Enum.any?(captured_requests(capture_path), &(&1["method"] == "session/cancel"))

    Process.exit(adapter, :kill)
    assert {:error, {:adapter_unavailable, _reason}} = Task.await(caller)
  end

  test "adapter death tears down its prompt worker and connection through existing links" do
    {adapter, _capture_path} = start_adapter(gate_mode: "stall-turn", probe: false)
    assert {:ok, sid} = Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")
    conn = Adapter.conn(adapter)

    caller = Task.async(fn -> Adapter.prompt(adapter, sid, "stall") end)
    assert pending_count?(conn, 1)
    worker = prompt_requester(conn)
    worker_monitor = Process.monitor(worker)
    conn_monitor = Process.monitor(conn)

    Process.exit(adapter, :kill)

    assert {:error, {:adapter_unavailable, _reason}} = Task.await(caller)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    assert_receive {:DOWN, ^conn_monitor, :process, ^conn, :killed}
  end

  test "thought and tool progress stay routed while an unbounded prompt runs" do
    {adapter, _capture_path} = start_adapter(gate_mode: "progress-turn", probe: false)
    assert {:ok, sid} = Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")
    owner = self()

    caller =
      Task.async(fn ->
        Adapter.prompt(adapter, sid, "report progress",
          progress: fn status, seq -> send(owner, {:progress, status, seq}) end
        )
      end)

    assert {:ok, %{stop_reason: "end_turn", text: "progressed"}} = Task.await(caller)

    assert_receive {:progress, "Thinking…", 1}
    assert_receive {:progress, "Read config/runtime.exs", 2}
  end

  test "close_session sends ACP session/close with the harness session id" do
    {adapter, capture_path} = start_adapter()

    assert {:ok, "sess-1"} =
             Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")

    assert Adapter.knows_session?(adapter, "sess-1")

    assert :ok = Adapter.close_session(adapter, "sess-1")
    refute Adapter.knows_session?(adapter, "sess-1")

    assert [%{"method" => "session/close", "sessionId" => "sess-1"}] =
             Enum.filter(captured_requests(capture_path), &(&1["method"] == "session/close"))
  end

  test "new_session and load_session still send an empty mcpServers list" do
    {a, capture_path} = start_adapter()
    assert {:ok, "sess-1"} = Adapter.new_session(a, Model.new("haiku"), "/tmp", [], "guidance")

    assert {:ok, %Model{family: "haiku", effort: nil}} =
             Adapter.load_session(a, "sess-1", Model.new("haiku"), "/tmp", [], "guidance")

    assert [
             %{"method" => "session/new", "mcpServers" => []},
             %{"method" => "session/load", "mcpServers" => []}
           ] = session_requests(capture_path)
  end

  test "bounded continuity guidance uses the harness-accurate metadata channel on new and load" do
    guidance =
      "served guidance\n\n" <>
        "Run `tightbeam transcript --session \"same-key\" --limit 50`. " <>
        "Do not replay or inject earlier messages."

    for {harness, expected} <- [
          {:codex, %{"developerInstructions" => guidance}},
          {:claude,
           %{
             "systemPrompt" => %{
               "type" => "preset",
               "preset" => "claude_code",
               "append" => guidance
             }
           }},
          {:fixture, %{"instructions" => guidance}}
        ] do
      {adapter, capture_path} = start_adapter(harness: harness)

      assert {:ok, "sess-1"} =
               Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], guidance)

      assert {:ok, _pushed_model} =
               Adapter.load_session(
                 adapter,
                 "sess-1",
                 "haiku",
                 "/tmp",
                 [],
                 guidance
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

  # FAIL-BEFORE: against the tree preceding #99 new returned the raw JSON-RPC
  # envelope, which the gateway could only record as an unclassifiable error.
  test "the adapter's -32602 model refusal surfaces on new and canonical reattach" do
    {adapter, _capture} = start_adapter(harness: :codex, fail_mode: "model-invalid-params")

    assert {:error, :model_unavailable} =
             Adapter.new_session(adapter, Model.new("gpt-5.1-codex"), "/tmp", [], "guidance")

    assert {:error, {:model_apply_failed, :model_unavailable}} =
             Adapter.load_session(
               adapter,
               "sess-1",
               Model.new("gpt-5.1-codex"),
               "/tmp",
               [],
               "guidance"
             )

    refute Adapter.knows_session?(adapter, "sess-1")
  end

  test "a rejected candidate reports verified teardown" do
    {adapter, capture_path} = start_adapter(harness: :codex, fail_mode: "model-invalid-params")

    assert {:error,
            {:session_prepare_failed, :model_unavailable, "sess-1",
             %{status: "verified", reason: nil}}} =
             Adapter.new_candidate_session(
               adapter,
               Model.new("gpt-5.1-codex"),
               "/tmp",
               [],
               "guidance"
             )

    assert Enum.any?(captured_requests(capture_path), fn request ->
             request["method"] == "session/close" and
               request["sessionId"] == "sess-1"
           end)
  end

  test "strict apply does not retry an invalid-params model refusal" do
    {adapter, capture_path} =
      start_adapter(harness: :codex, fail_mode: "model-invalid-params")

    assert {:ok, "sess-1"} = Adapter.new_session(adapter, nil, "/tmp", [], "guidance")
    assert {:ok, prior_model} = Adapter.current_model(adapter, "sess-1")

    assert {:error, :model_unavailable} =
             Adapter.apply_model_strict(
               adapter,
               "sess-1",
               Model.new("gpt-5.1-codex"),
               prior_model
             )

    model_writes =
      captured_requests(capture_path)
      |> Enum.filter(&(&1["method"] == "session/set_config_option" and &1["configId"] == "model"))

    assert length(model_writes) == 1
  end

  test "new and canonical reattach surface model apply failures" do
    {adapter, _capture} = start_adapter(harness: :claude, fail_mode: "model-refusal")

    assert {:error, %{"message" => "Invalid value for config option model"}} =
             Adapter.new_session(adapter, Model.new("fable"), "/tmp", [], "guidance")

    assert {:error,
            {:model_apply_failed, %{"message" => "Invalid value for config option model"}}} =
             Adapter.load_session(adapter, "sess-1", Model.new("fable"), "/tmp", [], "guidance")

    refute Adapter.knows_session?(adapter, "sess-1")

    {codex, _capture} = start_adapter(harness: :codex)

    assert {:ok, %Model{family: "gpt-old", effort: "medium"}} =
             Adapter.load_session(
               codex,
               "sess-1",
               Model.new("gpt-old", effort: "medium"),
               "/tmp",
               [],
               "guidance"
             )

    assert :ok = Adapter.apply_model(codex, "sess-1", Model.new("gpt-old", effort: "medium"))

    assert {:ok, %Model{family: "gpt-new", effort: "high"}} =
             Adapter.apply_model_strict(
               codex,
               "sess-1",
               Model.new("gpt-new", effort: "high"),
               Model.new("gpt-old", effort: "medium")
             )
  end

  test "strict apply treats cache disagreement as unknown and forces a canonical reload" do
    {adapter, capture_path} = start_adapter(harness: :codex)

    assert {:ok, "sess-1"} =
             Adapter.new_session(
               adapter,
               Model.new("gpt-old", effort: "medium"),
               "/tmp",
               [],
               "guidance"
             )

    assert {:ok, %Model{family: "gpt-new", effort: "high"}} =
             Adapter.apply_model_strict(
               adapter,
               "sess-1",
               Model.new("gpt-new", effort: "high"),
               Model.new("gpt-old", effort: "medium")
             )

    assert {:error, :model_readback_unavailable} =
             Adapter.apply_model_strict(
               adapter,
               "sess-1",
               Model.new("gpt-late"),
               Model.new("gpt-old", effort: "medium")
             )

    refute Adapter.knows_session?(adapter, "sess-1")
    assert {:error, :model_readback_unavailable} = Adapter.current_model(adapter, "sess-1")

    assert {:ok, %Model{family: "gpt-old", effort: "medium"}} =
             Adapter.load_session(
               adapter,
               "sess-1",
               Model.new("gpt-old", effort: "medium"),
               "/tmp",
               [],
               "guidance"
             )

    model_writes =
      captured_requests(capture_path)
      |> Enum.filter(&(&1["method"] == "session/set_config_option" and &1["configId"] == "model"))
      |> Enum.map(& &1["value"])

    assert model_writes == ["gpt-old", "gpt-new", "gpt-old"]
  end

  test "a partial strict apply reloads and recovers canonically without a rollback request" do
    {adapter, capture_path} =
      start_adapter(harness: :codex, fail_mode: "strict-partial-apply")

    assert {:ok, "sess-1"} =
             Adapter.new_session(
               adapter,
               Model.new("gpt-old", effort: "medium"),
               "/tmp",
               [],
               "guidance"
             )

    assert {:error, :partial_apply} =
             Adapter.apply_model_strict(
               adapter,
               "sess-1",
               Model.new("gpt-new", effort: "high"),
               Model.new("gpt-old", effort: "medium")
             )

    refute Adapter.knows_session?(adapter, "sess-1")
    assert {:error, :model_readback_unavailable} = Adapter.current_model(adapter, "sess-1")

    assert {:ok, %Model{family: "gpt-old", effort: "medium"}} =
             Adapter.load_session(
               adapter,
               "sess-1",
               Model.new("gpt-old", effort: "medium"),
               "/tmp",
               [],
               "guidance"
             )

    assert Adapter.knows_session?(adapter, "sess-1")

    assert {:ok, %Model{family: "gpt-old", effort: "medium"}} =
             Adapter.current_model(adapter, "sess-1")

    recovery_requests =
      captured_requests(capture_path)
      |> Enum.filter(fn request ->
        request["method"] == "session/load" or
          request["method"] == "session/set_config_option"
      end)
      |> Enum.map(&{&1["method"], &1["configId"], &1["value"]})

    assert recovery_requests == [
             {"session/set_config_option", "model", "gpt-old"},
             {"session/set_config_option", "reasoning_effort", "medium"},
             {"session/set_config_option", "model", "gpt-new"},
             {"session/set_config_option", "reasoning_effort", "high"},
             {"session/load", nil, nil},
             {"session/set_config_option", "model", "gpt-old"},
             {"session/set_config_option", "reasoning_effort", "medium"}
           ]
  end

  test "a hung strict effort request returns inside the outer budget and cleans up its late reply" do
    {adapter, _capture_path} = start_adapter(harness: :codex, fail_mode: "strict-effort-hang")

    assert {:ok, "sess-1"} =
             Adapter.new_session(
               adapter,
               Model.new("gpt-old", effort: "medium"),
               "/tmp",
               [],
               "guidance"
             )

    started = System.monotonic_time(:millisecond)

    deadline = System.monotonic_time(:millisecond) + 50

    assert {:error, :partial_apply} =
             GenServer.call(
               adapter,
               {:apply_model_strict, "sess-1", Model.new("gpt-new", effort: "high"),
                Model.new("gpt-old", effort: "medium"), deadline},
               30_000
             )

    assert System.monotonic_time(:millisecond) - started < 1_000
    refute Adapter.knows_session?(adapter, "sess-1")
    assert {:error, :model_readback_unavailable} = Adapter.current_model(adapter, "sess-1")

    Process.sleep(250)
    assert Process.alive?(adapter)
    assert :sys.get_state(Adapter.conn(adapter)).pending == %{}
  end

  @tag timeout: 35_000
  test "strict apply accepts a bare-model reply after the former inner bound and retains residency" do
    {adapter, _capture_path} = start_adapter(harness: :codex, fail_mode: "slow-strict-success")

    assert {:ok, "sess-1"} =
             Adapter.new_session(adapter, Model.new("gpt-old"), "/tmp", [], "guidance")

    assert {:ok, prior_model} = Adapter.current_model(adapter, "sess-1")

    assert {:ok, %Model{family: "gpt-new", effort: nil}} =
             Adapter.apply_model_strict(adapter, "sess-1", Model.new("gpt-new"), prior_model)

    assert Adapter.knows_session?(adapter, "sess-1")

    assert {:ok, %Model{family: "gpt-new", effort: nil}} =
             Adapter.current_model(adapter, "sess-1")
  end

  # FAIL-BEFORE: strict_apply/4 used to start its deadline only after the
  # preceding blocked request released the shared Adapter, so queue time was
  # free and its fresh request outlived the caller's 30s GenServer.call budget.
  # The 30.6s blocker exceeds the 30s operation deadline, so a correctly
  # caller-stamped budget is exhausted at dequeue: nothing may be dispatched,
  # and the structured error must still beat the caller's exit, which waits
  # the reply margin past the operation deadline.
  @tag timeout: 40_000
  test "strict apply queue time spends the caller-owned operation budget" do
    {adapter, capture_path} =
      start_adapter(harness: :codex, fail_mode: "slow-apply-before-strict")

    assert {:ok, "sess-1"} =
             Adapter.new_session(
               adapter,
               Model.new("gpt-old", effort: "medium"),
               "/tmp",
               [],
               "guidance"
             )

    # The blocker exists to OCCUPY the shared Adapter past the strict
    # operation deadline; the handler holds the server until Conn answers at
    # 30.6s whether or not the blocker's own 30s caller is still listening,
    # so its caller exit is expected and irrelevant to what is under test.
    blocker =
      Task.async(fn ->
        try do
          Adapter.apply_model(adapter, "sess-1", Model.new("gpt-blocking"))
        catch
          :exit, reason -> {:caller_exit, reason}
        end
      end)

    assert_request_captured(capture_path, "model", "gpt-blocking")

    strict =
      Task.async(fn ->
        try do
          Adapter.apply_model_strict(
            adapter,
            "sess-1",
            Model.new("gpt-new", effort: "high"),
            Model.new("gpt-old", effort: "medium")
          )
        catch
          :exit, reason -> {:caller_exit, reason}
        end
      end)

    assert {:error, :model_transport_failure} = Task.await(strict, 33_000)
    assert {:caller_exit, _} = Task.await(blocker, 33_000)

    refute Enum.any?(captured_requests(capture_path), fn request ->
             request["method"] == "session/set_config_option" and
               request["configId"] == "model" and request["value"] == "gpt-new"
           end)
  end

  test "a failed ordinary apply also forfeits cached residency" do
    {adapter, _capture_path} =
      start_adapter(harness: :codex, fail_mode: "apply-effort-failure")

    assert {:ok, "sess-1"} =
             Adapter.new_session(
               adapter,
               Model.new("gpt-old", effort: "medium"),
               "/tmp",
               [],
               "guidance"
             )

    assert {:error, %{"message" => "effort refused"}} =
             Adapter.apply_model(adapter, "sess-1", Model.new("gpt-new", effort: "high"))

    refute Adapter.knows_session?(adapter, "sess-1")
    assert {:error, :model_readback_unavailable} = Adapter.current_model(adapter, "sess-1")

    assert {:ok, %Model{family: "gpt-old", effort: "medium"}} =
             Adapter.load_session(
               adapter,
               "sess-1",
               Model.new("gpt-old", effort: "medium"),
               "/tmp",
               [],
               "guidance"
             )
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

    {:ok, park_receiver} =
      Tightbeam.CredentialParkTestReceiver.start_link(fn :openai ->
        send(owner, :parked)
        :ok
      end)

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
        park_edge: Tightbeam.CommandEdge.request_to(park_receiver)
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
    :ok = Tightbeam.Schema.ensure_all(db)
    Tightbeam.Archetypes.load!(base)
    Tightbeam.Rails.load!(base)

    start_supervised!({Task.Supervisor, name: Tightbeam.TurnTaskSupervisor})
    {:ok, adapter_slot} = Agent.start_link(fn -> nil end)

    {:ok, park_receiver} =
      Tightbeam.CredentialParkTestReceiver.start_link(fn :openai ->
        adapter = Agent.get(adapter_slot, & &1)
        _ = Adapter.knows_session?(adapter, "missing")
        send(owner, :parked)
        :ok
      end)

    start_supervised!(
      {Tightbeam.Credentials,
       name: Tightbeam.Credentials,
       base_dir: base,
       machine: "testhost",
       park_edge: Tightbeam.CommandEdge.request_to(park_receiver)}
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
    :ok = Tightbeam.Schema.ensure_all(db)

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
        model: Model.new("fixture")
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
    :ok = Tightbeam.Schema.ensure_all(db)

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
        model: Model.new("fixture")
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
          send(owner, {:subagent_task_captured, self()})

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

        assert_receive {:subagent_task_captured, ^adapter}
        GenServer.stop(db_pid)
        send(adapter, :release_subagent_task)
        Process.sleep(100)
      end)

    assert log =~ "subagent event ingestion failed"
    assert log =~ "retry=false"
    assert Process.alive?(adapter)
  end

  test "prompt preserves distinct ACP assistant message ids across chunk and tool updates" do
    {adapter, _capture_path} =
      start_adapter(gate_mode: "message-boundaries", probe: false)

    assert {:ok, sid} =
             Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")

    assert {:ok,
            %{
              stop_reason: "end_turn",
              text: "first messagesecond message",
              messages: [
                %{message_id: "msg-1", text: "first message"},
                %{message_id: "msg-2", text: "second message"}
              ]
            }} = Adapter.prompt(adapter, sid, "preserve boundaries")
  end

  test "consecutive prompts reset the accumulator" do
    {a, _capture_path} = start_adapter()
    {:ok, _} = Adapter.new_session(a, Model.new("haiku"), "/tmp", [], "guidance")
    assert {:ok, %{text: "pong[allow-once]"}} = Adapter.prompt(a, "sess-1", "one")
    assert {:ok, %{text: "pong[allow-once]"}} = Adapter.prompt(a, "sess-1", "two")
  end

  test "a delayed prompt completes without an elapsed-duration failure" do
    {adapter, _capture_path} = start_adapter(gate_mode: "delay-turn", probe: false)
    assert {:ok, sid} = Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")

    started = System.monotonic_time(:millisecond)

    assert {:ok, %{stop_reason: "end_turn", text: "delayed"}} =
             Adapter.prompt(adapter, sid, "wait")

    assert System.monotonic_time(:millisecond) - started >= 50
  end

  test "delayed live-turn setup completes after an observer returns" do
    {adapter, _capture_path} = start_adapter(gate_mode: "delay-setup", probe: false)

    setup =
      Task.async(fn ->
        Adapter.new_session_for_turn(
          adapter,
          Model.new("haiku"),
          "/tmp",
          [],
          "guidance"
        )
      end)

    refute Task.yield(setup, 25)
    assert {:ok, "sess-1"} = Task.await(setup, 2_000)
  end

  test "preset modes are pinned for both harnesses" do
    for {harness, expected} <- [claude: "bypassPermissions", codex: "agent-full-access"] do
      {adapter, capture_path} = start_adapter(harness: harness)

      assert {:ok, "sess-1"} =
               Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")

      assert [%{"method" => "session/set_mode", "modeId" => ^expected}] =
               Enum.filter(captured_requests(capture_path), &(&1["method"] == "session/set_mode"))
    end
  end

  test "load does not assert mode" do
    {plain, plain_capture} = start_adapter()

    assert {:ok, %Model{family: "haiku", effort: nil}} =
             Adapter.load_session(plain, "sess-1", Model.new("haiku"), "/tmp", [], "guidance")

    refute Enum.any?(captured_requests(plain_capture), &(&1["method"] == "session/set_mode"))
  end

  test "new session mode set stays best effort" do
    {plain, _capture} = start_adapter(fail_mode: "fail")

    assert {:ok, "sess-1"} =
             Adapter.new_session(plain, Model.new("haiku"), "/tmp", [], "guidance")
  end

  test "gate wiring-check passes on message, tool content, or pi-acp terminal-output meta and discards the probe session" do
    for gate_mode <- ["pass-message", "pass-tool", "pass-tool-pi-bash-meta"] do
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

      assert {:ok, "sess-1"} =
               Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")

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
        Task.async(fn ->
          Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], "guidance")
        end)

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
                 Adapter.new_session(adapter, Model.new("haiku"), "/tmp", [], guidance_marker)

        assert_receive {:DOWN, ^monitor, :process, ^adapter, _reason}
        Logger.flush()
      end)

    refute log =~ chunk_marker
    refute log =~ guidance_marker
    assert log =~ "State: :redacted"
    assert log =~ ~r/Last message(?: \(from .+?\))?: :redacted/
  end

  test "gate wiring-check has no elapsed-time failure" do
    {adapter, _capture_path} = start_adapter(harness: :codex, gate_mode: "stall")

    monitor = Process.monitor(adapter)

    queued =
      Task.async(fn ->
        Adapter.new_session_for_turn(adapter, Model.new("haiku"), "/tmp", [], "guidance")
      end)

    refute Task.yield(queued, 75)
    assert Process.alive?(adapter)

    Process.exit(adapter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^adapter, :killed}
    assert {:error, {:adapter_unavailable, _reason}} = Task.await(queued)
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
