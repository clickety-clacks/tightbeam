defmodule Tightbeam.HolderProdTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    ConnRegistry,
    DB,
    Gateway,
    HolderProd,
    Ledger,
    Model,
    NoticeBatcher,
    Org,
    SessionCustodyTransfer,
    StateResources,
    Wakes
  }

  alias Tightbeam.DB.Txn

  @quiet 30 * 60 * 1_000
  @assignment "asg_fixture"

  defmodule LaneStub do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(:ok), do: {:ok, :ok}
    def handle_call({:ensure_lane, _session_key}, _from, state), do: {:reply, :ok, state}
  end

  test "assignment readback follows each attempt in the same episode until eligibility changes",
       ctx do
    start_supervised!({ConnRegistry, name: :holder_prod_test_registry})
    start_supervised!({LaneStub, :holder_prod_test_lane})

    delivery_opts = [
      conn_registry: :holder_prod_test_registry,
      lane_manager: :holder_prod_test_lane
    ]

    at = ctx.opened + @quiet

    assert %{id: @assignment, holderProd: %{episodeId: episode, state: "scheduled"}} =
             assignment_readback(ctx.db)

    for number <- 0..2 do
      due = at + number * @quiet
      sweep(ctx.db, due)

      assert %{
               id: @assignment,
               holderProd: %{
                 holderSessionKey: "holder",
                 episodeId: ^episode,
                 wakeId: current_wake,
                 repeatNumber: ^number,
                 state: "pending"
               }
             } = assignment_readback(ctx.db)

      assert [carrier] = NoticeBatcher.recover(ctx.db, due, delivery_opts, "holder")
      assert carrier != current_wake
      finish_prod(ctx.db, current_wake)

      assert %{
               holderProd: %{
                 episodeId: ^episode,
                 wakeId: ^current_wake,
                 repeatNumber: ^number,
                 state: "delivered"
               }
             } = assignment_readback(ctx.db)

      assert length(Enum.uniq_by(notices(ctx.db), &hd/1)) == number + 1
    end

    assert %{wake_id: _} =
             gateway_wake(ctx.db, "holder", %{
               assignment_id: @assignment,
               condition_kind: "fixture-ready",
               condition_scope: @assignment,
               after_ms: 12 * @quiet,
               wait_reason: "Waiting for fixture readiness"
             })

    refute Map.has_key?(assignment_readback(ctx.db), :holderProd)
  end

  for mixed <- [false, true] do
    test "staggered assignments #{if mixed, do: "respect mixed batches", else: "ignore prod-only turns"}",
         ctx do
      later_id = "asg_later"
      later_opened = ctx.opened - 60_000
      first_opened = later_opened - 60_000
      sql!(ctx.db, "UPDATE assignments SET openedAt=?2 WHERE id=?1", [@assignment, first_opened])

      sql!(
        ctx.db,
        """
        INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state)
        VALUES (?1,'second fixture assignment','holder','other',?2,'open')
        """,
        [later_id, later_opened]
      )

      sweep(ctx.db, first_opened + @quiet)
      assert [[first_wake, "holder", "pending"]] = notices(ctx.db)
      sweep(ctx.db, later_opened + @quiet)
      assert [[^first_wake, "holder", "pending"]] = notices(ctx.db)

      if unquote(mixed) do
        Wakes.schedule(ctx.db, %{
          session_key: "holder",
          creator_session_key: "other",
          origin: "session:other",
          due_at: System.system_time(:millisecond),
          prompt: "ordinary assignment context",
          class: "fyi"
        })
      end

      start_supervised!({ConnRegistry, name: :holder_prod_test_registry})
      start_supervised!({LaneStub, :holder_prod_test_lane})
      scheduler = start_scheduler(ctx.db, false)
      assert :ok = Wakes.fire_due(scheduler)

      assert %{fired_at: first_sent} = Wakes.get(ctx.db, first_wake)
      sweep(ctx.db, first_sent)
      assert [[^first_wake, "holder", "fired"]] = notices(ctx.db)

      finished = finish_prod(ctx.db, first_wake)

      if unquote(mixed) do
        assert %{quietSince: ^finished, wakeId: nil} =
                 HolderProd.evidence(ctx.db, later_id, "holder")

        sweep(ctx.db, finished + @quiet - 1)
        assert [[^first_wake, "holder", "fired"]] = notices(ctx.db)
      else
        assert %{quietSince: ^later_opened, wakeId: nil} =
                 HolderProd.evidence(ctx.db, later_id, "holder")

        sweep(ctx.db, finished)

        assert [[^first_wake, "holder", "fired"], [second_wake, "holder", "pending"]] =
                 notices(ctx.db)

        assert :ok = Wakes.fire_due(scheduler)
        finish_prod(ctx.db, second_wake)
        sweep(ctx.db, first_sent + @quiet - 1)

        assert [[^first_wake, "holder", "fired"], [^second_wake, "holder", "fired"]] =
                 notices(ctx.db)

        assert %{quietSince: ^first_opened, episodeId: first_episode, repeatNumber: 0} =
                 HolderProd.evidence(ctx.db, @assignment, "holder")

        assert %{quietSince: ^later_opened, repeatNumber: 0} =
                 HolderProd.evidence(ctx.db, later_id, "holder")

        sweep(ctx.db, first_sent + @quiet)

        assert %{quietSince: ^first_opened, episodeId: ^first_episode, repeatNumber: 1} =
                 HolderProd.evidence(ctx.db, @assignment, "holder")
      end
    end
  end

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = ensure_all_schemas(db)
    sql!(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('fixture-owner',0,1)")

    for key <- ["holder", "other", "successor"] do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "fixture-owner",
        origin: "user:fixture-owner",
        archetype: "default",
        harness: "codex",
        provider: "openai",
        model: Model.new("fixture"),
        host: "test-host"
      })
    end

    opened = System.system_time(:millisecond) - @quiet

    sql!(
      db,
      """
      INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state)
      VALUES (?1,'fixture work','holder','other',?2,'open')
      """,
      [@assignment, opened]
    )

    %{db: db, opened: opened}
  end

  test "only one source is admitted at the threshold and its evidence is assignment-scoped",
       ctx do
    threshold = ctx.opened + @quiet
    assert deadline(ctx.db) == threshold
    sweep(ctx.db, threshold - 1)
    assert notices(ctx.db) == []

    sweep(ctx.db, threshold)
    sweep(ctx.db, threshold + @quiet)
    assert [[wake_id, "holder", "pending"]] = notices(ctx.db)
    assert deadline(ctx.db) == nil

    result =
      Assignments.__handle__(ctx.db, "assignment-get", %{
        principal: {:user, "fixture-owner"},
        params: %{assignment_id: @assignment}
      })

    assert %{
             id: @assignment,
             holderProd: %{
               holderSessionKey: "holder",
               quietSince: since,
               episodeId: episode,
               wakeId: ^wake_id,
               state: "pending"
             }
           } = result

    assert since == ctx.opened
    assert is_binary(episode)
    assert Wakes.get(ctx.db, wake_id).prompt =~ "fact, predicate, or timed fallback"

    start_supervised!({ConnRegistry, name: :holder_prod_test_registry})
    start_supervised!({LaneStub, :holder_prod_test_lane})
    scheduler = start_scheduler(ctx.db)
    assert :ok = Wakes.fire_due(scheduler)
    assert %{state: "fired", delivered_turn_seq: seq, fired_at: sent} = Wakes.get(ctx.db, wake_id)

    assert %{wakeId: ^wake_id, state: "delivered"} =
             HolderProd.evidence(ctx.db, @assignment, "holder")

    assert {:ok, %{seq: ^seq} = turn} = Ledger.claim_next(ctx.db, "holder", "fixture")
    assert :ok = Ledger.finish(ctx.db, seq, "delivered", nil, owner_lease: turn.owner_lease)
    sweep(ctx.db, sent + @quiet - 1)
    stop_supervised!(Wakes)
    assert :ok = ctx.db |> start_scheduler() |> Wakes.fire_due()
    assert length(notices(ctx.db)) == 1

    record_wait(ctx.db, "holder", "holder", threshold + @quiet, :fact)
    refute HolderProd.evidence(ctx.db, @assignment, "holder")
    assert %{state: "fired", delivered_turn_seq: ^seq} = Wakes.get(ctx.db, wake_id)
  end

  test "an item-only wait does not quiet the same session's assignment prods", ctx do
    handlers = Gateway.handlers(%{db: ctx.db})

    item =
      handlers["work-item-create"].(%{
        verb: "work-item-create",
        principal: {:session, "holder"},
        origin: "session:holder",
        params: %{title: "Separate item waiting on an event"}
      })

    handlers["work-item-update"].(%{
      verb: "work-item-update",
      principal: {:session, "holder"},
      origin: "session:holder",
      params: %{work_item_id: item.id, delivery_owner_session_key: "holder"}
    })

    assert %{wait: %{active: true}} =
             handlers["work-item-wait"].(%{
               verb: "work-item-wait",
               principal: {:session, "holder"},
               origin: "session:holder",
               params: %{
                 work_item_id: item.id,
                 condition_kind: "upstream-ready",
                 condition_scope: "dependency",
                 after_ms: 12 * @quiet,
                 wait_reason: "Waiting on a different item"
               }
             })

    assert deadline(ctx.db) == ctx.opened + @quiet
    sweep(ctx.db, ctx.opened + @quiet)
    assert [[_, "holder", "pending"]] = notices(ctx.db)
  end

  for wait <- [:timed, :fact, :predicate, :after_turn] do
    test "a holder's own #{wait} wait suppresses the prod", ctx do
      at = ctx.opened + @quiet
      record_wait(ctx.db, "holder", "holder", at + @quiet, unquote(wait))

      assert deadline(ctx.db) == nil
      sweep(ctx.db, at)
      assert notices(ctx.db) == []
      refute HolderProd.evidence(ctx.db, @assignment, "holder")
    end

    test "another session's #{wait} wait does not cover the assignment", ctx do
      at = ctx.opened + @quiet
      record_wait(ctx.db, "other", "other", at + @quiet, unquote(wait))
      record_wait(ctx.db, "other", "holder", at + @quiet, unquote(wait))

      assert deadline(ctx.db) == at
      sweep(ctx.db, at)
      assert [[_, "holder", "pending"]] = notices(ctx.db)
    end
  end

  test "new fact and timed waits require a reason and read it back after scheduling", ctx do
    for trigger <- [
          %{condition_kind: "fixture-ready", after_ms: @quiet},
          %{after_ms: @quiet, assignment_id: @assignment}
        ] do
      for {reason, code} <- [
            {nil, "missing_reason"},
            {"  ", "missing_reason"},
            {"first\nsecond", "invalid_wait_reason"},
            {String.duplicate("a", 141), "wait_reason_too_long"}
          ] do
        params = if is_nil(reason), do: trigger, else: Map.put(trigger, :wait_reason, reason)
        assert %{code: ^code} = gateway_wake(ctx.db, "holder", params)
      end

      reason = String.duplicate("é", 140)

      assert %{wake_id: wake_id, wait_reason: ^reason} =
               gateway_wake(ctx.db, "holder", Map.put(trigger, :wait_reason, reason))

      assert Wakes.get(ctx.db, wake_id).wait_reason == reason

      assert StateResources.wake(StateResources.query_wake(ctx.db, wake_id))["waitReason"] ==
               reason
    end
  end

  test "ordinary notices need no reason and a historical reasonless wait still suppresses", ctx do
    assert %{wake_id: notice_id} = gateway_wake(ctx.db, "other", %{after_ms: @quiet})

    refute Map.has_key?(
             StateResources.wake(StateResources.query_wake(ctx.db, notice_id)),
             "waitReason"
           )

    record_wait(ctx.db, "holder", "holder", ctx.opened + 2 * @quiet, :fact)

    assert [[nil]] =
             sql!(ctx.db, """
             SELECT r.reason FROM wakes w LEFT JOIN wake_wait_reasons r ON r.wakeId=w.wakeId
             WHERE w.conditionKind='assignment-landed'
             """)

    sweep(ctx.db, ctx.opened + @quiet)
    assert notices(ctx.db) == []

    reason = "Waiting for the external deadline"

    assert %{wake_id: _, wait_reason: ^reason} =
             gateway_wake(ctx.db, "holder", %{after_ms: @quiet, wait_reason: reason})
  end

  test "a wait attestation keeps its short note as the reason and covers its holder", ctx do
    attest = fn note ->
      Assignments.__handle__(ctx.db, "attest", %{
        verb: "attest",
        origin: "session:holder",
        principal: {:session, "holder"},
        params: %{assignment_id: @assignment, kind: "cannot-proceed", note: note}
      })
    end

    assert %{code: "missing_reason"} = attest.(nil)
    assert %{code: "missing_reason"} = attest.("  ")
    assert %{code: "wait_reason_too_long"} = attest.(String.duplicate("a", 141))
    assert %{code: "invalid_wait_reason"} = attest.("first\nsecond")
    reason = String.duplicate("a", 140)

    assert %{cannotProceed: %{reason: ^reason}, decisionWake: %{wake_id: decision_wake}} =
             attest.(reason)

    assert %{replayed: true, cannotProceed: %{decisionWakeId: ^decision_wake}} = attest.(reason)
    assert %{session_key: "other", state: "pending"} = Wakes.get(ctx.db, decision_wake)

    start_supervised!({ConnRegistry, name: :holder_prod_test_registry})
    start_supervised!({LaneStub, :holder_prod_test_lane})
    assert :ok = ctx.db |> start_scheduler(false) |> Wakes.fire_due()

    assert %{session_key: "other", state: "fired", delivered_turn_seq: seq} =
             Wakes.get(ctx.db, decision_wake)

    assert is_integer(seq)

    sweep(ctx.db, ctx.opened + 2 * @quiet)
    assert notices(ctx.db) == []
    IO.puts("Holder nudge cannot-proceed proof opener_deliveries=1 follow_up_nudges=0")
  end

  test "an admitted nudge is superseded if its harness becomes fenced before delivery", ctx do
    at = ctx.opened + @quiet
    sweep(ctx.db, at)
    assert [[wake_id, "holder", "pending"]] = notices(ctx.db)

    sql!(
      ctx.db,
      """
      INSERT INTO harness_park_fences(adapterKey,requestedAt,generation)
      VALUES ('codex:shared@test-host',?1,1)
      """,
      [at]
    )

    start_supervised!({ConnRegistry, name: :holder_prod_test_registry})
    start_supervised!({LaneStub, :holder_prod_test_lane})
    scheduler = start_scheduler(ctx.db, false)
    assert :ok = Wakes.fire_due(scheduler)
    assert [[^wake_id, "holder", "canceled"]] = notices(ctx.db)
    assert %{delivered_turn_seq: nil} = Wakes.get(ctx.db, wake_id)
    assert deadline(ctx.db) == nil

    assert :ok = Tightbeam.HarnessProcess.complete_park(ctx.db, {"codex", "shared", "test-host"})
    assert deadline(ctx.db) == at

    assert %{holderProd: %{wakeId: ^wake_id, repeatNumber: 0, state: "canceled"}} =
             assignment_readback(ctx.db)

    sweep(ctx.db, at)

    assert [[^wake_id, "holder", "canceled"], [new_wake, "holder", "pending"]] = notices(ctx.db)

    assert %{wakeId: ^new_wake, repeatNumber: 0} =
             HolderProd.evidence(ctx.db, @assignment, "holder")
  end

  test "report-only durably meters would-send events without leaving a wake", ctx do
    settings = %{cap: 1, report_only: true}
    at = ctx.opened + @quiet

    for {due, count} <- [{at, 1}, {at + @quiet, 0}, {at + 2 * @quiet, 1}] do
      assert {:ok, {:would_send, ^count}} =
               DB.transaction(ctx.db, &HolderProd.admit_due_in_txn(&1, due, 100, settings))
    end

    assert [] = notices(ctx.db)
    assert %{wakeId: nil, state: "scheduled"} = HolderProd.evidence(ctx.db, @assignment, "holder")

    assert [[first], [second]] =
             sql!(
               ctx.db,
               """
               SELECT detail FROM lifecycle_events
               WHERE kind='holder_prod_would_send' AND subject=?1 ORDER BY id
               """,
               [@assignment]
             )

    assert %{"repeatNumber" => 0, "episodeId" => episode, "at" => ^at} = JSON.decode!(first)
    assert %{"repeatNumber" => 1, "episodeId" => ^episode} = JSON.decode!(second)
  end

  defp gateway_wake(db, target, params) do
    Gateway.handlers(%{db: db})["wake"].(%{
      verb: "wake",
      origin: "session:holder",
      principal: {:session, "holder"},
      session_key: target,
      params: Map.put(params, :prompt, "Fixture follow-through")
    })
  end

  test "a linked queued turn and an unrelated running turn cover the holder", ctx do
    at = ctx.opened + @quiet

    sql!(
      ctx.db,
      """
      INSERT INTO turns(sessionKey,messageId,origin,prompt,assignmentId,status,createdAt,startedAt)
      VALUES ('holder','queued','user:fixture-owner','queued',?1,'queued',?2,NULL),
             ('holder','running','user:fixture-owner','running',NULL,'running',?2,?2)
      """,
      [@assignment, at]
    )

    sweep(ctx.db, at)
    assert notices(ctx.db) == []

    for message <- ["queued", "running"] do
      sql!(ctx.db, "UPDATE turns SET status='delivered',endedAt=?2 WHERE messageId=?1", [
        message,
        at + 1
      ])
    end

    sweep(ctx.db, at + @quiet)
    assert notices(ctx.db) == []
    sweep(ctx.db, at + @quiet + 1)
    assert [[_, "holder", "pending"]] = notices(ctx.db)
  end

  test "custody transfer disarms the old pending source and starts a fresh interval", ctx do
    sweep(ctx.db, ctx.opened + @quiet)
    assert [[previous, "holder", "pending"]] = notices(ctx.db)

    assert %{"appliedAt" => transferred} =
             SessionCustodyTransfer.handle(ctx.db, %{
               principal: {:user, "fixture-owner"},
               params: %{
                 from_session_key: "holder",
                 to_session_key: "successor",
                 idempotency_key: "fixture-transfer"
               }
             })

    assert %{state: "canceled"} = Wakes.get(ctx.db, previous)
    refute HolderProd.evidence(ctx.db, @assignment, "holder")

    assert %{holderSessionKey: "successor", quietSince: ^transferred, wakeId: nil} =
             HolderProd.evidence(ctx.db, @assignment, "successor")

    assert %{
             holderProd: %{holderSessionKey: "successor", wakeId: nil, repeatNumber: nil}
           } = assignment_readback(ctx.db)

    sweep(ctx.db, transferred + @quiet - 1)
    assert [[^previous, "holder", "canceled"]] = notices(ctx.db)
    sweep(ctx.db, transferred + @quiet)
    assert [[^previous, "holder", "canceled"], [_, "successor", "pending"]] = notices(ctx.db)
  end

  defp assignment_readback(db) do
    Assignments.__handle__(db, "assignment-get", %{
      principal: {:user, "fixture-owner"},
      params: %{assignment_id: @assignment}
    })
  end

  defp notices(db) do
    sql!(db, """
    SELECT wakeId,sessionKey,state FROM wakes
    WHERE obligationRef LIKE 'assignment-holder-prod-v1:%' ORDER BY rowid
    """)
  end

  defp finish_prod(db, wake_id) do
    assert %{state: "fired", delivered_turn_seq: seq} = Wakes.get(db, wake_id)
    assert {:ok, %{seq: ^seq} = turn} = Ledger.claim_next(db, "holder", "fixture")
    assert :ok = Ledger.finish(db, seq, "delivered", nil, owner_lease: turn.owner_lease)
    assert [[ended]] = sql!(db, "SELECT endedAt FROM turns WHERE seq=?1", [seq])
    ended
  end

  defp start_scheduler(db, enabled \\ true) do
    start_supervised!(
      {Wakes,
       db: db,
       name: nil,
       holder_prod: enabled,
       deliver: fn _ -> :ok end,
       delivery_opts: [
         conn_registry: :holder_prod_test_registry,
         lane_manager: :holder_prod_test_lane
       ]}
    )
  end

  defp deadline(db) do
    {:ok, deadline} =
      DB.transaction(db, &HolderProd.next_deadline_in_txn(&1, System.system_time(:millisecond)))

    deadline
  end

  defp sweep(db, at) do
    assert {:ok, :ok} = DB.transaction(db, &HolderProd.admit_due_in_txn(&1, at))
  end

  defp record_wait(db, creator, recipient, due_at, wait) do
    options =
      case wait do
        :timed -> %{}
        :fact -> %{condition_kind: "assignment-landed", condition_scope: @assignment}
        :predicate -> %{wait_mode: "dependency", predicate: %{"conditions" => []}}
        :after_turn -> %{wait_mode: "after-turn", originating_turn_seq: 1}
      end

    assert {:ok, _wake} =
             DB.transaction(db, fn %Txn{} = txn ->
               Wakes.schedule_in_txn(
                 txn,
                 Map.merge(options, %{
                   origin: "session:" <> creator,
                   creator_session_key: creator,
                   session_key: recipient,
                   assignment_id: @assignment,
                   due_at: due_at,
                   prompt: "fixture wait"
                 })
               )
             end)
  end

  defp sql!(db, query, bindings \\ []) do
    {:ok, rows} = DB.query(db, query, bindings)
    rows
  end
end
