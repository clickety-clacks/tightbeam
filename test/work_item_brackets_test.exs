defmodule Tightbeam.WorkItemBracketsTest do
  @moduledoc """
  The work-item-brackets-v1 required proofs (fail-on-revert). Each test names
  the proof number it discharges; see the spec §Required proofs.
  """
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Assignments,
    ConnRegistry,
    DB,
    Dispatch,
    Gateway,
    Org,
    Projection,
    RailRemedy,
    Rules,
    Wakes,
    WorkItems,
    WorkState
  }

  alias Tightbeam.DB.Txn

  # Records the doorbells one subscriber actually received, drained by a call.
  #
  # The drain is what makes the assertions timing-free. `ConnRegistry` delivers
  # with a bare `send` from inside its own `handle_call`, so a doorbell is in
  # this process's mailbox before the publishing verb returns to the test; the
  # `drain/1` call the test issues next is therefore enqueued behind it, and a
  # GenServer serves its mailbox in order. Whatever was published has been
  # recorded by the time `drain/1` answers.
  #
  # This replaced a `spawn`ed process that forwarded each push onward to the
  # test. That hop was unsynchronized: a verb returning proved only that the
  # doorbell had reached the relay, never that the relay had been scheduled to
  # pass it on, so every `refute_receive` across it could pass on a loaded
  # machine simply because the relay had not run yet — a false PASS on the
  # assertions that exist to catch a doorbell being emitted when it must not be.
  defmodule Observer do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, [])

    @doc "Every payload received since the last drain, oldest first."
    def drain(observer), do: GenServer.call(observer, :drain)

    @impl true
    def init(received), do: {:ok, received}

    @impl true
    def handle_call(:drain, _from, received), do: {:reply, Enum.reverse(received), []}

    @impl true
    def handle_info({:push, payload}, received), do: {:noreply, [payload | received]}
  end

  setup do
    db = :"brackets_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: ConnRegistry})

    :ok = Tightbeam.Schema.ensure_all(db)

    register_hosts(db, %{
      "eezo" => %{
        ssh: nil,
        base_dir: Application.fetch_env!(:tightbeam, :base_dir),
        cli_bin: nil
      }
    })

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('flynn', 1, 'admin_add', 1), ('dana', 0, 'admin_add', 1), ('eve', 0, 'admin_add', 1)"
      )

    # Owners are always users; bracket wakes target the owner's personal session.
    flynn_main = session(db, Org.personal_session_key("flynn"), "flynn")
    _dana_main = session(db, Org.personal_session_key("dana"), "dana")
    holder = session(db, "holder", "flynn")
    dsession = session(db, "dsession", "dana")

    base = Path.join(System.tmp_dir!(), "tb-brackets-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
    Rules.load!(base, Map.keys(handlers))
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      db: db,
      handlers: handlers,
      flynn_main: flynn_main,
      holder: holder,
      dsession: dsession
    }
  end

  ## Proof 1 — create arms bracket 1; keyed replay returns the original, arms nothing.

  test "Proof 1: create (keyed and keyless) arms bracket 1; keyed replay is inert", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Route me"})
    assert item.state == "open"
    assert item.ownerUserId == "flynn"

    routing = routing_wake_id(ctx.db, item.id)
    assert is_binary(routing)
    wake = Wakes.get(ctx.db, routing)
    assert wake.consumer == "prompt"
    assert wake.session_key == Org.personal_session_key("flynn")
    assert wake.work_item_id == item.id
    assert wake.prompt =~ "route it or icebox it"
    assert item_wake_count(ctx.db, item.id) == 1

    keyed = create(ctx, {:user, "flynn"}, %{title: "Keyed", idempotency_key: "kc"})
    original_routing = routing_wake_id(ctx.db, keyed.id)
    assert is_binary(original_routing)

    replay = create(ctx, {:user, "flynn"}, %{title: "Different title", idempotency_key: "kc"})
    assert replay.id == keyed.id
    # Replay arms NOTHING new: same routing wake, still exactly one pending wake.
    assert routing_wake_id(ctx.db, keyed.id) == original_routing
    assert item_wake_count(ctx.db, keyed.id) == 1
    assert work_item_count(ctx.db) == 2
  end

  ## Proof 2 — first assign AND first dispatch cancel bracket 1; both persist workItemId.

  test "Proof 2: first assign and first dispatch each cancel bracket 1 and persist workItemId",
       ctx do
    a_item = create(ctx, {:user, "flynn"}, %{title: "Assign path"})
    a_routing = routing_wake_id(ctx.db, a_item.id)
    {:ok, assignment} = disp_assign(ctx, {:user, "flynn"}, "holder", "work", a_item.id)
    assert assignment.workItemId == a_item.id
    assert routing_wake_id(ctx.db, a_item.id) == nil
    assert Wakes.get(ctx.db, a_routing).state == "canceled"

    assert [
             "tightbeam:work-items",
             "routing_bracket_satisfied",
             "assignment_transition",
             source_assignment_id,
             "disposition",
             "assignment_transition",
             disposition_assignment_id,
             "work_item",
             assignment_work_item,
             "linked_work_open",
             "supervision_entitlement",
             entitlement_id,
             1
           ] = cancellation(ctx.db, a_routing)

    assert source_assignment_id == assignment.id
    assert disposition_assignment_id == assignment.id
    assert assignment_work_item == a_item.id
    assert entitlement_id == "#{assignment.id}#1"

    d_item = create(ctx, {:user, "flynn"}, %{title: "Dispatch path"})
    d_routing = routing_wake_id(ctx.db, d_item.id)
    {:ok, dispatched} = disp_dispatch(ctx, {:user, "flynn"}, "holder", "work", d_item.id)
    assert dispatched.workItemId == d_item.id
    assert routing_wake_id(ctx.db, d_item.id) == nil
    assert Wakes.get(ctx.db, d_routing).state == "canceled"
    assert Enum.at(cancellation(ctx.db, d_routing), 0) == "tightbeam:work-items"
  end

  test "typed bracket refusal rolls back the caller transaction", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Refused bracket"})
    routing = routing_wake_id(ctx.db, item.id)

    assert {:error, %WorkItems.CancellationRefused{wake_id: ^routing}} =
             DB.transaction(ctx.db, fn txn ->
               WorkItems.cancel_brackets_in_txn(txn, item.id, %{
                 causal_source: %{kind: "session_transition", id: "missing-session"},
                 outcome: %{kind: "no_replacement"}
               })
             end)

    assert routing_wake_id(ctx.db, item.id) == routing
    assert Wakes.get(ctx.db, routing).state == "pending"

    assert {:ok, []} =
             DB.query(ctx.db, "SELECT wakeId FROM wake_cancellations WHERE wakeId=?1", [routing])
  end

  test "linked assign and dispatch roll back the complete accepted bundle", ctx do
    for {verb, dispatch_fun} <- [
          {"assign", &disp_assign(&1, {:user, "flynn"}, "holder", &2, &3)},
          {"dispatch", &disp_dispatch(&1, {:user, "flynn"}, "holder", &2, &3)}
        ] do
      subject = "forced #{verb} rollback"
      item = create(ctx, {:user, "flynn"}, %{title: subject})
      routing = routing_wake_id(ctx.db, item.id)

      :ok =
        DB.execute(
          ctx.db,
          """
          CREATE TRIGGER force_#{verb}_bracket_rollback
          BEFORE UPDATE OF state ON wakes
          WHEN OLD.wakeId='#{routing}' AND NEW.state='canceled'
          BEGIN
            SELECT RAISE(ABORT, 'forced #{verb} bracket rollback');
          END;
          """
        )

      assert {:error, %{code: "server_error", message: message}} =
               dispatch_fun.(ctx, subject, item.id)

      assert message =~ "forced #{verb} bracket rollback"
      assert routing_wake_id(ctx.db, item.id) == routing
      assert Wakes.get(ctx.db, routing).state == "pending"

      assert {:ok, [[0, 0, 0, 0, 0, 0]]} =
               DB.query(
                 ctx.db,
                 """
                 SELECT
                   (SELECT count(*) FROM assignments WHERE subject=?1),
                   (SELECT count(*) FROM supervision_entitlements e
                      JOIN assignments a ON a.id=e.assignmentId WHERE a.subject=?1),
                   (SELECT count(*) FROM effort_checkin_generations g
                      JOIN assignments a ON a.id=g.assignmentId WHERE a.subject=?1),
                   (SELECT count(*) FROM wake_cancellations WHERE wakeId=?2),
                   (SELECT count(*) FROM events
                      WHERE verb=?3 AND payload LIKE '%' || ?1 || '%'),
                   (SELECT count(*) FROM turns WHERE prompt LIKE '%' || ?1 || '%')
                 """,
                 [subject, routing, verb]
               )
    end
  end

  test "linked assign and dispatch roll back the complete bundle when event append fails", ctx do
    for {verb, dispatch_fun} <- [
          {"assign", &disp_assign(&1, {:user, "flynn"}, "holder", &2, &3)},
          {"dispatch", &disp_dispatch(&1, {:user, "flynn"}, "holder", &2, &3)}
        ] do
      subject = "forced #{verb} event rollback"
      item = create(ctx, {:user, "flynn"}, %{title: subject})
      routing = routing_wake_id(ctx.db, item.id)

      :ok =
        DB.execute(
          ctx.db,
          """
          CREATE TRIGGER force_#{verb}_event_rollback
          BEFORE INSERT ON events
          WHEN NEW.verb='#{verb}' AND NEW.payload LIKE '%#{subject}%'
          BEGIN
            SELECT RAISE(ABORT, 'forced #{verb} event rollback');
          END;
          """
        )

      error =
        assert_raise MatchError, fn ->
          dispatch_fun.(ctx, subject, item.id)
        end

      assert {:error, %DB.Error{message: message}} = error.term
      assert message =~ "forced #{verb} event rollback"
      assert routing_wake_id(ctx.db, item.id) == routing
      assert Wakes.get(ctx.db, routing).state == "pending"

      assert {:ok, [[0, 0, 0, 0, 0, 0]]} =
               DB.query(
                 ctx.db,
                 """
                 SELECT
                   (SELECT count(*) FROM assignments WHERE subject=?1),
                   (SELECT count(*) FROM supervision_entitlements e
                      JOIN assignments a ON a.id=e.assignmentId WHERE a.subject=?1),
                   (SELECT count(*) FROM effort_checkin_generations g
                      JOIN assignments a ON a.id=g.assignmentId WHERE a.subject=?1),
                   (SELECT count(*) FROM wake_cancellations WHERE wakeId=?2),
                   (SELECT count(*) FROM events
                      WHERE verb=?3 AND payload LIKE '%' || ?1 || '%'),
                   (SELECT count(*) FROM turns WHERE prompt LIKE '%' || ?1 || '%')
                 """,
                 [subject, routing, verb]
               )
    end
  end

  ## Proof 3 — bracket-1 fire re-arms; icebox cancels and stops the nag.

  test "Proof 3: an ignored bracket-1 wake re-arms on fire; icebox stops the nag", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Nagged"})
    old = routing_wake_id(ctx.db, item.id)

    deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, old))

    assert Wakes.get(ctx.db, old).state == "fired"
    new = routing_wake_id(ctx.db, item.id)
    assert new != old
    assert Wakes.get(ctx.db, new).state == "pending"

    # One nag turn was delivered to the owner's personal session.
    assert Enum.any?(
             Projection.list_after(ctx.db, Org.personal_session_key("flynn"), nil, 10),
             &(&1.content =~ "route it or icebox it")
           )

    assert %{ok: true, workItem: %{state: "iceboxed"}} =
             dispose(ctx, "work-item-icebox", {:user, "flynn"}, item.id)

    assert routing_wake_id(ctx.db, item.id) == nil
    assert Wakes.get(ctx.db, new).state == "canceled"

    assert [
             "tightbeam:work-items",
             "routing_bracket_satisfied",
             "work_item_transition",
             _source_id,
             "disposition",
             "work_item_transition",
             _disposition_id,
             "work_item",
             item_id,
             "linked_work_not_open",
             nil,
             nil,
             0
           ] = cancellation(ctx.db, new)

    assert item_id == item.id
  end

  ## Proof 4 — last-close of a non-terminal item arms the slate wake in the close txn
  ## (all four close paths); next assign cancels it; re-arms on the next last-close.

  test "Proof 4: every close path arms bracket 2 durably; next assign cancels; re-arms", ctx do
    # Completion path + the full assign/cancel/re-arm cycle.
    item = create(ctx, {:user, "flynn"}, %{title: "Slate"})
    {:ok, a} = disp_assign(ctx, {:user, "flynn"}, "holder", "w", item.id)
    complete(ctx, "holder", a.id)

    slate = slate_wake_id(ctx.db, item.id)
    assert is_binary(slate)
    wake = Wakes.get(ctx.db, slate)
    # Durable row (survives a crash between commit and any delivery — no callback).
    assert wake.state == "pending"
    assert wake.session_key == Org.personal_session_key("flynn")
    assert wake.prompt =~ "slate clear"

    {:ok, a2} = disp_assign(ctx, {:user, "flynn"}, "holder", "w2", item.id)
    assert a2.workItemId == item.id
    assert slate_wake_id(ctx.db, item.id) == nil
    assert Wakes.get(ctx.db, slate).state == "canceled"

    complete(ctx, "holder", a2.id)
    slate2 = slate_wake_id(ctx.db, item.id)
    assert is_binary(slate2)
    assert slate2 != slate

    # Surrender path.
    surrender_item = create(ctx, {:user, "flynn"}, %{title: "Surrendered"})
    {:ok, sa} = disp_assign(ctx, {:user, "flynn"}, "holder", "sw", surrender_item.id)
    surrender(ctx, "holder", sa.id)
    assert is_binary(slate_wake_id(ctx.db, surrender_item.id))

    # Revoke path.
    revoke_item = create(ctx, {:user, "flynn"}, %{title: "Revoked"})
    {:ok, ra} = disp_assign(ctx, {:user, "flynn"}, "holder", "rw", revoke_item.id)
    revoke(ctx, ra.id)
    assert is_binary(slate_wake_id(ctx.db, revoke_item.id))

    # Retire-strand path (interrupt_for_retire closes the strand's open assignments).
    strand_holder = session(ctx.db, "strand-holder", "flynn")
    retire_item = create(ctx, {:user, "flynn"}, %{title: "Stranded"})
    {:ok, _ta} = disp_assign(ctx, {:user, "flynn"}, "strand-holder", "tw", retire_item.id)

    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        Assignments.interrupt_for_retire_in_txn(
          txn,
          strand_holder.session_key,
          "flynn",
          "user:flynn"
        )
      end)

    assert is_binary(slate_wake_id(ctx.db, retire_item.id))
  end

  ## Proof 5 — terminal dispositions transition, cancel both brackets, refuse work, no-op, reopen.

  test "Proof 5: dispositions transition, cancel both brackets, refuse work, no-op, reopen",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Disposed"})
    {:ok, a} = disp_assign(ctx, {:user, "flynn"}, "holder", "w", item.id)
    complete(ctx, "holder", a.id)
    slate = slate_wake_id(ctx.db, item.id)
    assert is_binary(slate)

    assert %{ok: true, workItem: %{state: "iceboxed"}} =
             dispose(ctx, "work-item-icebox", {:user, "flynn"}, item.id)

    # Cancels BOTH brackets (slate wake canceled, both ids cleared).
    assert Wakes.get(ctx.db, slate).state == "canceled"
    assert routing_wake_id(ctx.db, item.id) == nil
    assert slate_wake_id(ctx.db, item.id) == nil

    # Refuses assign/dispatch afterward (terminal guard).
    assert {:error, %{code: "work_item_not_open"}} =
             disp_assign(ctx, {:user, "flynn"}, "holder", "again", item.id)

    # Same-state disposition is a no-op success.
    assert %{ok: true, workItem: %{state: "iceboxed"}} =
             dispose(ctx, "work-item-icebox", {:user, "flynn"}, item.id)

    # Reopen re-arms bracket 1.
    assert %{ok: true, workItem: %{state: "open"}} =
             dispose(ctx, "work-item-reopen", {:user, "flynn"}, item.id)

    reopened_routing = routing_wake_id(ctx.db, item.id)
    assert is_binary(reopened_routing)
    assert Wakes.get(ctx.db, reopened_routing).state == "pending"

    # close and fail transition and refuse too.
    close_item = create(ctx, {:user, "flynn"}, %{title: "Closeable"})

    assert %{ok: true, workItem: %{state: "closed"}} =
             dispose(ctx, "work-item-close", {:user, "flynn"}, close_item.id)

    assert {:error, %{code: "work_item_not_open"}} =
             disp_assign(ctx, {:user, "flynn"}, "holder", "x", close_item.id)

    fail_item = create(ctx, {:user, "flynn"}, %{title: "Failable"})

    assert %{ok: true, workItem: %{state: "failed"}} =
             dispose(ctx, "work-item-fail", {:user, "flynn"}, fail_item.id)

    assert {:error, %{code: "work_item_not_open"}} =
             disp_assign(ctx, {:user, "flynn"}, "holder", "x", fail_item.id)
  end

  ## Disposition authority — owner-or-admin, resolved through the session's user.

  test "disposition authority: an admin session disposes a foreign item; a non-admin cannot",
       ctx do
    eves_item = create(ctx, {:user, "eve"}, %{title: "Eve's item"})

    # A non-admin session (dana) cannot dispose another user's item.
    assert %{code: "not_authorized"} =
             dispose(ctx, "work-item-close", {:session, "dsession"}, eves_item.id)

    # "holder" is owned by flynn, who is admin — an admin session (not the owner)
    # disposes it. Before the fix this was wrongly refused (session != owner).
    assert %{ok: true, workItem: %{state: "closed"}} =
             dispose(ctx, "work-item-close", {:session, "holder"}, eves_item.id)

    # A non-admin session still disposes its OWN owner's item.
    danas_item = create(ctx, {:user, "dana"}, %{title: "Dana's item"})

    assert %{ok: true, workItem: %{state: "iceboxed"}} =
             dispose(ctx, "work-item-icebox", {:session, "dsession"}, danas_item.id)
  end

  ## Proof 6 — owner resolution: session-created items anchor to the session's owning user.

  test "Proof 6: a session-created item is owned by its session's user; bracket targets the main",
       ctx do
    item = create(ctx, {:session, "dsession"}, %{title: "Session filed"})
    assert item.ownerUserId == "dana"
    assert item.createdBySession == "dsession"

    wake = Wakes.get(ctx.db, routing_wake_id(ctx.db, item.id))
    # The bracket wake reaches the durable personal session, never the creator session.
    assert wake.session_key == Org.personal_session_key("dana")
    refute wake.session_key == "dsession"
  end

  ## Proof 7 — effort-checkin coexistence: both machineries close in one transaction.

  test "Proof 7: a dispatched assignment closes through effort-cancel and slate-arm together",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Coexist"})
    {:ok, d} = disp_dispatch(ctx, {:user, "flynn"}, "holder", "w", item.id)

    assert effort_state(ctx.db, d.id) == "armed"

    complete(ctx, "holder", d.id)

    # Both effects land in the one close transaction: effort canceled, slate armed.
    assert effort_state(ctx.db, d.id) == "canceled"
    assert is_binary(slate_wake_id(ctx.db, item.id))
    assert assignment_state(ctx.db, d.id) == "closed"
  end

  ## Proof 8 — feature_smoke journey.

  test "Proof 9: create -> nag -> dispatch cancels -> revoke arms slate -> fail disposes", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Journey"})

    # Idle past the triage horizon: the routing wake fires and re-nags.
    deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, routing_wake_id(ctx.db, item.id)))

    assert Enum.any?(
             Projection.list_after(ctx.db, Org.personal_session_key("flynn"), nil, 10),
             &(&1.content =~ "route it or icebox it")
           )

    # Dispatch cancels bracket 1.
    {:ok, d} = disp_dispatch(ctx, {:user, "flynn"}, "holder", "ship", item.id)
    assert routing_wake_id(ctx.db, item.id) == nil

    # Revoke (last close) arms the slate wake, which then arrives.
    revoke(ctx, d.id)
    slate = slate_wake_id(ctx.db, item.id)
    assert is_binary(slate)
    deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, slate))

    assert Enum.any?(
             Projection.list_after(ctx.db, Org.personal_session_key("flynn"), nil, 10),
             &(&1.content =~ "slate clear")
           )

    # work-item-fail disposes and cancels bracket 2.
    assert %{ok: true, workItem: %{state: "failed", failReason: "shipped elsewhere"}} =
             dispose(ctx, "work-item-fail", {:user, "flynn"}, item.id, %{
               reason: "shipped elsewhere"
             })

    assert slate_wake_id(ctx.db, item.id) == nil
  end

  ## Proof 10 — dispatch replay bypasses rumination and the terminal guard.

  test "Proof 10: a keyed dispatch replay returns the original across any workItemId, even disposed",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Replay"})
    other = create(ctx, {:user, "flynn"}, %{title: "Other"})

    {:ok, orig} = disp_dispatch(ctx, {:user, "flynn"}, "holder", "ship", item.id, key: "dk")
    assert orig.workItemId == item.id

    # Dispose the item since — the replay must still succeed (no terminal-guard eval).
    revoke(ctx, orig.id)
    dispose(ctx, "work-item-fail", {:user, "flynn"}, item.id)

    for work_item_id <- [item.id, other.id, nil, "wi_unknown"] do
      assert {:ok, replay} =
               disp_dispatch(ctx, {:user, "flynn"}, "holder", "ship", work_item_id, key: "dk")

      assert replay.id == orig.id
      assert replay.workItemId == item.id
    end

    # ZERO rumination wakes were created by the replays.
    assert rumination_wake_count(ctx.db) == 0
  end

  test "Proof 10 (added): a keyed assign replay through Dispatch is statute-inert", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Assign replay"})
    {:ok, orig} = disp_assign(ctx, {:user, "flynn"}, "holder", "seed", item.id, key: "ak")
    assert orig.workItemId == item.id

    # Install a statute that Rules.decide WOULD deny a user-origin assign under.
    load_rules(ctx, """
    [[rule]]
    name = "deny-assign"
    verb = "assign"
    text = "assign denied"
    [[rule.deny_when]]
    fact = "caller.origin_class"
    op = "eq"
    value = "user"
    """)

    # The statute is live: a fresh (non-replay) assign is denied by the rail.
    assert {:error, %{code: "rule_denied"}} =
             disp_assign(ctx, {:user, "flynn"}, "holder", "fresh", item.id)

    # The keyed replay short-circuits ABOVE the rail: the original assignment
    # returns untouched and no remedy episode is filed (statute inertness).
    assert {:ok, replay} =
             disp_assign(ctx, {:user, "flynn"}, "holder", "ignored", item.id, key: "ak")

    assert replay.id == orig.id
    assert replay.workItemId == item.id
    assert RailRemedy.episode(ctx.db, "deny-assign", item.id) == nil
  end

  ## Proof 11 — disposition-while-open is refused with a legible error.

  test "Proof 11: icebox/close/fail are refused while any assignment is open", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Busy"})
    {:ok, _a} = disp_assign(ctx, {:user, "flynn"}, "holder", "w", item.id)

    for verb <- ["work-item-icebox", "work-item-close", "work-item-fail"] do
      assert %{code: "assignments_open"} = dispose(ctx, verb, {:user, "flynn"}, item.id)
    end
  end

  ## Proof 13 — failReason column truth.

  test "Proof 13: work-item-fail --reason persists and surfaces; icebox/close leave it NULL",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Reasoned"})

    assert %{workItem: %{failReason: "cannot repro"}} =
             dispose(ctx, "work-item-fail", {:user, "flynn"}, item.id, %{reason: "cannot repro"})

    assert get(ctx, item.id).workItem.failReason == "cannot repro"
    assert Enum.find(list(ctx).workItems, &(&1.id == item.id)).failReason == "cannot repro"
    assert WorkState.item_detail(ctx.db, item.id).workItem.failReason == "cannot repro"

    closed = create(ctx, {:user, "flynn"}, %{title: "Closed"})

    assert %{workItem: %{failReason: nil}} =
             dispose(ctx, "work-item-close", {:user, "flynn"}, closed.id)

    iceboxed = create(ctx, {:user, "flynn"}, %{title: "Iced"})

    assert %{workItem: %{failReason: nil}} =
             dispose(ctx, "work-item-icebox", {:user, "flynn"}, iceboxed.id)
  end

  ## Proof 14 — response shapes carry owner/state/failReason; never wake ids.

  test "Proof 14: every response object exposes owner/state/failReason and hides wake ids", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Shaped"})

    objects = [
      item,
      get(ctx, item.id).workItem,
      Enum.find(list(ctx).workItems, &(&1.id == item.id)),
      update(ctx, item.id, %{title: "Reshaped"}),
      WorkState.item_detail(ctx.db, item.id).workItem,
      Enum.find(WorkState.list_items(ctx.db, %{}).items, &(&1.workItem.id == item.id)).workItem
    ]

    for object <- objects do
      assert Map.has_key?(object, :ownerUserId)
      assert Map.has_key?(object, :state)
      assert Map.has_key?(object, :failReason)
      refute Map.has_key?(object, :routingWakeId)
      refute Map.has_key?(object, :slateWakeId)
    end

    disposition = dispose(ctx, "work-item-close", {:user, "flynn"}, item.id)
    assert %{ok: true, workItem: work_item} = disposition
    assert map_size(disposition) == 2
    refute Map.has_key?(disposition.workItem, :routingWakeId)
    refute Map.has_key?(work_item, :assignments)

    # A same-state no-op returns the same ok envelope and changes nothing.
    assert %{ok: true, workItem: %{state: "closed"}} =
             dispose(ctx, "work-item-close", {:user, "flynn"}, item.id)
  end

  ## Proof 15 — create doorbell: one on a real create, zero on a keyed replay.

  test "Proof 15: an actual create publishes to the owner's board (unassigned); replay is silent",
       ctx do
    flynn = observe("flynn")
    eve = observe("eve")

    # An UNASSIGNED item has no holders: the doorbell must still reach its owner.
    item = create(ctx, {:user, "flynn"}, %{title: "Doorbell", idempotency_key: "dk"})
    assert doorbell_count(ctx.db, item.id) == 1
    assert [%{"type" => "work_item_event", "kind" => "metadata"}] = Observer.drain(flynn)
    assert Observer.drain(eve) == []

    replay = create(ctx, {:user, "flynn"}, %{title: "Doorbell", idempotency_key: "dk"})
    assert replay.id == item.id
    assert doorbell_count(ctx.db, item.id) == 1
    assert Observer.drain(flynn) == []

    assert item.id in item_ids(WorkState.list_items(ctx.db, %{owner_user_id: "flynn"}))
    refute item.id in item_ids(WorkState.list_items(ctx.db, %{owner_user_id: "eve"}))
  end

  ## Proof 16 — the in-txn state='open' interlock aborts an insert racing a disposition.

  test "Proof 16: through Dispatch, a disposition landing between the guards aborts the insert",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Raced"})

    # The pre-statute guard (Dispatch precheck) will read this open state and proceed.
    assert WorkItems.state_for(ctx.db, item.id) == "open"

    call =
      assign_call({:user, "flynn"}, "holder", "w", item.id)
      |> Map.put(:on_work_item_interlock, fn txn ->
        # A genuine disposition (close) commits AFTER the pre-statute guard read
        # but BEFORE the insert — the same mechanics work-item-close applies
        # (cancel both brackets, set state). The substrate is one BEGIN IMMEDIATE
        # connection, so this txn seam is how a committed disposition interleaves;
        # a literal second connection would serialize behind this transaction.
        Txn.q(txn, "UPDATE work_items SET state = 'closed' WHERE id = ?1", [item.id])

        Tightbeam.CausalEvents.append_in_txn(txn, %{
          kind: "disposition_transition",
          job_ref: item.id,
          assignment_id: nil,
          session_key: nil,
          detail: %{workItemId: item.id, fromState: "open", toState: "closed"}
        })

        [[transition_id]] = Txn.q(txn, "SELECT last_insert_rowid()")

        WorkItems.cancel_brackets_in_txn(txn, item.id, %{
          causal_source: %{kind: "work_item_transition", id: to_string(transition_id)},
          outcome: %{
            kind: "disposition",
            disposition_kind: "work_item_transition",
            disposition_id: to_string(transition_id)
          }
        })
      end)

    # Driven through the chokepoint: precheck saw open, only the in-txn interlock
    # catches the disposition and aborts the insert.
    assert {:error, %{code: "work_item_not_open"}} = Dispatch.dispatch(ctx.db, ctx.handlers, call)

    # The now-terminal item never acquired an assignment.
    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE workItemId = ?1", [item.id])

    assert WorkItems.state_for(ctx.db, item.id) == "closed"
  end

  ## Proof 17 — bracket-2 slate re-arm on fire.

  test "Proof 17: an ignored slate wake re-arms itself at the next horizon", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Slate re-arm"})
    {:ok, a} = disp_assign(ctx, {:user, "flynn"}, "holder", "w", item.id)
    complete(ctx, "holder", a.id)

    slate = slate_wake_id(ctx.db, item.id)
    deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, slate))

    assert Wakes.get(ctx.db, slate).state == "fired"
    new = slate_wake_id(ctx.db, item.id)
    assert new != slate
    assert Wakes.get(ctx.db, new).state == "pending"
  end

  ## Proof 18 — a non-admin owner sees its own UNASSIGNED item through the owner path.

  test "Proof 18: a non-admin owner lists and details its own unassigned item", ctx do
    item = create(ctx, {:user, "dana"}, %{title: "Dana's item"})

    listed = item_ids(WorkState.list_items(ctx.db, %{owner_user_id: "dana"}))
    assert item.id in listed

    detail = WorkState.item_detail(ctx.db, item.id)
    assert detail.workItem.ownerUserId == "dana"
    assert detail.assignments == []

    # A different non-admin, non-owner does not see it (owner path, not admin bypass).
    refute item.id in item_ids(WorkState.list_items(ctx.db, %{owner_user_id: "eve"}))
  end

  ## Proof 19 — disposition doorbells fire on real transitions, stay silent on no-ops.

  test "Proof 19: each real disposition emits a doorbell; a same-state no-op emits none", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Doorbells"})
    base = doorbell_count(ctx.db, item.id)

    # A disposition on an UNASSIGNED item still reaches the owner's board.
    flynn = observe("flynn")
    dispose(ctx, "work-item-icebox", {:user, "flynn"}, item.id)
    assert doorbell_count(ctx.db, item.id) == base + 1
    assert [%{"type" => "work_item_event", "kind" => "metadata"}] = Observer.drain(flynn)

    # Same-state no-op: no doorbell, no publish.
    dispose(ctx, "work-item-icebox", {:user, "flynn"}, item.id)
    assert doorbell_count(ctx.db, item.id) == base + 1
    assert Observer.drain(flynn) == []

    dispose(ctx, "work-item-reopen", {:user, "flynn"}, item.id)
    assert doorbell_count(ctx.db, item.id) == base + 2

    dispose(ctx, "work-item-close", {:user, "flynn"}, item.id)
    assert doorbell_count(ctx.db, item.id) == base + 3

    fail_item = create(ctx, {:user, "flynn"}, %{title: "Failing"})
    fail_base = doorbell_count(ctx.db, fail_item.id)
    dispose(ctx, "work-item-fail", {:user, "flynn"}, fail_item.id)
    assert doorbell_count(ctx.db, fail_item.id) == fail_base + 1
  end

  ## Helpers ----------------------------------------------------------------

  defp create(ctx, principal, params) do
    ctx.handlers["work-item-create"].(work_item_call("work-item-create", principal, params))
  end

  defp dispose(ctx, verb, principal, id, extra \\ %{}) do
    params = Map.put(extra, :work_item_id, id)
    ctx.handlers[verb].(work_item_call(verb, principal, params))
  end

  defp get(ctx, id),
    do:
      ctx.handlers["work-item-get"].(
        work_item_call("work-item-get", {:user, "flynn"}, %{work_item_id: id})
      )

  defp list(ctx),
    do: ctx.handlers["work-item-list"].(work_item_call("work-item-list", {:user, "flynn"}, %{}))

  defp update(ctx, id, patch),
    do:
      ctx.handlers["work-item-update"].(
        work_item_call("work-item-update", {:user, "flynn"}, Map.put(patch, :work_item_id, id))
      )

  defp work_item_call(verb, principal, params) do
    %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      params: params
    }
  end

  defp disp_assign(ctx, principal, holder, subject, work_item_id, opts \\ []) do
    Dispatch.dispatch(
      ctx.db,
      ctx.handlers,
      assign_call(principal, holder, subject, work_item_id, opts)
    )
  end

  defp assign_call(principal, holder, subject, work_item_id, opts \\ []) do
    params =
      %{subject: subject, work_item_id: work_item_id}
      |> maybe_put(:idempotency_key, opts[:key])

    %{
      verb: "assign",
      origin: origin(principal),
      principal: principal,
      session_key: holder,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: params
    }
  end

  defp disp_dispatch(ctx, principal, holder, subject, work_item_id, opts \\ []) do
    params =
      %{subject: subject, brief: "Implement #{subject}.", work_item_id: work_item_id}
      |> maybe_put(:idempotency_key, opts[:key])

    call = %{
      verb: "dispatch",
      origin: origin(principal),
      principal: principal,
      session_key: holder,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: params
    }

    Dispatch.dispatch(ctx.db, ctx.handlers, call)
  end

  defp complete(ctx, holder, assignment_id), do: attest(ctx, holder, assignment_id, "completion")
  defp surrender(ctx, holder, assignment_id), do: attest(ctx, holder, assignment_id, "surrender")

  defp attest(ctx, holder, assignment_id, kind) do
    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "agent:#{holder}",
      principal: {:session, holder},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: kind}
    })
  end

  defp revoke(ctx, assignment_id) do
    Assignments.__handle__(ctx.db, "revoke-assignment", %{
      verb: "revoke-assignment",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{assignment_id: assignment_id}
    })
  end

  defp deliver_bracket_wake(db, wake) do
    {:ok, _} =
      DB.transaction(db, fn txn ->
        Gateway.deliver_prompt_in_txn(txn, wake.session_key, wake.origin, wake.prompt,
          wake_id: wake.wake_id,
          sender: wake.origin,
          target_gate: wake,
          fire_wake_in_txn: true
        )
      end)
  end

  defp routing_wake_id(db, id), do: column(db, id, "routingWakeId")
  defp slate_wake_id(db, id), do: column(db, id, "slateWakeId")

  defp column(db, id, name) do
    {:ok, [[value]]} = DB.query(db, "SELECT #{name} FROM work_items WHERE id = ?1", [id])
    value
  end

  defp item_wake_count(db, work_item_id) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT count(*) FROM wakes WHERE work_item_id = ?1 AND state = 'pending'",
        [work_item_id]
      )

    count
  end

  defp cancellation(db, wake_id) do
    {:ok, [row]} =
      DB.query(
        db,
        """
        SELECT requesterId,reasonKind,causalSourceKind,causalSourceId,
               outcomeKind,dispositionKind,dispositionId,primaryWorkKind,
               primaryWorkId,workImpactKind,livenessTriggerKind,
               livenessTriggerId,actionNeeded
        FROM wake_cancellations WHERE wakeId=?1
        """,
        [wake_id]
      )

    row
  end

  defp rumination_wake_count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT count(*) FROM wakes WHERE rumination = 1")
    count
  end

  defp work_item_count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT count(*) FROM work_items")
    count
  end

  defp doorbell_count(db, work_item_id) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT count(*) FROM work_item_events WHERE workItemId = ?1 AND kind = 'metadata'",
        [work_item_id]
      )

    count
  end

  defp assignment_state(db, id) do
    {:ok, [[state]]} = DB.query(db, "SELECT state FROM assignments WHERE id = ?1", [id])
    state
  end

  defp effort_state(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT state FROM effort_checkin_generations WHERE assignmentId = ?1 ORDER BY generation DESC LIMIT 1",
        [assignment_id]
      )

    case rows do
      [[state]] -> state
      [] -> nil
    end
  end

  defp item_ids(%{items: items}), do: Enum.map(items, & &1.workItem.id)

  # Register a work-state subscriber for a user. Each subscriber is its own
  # process because attribution is the subject here — which user's board a
  # doorbell reached — and `ConnRegistry` addresses a subscriber only by pid.
  defp observe(user_id) do
    observer = start_supervised!({Observer, []}, id: {:observer, user_id})

    {:ok, _, _} =
      Tightbeam.ConnRegistry.register(Tightbeam.ConnRegistry, %{
        pid: observer,
        user_id: user_id,
        device_id: "obs-#{user_id}",
        is_admin: false,
        subscriptions: MapSet.new(["work_state"])
      })

    observer
  end

  defp load_rules(ctx, toml) do
    base = Path.join(System.tmp_dir!(), "tb-brackets-rules-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "identity/rules"))
    File.write!(Path.join(base, "identity/rules/statute.toml"), toml)
    Rules.load!(base, Map.keys(ctx.handlers))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp origin({:user, user}), do: "user:#{user}"
  defp origin({:session, session}), do: "agent:#{session}"

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "eezo"
    })
  end
end
