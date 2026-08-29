defmodule Tightbeam.TerminalDecisionRequestIdIntegrityTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, DB, Escalation, Model, Org, Wakes}

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, session_key}, _from, parent) do
      send(parent, {:lane_nudged, session_key})
      {:reply, :ok, parent}
    end
  end

  setup do
    db = :"terminal_request_id_db_#{System.unique_integer([:positive])}"
    scheduler = :"terminal_request_id_scheduler_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)
    ensure_main_session(db, "flynn")
    raiser = session(db, "raiser", "flynn")
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    start_supervised!(
      {Wakes, db: db, name: scheduler, tick_ms: 60_000, deliver: fn _wake -> :ok end}
    )

    %{db: db, scheduler: scheduler, raiser: raiser}
  end

  test "a linked ruled dr_x corruption refuses after visibility and records request identity",
       ctx do
    request =
      Escalation.operator_ask(
        ctx.db,
        operator_call(ctx.raiser, %{question: "canonical request identity?"})
      )

    assert %{status: "ruled"} =
             Escalation.operator_rule(
               ctx.db,
               owner_operator_rule(request.id, %{decision: "accept"}),
               scheduler: ctx.scheduler
             )

    corrupt_id = "dr_x"

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE condition_facts SET scope=?1 WHERE kind='escalation-ruled' AND scope=?2",
               [corrupt_id, request.id]
             )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE lifecycle_events SET subject=?1 WHERE kind='decision_request_ruled' AND subject=?2",
               [corrupt_id, request.id]
             )

    prompt =
      "Decision request #{corrupt_id} was ruled. Read it with tightbeam decision-request --request #{corrupt_id}."

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE wakes SET conditionScope=?1,prompt=?2 WHERE conditionKind='escalation-ruled' AND conditionScope=?3",
               [corrupt_id, prompt, request.id]
             )

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE decision_requests SET id=?1 WHERE id=?2", [
               corrupt_id,
               request.id
             ])

    assert {:ok, [[1, 1, 1, 1, ^prompt]]} =
             DB.query(
               ctx.db,
               "SELECT (SELECT COUNT(*) FROM decision_requests WHERE id=?1), (SELECT COUNT(*) FROM condition_facts WHERE kind='escalation-ruled' AND scope=?1), (SELECT COUNT(*) FROM lifecycle_events WHERE kind='decision_request_ruled' AND subject=?1), (SELECT COUNT(*) FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope=?1), (SELECT prompt FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope=?1)",
               [corrupt_id]
             )

    ensure_main_session(ctx.db, "other")
    foreign = session(ctx.db, "foreign", "other")
    assert nil == Escalation.get(ctx.db, operator_call(foreign, %{}), corrupt_id)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM decision_request_integrity_evidence WHERE requestId=?1",
               [corrupt_id]
             )

    owner_call = owner_operator_rule(corrupt_id, %{})

    detail = Escalation.get(ctx.db, owner_call, corrupt_id)
    listed = Escalation.list(ctx.db, owner_call, "ruled", owner_user_id: "flynn")

    replay =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(corrupt_id, %{decision: "accept"}),
        scheduler: ctx.scheduler
      )

    for refusal <- [detail, listed, replay] do
      assert %{code: "decision_request_integrity_invalid", request_id: ^corrupt_id} = refusal
      refute Map.has_key?(refusal, :status)
      refute Map.has_key?(refusal, :decision)
      refute Map.has_key?(refusal, :ruled_at)
    end

    assert {:ok, [[1, ~s(["requestIdentity"])]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*),MIN(failingFields) FROM decision_request_integrity_evidence WHERE requestId=?1",
               [corrupt_id]
             )
  end

  defp session(db, name, owner) do
    Org.create(db, %{
      session_key: "agent:#{name}:app",
      display_name: name,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp operator_call(session, params) do
    %{
      verb: "operator-ask",
      origin: "agent:raiser",
      principal: {:session, session.session_key},
      transport_session_key: session.session_key,
      params: params
    }
  end

  defp owner_operator_rule(id, params) do
    %{
      verb: "operator-rule",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      transport_session_key: nil,
      params: Map.put(params, :request, id)
    }
  end
end
