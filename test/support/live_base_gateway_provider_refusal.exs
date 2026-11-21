defmodule RefusalFixtureDoorbell do
  use GenServer

  def init(nil), do: {:ok, nil}
  def handle_call({:ensure_lane, _key}, _from, nil), do: {:reply, :ok, nil}
end

import ExUnit.Assertions

alias Tightbeam.{Assignments, DB, Gateway, Ledger, Model, Org, Projection, SessionLane}
alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}
alias Tightbeam.Productions.Bubble

Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config} ->
  for {key, parent} <- [{"ancestor", nil}, {"opener", "ancestor"}, {"holder", "ancestor"}] do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      spawned_by: parent
    })
  end

  {:ok, adapter} = AdapterStub.start_link(self())
  {:ok, _coordinator} = CoordinatorStub.start_link(adapter)
  {:ok, doorbell} = GenServer.start_link(RefusalFixtureDoorbell, nil)

  {Tightbeam.LaneManager, lane_opts} =
    Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

  parent = self()
  {:ok, _registry} = Registry.start_link(keys: :unique, name: Tightbeam.LaneRegistry)
  {:ok, task_sup} = Task.Supervisor.start_link()

  {:ok, _lane} =
    SessionLane.start_link(
      session_key: "holder",
      db: db,
      task_sup: task_sup,
      runner: Keyword.fetch!(lane_opts, :runner),
      on_terminal: fn key, seq -> send(parent, {:terminal, key, seq}) end
    )

  assignment =
    Assignments.__handle__(db, "assign", %{
      verb: "assign",
      origin: "agent:opener",
      principal: {:session, "opener"},
      session_key: "holder",
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: %{subject: "provider refusal fixture"}
    })

  assert is_binary(assignment.id)

  for {prompt, status, refusal?} <- [
        {"provider refusal fixture", "failed", true},
        {"ordinary text fixture", "delivered", false},
        {"fail before dispatch", "failed", false}
      ] do
    assert :appended =
             Gateway.deliver_prompt("holder", "agent:opener", prompt,
               db: db,
               assignment_id: assignment.id,
               lane_manager: doorbell
             )

    assert :ok = SessionLane.nudge("holder")
    assert_receive {:terminal, "holder", seq}, 60_000

    assert {:ok, [[^status, ended_at, detail]]} =
             DB.query(
               db,
               """
               SELECT t.status,t.endedAt,event.detail
               FROM turns t JOIN turn_lifecycle_events event ON event.turnSeq=t.seq
               WHERE t.seq=?1 AND event.eventKey='terminal:committed'
               """,
               [seq]
             )

    assert is_integer(ended_at)
    detail = JSON.decode!(detail)

    for _ <- 1..2, do: assert(:ok = Bubble.recognize_terminal(db, seq))

    assert {:ok, notices} =
             DB.query(
               db,
               "SELECT sessionKey,content FROM messages WHERE clientMessageId=?1",
               ["wake-undelivered:#{seq}"]
             )

    assert {:ok, bubble_notices} =
             DB.query(db, "SELECT sessionKey,prompt FROM turns WHERE requestRef=?1", [
               "bubble:#{seq}"
             ])

    case {refusal?, status} do
      {true, "failed"} ->
        assert %{
                 "workOutcome" => "did_not_perform",
                 "reason" => "provider_refusal",
                 "promptDelivery" => "delivered"
               } = detail

        assert notices == []
        assert [["opener", content]] = bubble_notices
        assert content =~ "received the prompt"
        assert content =~ "did not perform work"
        assert Ledger.pending_count(db, "ancestor") == 0
        assert Ledger.pending_count(db, "opener") == 1

        assert Enum.any?(
                 Projection.list_after(db, "holder", nil, 20),
                 &(&1.content == "The request was declined." and &1.role == "assistant")
               )

      {false, "delivered"} ->
        refute Map.has_key?(detail, "workOutcome")
        assert notices == []
        assert bubble_notices == []

      {false, "failed"} ->
        refute Map.has_key?(detail, "workOutcome")
        assert [["opener", content]] = notices
        assert content =~ "undelivered"
        assert [["ancestor", _content]] = bubble_notices
    end
  end
end)

IO.puts("guarded-gateway-provider-refusal: ok")
