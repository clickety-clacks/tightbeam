import ExUnit.Assertions
alias Tightbeam.{DB, Gateway, Org, Model}

Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config} ->
  Org.create(db, %{
    session_key: "k1",
    display_name: "Main",
    owner_user_id: "flynn",
    origin: "user:flynn",
    archetype: "default",
    host: "testhost",
    harness: "claude",
    provider: "anthropic",
    model: Model.new("fable")
  })

  :ok =
    DB.execute(
      db,
      "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt) VALUES ('asg_boot_recovery', 'boot recovery', 'k1', 'flynn', 1)"
    )

  _children =
    Gateway.children(
      config
      |> Map.put(:wake_tick_ms, 1_234)
      |> Map.merge(%{supervision_interval_ms: 4_321})
    )

  assert {:ok, [[4322, 4321, 1, "k1"]]} =
           DB.query(db, """
           SELECT dueAt, json_extract(prompt, '$.intervalMs'), json_extract(prompt, '$.activityAt'),
                  sessionKey
           FROM wakes
           WHERE assignmentId='asg_boot_recovery'
             AND consumer='assignment_inactivity_deadline' AND state='pending'
           """)
end)

IO.puts("guarded-gateway-liveness: ok")
