# E1 FIRST LIGHT — a prompt round-trips through the SUPERVISED Elixir spine to
# a REAL claude adapter: DB + Ledger + reconciler + SessionLane + Acp.Adapter.
# No wire, no client — the E1 exit criterion (supervised prompt round-trip).
#
# Run on eezo:  mix run scripts/e1_first_light.exs
# Uses the TS repo's installed claude adapter binary + real ~/.claude creds.

alias Tightbeam.{DB, Ledger, EventLog, SessionLane, LaneManager}
alias Tightbeam.Acp.Adapter

home = System.get_env("HOME")
base = Path.join(System.tmp_dir!(), "tb-ex-firstlight-#{System.unique_integer([:positive])}")
adapter_home = Path.join(base, "home")
File.mkdir_p!(adapter_home)

# Seed claude creds into the adapter home (real .credentials.json).
cred_src = Path.join([home, ".claude", ".credentials.json"])
File.cp!(cred_src, Path.join(adapter_home, ".credentials.json"))
File.write!(Path.join(adapter_home, "CLAUDE.md"), "# Tightbeam E1\nBe terse.")

adapter_bin =
  Path.join([home, "src/tightbeam/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js"])

node = System.find_executable("node")

IO.puts("[e1] base=#{base}")

# --- bring up the supervised spine (mirrors the Application tree) ---
{:ok, _} = DB.start_link(path: Path.join(base, "state.db"), name: DB)
:ok = Ledger.ensure_schema()
:ok = EventLog.ensure_schema()
_epoch = EventLog.boot()

{:ok, _} = Registry.start_link(keys: :unique, name: Tightbeam.LaneRegistry)
{:ok, task_sup} = Task.Supervisor.start_link(name: Tightbeam.TurnTaskSupervisor)
{:ok, lane_sup} = DynamicSupervisor.start_link(strategy: :one_for_one, name: Tightbeam.LaneSupervisor)

{:ok, adapter} =
  Adapter.start_link(
    harness: :claude,
    cmd: [node, adapter_bin],
    home: adapter_home,
    cwd: home,
    stderr_path: Path.join(base, "adapter.stderr.log"),
    name: :e1_adapter
  )

IO.puts("[e1] adapter up")

# One live harness session for this UI session; the runner maps a turn ->
# adapter prompt and records the harness session id via the ledger's row.
{:ok, sid} = Adapter.new_session(adapter, "haiku")
IO.puts("[e1] harness session: #{sid}")

test_ref = self()

runner = fn turn ->
  case Adapter.prompt(adapter, sid, turn.prompt) do
    {:ok, %{stop_reason: sr, text: text}} ->
      send(test_ref, {:reply, turn.seq, sr, text})
      {:ok, %{text: text}}

    {:error, e} ->
      send(test_ref, {:reply_error, turn.seq, e})
      {:error, e}
  end
end

{:ok, _mgr} =
  LaneManager.start_link(
    lane_sup: lane_sup,
    task_sup: task_sup,
    runner: runner,
    interval: 500
  )

# Enqueue a turn (as a client post would) and let the reconciler/lane run it.
session_key = "agent:main:clawline:flynn:main"
{:ok, seq} =
  Ledger.enqueue(%{
    session_key: session_key,
    message_id: "s_e1_1",
    origin: "user:flynn",
    prompt: "Reply with exactly: ELIXIR FIRST LIGHT"
  })

LaneManager.ensure_lane(session_key)
IO.puts("[e1] enqueued turn seq=#{seq}; awaiting delivery...")

receive do
  {:reply, ^seq, stop_reason, text} ->
    IO.puts("[e1] stop_reason=#{stop_reason} reply=#{inspect(text)}")

    # assert the ledger recorded exactly one terminal, published
    Process.sleep(200)
    {:ok, [[status, published]]} =
      DB.query(DB, "SELECT status, publishedAt FROM turns WHERE seq = ?1", [seq])

    pass =
      String.contains?(text, "ELIXIR FIRST LIGHT") and status == "delivered" and published != nil and
        Ledger.non_terminal_older_than(0) == []

    IO.puts(if pass, do: "[e1] ✅ PASS", else: "[e1] ❌ FAIL (status=#{status} published=#{inspect(published)})")
    System.halt(if pass, do: 0, else: 1)

  {:reply_error, ^seq, e} ->
    IO.puts("[e1] ❌ FAIL — adapter error: #{inspect(e)}")
    System.halt(1)
after
  120_000 ->
    IO.puts("[e1] ❌ FAIL — timed out")
    System.halt(1)
end
