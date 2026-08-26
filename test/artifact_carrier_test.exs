defmodule Tightbeam.ArtifactCarrierTest.PausingDb do
  @moduledoc """
  A `Tightbeam.DB` transport interposer for forcing one interleaving.

  It implements no database behaviour of its own: every call is forwarded
  verbatim to the real server, so what runs is the real SQL against the real
  connection. The single power it adds is holding ONE call — the first whose SQL
  contains `fragment` — open until the test releases it, which is how a test can
  stand inside a gap instead of racing to hit it.
  """

  use GenServer
  alias Tightbeam.Model

  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  @doc "Answer the held call and stop holding."
  def release(server), do: GenServer.call(server, :release, 10_000)

  @impl true
  def init(opts), do: {:ok, Map.merge(opts, %{armed: true, held: nil})}

  @impl true
  def handle_call(:release, _from, %{held: {from, message}} = state) do
    GenServer.reply(from, GenServer.call(state.db, message))
    # Re-armed: one hold is not always enough, because the durations a test can
    # use are bracketed by the product's own timeouts and sometimes only several
    # short holds fit between them.
    {:reply, :ok, %{state | held: nil, armed: true}}
  end

  def handle_call(:release, _from, state), do: {:reply, :ok, state}

  def handle_call(message, from, state) do
    if state.armed and holds?(message, state.fragment) do
      send(state.notify, {:db_paused, self()})
      {:noreply, %{state | armed: false, held: {from, message}}}
    else
      {:reply, GenServer.call(state.db, message), state}
    end
  end

  defp holds?({:query, sql, _params}, fragment), do: String.contains?(sql, fragment)
  defp holds?(_message, _fragment), do: false
end

