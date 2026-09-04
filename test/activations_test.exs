defmodule Tightbeam.ActivationsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Activations, ColdStart, DB, Dispatch, Gateway, Model, Org, Rules}
  alias Tightbeam.ClientE2E.LegGateway

  @sha String.duplicate("a", 64)
  @sha2 String.duplicate("b", 64)
  @legacy_base "6e852693a4ba9f6bedbc9a77ed24675abdbd4fea"

  setup do
    db = :activations_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('owner',0,'admin_add',1),('other',0,'admin_add',1),('admin',1,'admin_add',1)"
      )

    personal(db, "owner")
    personal(db, "other")
    personal(db, "admin")
    session(db, "holder", "owner")

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO work_items (id,title,ownerUserId,state,createdByUser,createdAt) VALUES ('wi_activation','activation','owner','open','owner',1)"
      )

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state,workItemId) VALUES ('asg_root','root','holder','owner',1,'open','wi_activation')"
      )

    %{db: db}
  end

  test "schema adds exactly the neutral event-store columns and closed uniqueness indexes", %{
    db: db
  } do
    assert {:ok, columns} = DB.query(db, "PRAGMA table_info(activation_events)")

    assert Enum.map(columns, fn [_cid, name | _] -> name end) ==
             ~w(seq eventId activationId kind predecessorEventId rootAssignmentId workItemId actorAssignmentId bySession byUser idempotencyKey requestSha256 payload noticeWakeId ts)

    assert {:ok, tables} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%activation%' ORDER BY name"
             )

    assert tables == [["activation_events"]]

    assert {:ok, indexes} = DB.query(db, "PRAGMA index_list(activation_events)")
    names = Enum.map(indexes, fn [_seq, name | _] -> name end)

    for name <-
          ~w(activation_one_declaration activation_one_attempt activation_one_observation activation_one_reconciliation activation_one_withdrawal activation_one_acknowledgement activation_one_requeue_per_wake activation_events_session_key activation_events_user_key) do
      assert name in names
    end
  end

  test "records one neutral stream, notices atomically, protects reads, and replays first", %{
    db: db
  } do
    declared = apply(db, "activation-declare", {:session, "holder"}, declare_params())
    assert declared.state == "declared"
    assert declared.event.kind == "declared"
    activation_id = declared.event.activation_id

    authority =
      apply(db, "activation-authority", {:session, "holder"}, %{
        activation_id: activation_id,
        predecessor_event_id: declared.event.event_id,
        actor_assignment_id: "asg_root",
        authorizer: identity("owner"),
        basis: resource("basis", @sha),
        decision: code("recorded"),
        idempotency_key: "authority-1"
      })

    assert authority.event.kind == "authority-attached"

    attempt_params = %{
      activation_id: activation_id,
      predecessor_event_id: authority.event.event_id,
      actor_assignment_id: "asg_root",
      authority_event_ids: [authority.event.event_id],
      executor: identity("executor"),
      external_attempt: resource("attempt-1", nil),
      target_state_before: nil,
      idempotency_key: "attempt-1"
    }

    attempted = apply(db, "activation-attempt", {:session, "holder"}, attempt_params)
    assert attempted.state == "attempted"
    assert is_binary(attempted.event.notice_wake_id)

    assert {:ok, [[1, "pending"]]} =
             DB.query(
               db,
               "SELECT COUNT(*),MIN(state) FROM wakes WHERE wakeId=?1",
               [attempted.event.notice_wake_id]
             )

    # Exact replay precedes the now-terminal work-item check and returns the
    # original prefix response, including the same event and wake IDs.
    {:ok, _} = DB.query(db, "UPDATE work_items SET state='closed' WHERE id='wi_activation'")
    assert apply(db, "activation-attempt", {:session, "holder"}, attempt_params) == attempted

    observed =
      apply(db, "activation-observe", {:user, "owner"}, %{
        activation_id: activation_id,
        predecessor_event_id: attempted.event.event_id,
        attempt_event_id: attempted.event.event_id,
        certainty: "determinate",
        result: code("seen"),
        target_state_after: resource("after", @sha2),
        outputs: [resource("output", nil)],
        evidence: resource("evidence", @sha),
        external_occurred_at_ms: nil,
        idempotency_key: "observe-1"
      })

    assert observed.state == "observed"
    assert observed.event.notice_wake_id

    status =
      apply(db, "activation-status", {:user, "owner"}, %{activation_id: activation_id})

    assert status.state == "observed"

    assert Enum.map(status.events, & &1.kind) ==
             ~w(declared authority-attached attempted observed)

    assert %{code: "not_found"} =
             apply(db, "activation-status", {:user, "other"}, %{activation_id: activation_id})

    assert %{activations: [], count: 0} = apply(db, "activations", {:user, "other"}, %{})

    assert %{count: 1, activations: [%{activation_id: ^activation_id}]} =
             apply(db, "activations", {:user, "owner"}, %{work_item_id: "wi_activation"})
  end

  test "closed shapes, stale heads, authority order, and idempotency conflicts refuse", %{db: db} do
    assert %{code: "invalid_activation_payload"} =
             apply(
               db,
               "activation-declare",
               {:session, "holder"},
               Map.put(declare_params(), :event_id, "aev_forged")
             )

    declared = apply(db, "activation-declare", {:session, "holder"}, declare_params())

    changed = put_in(declare_params(), [:target, "id"], "different")

    assert %{code: "idempotency_conflict"} =
             apply(db, "activation-declare", {:session, "holder"}, changed)

    assert %{code: "activation_head_changed", current_head: head} =
             apply(db, "activation-withdraw", {:user, "owner"}, %{
               activation_id: declared.event.activation_id,
               predecessor_event_id: "aev_stale",
               reason: code("stopped"),
               basis: resource("basis", @sha),
               idempotency_key: "withdraw-stale"
             })

    assert head == declared.event.event_id
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM activation_events")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
  end

  test "indeterminate evidence remains unresolved until one reconciliation", %{db: db} do
    {declared, authority, attempted} = attempted_stream(db, "recovery")

    observed =
      apply(db, "activation-observe", {:user, "owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: attempted.event.event_id,
        attempt_event_id: attempted.event.event_id,
        certainty: "indeterminate",
        result: code("unknown"),
        target_state_after: nil,
        outputs: [],
        evidence: resource("uncertain", @sha),
        external_occurred_at_ms: nil,
        idempotency_key: "observe-recovery"
      })

    assert observed.state == "needs-reconciliation"

    reconciled =
      apply(db, "activation-reconcile", {:session, "holder"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: observed.event.event_id,
        actor_assignment_id: "asg_root",
        observed_event_id: observed.event.event_id,
        certainty: "irrecoverable",
        result: code("unresolved"),
        target_state_after: nil,
        outputs: [],
        evidence: resource("reconciliation", @sha2),
        external_occurred_at_ms: 0,
        idempotency_key: "reconcile-recovery"
      })

    assert reconciled.state == "observed"

    assert %{code: "activation_transition_refused"} =
             apply(db, "activation-reconcile", {:session, "holder"}, %{
               activation_id: declared.event.activation_id,
               predecessor_event_id: reconciled.event.event_id,
               actor_assignment_id: "asg_root",
               observed_event_id: observed.event.event_id,
               certainty: "determinate",
               result: code("seen"),
               target_state_after: nil,
               outputs: [],
               evidence: resource("second", @sha2),
               external_occurred_at_ms: nil,
               idempotency_key: "reconcile-second"
             })

    assert authority.event.kind == "authority-attached"
  end

  test "recovery evidence requires a recovery principal even when the stream is readable", %{
    db: db
  } do
    declared = apply(db, "activation-declare", {:session, "holder"}, declare_params())

    authority =
      apply(db, "activation-authority", {:user, "owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: declared.event.event_id,
        authorizer: identity("owner"),
        basis: resource("recovery-basis", @sha),
        decision: code("recorded"),
        idempotency_key: "authority-recovery-principal"
      })

    attempted =
      apply(db, "activation-attempt", {:session, "holder"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: authority.event.event_id,
        actor_assignment_id: "asg_root",
        authority_event_ids: [authority.event.event_id],
        executor: identity("executor"),
        external_attempt: resource("recovery-principal-attempt", nil),
        target_state_before: nil,
        idempotency_key: "attempt-recovery-principal"
      })

    params = %{
      activation_id: declared.event.activation_id,
      predecessor_event_id: attempted.event.event_id,
      attempt_event_id: attempted.event.event_id,
      certainty: "determinate",
      result: code("seen"),
      target_state_after: nil,
      outputs: [],
      evidence: resource("recovery-principal-evidence", @sha),
      external_occurred_at_ms: nil,
      idempotency_key: "observe-recovery-principal"
    }

    assert %{code: "activation_assignment_refused"} =
             apply(db, "activation-observe", {:user, "admin"}, params)

    {:ok, _} = DB.query(db, "UPDATE work_items SET state='closed' WHERE id='wi_activation'")

    assert %{state: "observed"} =
             apply(db, "activation-observe", {:user, "owner"}, params)
  end

  test "an attempt preserves authority stream order without interpreting authority meaning", %{
    db: db
  } do
    declared =
      apply(
        db,
        "activation-declare",
        {:session, "holder"},
        declare_params()
        |> Map.put(:correlation_key, "authority-order")
        |> Map.put(:idempotency_key, "declare-authority-order")
      )

    first =
      apply(db, "activation-authority", {:user, "owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: declared.event.event_id,
        authorizer: identity("first"),
        basis: resource("first", @sha),
        decision: code("one"),
        idempotency_key: "authority-order-1"
      })

    second =
      apply(db, "activation-authority", {:user, "owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: first.event.event_id,
        authorizer: identity("second"),
        basis: resource("second", @sha2),
        decision: code("two"),
        idempotency_key: "authority-order-2"
      })

    base = %{
      activation_id: declared.event.activation_id,
      predecessor_event_id: second.event.event_id,
      actor_assignment_id: "asg_root",
      executor: identity("executor"),
      external_attempt: resource("attempt-order", nil),
      target_state_before: nil,
      idempotency_key: "attempt-order"
    }

    assert %{code: "activation_authority_refused"} =
             apply(
               db,
               "activation-attempt",
               {:session, "holder"},
               Map.put(base, :authority_event_ids, [second.event.event_id, first.event.event_id])
             )

    attempted =
      apply(
        db,
        "activation-attempt",
        {:session, "holder"},
        base
        |> Map.put(:authority_event_ids, [first.event.event_id, second.event.event_id])
        |> Map.put(:idempotency_key, "attempt-order-correct")
      )

    assert attempted.event.payload["authorityEventIds"] ==
             [first.event.event_id, second.event.event_id]
  end

  test "a canceled notice can be replaced once and only its fired owner wake can be acknowledged",
       %{db: db} do
    {declared, _authority, attempted} = attempted_stream(db, "notice")
    original_wake = attempted.event.notice_wake_id

    liveness =
      Tightbeam.Wakes.schedule(db, %{
        session_key: Org.personal_session_key("owner"),
        origin: "process:tightbeam",
        prompt: "bounded test liveness",
        due_at: System.system_time(:millisecond) + 60_000,
        work_item_id: "wi_activation",
        assignment_id: "asg_root"
      })

    assert {:ok, true} =
             DB.transaction(db, fn txn ->
               Tightbeam.Wakes.cancel_in_txn(txn, %{
                 wake_id: original_wake,
                 requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
                 reason_kind: "consumer_unavailable",
                 causal_source: %{kind: "scheduler_delivery", id: original_wake},
                 outcome: %{
                   kind: "no_replacement",
                   liveness_trigger: %{kind: "pending_wake", id: liveness.wake_id}
                 }
               })
             end)

    requeued =
      apply(db, "activation-renotify", {:user, "owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: attempted.event.event_id,
        noticed_event_id: attempted.event.event_id,
        replaces_wake_id: original_wake,
        idempotency_key: "renotify-notice"
      })

    replacement = requeued.event.notice_wake_id
    assert replacement != original_wake
    assert requeued.state == "attempted"

    assert %{code: "activation_notice_refused"} =
             apply(db, "activation-ack", {:user, "owner"}, %{
               activation_id: declared.event.activation_id,
               predecessor_event_id: requeued.event.event_id,
               noticed_event_id: attempted.event.event_id,
               acknowledged_wake_id: replacement,
               idempotency_key: "ack-pending"
             })

    {:ok, _} =
      DB.query(db, "UPDATE wakes SET state='fired',firedAt=20 WHERE wakeId=?1", [replacement])

    acknowledged =
      apply(db, "activation-ack", {:user, "owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: requeued.event.event_id,
        noticed_event_id: attempted.event.event_id,
        acknowledged_wake_id: replacement,
        idempotency_key: "ack-fired"
      })

    assert acknowledged.event.kind == "acknowledged"
    assert acknowledged.state == "attempted"

    status =
      apply(db, "activation-status", {:user, "owner"}, %{
        activation_id: declared.event.activation_id
      })

    assert [%{acknowledged_event_id: ack_id, wake_states: states}] = status.notices
    assert ack_id == acknowledged.event.event_id
    assert states == %{original_wake => "canceled", replacement => "fired"}
  end

  test "concurrent successors after one head commit exactly one row", %{db: db} do
    declared = apply(db, "activation-declare", {:session, "holder"}, declare_params())

    authority = fn suffix ->
      apply(db, "activation-authority", {:user, "owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: declared.event.event_id,
        authorizer: identity("authorizer-#{suffix}"),
        basis: resource("basis-#{suffix}", @sha),
        decision: code("decision-#{suffix}"),
        idempotency_key: "concurrent-authority-#{suffix}"
      })
    end

    results =
      ["one", "two"]
      |> Enum.map(fn suffix -> Task.async(fn -> authority.(suffix) end) end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert [winner] = Enum.filter(results, &match?(%{event: %{kind: "authority-attached"}}, &1))

    assert [%{code: "activation_head_changed", current_head: winning_head}] =
             Enum.filter(results, &match?(%{code: "activation_head_changed"}, &1))

    assert winning_head == winner.event.event_id
    assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM activation_events")

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM activation_events WHERE kind!='declared'")
  end

  test "successor bridge admits only a held same-work-item root after a terminal predecessor",
       %{db: db} do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('successor',0,'admin_add',1)"
      )

    session(db, "successor-holder", "successor")

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state,workItemId) VALUES ('asg_successor','successor','successor-holder','owner',2,'open','wi_activation')"
      )

    declared =
      apply(
        db,
        "activation-declare",
        {:session, "holder"},
        declare_params()
        |> Map.put(:prepared_input, resource("old-secret-input", @sha))
        |> Map.put(:correlation_key, "old-secret-correlation")
      )

    authority =
      apply(db, "activation-authority", {:user, "owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: declared.event.event_id,
        authorizer: identity("old-authorizer"),
        basis: resource("old-secret-basis", @sha),
        decision: code("old-decision"),
        idempotency_key: "old-authority"
      })

    withdrawn =
      apply(db, "activation-withdraw", {:user, "owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: authority.event.event_id,
        reason: code("transferred"),
        basis: resource("transfer", @sha2),
        idempotency_key: "withdraw-transfer"
      })

    successor =
      apply(db, "activation-declare", {:session, "successor-holder"}, %{
        root_assignment_id: "asg_successor",
        owner_user_id: "successor",
        domain: "example",
        correlation_key: "successor-correlation",
        prepared_input: resource("successor-input", @sha2),
        target: resource("successor-target", nil),
        prior_activation_id: declared.event.activation_id,
        relation: "supersedes",
        idempotency_key: "successor-declare"
      })

    assert successor.state == "declared"

    assert successor.event.payload["prior"] == %{
             "activationId" => declared.event.activation_id,
             "relation" => "supersedes"
           }

    refute inspect(successor) =~ "old-secret"

    assert %{code: "not_found"} =
             apply(db, "activation-status", {:session, "successor-holder"}, %{
               activation_id: declared.event.activation_id
             })

    assert %{activations: [%{activation_id: successor_id}], count: 1} =
             apply(db, "activations", {:session, "successor-holder"}, %{})

    assert successor_id == successor.event.activation_id

    assert %{code: "activation_transition_refused"} =
             apply(db, "activation-attempt", {:session, "holder"}, %{
               activation_id: declared.event.activation_id,
               predecessor_event_id: withdrawn.event.event_id,
               actor_assignment_id: "asg_root",
               authority_event_ids: [authority.event.event_id],
               executor: identity("stale-executor"),
               external_attempt: resource("stale-attempt", nil),
               target_state_before: nil,
               idempotency_key: "stale-attempt"
             })

    successor_authority =
      apply(db, "activation-authority", {:user, "successor"}, %{
        activation_id: successor.event.activation_id,
        predecessor_event_id: successor.event.event_id,
        authorizer: identity("successor-authorizer"),
        basis: resource("successor-basis", @sha2),
        decision: code("successor-decision"),
        idempotency_key: "successor-authority"
      })

    assert %{code: "activation_authority_refused"} =
             apply(db, "activation-attempt", {:session, "successor-holder"}, %{
               activation_id: successor.event.activation_id,
               predecessor_event_id: successor_authority.event.event_id,
               actor_assignment_id: "asg_successor",
               authority_event_ids: [authority.event.event_id],
               executor: identity("successor-executor"),
               external_attempt: resource("successor-attempt", nil),
               target_state_before: nil,
               idempotency_key: "successor-old-authority-attempt"
             })

    nonterminal =
      apply(
        db,
        "activation-declare",
        {:session, "holder"},
        declare_params()
        |> Map.put(:correlation_key, "nonterminal-prior")
        |> Map.put(:idempotency_key, "nonterminal-prior")
      )

    assert %{code: "not_found"} =
             apply(
               db,
               "activation-declare",
               {:session, "successor-holder"},
               declare_params()
               |> Map.put(:root_assignment_id, "asg_successor")
               |> Map.put(:owner_user_id, "successor")
               |> Map.put(:correlation_key, "nonterminal-successor")
               |> Map.put(:prior_activation_id, nonterminal.event.activation_id)
               |> Map.put(:relation, "supersedes")
               |> Map.put(:idempotency_key, "nonterminal-successor")
             )

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO work_items (id,title,ownerUserId,state,createdByUser,createdAt) VALUES ('wi_other','other','owner','open','owner',3)"
      )

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state,workItemId) VALUES ('asg_other','other','successor-holder','owner',3,'open','wi_other')"
      )

    assert %{code: "not_found"} =
             apply(db, "activation-declare", {:session, "successor-holder"}, %{
               root_assignment_id: "asg_other",
               owner_user_id: "successor",
               domain: "example",
               correlation_key: "different-work-item",
               prepared_input: resource("different-input", @sha),
               target: resource("different-target", nil),
               prior_activation_id: declared.event.activation_id,
               relation: "supersedes",
               idempotency_key: "different-work-item"
             })
  end

  test "noticed event and wake roll back together at each injected transaction boundary",
       %{db: db} do
    {declared, authority} = authority_stream(db, "atomic")
    base_event_count = row_count(db, "activation_events")
    base_wake_count = row_count(db, "wakes")

    :ok =
      DB.execute(
        db,
        """
        CREATE TRIGGER fail_before_activation_wake
        BEFORE INSERT ON wakes
        BEGIN SELECT RAISE(ABORT, 'injected-before-wake'); END;
        """
      )

    assert_raise Tightbeam.DB.Error, fn -> attempt(db, declared, authority, "before-wake") end
    assert row_count(db, "activation_events") == base_event_count
    assert row_count(db, "wakes") == base_wake_count
    :ok = DB.execute(db, "DROP TRIGGER fail_before_activation_wake")

    :ok =
      DB.execute(
        db,
        """
        CREATE TRIGGER fail_between_activation_wake_and_event
        BEFORE INSERT ON activation_events WHEN NEW.kind = 'attempted'
        BEGIN SELECT RAISE(ABORT, 'injected-before-event'); END;
        """
      )

    assert_raise Tightbeam.DB.Error, fn -> attempt(db, declared, authority, "before-event") end
    assert row_count(db, "activation_events") == base_event_count
    assert row_count(db, "wakes") == base_wake_count
    :ok = DB.execute(db, "DROP TRIGGER fail_between_activation_wake_and_event")

    :ok =
      DB.execute(
        db,
        """
        CREATE TABLE activation_commit_probe (
          eventId TEXT REFERENCES activation_events(eventId) DEFERRABLE INITIALLY DEFERRED
        );
        CREATE TRIGGER fail_activation_commit
        AFTER INSERT ON activation_events WHEN NEW.kind = 'attempted'
        BEGIN INSERT INTO activation_commit_probe(eventId) VALUES ('aev_missing_at_commit'); END;
        """
      )

    assert_raise MatchError, ~r/FOREIGN KEY constraint failed/, fn ->
      attempt(db, declared, authority, "at-commit")
    end

    assert row_count(db, "activation_events") == base_event_count
    assert row_count(db, "wakes") == base_wake_count

    :ok =
      DB.execute(db, "DROP TRIGGER fail_activation_commit; DROP TABLE activation_commit_probe;")

    accepted = attempt(db, declared, authority, "accepted")
    assert accepted.event.notice_wake_id
    assert row_count(db, "activation_events") == base_event_count + 1
    assert row_count(db, "wakes") == base_wake_count + 1

    assert {:ok, [[accepted.event.notice_wake_id]]} ==
             DB.query(
               db,
               "SELECT wakeId FROM wakes WHERE wakeId=?1",
               [accepted.event.notice_wake_id]
             )
  end

  test "additive bootstrap preserves stamped rows and synthesizes no activation facts", %{db: db} do
    assert {:ok, old_users} = DB.query(db, "SELECT * FROM users ORDER BY userId")
    assert {:ok, old_stamp} = DB.query(db, "SELECT * FROM schema_stamp")
    :ok = DB.execute(db, "DROP TABLE activation_events")

    :ok = Activations.ensure_schema(db)

    assert {:ok, ^old_users} = DB.query(db, "SELECT * FROM users ORDER BY userId")
    assert {:ok, ^old_stamp} = DB.query(db, "SELECT * FROM schema_stamp")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM activation_events")

    assert {:ok, indexes} = DB.query(db, "PRAGMA index_list(activation_events)")
    assert length(indexes) == 12
  end

  @tag timeout: 420_000
  test "the exact older gateway opens activation rows and current CLI refuses before dispatch" do
    root =
      Path.join(
        System.tmp_dir!(),
        "activation-downgrade-client-e2e-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    Tightbeam.CursorSigning.provision!(root)
    path = Path.join(root, "state.db")
    writer = :activation_downgrade_writer
    reader = :activation_downgrade_reader
    on_exit(fn -> File.rm_rf!(root) end)

    legacy_checkout = exact_legacy_checkout!()
    legacy_build = Path.join(Path.expand("..", __DIR__), "_build/legacy-base-#{System.pid()}")

    # The legacy gateway must own the database shape used by this downgrade
    # test. A current bootstrap would stamp a newer shape that the exact older
    # binary must refuse, which tests schema downgrade rather than CLI feature
    # negotiation.
    bootstrap_gateway =
      case LegGateway.boot(root, free_port(),
             repo_root: legacy_checkout,
             boot_timeout_ms: 300_000,
             env: [
               {"PATH", System.fetch_env!("PATH")},
               {"ELIXIR_ERL_OPTIONS", "+fnu"},
               {"MIX_BUILD_PATH", legacy_build}
             ]
           ) do
        {:ok, gateway} ->
          gateway

        {:error, reason, gateway} ->
          log = if File.exists?(gateway.log_path), do: File.read!(gateway.log_path), else: ""
          LegGateway.teardown(gateway, remove: false)
          flunk("exact legacy gateway failed to bootstrap: #{inspect(reason)}\n#{log}")
      end

    assert :ok = LegGateway.teardown(bootstrap_gateway, remove: false)

    {:ok, writer_pid} = DB.start_link(path: path, name: writer)
    :ok = Activations.ensure_schema(writer)

    assert {:ok, %{phase: "reserved"}} =
             ColdStart.add_first_user(writer, "legacy", %{
               host: "testhost",
               harness: :claude,
               provider: :anthropic,
               model: Model.new("fable")
             })

    session(writer, "legacy-holder", "legacy")

    {:ok, _} =
      DB.query(
        writer,
        "INSERT INTO work_items (id,title,ownerUserId,state,createdByUser,createdAt) VALUES ('wi_legacy','legacy-readable','legacy','open','legacy',1)"
      )

    {:ok, _} =
      DB.query(
        writer,
        "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state,workItemId) VALUES ('asg_legacy','legacy','legacy-holder','legacy',1,'open','wi_legacy')"
      )

    current =
      apply(writer, "activation-declare", {:session, "legacy-holder"}, %{
        root_assignment_id: "asg_legacy",
        owner_user_id: "legacy",
        domain: "example",
        correlation_key: "downgrade",
        prepared_input: resource("downgrade-input", @sha),
        target: resource("downgrade-target", nil),
        idempotency_key: "downgrade-declare"
      })

    GenServer.stop(writer_pid)
    port = free_port()

    gateway_result =
      case LegGateway.boot(root, port,
             repo_root: legacy_checkout,
             boot_timeout_ms: 300_000,
             env: [
               {"PATH", System.fetch_env!("PATH")},
               {"ELIXIR_ERL_OPTIONS", "+fnu"},
               {"MIX_BUILD_PATH", legacy_build}
             ]
           ) do
        {:ok, gateway} ->
          {:ok, gateway}

        {:error, reason, gateway} ->
          log = if File.exists?(gateway.log_path), do: File.read!(gateway.log_path), else: ""
          LegGateway.teardown(gateway, remove: false)
          {:refused, reason, log}
      end

    case gateway_result do
      {:refused, _reason, log} ->
        assert log =~ "stamped: coordination-fabric-v1-phase1-v17"
        assert log =~ "this build: coordination-fabric-v1-phase1-v13"
        assert log =~ "There is no migration"

      {:ok, gateway} ->
        on_exit(fn -> assert :ok = LegGateway.teardown(gateway, remove: false) end)

        assert %{"protocolVersion" => 1} = version = gateway_version!(port)
        refute Map.has_key?(version, "features")

        cli = Path.expand("../cli/target/release/tightbeam", __DIR__)
        assert File.exists?(cli), "build cli/target/release/tightbeam before running this gate"

        cli_env = [{"TIGHTBEAM_BASE_DIR", root}]

        assert {legacy_journey, 0} =
                 System.cmd(cli, ["work-item-get", "wi_legacy", "--as-user", "legacy"],
                   cd: root,
                   env: cli_env,
                   stderr_to_stdout: true
                 )

        assert legacy_journey =~ "wi_legacy"
        assert legacy_journey =~ "legacy-readable"

        assert {"capability_missing: activation-events-v1\n", 1} =
                 System.cmd(
                   cli,
                   [
                     "activation-status",
                     "--activation",
                     current.event.activation_id,
                     "--as-user",
                     "legacy"
                   ],
                   cd: root,
                   env: cli_env,
                   stderr_to_stdout: true
                 )

        {:ok, reader_pid} = DB.start_link(path: path, name: reader)
        on_exit(fn -> if Process.alive?(reader_pid), do: GenServer.stop(reader_pid) end)

        assert {:ok, [["wi_legacy", "legacy-readable", "open"]]} =
                 DB.query(reader, "SELECT id,title,state FROM work_items WHERE id='wi_legacy'")

        assert {:ok, [[current.event.activation_id]]} ==
                 DB.query(reader, "SELECT activationId FROM activation_events")

        assert {:ok, [[0]]} =
                 DB.query(reader, "SELECT COUNT(*) FROM events WHERE verb='activation-status'")
    end
  end

  test "dispatch and work trace expose activation metadata without protected payload objects", %{
    db: db
  } do
    handlers = Gateway.handlers(%{db: db})
    Rules.load!(System.tmp_dir!(), Map.keys(handlers))

    assert {:ok, %{event: event}} =
             Dispatch.dispatch(db, handlers, %{
               verb: "activation-declare",
               origin: "agent:holder",
               principal: {:session, "holder"},
               session_key: nil,
               params: declare_params()
             })

    assert {:ok, [[encoded]]} =
             DB.query(
               db,
               "SELECT payload FROM events WHERE verb='activation-declare' ORDER BY id DESC LIMIT 1"
             )

    assert encoded =~ event.activation_id
    assert encoded =~ "event_kind: \"declared\""
    refute encoded =~ "preparedInput"
    refute encoded =~ @sha

    assert [trace] = Activations.trace_entries(db, "wi_activation")
    assert trace.activationId == event.activation_id
    assert trace.kind == "declared"
    refute Map.has_key?(trace, :payload)
  end

  defp apply(db, verb, principal, params) do
    Activations.handle(db, verb, %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      params: params
    })
  end

  defp declare_params do
    %{
      root_assignment_id: "asg_root",
      owner_user_id: "owner",
      domain: "example",
      correlation_key: "correlation-1",
      prepared_input: resource("input", @sha),
      target: resource("target", nil),
      idempotency_key: "declare-1"
    }
  end

  defp attempted_stream(db, suffix) do
    params =
      declare_params()
      |> Map.put(:correlation_key, "correlation-#{suffix}")
      |> Map.put(:idempotency_key, "declare-#{suffix}")

    declared = apply(db, "activation-declare", {:session, "holder"}, params)

    authority =
      apply(db, "activation-authority", {:user, "owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: declared.event.event_id,
        authorizer: identity("owner"),
        basis: resource("basis-#{suffix}", @sha),
        decision: code("recorded"),
        idempotency_key: "authority-#{suffix}"
      })

    attempted =
      apply(db, "activation-attempt", {:session, "holder"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: authority.event.event_id,
        actor_assignment_id: "asg_root",
        authority_event_ids: [authority.event.event_id],
        executor: identity("executor"),
        external_attempt: resource("attempt-#{suffix}", nil),
        target_state_before: nil,
        idempotency_key: "attempt-#{suffix}"
      })

    {declared, authority, attempted}
  end

  defp authority_stream(db, suffix) do
    declared =
      apply(
        db,
        "activation-declare",
        {:session, "holder"},
        declare_params()
        |> Map.put(:correlation_key, "correlation-#{suffix}")
        |> Map.put(:idempotency_key, "declare-#{suffix}")
      )

    authority =
      apply(db, "activation-authority", {:user, "owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: declared.event.event_id,
        authorizer: identity("owner"),
        basis: resource("basis-#{suffix}", @sha),
        decision: code("recorded"),
        idempotency_key: "authority-#{suffix}"
      })

    {declared, authority}
  end

  defp attempt(db, declared, authority, suffix) do
    apply(db, "activation-attempt", {:session, "holder"}, %{
      activation_id: declared.event.activation_id,
      predecessor_event_id: authority.event.event_id,
      actor_assignment_id: "asg_root",
      authority_event_ids: [authority.event.event_id],
      executor: identity("executor-#{suffix}"),
      external_attempt: resource("attempt-#{suffix}", nil),
      target_state_before: nil,
      idempotency_key: "attempt-#{suffix}"
    })
  end

  defp row_count(db, table) when table in ~w(activation_events wakes) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM #{table}")
    count
  end

  defp identity(id), do: %{"namespace" => "example", "id" => id}
  defp code(value), do: %{"namespace" => "example", "code" => value}
  defp resource(id, sha), do: %{"namespace" => "example", "id" => id, "sha256" => sha}
  defp origin({:session, session}), do: "agent:" <> session
  defp origin({:user, user}), do: "user:" <> user

  defp exact_legacy_checkout! do
    repo = Path.expand("..", __DIR__)
    checkout = Path.join(repo, "_build/legacy-checkout-#{@legacy_base}")

    unless File.dir?(Path.join(checkout, ".git")) do
      assert {origin, 0} = System.cmd("git", ["remote", "get-url", "origin"], cd: repo)

      assert {_output, 0} =
               System.cmd("git", ["clone", "--shared", "--no-checkout", repo, checkout],
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["fetch", "--depth=1", String.trim(origin), @legacy_base],
                 cd: checkout,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("git", ["checkout", "--detach", @legacy_base],
                 cd: checkout,
                 stderr_to_stdout: true
               )

      File.ln_s!(Path.join(repo, "deps"), Path.join(checkout, "deps"))
      File.ln_s!(Path.join(repo, "cli/target"), Path.join(checkout, "cli/target"))
    end

    # Current clean/build gates may prune a nested checkout's tracked lib tree.
    # Restore the pinned source before every use; the checkout is generated and
    # contains no authored work.
    assert {_output, 0} =
             System.cmd(
               "git",
               ["restore", "--source", @legacy_base, "--staged", "--worktree", "--", "."],
               cd: checkout,
               stderr_to_stdout: true
             )

    assert {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: checkout)
    assert String.trim(commit) == @legacy_base
    checkout
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp gateway_version!(port) do
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, {{_http, 200, _reason}, _headers, body}} =
      :httpc.request(
        :get,
        {~c"http://127.0.0.1:#{port}/version", []},
        [],
        body_format: :binary
      )

    JSON.decode!(body)
  end

  defp personal(db, owner), do: session(db, Org.personal_session_key(owner), owner)

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
