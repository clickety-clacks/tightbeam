import ExUnit.Assertions
alias Tightbeam.{Assignments, DB, Gateway, Identity, Model, Org, Wakes}

Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config, base: base} ->
  Identity.init!(base)

  Org.create(db, %{
    session_key: "k1",
    display_name: "Main",
    owner_user_id: "test-owner",
    origin: "user:test-owner",
    archetype: "default",
    host: "testhost",
    harness: "claude",
    provider: "anthropic",
    model: Model.new("fable")
  })

  assignment =
    Assignments.__handle__(db, "assign", %{
      verb: "assign",
      origin: "user:test-owner",
      principal: {:user, "test-owner"},
      session_key: "k1",
      target_role: nil,
      role_fallback: false,
      params: %{subject: "legacy wake startup"}
    })

  future = System.system_time(:millisecond) + 60_000

  old_wakes = [
    Wakes.schedule(db, %{
      session_key: "k1",
      origin: "process:tightbeam",
      consumer: "assignment_inactivity_deadline",
      prompt: "legacy deadline",
      due_at: future,
      assignment_id: assignment.id,
      obligation_ref: "assignment-inactivity-deadline-v1:" <> assignment.id
    }),
    Wakes.schedule(db, %{
      session_key: "k1",
      origin: "process:tightbeam",
      consumer: "assignment_inactivity_climb",
      prompt: "legacy escalation",
      due_at: future,
      assignment_id: assignment.id,
      obligation_ref: "assignment-inactivity-episode-v1:" <> assignment.id
    }),
    Wakes.schedule(db, %{
      session_key: "k1",
      origin: "process:tightbeam",
      consumer: "prompt",
      prompt: "legacy holder notice",
      due_at: future,
      assignment_id: assignment.id,
      obligation_ref: "assignment-inactivity-episode-v1:" <> assignment.id
    })
  ]

  [deadline, climb, prompt] = old_wakes

  delivered_prompt =
    Wakes.schedule(db, %{
      session_key: "k1",
      origin: "process:tightbeam",
      consumer: "prompt",
      prompt: "already delivered legacy notice",
      due_at: future,
      assignment_id: assignment.id,
      obligation_ref: "assignment-inactivity-episode-v1:" <> assignment.id
    })

  assert {:ok, _} =
           DB.query(db, "UPDATE wakes SET deliveredTurnSeq=123 WHERE wakeId=?1", [
             delivered_prompt.wake_id
           ])

  _children = Gateway.children(config)

  for wake <- [deadline, climb, prompt] do
    assert %{state: "canceled"} = Wakes.get(db, wake.wake_id)
  end

  # Startup suppresses only undelivered legacy actions. A queued message that
  # crossed delivery remains in its original state and cannot be recalled.
  assert %{state: "pending", delivered_turn_seq: 123} =
           Wakes.get(db, delivered_prompt.wake_id)

  assert {:ok, [[0]]} =
           DB.query(
             db,
             "SELECT COUNT(*) FROM turns WHERE sessionKey='k1' AND prompt='legacy holder notice'"
           )
end)

IO.puts("legacy-assignment-inactivity-startup: ok")