defmodule Tightbeam.ArtifactCarrierTest do
  alias Tightbeam.Model

  @moduledoc """
  The artifact-record firing-turn carrier (artifact-carrier-proposal-v1).

  EVERY evidence class here is pinned through the REAL dispatch path — a wire
  body posted at `/agent/dispatch` against the real `Gateway.handlers`, and a
  real `/agent/tool-call-observed` for the hook leg. Nothing is asserted by
  INSERTing a row or by handing the handler a `recorded_message_id` it could not
  have got over the wire. That shortcut is exactly why the live defect survived:
  the suite drove a path no CLI client can reach, so the refusal every real
  caller met was invisible to it.
  """

  use Tightbeam.TestCase, async: false

  import Plug.Test

  alias Tightbeam.{
    Artifacts,
    DB,
    Gateway,
    Ledger,
    Org,
    Projection,
    Roles,
    Rules,
    TurnObservations
  }

  alias Tightbeam.ArtifactCarrierTest.PausingDb
  alias Tightbeam.Wire.Router

  setup do
    db = :"artifact_carrier_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = Tightbeam.Schema.ensure_all(db)

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-carrier-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    main_key = Org.personal_session_key("flynn")

    Org.create(db, %{
      session_key: main_key,
      display_name: "Main",
      kind: "main",
      is_built_in: true,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    coder =
      Org.create(db, %{
        session_key: "carrier-coder",
        display_name: "Carrier Coder",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    Roles.create!(db, "carrier-coder", "flynn", coder.session_key)

    handlers = Gateway.handlers(%{db: db, base_dir: base_dir})
    Rules.load!(base_dir, Map.keys(handlers))

    router_opts =
      Router.init(
        db: db,
        base_dir: base_dir,
        handlers: handlers,
        cli_token: "tbc_carrier",
        session_status: fn _ -> nil end
      )

    work_item =
      handlers["work-item-create"].(%{
        principal: {:user, "flynn"},
        params: %{title: "Carrier work"}
      })

    %{db: db, coder: coder, router_opts: router_opts, work_item_id: work_item.id}
  end

  ## The live defect — R1

  test "an artifact-record over the real wire records instead of refusing", ctx do
    result =
      record_over_wire(ctx, %{
        "kind" => "report",
        "title" => "Results",
        "contentSha256" => "abc123"
      })

    refute Map.has_key?(result, "code")
    assert result["recordedMessageId"] == nil
    assert result["recordedTurnEvidence"] == "none"
    assert result["contentSha256Status"] == "attested-not-verified"

    assert [row] = Artifacts.list(ctx.db, %{session_key: ctx.coder.session_key})
    assert row.recorded_message_id == nil
    assert row.recorded_turn_evidence == "none"
    assert row.content_sha256_status == "attested-not-verified"
  end

  ## The three evidence classes, each over the real path

  test "a hook observation binds the turn it saw, as tool-call-observed", ctx do
    message_id = start_turn(ctx)

    assert observe_over_wire(ctx) == 200

    result = record_over_wire(ctx, %{"kind" => "report", "title" => "Observed"})

    assert result["recordedMessageId"] == message_id
    assert result["recordedTurnEvidence"] == "tool-call-observed"
  end

  test "an unobserved record during a running turn is session-concurrent", ctx do
    message_id = start_turn(ctx)

    result = record_over_wire(ctx, %{"kind" => "report", "title" => "Script-wrapped"})

    assert result["recordedMessageId"] == message_id
    assert result["recordedTurnEvidence"] == "session-concurrent"
  end

  test "an unobserved record with no running turn is none, with a null edge", ctx do
    seq = enqueue_turn(ctx)
    {:ok, turn} = Ledger.claim_next(ctx.db, ctx.coder.session_key, "owner")
    :ok = Ledger.finish(ctx.db, seq, "delivered", nil, owner_lease: turn.owner_lease)

    result = record_over_wire(ctx, %{"kind" => "doc", "title" => "Operator shell"})

    assert result["recordedMessageId"] == nil
    assert result["recordedTurnEvidence"] == "none"
  end

  ## What capturing AT OBSERVATION TIME buys — the two cases request-time
  ## derivation gets wrong, asserted rather than described.

  test "the window holds the turn that was running when the hook fired, not at request time",
       ctx do
    observed_message = start_turn(ctx)
    assert observe_over_wire(ctx) == 200

    :ok = finish_running(ctx, "delivered")
    next_message = start_turn(ctx)
    refute next_message == observed_message

    result = record_over_wire(ctx, %{"kind" => "report", "title" => "Slow command"})

    assert result["recordedMessageId"] == observed_message
    assert result["recordedTurnEvidence"] == "tool-call-observed"
  end

  test "a record arriving after its turn was canceled still binds that turn", ctx do
    observed_message = start_turn(ctx)
    assert observe_over_wire(ctx) == 200

    # Cancel terminalizes BEFORE the serving task dies (session_lane.ex), which is
    # what used to make a legitimate mid-work record bind nothing.
    :ok = finish_running(ctx, "canceled")

    result = record_over_wire(ctx, %{"kind" => "report", "title" => "Mid-work"})

    assert result["recordedMessageId"] == observed_message
    assert result["recordedTurnEvidence"] == "tool-call-observed"
  end

  ## R3 — the boundary strip

  test "caller-supplied provenance never reaches the row", ctx do
    forged = start_turn(ctx)
    :ok = finish_running(ctx, "delivered")

    result =
      record_over_wire(ctx, %{
        "kind" => "report",
        "title" => "Forged",
        "recordedMessageId" => forged,
        "recordedTurnEvidence" => "tool-call-observed"
      })

    assert result["recordedMessageId"] == nil
    assert result["recordedTurnEvidence"] == "none"
  end

  test "the strip is pinned at the boundary seam itself", _ctx do
    assert Router.atomize_params_for_test("artifact-record", %{
             "kind" => "report",
             "recordedMessageId" => "msg_forged",
             "recordedTurnEvidence" => "tool-call-observed"
           }) == %{kind: "report"}
  end

  ## R5 — the completion gate is blind to the evidence class

  test "recorded_kinds answers identically whatever the evidence class is", ctx do
    _observed = start_turn(ctx)
    assert observe_over_wire(ctx) == 200
    record_over_wire(ctx, %{"kind" => "report", "title" => "Observed report"})

    assert Artifacts.recorded_kinds(ctx.db, ctx.work_item_id, ctx.coder.session_key) == ["report"]

    other =
      Org.create(ctx.db, %{
        session_key: "carrier-other",
        display_name: "Other",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    Roles.create!(ctx.db, "carrier-other", "flynn", other.session_key)

    other_ctx = %{ctx | coder: other}
    result = record_over_wire(other_ctx, %{"kind" => "report", "title" => "Bare report"})
    assert result["recordedTurnEvidence"] == "none"

    assert Artifacts.recorded_kinds(ctx.db, ctx.work_item_id, other.session_key) == ["report"]
  end

  ## The window itself

  test "a fresher observation supersedes the session's window", ctx do
    first = start_turn(ctx)
    assert observe_over_wire(ctx) == 200
    :ok = finish_running(ctx, "delivered")

    second = start_turn(ctx)
    assert observe_over_wire(ctx) == 200

    result = record_over_wire(ctx, %{"kind" => "report", "title" => "Second"})

    assert result["recordedMessageId"] == second
    refute result["recordedMessageId"] == first
  end

  test "an observation that finds no running turn closes the window rather than leaving it",
       ctx do
    _stale = start_turn(ctx)
    assert observe_over_wire(ctx) == 200
    :ok = finish_running(ctx, "delivered")

    # A second hook fire with nothing running: the freshest look saw no turn, so
    # the stale message must not survive to be bound.
    assert observe_over_wire(ctx) == 200

    result = record_over_wire(ctx, %{"kind" => "report", "title" => "After close"})

    assert result["recordedMessageId"] == nil
    assert result["recordedTurnEvidence"] == "none"
  end

  test "one window serves every record of the command that opened it", ctx do
    message_id = start_turn(ctx)
    assert observe_over_wire(ctx) == 200

    first = record_over_wire(ctx, %{"kind" => "spec", "title" => "One"})
    second = record_over_wire(ctx, %{"kind" => "report", "title" => "Two"})

    for result <- [first, second] do
      assert result["recordedMessageId"] == message_id
      assert result["recordedTurnEvidence"] == "tool-call-observed"
    end
  end

  test "the org token opens no window — it names no session", ctx do
    conn =
      conn(:post, "/agent/tool-call-observed", "{}")
      |> Plug.Conn.put_req_header("authorization", "Bearer tbc_carrier")
      |> Plug.Conn.put_req_header(
        "x-tightbeam-cli-version",
        Tightbeam.CliCompatibility.required_version()
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(ctx.router_opts)

    assert conn.status == 403
    assert JSON.decode!(conn.resp_body)["error"]["code"] == "session_required"
  end

  test "a missing writer degrades the class and never the record", ctx do
    message_id = start_turn(ctx)
    assert observe_over_wire(ctx) == 200

    stop_supervised!(TurnObservations)

    result = record_over_wire(ctx, %{"kind" => "report", "title" => "Writerless"})

    assert result["recordedMessageId"] == message_id
    assert result["recordedTurnEvidence"] == "session-concurrent"
  end

  ## Concurrency — the two interleavings, forced rather than sampled.

  # THE property: evidence resolution is ONE writer-owned operation, so nothing
  # can run between the window lookup and the ledger fallback.
  #
  # It is measured by writer OCCUPANCY, because that is what actually differs.
  # When the ledger read is paused mid-flight, the question "is the writer busy?"
  # answers "who owns this resolution": resolved in one operation the writer is
  # inside it and can serve nothing else; split across processes the writer
  # handed back its half and sits idle while the request process reads the
  # ledger — and idle is exactly the state in which some other message gets in
  # between the two halves.
  #
  # What this does NOT claim: that a turn can never terminalize during a
  # resolution. A single ledger read observes whatever instant it runs at, and
  # nothing here makes the ledger and the window one atomic snapshot of the
  # world. What is eliminated is the SCHEDULING GAP — an unbounded round trip
  # plus rescheduling, versus two adjacent statements no message can split.
  test "nothing can be served between the window lookup and the ledger fallback", ctx do
    running_message = start_turn(ctx)
    {proxy, _real} = pausing_db(ctx, "SELECT messageId FROM turns")

    recorder =
      Task.async(fn ->
        Artifacts.record(proxy, %{
          principal: {:session, ctx.coder.session_key},
          session_key: ctx.coder.session_key,
          params: %{
            kind: "report",
            title: "Contended",
            origin_path: "results.txt",
            work_item_id: ctx.work_item_id
          }
        })
      end)

    assert_receive {:db_paused, ^proxy}, 2_000

    # The ledger read is in flight RIGHT NOW. Ask the writer for anything at all.
    probe = Task.async(fn -> TurnObservations.observe(ctx.db, "probe-session") end)

    refute Task.yield(probe, 500),
           "the writer answered a call while an evidence resolution was in flight — " <>
             "the resolution is not writer-owned, so something can land between its two reads"

    release_db(proxy)

    assert %{recorded_turn_evidence: "session-concurrent", recorded_message_id: ^running_message} =
             Task.await(recorder, 5_000)

    Task.await(probe, 5_000)
  end

  # A post its caller has abandoned must never act. The caller's `GenServer.call`
  # times out but the message stays in the mailbox, so without a deadline riding
  # on it the writer opens the window LATE — and a later, unrelated record reads
  # it and is STRENGTHENED to `tool-call-observed`. Degradation must not invent
  # evidence; that is the wrong direction to fail in.
  #
  # The post is stalled INSIDE its own ledger read, which is the interleaving an
  # arrival-only check cannot see: the writer entered the callback in good time
  # and the deadline passed while it was reading.
  #
  # THE THREE DURATIONS ARE NOT FREE CHOICES. They are boxed in by the product's
  # own two timeouts, and each bound is there for a reason a previous version of
  # this test got wrong:
  #
  #   * the post must be PICKED UP before its 2s deadline, or the arrival check
  #     drops it and the in-flight crossing is never exercised at all — so the
  #     first hold is short, and the second pause is asserted, which is what
  #     proves the post really did enter the callback in time;
  #   * the window must open AFTER the 5s that the unfenced writer made its
  #     caller wait, or the baseline red is only "a post acted late" rather than
  #     "a post acted for a caller that was already gone";
  #   * no single hold may reach `DB.query/3`'s own 5s ceiling, or the writer
  #     dies instead of deciding — a dead writer yields the same evidence class
  #     for an entirely different reason, which is exactly how an earlier version
  #     of this test passed while proving nothing.
  #
  # Those three leave roughly half a second of room at each end, which is why the
  # time is spent across two holds rather than one, and why liveness is asserted
  # rather than assumed. Every duration is wall-clock from a monotonic origin, so
  # load moves the assertions, not the holds.
  @tag timeout: 60_000
  test "an observation its caller gave up on can never open a window later", ctx do
    running_message = start_turn(ctx)
    {proxy, _real} = pausing_db(ctx, "SELECT messageId FROM turns")
    writer = Process.whereis(TurnObservations)

    # Occupy the writer first, so the post that matters is queued behind a call
    # already in progress — which is what makes its pickup time ours to choose.
    occupier = Task.async(fn -> TurnObservations.observe(proxy, "occupier-session") end)
    assert_receive {:db_paused, ^proxy}, 2_000

    posted_at = System.monotonic_time(:millisecond)
    abandoned = Task.async(fn -> TurnObservations.observe(proxy, ctx.coder.session_key) end)

    wait_until(posted_at + 1_000)
    release_db(proxy)
    assert Task.await(occupier, 5_000) == :ok

    # The post is now INSIDE its callback, parked on its own ledger read, having
    # entered a full second before its deadline.
    assert_receive {:db_paused, ^proxy}, 2_000

    wait_until(posted_at + 5_500)

    # ASSERTED BEFORE THE RELEASE, and that order is the whole point. Awaiting
    # after it cannot tell a timeout fallback from a writer reply — both are
    # `:ok` — so a caller whose start slipped by half a second would time out at
    # the very moment the window opened, and the baseline red would quietly
    # decay from "acted for a caller that was gone" back to "acted late".
    # Checking here, with nothing released yet, there is nothing but the timeout
    # this could be.
    assert Task.yield(abandoned, 0) == {:ok, :ok},
           "the caller had not abandoned yet, so opening the window now would not prove the defect"

    release_db(proxy)

    assert Process.alive?(writer),
           "the writer died rather than dropping the post — this test would then pass for the wrong reason"

    # Mailbox order: this post is behind the abandoned one, so its answer proves
    # the abandoned one has already been processed. No sleeping, no polling.
    assert TurnObservations.observe(ctx.db, "barrier-session") == :ok

    result = record_over_wire(ctx, %{"kind" => "report", "title" => "After the abandoned post"})

    assert result["recordedMessageId"] == running_message

    assert result["recordedTurnEvidence"] == "session-concurrent",
           "an abandoned observation opened a window and strengthened a later record"
  end

  ## Helpers — every one of them a real path.

  # A transport interposer, NOT a fake database: it speaks `Tightbeam.DB`'s own
  # call protocol and forwards every message to the real server. Its only power
  # is to hold ONE matching call open, which is how an interleaving gets forced
  # instead of sampled for.
  defp pausing_db(ctx, sql_fragment) do
    {:ok, proxy} = PausingDb.start_link(db: ctx.db, fragment: sql_fragment, notify: self())
    on_exit(fn -> if Process.alive?(proxy), do: GenServer.stop(proxy) end)
    {proxy, ctx.db}
  end

  defp release_db(proxy), do: PausingDb.release(proxy)

  # Monotonic, so the wait is the elapsed time it claims to be even if the wall
  # clock moves under it.
  defp wait_until(target) do
    case target - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 ->
        Process.sleep(remaining)
        wait_until(target)

      _ ->
        :ok
    end
  end

  defp record_over_wire(ctx, params) do
    params = Map.merge(%{"originPath" => "results.txt", "workItemId" => ctx.work_item_id}, params)

    body = JSON.encode!(%{"verb" => "artifact-record", "params" => params})

    conn =
      conn(:post, "/agent/dispatch", body)
      |> Plug.Conn.put_req_header("authorization", "Bearer #{ctx.coder.cli_token}")
      |> Plug.Conn.put_req_header(
        "x-tightbeam-cli-version",
        Tightbeam.CliCompatibility.required_version()
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(ctx.router_opts)

    assert conn.status == 200
    JSON.decode!(conn.resp_body)["result"]
  end

  defp observe_over_wire(ctx) do
    conn(:post, "/agent/tool-call-observed", "{}")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{ctx.coder.cli_token}")
    |> Plug.Conn.put_req_header(
      "x-tightbeam-cli-version",
      Tightbeam.CliCompatibility.required_version()
    )
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Router.call(ctx.router_opts)
    |> Map.fetch!(:status)
  end

  defp enqueue_turn(ctx) do
    {:appended, message} =
      Projection.append(ctx.db, %{
        session_key: ctx.coder.session_key,
        role: "user",
        content: "do the work"
      })

    {:ok, seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.coder.session_key,
        message_id: message.id,
        origin: "user:flynn",
        prompt: "do the work"
      })

    seq
  end

  defp start_turn(ctx) do
    _seq = enqueue_turn(ctx)
    {:ok, turn} = Ledger.claim_next(ctx.db, ctx.coder.session_key, "owner")
    turn.message_id
  end

  defp running_seq(ctx) do
    {:ok, [[seq]]} =
      DB.query(
        ctx.db,
        "SELECT seq FROM turns WHERE sessionKey = ?1 AND status = 'running'",
        [ctx.coder.session_key]
      )

    seq
  end

  defp finish_running(ctx, terminal) do
    seq = running_seq(ctx)

    {:ok, [[lease]]} =
      DB.query(
        ctx.db,
        "SELECT ownerLease FROM turn_lifecycle_events WHERE turnSeq=?1 AND kind='claimed'",
        [seq]
      )

    Ledger.finish(ctx.db, seq, terminal, nil, owner_lease: lease)
  end
end
