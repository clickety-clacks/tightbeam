defmodule Tightbeam.ArtifactCarrierTest do
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
    Assignments,
    ConditionFacts,
    DB,
    EventLog,
    Gateway,
    Ledger,
    Org,
    Projection,
    Roles,
    Rules,
    TurnObservations,
    Wakes,
    WorkItems,
    WorkState
  }

  alias Tightbeam.Wire.Router

  setup do
    db = :"artifact_carrier_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [
          Tightbeam.CausalEvents,
          Tightbeam.Assets,
          Tightbeam.Devices,
          ConditionFacts,
          Tightbeam.Idempotency,
          Ledger,
          Org,
          Projection,
          Roles,
          Wakes,
          WorkItems,
          Assignments,
          WorkState,
          EventLog,
          Tightbeam.Escalation,
          Tightbeam.RailRemedy,
          Tightbeam.Placement,
          Artifacts
        ],
        do: :ok = module.ensure_schema(db)

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-carrier-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

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
        model: "fable"
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
    result = record_over_wire(ctx, %{"kind" => "report", "title" => "Results"})

    refute Map.has_key?(result, "code")
    assert result["recordedMessageId"] == nil
    assert result["recordedTurnEvidence"] == "none"

    assert [row] = Artifacts.list(ctx.db, %{session_key: ctx.coder.session_key})
    assert row.recorded_message_id == nil
    assert row.recorded_turn_evidence == "none"
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
    {:ok, _turn} = Ledger.claim_next(ctx.db, ctx.coder.session_key, "owner")
    :ok = Ledger.finish(ctx.db, seq, "delivered")

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

    :ok = Ledger.finish(ctx.db, running_seq(ctx), "delivered")
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
    :ok = Ledger.finish(ctx.db, running_seq(ctx), "canceled")

    result = record_over_wire(ctx, %{"kind" => "report", "title" => "Mid-work"})

    assert result["recordedMessageId"] == observed_message
    assert result["recordedTurnEvidence"] == "tool-call-observed"
  end

  ## R3 — the boundary strip

  test "caller-supplied provenance never reaches the row", ctx do
    forged = start_turn(ctx)
    :ok = Ledger.finish(ctx.db, running_seq(ctx), "delivered")

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
        model: "fable"
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
    :ok = Ledger.finish(ctx.db, running_seq(ctx), "delivered")

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
    :ok = Ledger.finish(ctx.db, running_seq(ctx), "delivered")

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

  ## Helpers — every one of them a real path.

  defp record_over_wire(ctx, params) do
    params = Map.merge(%{"originPath" => "results.txt", "workItemId" => ctx.work_item_id}, params)

    body = JSON.encode!(%{"verb" => "artifact-record", "params" => params})

    conn =
      conn(:post, "/agent/dispatch", body)
      |> Plug.Conn.put_req_header("authorization", "Bearer #{ctx.coder.cli_token}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(ctx.router_opts)

    assert conn.status == 200
    JSON.decode!(conn.resp_body)["result"]
  end

  defp observe_over_wire(ctx) do
    conn(:post, "/agent/tool-call-observed", "{}")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{ctx.coder.cli_token}")
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
end
