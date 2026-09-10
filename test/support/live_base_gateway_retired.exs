import ExUnit.Assertions
alias Tightbeam.{DB, Gateway, Model, Org, RuleRuntime, Wakes}

Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config, base: base} ->
  for key <- ["k1", "boot-retired"] do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  retired = Org.get(db, "boot-retired")

  :ok =
    DB.execute(
      db,
      "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt) VALUES ('asg_boot_retired', 'retired at boot', '#{retired.session_key}', 'flynn', 1)"
    )

  :ok =
    DB.execute(
      db,
      "UPDATE sessions SET state='retired' WHERE sessionKey='#{retired.session_key}'"
    )

  rules_dir = Path.join(base, "identity/rules")
  File.mkdir_p!(rules_dir)

  File.write!(Path.join(rules_dir, "boot-recovery.toml"), """
  [[rule]]
  name = "observe-boot-recovery"
  verb = "retire"
  edges = ["row-commit"]
  effect = "notice"
  text = "record recovered assignment closure"
  deny_when = [{ fact = "assignment.state", op = "eq", value = "closed" }]

  [rule.notice]
  target_session = "k1"
  prompt = "boot recovery closed {assignment_id}"
  """)

  :persistent_term.erase(RuleRuntime)

  Gateway.children(
    config
    |> Map.put(:wake_tick_ms, 1_234)
  )

  assert {:ok, [["closed", "revoked"]]} =
           DB.query(
             db,
             "SELECT state, outcome FROM assignments WHERE id='asg_boot_retired'"
           )

  assert [wake] =
           db
           |> Wakes.list_pending()
           |> Enum.filter(&(&1.prompt == "boot recovery closed asg_boot_retired"))

  assert wake.session_key == "k1"
end)

IO.puts("guarded-gateway-retired: ok")
