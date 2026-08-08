defmodule Tightbeam.AttentionTierTest do
  @moduledoc """
  Proofs for the assistant attention tier (Flynn, 2026-07-26).

  TWO tiers, agent-elected: normal (0, what electing nothing gives) and high (1).
  The substrate derives nothing and decides no presentation — it stamps the
  election and emits it.

  The election proofs drive a REAL turn through the gateway's own runner, with the
  adapter calling the `attend` verb from inside its prompt callback. That is the
  actual interleaving: an agent elects mid-turn, while its turn is `running`,
  because the lane claimed it. Asserting the copy any other way would be testing a
  restatement of the seam instead of the seam.
  """
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    ConnRegistry,
    DB,
    Dispatch,
    Gateway,
    Ledger,
    ModelCatalog,
    Org,
    Projection
  }

  alias Tightbeam.Wire.{Payloads, Router}

  defmodule LaneDoorbell do
    @moduledoc false
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}
    def handle_call(_any, _from, parent), do: {:reply, :ok, parent}
  end

  defmodule CoordinatorStub do
    @moduledoc false
    use GenServer

    def start_link(adapter),
      do: GenServer.start_link(__MODULE__, adapter, name: Tightbeam.AdapterCoordinator)

    def init(adapter), do: {:ok, adapter}

    def handle_call({:adapter_for, _key}, _from, adapter),
      do: {:reply, {:ok, adapter, 1}, adapter}

    def handle_call({:generation, _key}, _from, adapter), do: {:reply, 1, adapter}
  end

  # The agent: it ELECTS from inside its own turn, then answers. `elect` is the
  # params the adapter should send to `attend` (nil = elect nothing).
  defmodule ElectingAdapter do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))
    def init(state), do: {:ok, state}

    def handle_call({:knows_session?, _sid}, _from, state), do: {:reply, true, state}

    def handle_call({:current_model, _sid}, _from, state),
      do: {:reply, {:ok, "claude-fable-5"}, state}

    def handle_call({:apply_model, _sid, _model}, _from, state), do: {:reply, :ok, state}

    def handle_call({:apply_model, sid, model, _request_timeout}, from, state),
      do: handle_call({:apply_model, sid, model}, from, state)

    def handle_call({:load_session, _sid, model, _cwd, _mcp, _guidance}, _from, state),
      do: {:reply, {:ok, model}, state}

    def handle_call(
          {:load_session, sid, model, cwd, mcp, guidance, _request_timeout},
          from,
          state
        ),
        do: handle_call({:load_session, sid, model, cwd, mcp, guidance}, from, state)

    def handle_call({:new_session, _model, _cwd, _mcp, _guidance}, _from, state),
      do: {:reply, {:ok, "harness-session"}, state}

    def handle_call(
          {:new_session, model, cwd, mcp, guidance, _request_timeout},
          from,
          state
        ),
        do: handle_call({:new_session, model, cwd, mcp, guidance}, from, state)

    def handle_call(:conn, _from, state), do: {:reply, self(), state}
    def handle_call({:close_session, _sid}, _from, state), do: {:reply, :ok, state}

    def handle_call({:prompt, _sid, prompt, _opts}, _from, state) do
      if params = state[:elect] do
        state.dispatch.(params)
      end

      if during = state[:during], do: during.()

      {:reply, {:ok, %{text: "reply to #{prompt}", stop_reason: "end_turn"}}, state}
    end
  end

  setup do
    db = :"attention_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    :ok = Tightbeam.Schema.ensure_all(db)

    :ok = DB.execute(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn',0,1)")

    Org.create(db, %{
      session_key: "k1",
      display_name: "Main",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })

    base_dir = Path.join(System.tmp_dir!(), "attention_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([base_dir, "auth", "claude"]))

    File.write!(
      Path.join([base_dir, "auth", "claude", ".credentials.json"]),
      ~s({"claudeAiOauth":{"accessToken":"t"}})
    )

    on_exit(fn -> File.rm_rf!(base_dir) end)

    start_supervised!(
      {ModelCatalog,
       base_dir: base_dir,
       db: db,
       codex_home: Path.join(base_dir, "codex"),
       claude_fetch: fn _, _ -> {:error, :offline} end,
       codex_read: fn _ -> {:error, :offline} end}
    )

    config = %{
      base_dir: base_dir,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 60_000,
      onboarding_lease_ms: 1_800_000,
      db: db,
      credential_status: fn _ -> :onboarded end,
      credential_kind: fn _ -> :subscription end,
      patch_adapter: fn _harness, _path -> :ok end
    }

    %{db: db, config: config, base_dir: base_dir}
  end

  ## Proof 1 — the election lands on the reply, and electing nothing is normal

  test "an elected turn's reply carries high; an unelected turn's reply carries normal", ctx do
    high = run_turn!(ctx, "elect high", elect: %{high: true})
    assert high.reply.attention_tier == 1
    assert high.echo.attention_tier == 0, "the USER echo is never elected"

    normal = run_turn!(ctx, "elect nothing", elect: nil)
    assert normal.reply.attention_tier == 0

    # Electing explicitly-not-high is the same answer as electing nothing.
    explicit = run_turn!(ctx, "elect normal", elect: %{})
    assert explicit.reply.attention_tier == 0
  end

  ## Proof 2 — the election is turn-scoped

  test "an election cannot leak into a later reply", ctx do
    elected = run_turn!(ctx, "first turn elects high", elect: %{high: true})
    assert elected.reply.attention_tier == 1

    # A LATER turn that elects nothing must not inherit it. The column lives on
    # the turn row, so a session-scoped election would leak here.
    later = run_turn!(ctx, "second turn elects nothing", elect: nil)
    assert later.reply.attention_tier == 0

    # And the first turn's own row still holds its election — it was not moved.
    assert turn_attention(ctx.db, elected.turn_seq) == 1
    assert turn_attention(ctx.db, later.turn_seq) == 0
  end

  test "a newer turn on another session cannot supply this reply's tier", ctx do
    Org.create(ctx.db, %{
      session_key: "k2",
      display_name: "Other",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })

    # k1's turn elects NOTHING, and while it is running — before its reply is
    # appended — a LATER turn appears on k2 electing high. A copy that reads "the
    # newest turn" instead of THIS turn would stamp k1's reply from k2's election.
    interfere = fn ->
      assert :appended =
               Gateway.deliver_prompt("k2", "user:flynn", "other session work",
                 db: ctx.db,
                 client_message_id: "c_other_#{System.unique_integer([:positive])}"
               )

      assert {:ok, other} = Ledger.claim_next(ctx.db, "k2", "lane")

      {:ok, _} =
        DB.query(ctx.db, "UPDATE turns SET replyAttention = 1 WHERE seq = ?1", [other.seq])
    end

    quiet = run_turn!(ctx, "k1 elects nothing", elect: nil, during: interfere)
    assert quiet.reply.attention_tier == 0
  end

  ## Proof 3 — a client cannot forge the column

  test "attend's substrate-owned params are stripped at the wire boundary" do
    # What a caller volunteers on the wire, atomized at the real boundary.
    stripped =
      Router.atomize_params_for_test("attend", %{
        "high" => true,
        "turnSeq" => 99,
        "sessionKey" => "someone-else",
        "replyAttention" => 1,
        "attentionTier" => 1
      })

    # The tier election survives — that IS the verb. Everything naming a target
    # turn or the raw column does not.
    assert stripped == %{high: true}
  end

  test "a volunteered attentionTier does not reach a posted message", ctx do
    # `post` is the only client path that creates a message from client input, and
    # it forwards a fixed set of params; the tier is not among them.
    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "hello",
               db: ctx.db,
               client_message_id: "c_forge",
               attention_tier: 1
             )

    {:ok, [[tier]]} =
      DB.query(ctx.db, "SELECT attentionTier FROM messages WHERE clientMessageId = 'c_forge'")

    assert tier == 0
  end

  ## Proof 4 — the wire carries the field

  test "the message payload emits the tier", ctx do
    high = run_turn!(ctx, "wire check", elect: %{high: true})

    assert Payloads.server_message(high.reply)["attentionTier"] == 1
    assert Payloads.server_message(high.echo)["attentionTier"] == 0
  end

  ## Proof 5 — the verb's own contract

  test "attend elects on the caller's running turn only", ctx do
    handlers = Gateway.handlers(ctx.config)

    # No running turn: refused, and no row is touched.
    assert %{code: "no_running_turn"} =
             handlers["attend"].(%{
               verb: "attend",
               origin: "user:flynn",
               principal: {:session, "k1"},
               session_key: nil,
               params: %{high: true}
             })

    # A QUEUED turn is not yet yours to elect on: the predicate is `running`, not
    # "any turn of mine".
    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "not started yet",
               db: ctx.db,
               client_message_id: "c_queued"
             )

    assert %{code: "no_running_turn"} =
             handlers["attend"].(%{
               verb: "attend",
               origin: "agent:k1",
               principal: {:session, "k1"},
               session_key: nil,
               params: %{high: true}
             })

    # A user principal has no turn to elect on.
    assert %{code: "invalid"} =
             handlers["attend"].(%{
               verb: "attend",
               origin: "user:flynn",
               principal: {:user, "flynn"},
               session_key: nil,
               params: %{high: true}
             })

    # With a running turn, the election lands on THAT turn.
    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "queued work",
               db: ctx.db,
               client_message_id: "c_running"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "lane")

    assert %{turn_seq: seq, attention: "high"} =
             handlers["attend"].(%{
               verb: "attend",
               origin: "agent:k1",
               principal: {:session, "k1"},
               session_key: nil,
               params: %{high: true}
             })

    assert seq == turn.seq
    assert turn_attention(ctx.db, turn.seq) == 1

    # Every elevation is attributed: the election goes through Dispatch, which
    # writes the verb event.
    assert {:ok, _} =
             Dispatch.dispatch(ctx.db, handlers, %{
               verb: "attend",
               origin: "agent:k1",
               principal: {:session, "k1"},
               session_key: nil,
               params: %{high: true}
             })

    {:ok, [[count]]} =
      DB.query(ctx.db, "SELECT COUNT(*) FROM events WHERE verb = 'attend' AND kind = 'verb'")

    assert count == 1
  end

  ## Helpers

  # One real turn: the lane's own runner, an adapter that elects mid-turn through
  # the real verb, and the gateway's own reply append.
  defp run_turn!(ctx, prompt, opts) do
    handlers = Gateway.handlers(ctx.config)

    dispatch = fn params ->
      Dispatch.dispatch(ctx.db, handlers, %{
        verb: "attend",
        origin: "agent:k1",
        principal: {:session, "k1"},
        session_key: nil,
        params: params
      })
    end

    adapter =
      start_supervised!(
        {ElectingAdapter, %{elect: opts[:elect], during: opts[:during], dispatch: dispatch}},
        id: :"adapter_#{System.unique_integer([:positive])}"
      )

    # Registered under the global coordinator name, so each turn starts and stops
    # its own; the id must be the SAME one on both calls.
    coordinator_id = :"coordinator_#{System.unique_integer([:positive])}"
    start_supervised!({CoordinatorStub, adapter}, id: coordinator_id)

    client_message_id = "c_#{System.unique_integer([:positive])}"

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", prompt,
               db: ctx.db,
               client_message_id: client_message_id
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert {:ok, _} = turn_runner(ctx).(Map.put(turn, :session_key, "k1"))
    # Close the turn the way the lane does, so a following turn can be claimed.
    :ok = Ledger.finish(ctx.db, turn.seq, "delivered")

    stop_supervised!(coordinator_id)

    echo = Projection.get(ctx.db, turn.message_id)

    reply =
      ctx.db
      |> Projection.list_after("k1", turn.message_id, 10)
      |> Enum.find(&(&1.role == "assistant"))

    %{turn_seq: turn.seq, echo: echo, reply: reply}
  end

  defp turn_runner(ctx) do
    {Tightbeam.LaneManager, lane_opts} =
      ctx.config
      |> Gateway.children()
      |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

    Keyword.fetch!(lane_opts, :runner)
  end

  defp turn_attention(db, seq) do
    {:ok, [[tier]]} = DB.query(db, "SELECT replyAttention FROM turns WHERE seq = ?1", [seq])
    tier
  end
end
