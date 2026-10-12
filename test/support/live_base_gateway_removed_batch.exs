import ExUnit.Assertions
alias Tightbeam.{DB, EventLog, Gateway, Ledger, Model, NoticeBatcher, Org, Roles, Wakes}

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

  assert {:ok, seq} =
           Ledger.enqueue(db, %{
             session_key: recipient.session_key,
             message_id: "role-removal-busy",
             origin: "user:flynn",
             prompt: "already running"
           })

  assert {:ok, %{seq: ^seq, owner_lease: lease}} =
           Ledger.claim_next(db, recipient.session_key, "test")

  source =
    Wakes.schedule(db, %{
      session_key: recipient.session_key,
      target_role: "batch-recipient",
      origin: "process:tightbeam",
      prompt: "batched role delivery",
      due_at: 0,
      class: "fyi"
    })

  # Sources stay editable while busy. Role removal precedes actual admission,
  # rather than invalidating a delivery that already committed.
  assert [] = NoticeBatcher.recover(db, source.due_at)
  assert [] = NoticeBatcher.source_refs(db, source.wake_id)
  assert Wakes.get(db, source.wake_id).state == "pending"
  assert :ok = Roles.rm(db, "batch-recipient")
  assert :ok = Ledger.finish(db, seq, "delivered", nil, owner_lease: lease)
  {:ok, scheduler} = Wakes.start_link(Keyword.put(wake_opts, :name, :guard_batch_scheduler))

  try do
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(db, source.wake_id).state == "fired"
    assert Wakes.get(db, source.wake_id).prompt == "batched role delivery"
    assert :ok = Wakes.fire_due(scheduler)
    assert [] = NoticeBatcher.source_refs(db, source.wake_id)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [source.wake_id])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM turns WHERE sessionKey=?1", [
               recipient.session_key
             ])

    assert Enum.any?(EventLog.lifecycle_events(db), fn event ->
             event.kind == "wake_unresolved" and event.subject == source.wake_id and
               event.detail == "role batch-recipient no longer exists"
           end)
  after
    GenServer.stop(scheduler)
  end
end)

IO.puts("guarded-gateway-removed-batch: ok")
