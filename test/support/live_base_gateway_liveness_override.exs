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

  children =
    Gateway.children(
      config
      |> Map.put(:wake_tick_ms, 1_234)
      |> Map.merge(%{supervision_interval_ms: 4_321})
    )

  assert {:ok,
          [
            [
              1,
              "armed",
              "recovery_backfill",
              "asg_boot_recovery",
              "recovery_backfill",
              "process:tightbeam",
              4321
            ]
          ]} =
           DB.query(db, """
           SELECT generation,state,basisKind,basisId,cause,principal,supervisionIntervalMs
           FROM supervision_entitlements
           WHERE assignmentId='asg_boot_recovery'
           """)

  {Tightbeam.Supervision, supervision_opts} =
    Enum.find(children, &match?({Tightbeam.Supervision, _}, &1))

  assert Keyword.fetch!(supervision_opts, :recover) == false
end)

IO.puts("guarded-gateway-liveness: ok")
