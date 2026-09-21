import ExUnit.Assertions
alias Tightbeam.{DB, Gateway, Model, NoticeBatcher, Org, Roles, Wakes}

Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config} ->
  {Wakes, wake_opts} = Gateway.children(%{config | port: 0}) |> Enum.find(&match?({Wakes, _}, &1))

  recipient =
    Org.create(db, %{
      session_key: "agent:batch-recipient",
      display_name: "agent:batch-recipient",
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: nil,
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

  Roles.create!(db, "batch-recipient", "flynn", recipient.session_key)

  {:ok, _policy} =
    DB.transaction(db, fn txn ->
      Org.apply_notice_batching_lane_policy_in_txn(
        txn,
        %{session_key: recipient.session_key, target_role: "batch-recipient"},
        true,
        "notice-batching-test-policy:role-removal",
        "agent:test-policy",
        "role-removal-regression",
        1
      )
    end)

  source =
    Wakes.schedule(db, %{
      session_key: recipient.session_key,
      target_role: "batch-recipient",
      origin: "process:tightbeam",
      prompt: "batched role delivery",
      due_at: 0,
      class: "fyi"
    })

  [carrier_id] = Wakes.materialize_digests(db, source.due_at)
  [%{batch_id: batch_id}] = NoticeBatcher.source_refs(db, source.wake_id)
  assert :ok = Roles.rm(db, "batch-recipient")
  {:ok, _} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [carrier_id])

  {:ok, scheduler} = Wakes.start_link(Keyword.put(wake_opts, :name, :guard_batch_scheduler))

  try do
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(db, carrier_id).state == "fired"

    assert %{state: "delivery_failed", terminal_cause: ":skipped"} =
             NoticeBatcher.batch(db, batch_id)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [carrier_id])
  after
    GenServer.stop(scheduler)
  end
end)

IO.puts("guarded-gateway-removed-batch: ok")
