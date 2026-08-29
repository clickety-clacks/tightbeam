defmodule Tightbeam.ActivationContractMatrixTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Activations, DB, Dispatch, Gateway, Model, Org, Rules, Wakes}

  @sha String.duplicate("a", 64)
  @sha2 String.duplicate("b", 64)
  @event_verbs ~w(activation-declare activation-authority activation-attempt activation-observe activation-reconcile activation-withdraw activation-renotify activation-ack)

  setup do
    db = :activation_contract_matrix_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES
          ('holder_owner',0,'admin_add',1),
          ('work_owner',0,'admin_add',1),
          ('other',0,'admin_add',1),
          ('admin',1,'admin_add',1),
          ('filer_owner',0,'admin_add',1),
          ('named_owner',0,'admin_add',1)
        """
      )

    for user <- ~w(holder_owner work_owner other admin filer_owner named_owner) do
      session(db, Org.personal_session_key(user), user)
    end

    session(db, "holder", "holder_owner")
    session(db, "other-holder", "other")
    session(db, "filer-holder", "filer_owner")
    session(db, "named-holder", "named_owner")

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO work_items (id,title,ownerUserId,state,createdByUser,createdAt) VALUES ('wi_matrix','matrix','work_owner','open','work_owner',1)"
      )

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state,workItemId) VALUES
          ('asg_matrix','root','holder','work_owner',1,'open','wi_matrix'),
          ('asg_actor','actor','filer-holder','work_owner',2,'open','wi_matrix')
        """
      )

    %{db: db}
  end

  test "A-06 rejects every event verb's open shape, missing field, wrong type, token, and bound",
       %{db: db} do
    cases = Enum.map(@event_verbs, &event_case(db, &1, "shape"))

    Enum.each(cases, fn %{verb: verb, principal: principal, params: params, required: required} ->
      before = counts(db)

      for mutant <- [
            Map.delete(params, required),
            Map.put(params, :event_id, "aev_forged"),
            Map.put(params, required, 42),
            Map.put(params, :idempotency_key, "contains whitespace"),
            Map.put(params, :idempotency_key, "control\ncharacter"),
            Map.put(params, :idempotency_key, String.duplicate("x", 201))
          ] do
        assert %{code: code} = apply(db, verb, principal, mutant)
        assert is_binary(code)
        assert counts(db) == before
      end
    end)
  end

  test "A-06 rejects null required digests before event or wake insertion", %{db: db} do
    mutants = [
      {event_case(db, "activation-declare", "digest-declare"), [:prepared_input, "sha256"]},
      {event_case(db, "activation-authority", "digest-authority"), [:basis, "sha256"]},
      {event_case(db, "activation-observe", "digest-observe"), [:evidence, "sha256"]},
      {event_case(db, "activation-reconcile", "digest-reconcile"), [:evidence, "sha256"]},
      {event_case(db, "activation-withdraw", "digest-withdraw"), [:basis, "sha256"]}
    ]

    Enum.each(mutants, fn {%{verb: verb, principal: principal, params: params}, path} ->
      before = counts(db)

      assert %{code: "invalid_activation_payload"} =
               apply(db, verb, principal, put_in(params, path, nil))

      assert counts(db) == before
    end)
  end

  test "A-07 declaration derives accountability and refuses every invalid relation", %{db: db} do
    accepted = apply(db, "activation-declare", {:session, "holder"}, declare("accountability"))
    assert accepted.event.root_assignment_id == "asg_matrix"
    assert accepted.event.work_item_id == "wi_matrix"
    assert accepted.event.by_session == "holder"

    cases = [
      fn ->
        apply(db, "activation-declare", {:session, "other-holder"}, declare("nonholder"))
      end,
      fn ->
        {:ok, _} =
          DB.query(
            db,
            "UPDATE assignments SET state='closed',outcome='revoked',closedAt=8,closedByUser='work_owner' WHERE id='asg_matrix'"
          )

        result =
          apply(db, "activation-declare", {:session, "holder"}, declare("closed-assignment"))

        {:ok, _} =
          DB.query(
            db,
            "UPDATE assignments SET state='open',outcome=NULL,closedAt=NULL,closedByUser=NULL WHERE id='asg_matrix'"
          )

        result
      end,
      fn ->
        {:ok, _} =
          DB.query(
            db,
            "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state,workItemId) VALUES ('asg_unlinked','unlinked','holder','work_owner',9,'open',NULL)"
          )

        apply(
          db,
          "activation-declare",
          {:session, "holder"},
          declare("unlinked") |> Map.put(:root_assignment_id, "asg_unlinked")
        )
      end,
      fn ->
        {:ok, _} = DB.query(db, "UPDATE work_items SET state='closed' WHERE id='wi_matrix'")
        result = apply(db, "activation-declare", {:session, "holder"}, declare("terminal-work"))
        {:ok, _} = DB.query(db, "UPDATE work_items SET state='open' WHERE id='wi_matrix'")
        result
      end
    ]

    Enum.each(cases, fn run ->
      before = counts(db)
      assert %{code: "activation_assignment_refused"} = run.()
      assert counts(db) == before
    end)

    before = counts(db)

    assert %{code: "activation_owner_refused"} =
             apply(
               db,
               "activation-declare",
               {:session, "holder"},
               declare("wrong-owner") |> Map.put(:owner_user_id, "other")
             )

    assert counts(db) == before
    assert %{count: 0, activations: []} = apply(db, "activations", {:user, "other"}, %{})
  end

  test "A-08 through A-10 reject hidden authority, foreign membership, and a second attempt",
       %{db: db} do
    first = declared(db, "membership-first")
    before = counts(db)

    assert %{code: "not_found"} =
             apply(db, "activation-authority", {:user, "other"}, %{
               activation_id: first.event.activation_id,
               predecessor_event_id: first.event.event_id,
               authorizer: identity("hidden"),
               basis: resource("hidden", @sha),
               decision: code("hidden"),
               idempotency_key: "hidden-authority"
             })

    assert counts(db) == before

    first_authority = authority(db, first, "membership-first-1")
    second_authority = authority(db, first_authority, "membership-first-2")
    foreign = declared(db, "membership-foreign")
    foreign_authority = authority(db, foreign, "membership-foreign")
    base = attempt_params(first, second_authority, "membership")

    invalid_lists = [
      {[foreign_authority.event.event_id], "activation_authority_refused"},
      {["aev_unknown"], "activation_authority_refused"},
      {[first_authority.event.event_id, first_authority.event.event_id],
       "invalid_activation_payload"},
      {[second_authority.event.event_id, first_authority.event.event_id],
       "activation_authority_refused"}
    ]

    Enum.with_index(invalid_lists, 1)
    |> Enum.each(fn {{ids, expected_code}, index} ->
      before = counts(db)

      refusal =
        apply(
          db,
          "activation-attempt",
          {:session, "holder"},
          base
          |> Map.put(:authority_event_ids, ids)
          |> Map.put(:idempotency_key, "invalid-membership-#{index}")
        )

      assert refusal.code == expected_code

      assert counts(db) == before
    end)

    attempted =
      apply(
        db,
        "activation-attempt",
        {:session, "holder"},
        base
        |> Map.put(:authority_event_ids, [
          first_authority.event.event_id,
          second_authority.event.event_id
        ])
        |> Map.put(:idempotency_key, "membership-attempt")
      )

    before = counts(db)

    assert %{code: "activation_transition_refused"} =
             apply(db, "activation-authority", {:user, "work_owner"}, %{
               activation_id: first.event.activation_id,
               predecessor_event_id: attempted.event.event_id,
               authorizer: identity("late"),
               basis: resource("late", @sha),
               decision: code("late"),
               idempotency_key: "late-authority"
             })

    assert %{code: "activation_transition_refused"} =
             apply(
               db,
               "activation-attempt",
               {:session, "holder"},
               base
               |> Map.put(:predecessor_event_id, attempted.event.event_id)
               |> Map.put(:idempotency_key, "second-attempt")
             )

    assert counts(db) == before
  end

  test "A-12 acknowledgement matrix rejects every unowned or undelivered wake", %{db: db} do
    {_declared, _authority, pending} = attempted_stream(db, "ack-pending")
    before = counts(db)

    assert %{code: "activation_notice_refused"} =
             ack(db, pending, pending.event.notice_wake_id, "pending")

    assert counts(db) == before

    {_declared, _authority, unrelated} = attempted_stream(db, "ack-unrelated")
    unrelated_wake = unrelated_wake(db, "ack-unrelated")

    {:ok, _} =
      DB.query(db, "UPDATE wakes SET state='fired',firedAt=10 WHERE wakeId=?1", [unrelated_wake])

    before = counts(db)
    assert %{code: "activation_notice_refused"} = ack(db, unrelated, unrelated_wake, "unrelated")
    assert counts(db) == before

    {_declared, _authority, nonowner} = attempted_stream(db, "ack-nonowner")

    {:ok, _} =
      DB.query(db, "UPDATE wakes SET state='fired',firedAt=11 WHERE wakeId=?1", [
        nonowner.event.notice_wake_id
      ])

    before = counts(db)

    assert %{code: "not_found"} =
             ack(db, nonowner, nonowner.event.notice_wake_id, "nonowner", {:user, "other"})

    assert counts(db) == before

    {_declared, _authority, canceled} = attempted_stream(db, "ack-canceled")

    cancel_wake(db, canceled.event.notice_wake_id, "ack-canceled")

    before = counts(db)

    assert %{code: "activation_notice_refused"} =
             ack(db, canceled, canceled.event.notice_wake_id, "canceled")

    assert counts(db) == before

    {_declared, _authority, delivered} = attempted_stream(db, "ack-delivered")

    {:ok, _} =
      DB.query(db, "UPDATE wakes SET state='fired',firedAt=13 WHERE wakeId=?1", [
        delivered.event.notice_wake_id
      ])

    accepted = ack(db, delivered, delivered.event.notice_wake_id, "accepted")
    assert accepted.event.kind == "acknowledged"
    before = counts(db)

    assert %{code: "activation_notice_refused"} =
             apply(db, "activation-ack", {:user, "holder_owner"}, %{
               activation_id: delivered.event.activation_id,
               predecessor_event_id: accepted.event.event_id,
               noticed_event_id: delivered.event.event_id,
               acknowledged_wake_id: delivered.event.notice_wake_id,
               idempotency_key: "ack-duplicate"
             })

    assert counts(db) == before
  end

  test "A-13 withdrawal commits one notice before attempt and refuses after attempt", %{db: db} do
    declaration = declared(db, "withdraw-success")
    before = counts(db)

    withdrawn =
      apply(db, "activation-withdraw", {:user, "work_owner"}, %{
        activation_id: declaration.event.activation_id,
        predecessor_event_id: declaration.event.event_id,
        reason: code("withdrawn"),
        basis: resource("withdraw-basis", @sha),
        idempotency_key: "withdraw-success"
      })

    assert withdrawn.state == "withdrawn"
    assert counts(db) == %{events: before.events + 1, wakes: before.wakes + 1}

    {_declared, _authority, attempted} = attempted_stream(db, "withdraw-attempted")
    before = counts(db)

    assert %{code: "activation_transition_refused"} =
             apply(db, "activation-withdraw", {:user, "work_owner"}, %{
               activation_id: attempted.event.activation_id,
               predecessor_event_id: attempted.event.event_id,
               reason: code("too-late"),
               basis: resource("too-late", @sha),
               idempotency_key: "withdraw-too-late"
             })

    assert counts(db) == before
  end

  test "A-15 reconciliation matrix rejects determinate, absent, foreign, and repeated observations",
       %{db: db} do
    {_declared, _authority, no_observation} = attempted_stream(db, "reconcile-none")
    before = counts(db)

    assert %{code: "activation_transition_refused"} =
             reconcile(db, no_observation, "aev_missing", "reconcile-none")

    assert counts(db) == before

    {_declared, _authority, determinate_attempt} = attempted_stream(db, "reconcile-determinate")
    determinate = observe(db, determinate_attempt, "determinate", "reconcile-determinate")
    before = counts(db)

    assert %{code: "activation_transition_refused"} =
             reconcile(db, determinate, determinate.event.event_id, "reconcile-determinate")

    assert counts(db) == before

    {_declared, _authority, first_attempt} = attempted_stream(db, "reconcile-first")
    first_observed = observe(db, first_attempt, "indeterminate", "reconcile-first")
    {_declared, _authority, other_attempt} = attempted_stream(db, "reconcile-other")
    other_observed = observe(db, other_attempt, "indeterminate", "reconcile-other")
    before = counts(db)

    assert %{code: "activation_transition_refused"} =
             reconcile(db, first_observed, other_observed.event.event_id, "reconcile-foreign")

    assert counts(db) == before

    accepted = reconcile(db, first_observed, first_observed.event.event_id, "reconcile-accepted")
    before = counts(db)

    assert %{code: "activation_transition_refused"} =
             reconcile(db, accepted, first_observed.event.event_id, "reconcile-repeat")

    assert counts(db) == before
  end

  test "A-18 notice requeue matrix accepts one linked cancellation and rejects every other wake",
       %{db: db} do
    {_declared, _authority, canceled} = attempted_stream(db, "requeue-success")

    cancel_wake(db, canceled.event.notice_wake_id, "requeue-success")

    requeued = renotify(db, canceled, canceled.event.notice_wake_id, "success")
    assert requeued.event.kind == "notice-requeued"
    assert requeued.event.notice_wake_id != canceled.event.notice_wake_id
    before = counts(db)

    assert %{code: "activation_notice_refused"} =
             apply(db, "activation-renotify", {:user, "holder_owner"}, %{
               activation_id: canceled.event.activation_id,
               predecessor_event_id: requeued.event.event_id,
               noticed_event_id: canceled.event.event_id,
               replaces_wake_id: canceled.event.notice_wake_id,
               idempotency_key: "requeue-second"
             })

    assert counts(db) == before

    {_declared, _authority, hidden} = attempted_stream(db, "requeue-hidden")

    cancel_wake(db, hidden.event.notice_wake_id, "requeue-hidden")

    before = counts(db)

    assert %{code: "not_found"} =
             renotify(db, hidden, hidden.event.notice_wake_id, "hidden", {:user, "other"})

    assert counts(db) == before

    for {state, suffix} <- [{"pending", "pending"}, {"fired", "fired"}] do
      {_declared, _authority, noticed} = attempted_stream(db, "requeue-#{suffix}")

      if state == "fired" do
        {:ok, _} =
          DB.query(db, "UPDATE wakes SET state='fired',firedAt=22 WHERE wakeId=?1", [
            noticed.event.notice_wake_id
          ])
      end

      before = counts(db)

      assert %{code: "activation_notice_refused"} =
               renotify(db, noticed, noticed.event.notice_wake_id, suffix)

      assert counts(db) == before
    end

    {_declared, _authority, unrelated} = attempted_stream(db, "requeue-unrelated")
    unrelated_wake = unrelated_wake(db, "requeue-unrelated")

    cancel_wake(db, unrelated_wake, "requeue-unrelated")

    before = counts(db)

    assert %{code: "activation_notice_refused"} =
             renotify(db, unrelated, unrelated_wake, "unrelated")

    assert counts(db) == before

    {_declared, _authority, acknowledged} = attempted_stream(db, "requeue-acknowledged")
    cancel_wake(db, acknowledged.event.notice_wake_id, "requeue-acknowledged")
    replacement = renotify(db, acknowledged, acknowledged.event.notice_wake_id, "before-ack")

    {:ok, _} =
      DB.query(db, "UPDATE wakes SET state='fired',firedAt=24 WHERE wakeId=?1", [
        replacement.event.notice_wake_id
      ])

    acked =
      apply(db, "activation-ack", {:user, "holder_owner"}, %{
        activation_id: acknowledged.event.activation_id,
        predecessor_event_id: replacement.event.event_id,
        noticed_event_id: acknowledged.event.event_id,
        acknowledged_wake_id: replacement.event.notice_wake_id,
        idempotency_key: "ack-before-requeue"
      })

    before = counts(db)

    assert %{code: "activation_notice_refused"} =
             apply(db, "activation-renotify", {:user, "holder_owner"}, %{
               activation_id: acknowledged.event.activation_id,
               predecessor_event_id: acked.event.event_id,
               noticed_event_id: acknowledged.event.event_id,
               replaces_wake_id: acknowledged.event.notice_wake_id,
               idempotency_key: "requeue-after-ack"
             })

    assert counts(db) == before
  end

  test "A-23 protected status and list expose rows only to the complete reader class", %{db: db} do
    declaration = declared(db, "reader-matrix")

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET ownerUserId='work_owner' WHERE sessionKey='filer-holder'")

    authority =
      apply(db, "activation-authority", {:session, "filer-holder"}, %{
        activation_id: declaration.event.activation_id,
        predecessor_event_id: declaration.event.event_id,
        actor_assignment_id: "asg_actor",
        authorizer: identity("reader-authorizer"),
        basis: resource("reader-basis", @sha),
        decision: code("reader-decision"),
        idempotency_key: "reader-authority"
      })

    assert authority.event.kind == "authority-attached"

    {:ok, _} =
      DB.query(
        db,
        "UPDATE sessions SET ownerUserId='filer_owner' WHERE sessionKey='filer-holder'"
      )

    {:ok, _} =
      DB.query(db, "UPDATE assignments SET holderKey='named-holder' WHERE id='asg_actor'")

    readers = [
      {:user, "holder_owner"},
      {:user, "work_owner"},
      {:session, "holder"},
      {:session, "named-holder"},
      {:session, "filer-holder"},
      {:user, "admin"}
    ]

    Enum.each(readers, fn principal ->
      assert %{activation_id: id, events: events} =
               apply(db, "activation-status", principal, %{
                 activation_id: declaration.event.activation_id
               })

      assert id == declaration.event.activation_id
      assert Enum.map(events, & &1.kind) == ~w(declared authority-attached)

      assert %{count: 1, activations: [%{activation_id: ^id}]} =
               apply(db, "activations", principal, %{work_item_id: "wi_matrix"})
    end)

    assert %{code: "not_found"} =
             apply(db, "activation-status", {:user, "other"}, %{
               activation_id: declaration.event.activation_id
             })

    assert %{count: 0, activations: []} =
             apply(db, "activations", {:user, "other"}, %{work_item_id: "wi_matrix"})

    before = counts(db)

    assert %{code: "not_found"} =
             apply(db, "activation-authority", {:user, "other"}, %{
               activation_id: declaration.event.activation_id,
               predecessor_event_id: authority.event.event_id,
               authorizer: identity("rejected-filer"),
               basis: resource("rejected-filer", @sha),
               decision: code("rejected-filer"),
               idempotency_key: "rejected-filer"
             })

    assert counts(db) == before

    assert %{code: "not_found"} =
             apply(db, "activation-status", {:user, "other"}, %{
               activation_id: declaration.event.activation_id
             })
  end

  test "A-24 redacts distinctive domain bytes from event logs, traces, wakes, and denials",
       %{db: db} do
    handlers = Gateway.handlers(%{db: db})
    Rules.load!(System.tmp_dir!(), Map.keys(handlers))
    secret = "distinctive-secret-7d2e"

    declared =
      dispatch(db, handlers, "activation-declare", {:session, "holder"}, %{
        root_assignment_id: "asg_matrix",
        owner_user_id: "holder_owner",
        domain: "distinctive.domain",
        correlation_key: "#{secret}-correlation",
        prepared_input: resource("#{secret}-input", @sha),
        target: resource("#{secret}-target", nil),
        idempotency_key: "privacy-declare"
      })

    authority =
      dispatch(db, handlers, "activation-authority", {:user, "work_owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: declared.event.event_id,
        authorizer: %{"namespace" => "distinctive.domain", "id" => "#{secret}-authorizer"},
        basis: %{
          "namespace" => "distinctive.domain",
          "id" => "#{secret}-basis",
          "sha256" => @sha
        },
        decision: %{"namespace" => "distinctive.domain", "code" => "#{secret}-decision"},
        idempotency_key: "privacy-authority"
      })

    attempted =
      dispatch(
        db,
        handlers,
        "activation-attempt",
        {:session, "holder"},
        attempt_params(declared, authority, "privacy")
        |> Map.put(:executor, %{
          "namespace" => "distinctive.domain",
          "id" => "#{secret}-executor"
        })
        |> Map.put(:external_attempt, %{
          "namespace" => "distinctive.domain",
          "id" => "#{secret}-external",
          "sha256" => nil
        })
      )

    observed =
      dispatch(db, handlers, "activation-observe", {:user, "holder_owner"}, %{
        activation_id: declared.event.activation_id,
        predecessor_event_id: attempted.event.event_id,
        attempt_event_id: attempted.event.event_id,
        certainty: "determinate",
        result: %{"namespace" => "distinctive.domain", "code" => "#{secret}-result"},
        target_state_after: resource("#{secret}-after", @sha2),
        outputs: [resource("#{secret}-output", nil)],
        evidence: resource("#{secret}-evidence", @sha),
        external_occurred_at_ms: 42,
        idempotency_key: "privacy-observe"
      })

    assert {:error, %{code: "not_found"}} =
             Dispatch.dispatch(db, handlers, %{
               verb: "activation-authority",
               origin: "user:other",
               principal: {:user, "other"},
               session_key: nil,
               params: %{
                 activation_id: declared.event.activation_id,
                 predecessor_event_id: observed.event.event_id,
                 authorizer: identity("#{secret}-denied"),
                 basis: resource("#{secret}-denied", @sha),
                 decision: code("#{secret}-denied"),
                 idempotency_key: "privacy-denial"
               }
             })

    assert {:ok, event_payloads} = DB.query(db, "SELECT payload FROM events")
    assert {:ok, wake_prompts} = DB.query(db, "SELECT prompt FROM wakes")

    for redacted <- [event_payloads, wake_prompts, Activations.trace_entries(db, "wi_matrix")] do
      refute inspect(redacted) =~ secret
    end

    status =
      apply(db, "activation-status", {:user, "holder_owner"}, %{
        activation_id: declared.event.activation_id
      })

    assert inspect(status) =~ secret
  end

  test "A-33 status and trace distinguish unresolved state and every durable notice state", %{
    db: db
  } do
    {_declared, _authority, pending} = attempted_stream(db, "operator-pending")

    pending_status =
      apply(db, "activation-status", {:user, "holder_owner"}, %{
        activation_id: pending.event.activation_id
      })

    assert pending_status.state == "attempted"

    assert [pending_notice] = pending_status.notices
    assert pending_notice.wake_states == %{pending.event.notice_wake_id => "pending"}

    {_declared, _authority, uncertain_attempt} = attempted_stream(db, "operator-uncertain")
    uncertain = observe(db, uncertain_attempt, "indeterminate", "operator-uncertain")

    cancel_wake(db, uncertain_attempt.event.notice_wake_id, "operator-uncertain")

    {:ok, _} =
      DB.query(db, "UPDATE wakes SET state='fired',firedAt=31 WHERE wakeId=?1", [
        uncertain.event.notice_wake_id
      ])

    status =
      apply(db, "activation-status", {:user, "holder_owner"}, %{
        activation_id: uncertain.event.activation_id
      })

    assert status.state == "needs-reconciliation"

    assert Enum.any?(status.notices, fn notice ->
             notice.wake_states[uncertain_attempt.event.notice_wake_id] == "canceled" and
               is_nil(notice.acknowledged_event_id)
           end)

    assert Enum.any?(status.notices, fn notice ->
             notice.wake_states[uncertain.event.notice_wake_id] == "fired" and
               is_nil(notice.acknowledged_event_id)
           end)

    trace = Activations.trace_entries(db, "wi_matrix")
    assert Enum.any?(trace, &(&1.kind == "attempted" and &1.noticeState == "pending"))
    assert Enum.any?(trace, &(&1.kind == "attempted" and &1.noticeState == "canceled"))
    assert Enum.any?(trace, &(&1.kind == "observed" and &1.noticeState == "fired"))
  end

  defp event_case(_db, "activation-declare" = verb, suffix) do
    %{
      verb: verb,
      principal: {:session, "holder"},
      params: declare(suffix),
      required: :root_assignment_id
    }
  end

  defp event_case(db, "activation-authority" = verb, suffix) do
    declaration = declared(db, "#{suffix}-authority")

    %{
      verb: verb,
      principal: {:user, "work_owner"},
      required: :activation_id,
      params: %{
        activation_id: declaration.event.activation_id,
        predecessor_event_id: declaration.event.event_id,
        authorizer: identity("authorizer-#{suffix}"),
        basis: resource("basis-#{suffix}", @sha),
        decision: code("decision-#{suffix}"),
        idempotency_key: "authority-#{suffix}"
      }
    }
  end

  defp event_case(db, "activation-attempt" = verb, suffix) do
    {declaration, authority} = authority_stream(db, "#{suffix}-attempt")

    %{
      verb: verb,
      principal: {:session, "holder"},
      params: attempt_params(declaration, authority, suffix),
      required: :activation_id
    }
  end

  defp event_case(db, "activation-observe" = verb, suffix) do
    {_declaration, _authority, attempted} = attempted_stream(db, "#{suffix}-observe")

    %{
      verb: verb,
      principal: {:user, "holder_owner"},
      params: observe_params(attempted, "determinate", suffix),
      required: :activation_id
    }
  end

  defp event_case(db, "activation-reconcile" = verb, suffix) do
    {_declaration, _authority, attempted} = attempted_stream(db, "#{suffix}-reconcile")
    observed = observe(db, attempted, "indeterminate", "#{suffix}-reconcile")

    %{
      verb: verb,
      principal: {:user, "holder_owner"},
      params: reconcile_params(observed, observed.event.event_id, suffix),
      required: :activation_id
    }
  end

  defp event_case(db, "activation-withdraw" = verb, suffix) do
    declaration = declared(db, "#{suffix}-withdraw")

    %{
      verb: verb,
      principal: {:user, "work_owner"},
      required: :activation_id,
      params: %{
        activation_id: declaration.event.activation_id,
        predecessor_event_id: declaration.event.event_id,
        reason: code("reason-#{suffix}"),
        basis: resource("basis-#{suffix}", @sha),
        idempotency_key: "withdraw-#{suffix}"
      }
    }
  end

  defp event_case(db, "activation-renotify" = verb, suffix) do
    {_declaration, _authority, attempted} = attempted_stream(db, "#{suffix}-renotify")
    cancel_wake(db, attempted.event.notice_wake_id, "#{suffix}-renotify")

    %{
      verb: verb,
      principal: {:user, "holder_owner"},
      required: :activation_id,
      params: %{
        activation_id: attempted.event.activation_id,
        predecessor_event_id: attempted.event.event_id,
        noticed_event_id: attempted.event.event_id,
        replaces_wake_id: attempted.event.notice_wake_id,
        idempotency_key: "renotify-#{suffix}"
      }
    }
  end

  defp event_case(db, "activation-ack" = verb, suffix) do
    {_declaration, _authority, attempted} = attempted_stream(db, "#{suffix}-ack")

    {:ok, _} =
      DB.query(db, "UPDATE wakes SET state='fired',firedAt=3 WHERE wakeId=?1", [
        attempted.event.notice_wake_id
      ])

    %{
      verb: verb,
      principal: {:user, "holder_owner"},
      required: :activation_id,
      params: %{
        activation_id: attempted.event.activation_id,
        predecessor_event_id: attempted.event.event_id,
        noticed_event_id: attempted.event.event_id,
        acknowledged_wake_id: attempted.event.notice_wake_id,
        idempotency_key: "ack-#{suffix}"
      }
    }
  end

  defp apply(db, verb, principal, params) do
    Activations.handle(db, verb, %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      params: params
    })
  end

  defp dispatch(db, handlers, verb, principal, params) do
    assert {:ok, result} =
             Dispatch.dispatch(db, handlers, %{
               verb: verb,
               origin: origin(principal),
               principal: principal,
               session_key: nil,
               params: params
             })

    result
  end

  defp declare(suffix) do
    %{
      root_assignment_id: "asg_matrix",
      owner_user_id: "holder_owner",
      domain: "example",
      correlation_key: "correlation-#{suffix}",
      prepared_input: resource("input-#{suffix}", @sha),
      target: resource("target-#{suffix}", nil),
      idempotency_key: "declare-#{suffix}"
    }
  end

  defp declared(db, suffix),
    do: apply(db, "activation-declare", {:session, "holder"}, declare(suffix))

  defp authority(db, previous, suffix) do
    activation_id = previous.event.activation_id

    apply(db, "activation-authority", {:user, "work_owner"}, %{
      activation_id: activation_id,
      predecessor_event_id: previous.event.event_id,
      authorizer: identity("authorizer-#{suffix}"),
      basis: resource("basis-#{suffix}", @sha),
      decision: code("decision-#{suffix}"),
      idempotency_key: "authority-#{suffix}"
    })
  end

  defp authority_stream(db, suffix) do
    declaration = declared(db, suffix)
    {declaration, authority(db, declaration, suffix)}
  end

  defp attempted_stream(db, suffix) do
    {declaration, authority} = authority_stream(db, suffix)

    attempted =
      apply(
        db,
        "activation-attempt",
        {:session, "holder"},
        attempt_params(declaration, authority, suffix)
      )

    {declaration, authority, attempted}
  end

  defp attempt_params(declaration, authority, suffix) do
    %{
      activation_id: declaration.event.activation_id,
      predecessor_event_id: authority.event.event_id,
      actor_assignment_id: "asg_matrix",
      authority_event_ids: [authority.event.event_id],
      executor: identity("executor-#{suffix}"),
      external_attempt: resource("attempt-#{suffix}", nil),
      target_state_before: nil,
      idempotency_key: "attempt-#{suffix}"
    }
  end

  defp observe(db, attempted, certainty, suffix) do
    apply(
      db,
      "activation-observe",
      {:user, "holder_owner"},
      observe_params(attempted, certainty, suffix)
    )
  end

  defp observe_params(attempted, certainty, suffix) do
    %{
      activation_id: attempted.event.activation_id,
      predecessor_event_id: attempted.event.event_id,
      attempt_event_id: attempted.event.event_id,
      certainty: certainty,
      result: code("result-#{suffix}"),
      target_state_after: resource("after-#{suffix}", @sha2),
      outputs: [resource("output-#{suffix}", nil)],
      evidence: resource("evidence-#{suffix}", @sha),
      external_occurred_at_ms: 42,
      idempotency_key: "observe-#{suffix}"
    }
  end

  defp reconcile(db, previous, observed_event_id, suffix) do
    apply(
      db,
      "activation-reconcile",
      {:user, "holder_owner"},
      reconcile_params(previous, observed_event_id, suffix)
    )
  end

  defp reconcile_params(previous, observed_event_id, suffix) do
    %{
      activation_id: previous.event.activation_id,
      predecessor_event_id: previous.event.event_id,
      observed_event_id: observed_event_id,
      certainty: "determinate",
      result: code("reconciled-#{suffix}"),
      target_state_after: resource("reconciled-after-#{suffix}", @sha2),
      outputs: [],
      evidence: resource("reconciled-evidence-#{suffix}", @sha),
      external_occurred_at_ms: 43,
      idempotency_key: "reconcile-#{suffix}"
    }
  end

  defp ack(db, attempted, wake_id, suffix, principal \\ {:user, "holder_owner"}) do
    apply(db, "activation-ack", principal, %{
      activation_id: attempted.event.activation_id,
      predecessor_event_id: attempted.event.event_id,
      noticed_event_id: attempted.event.event_id,
      acknowledged_wake_id: wake_id,
      idempotency_key: "ack-#{suffix}"
    })
  end

  defp renotify(db, attempted, wake_id, suffix, principal \\ {:user, "holder_owner"}) do
    apply(db, "activation-renotify", principal, %{
      activation_id: attempted.event.activation_id,
      predecessor_event_id: attempted.event.event_id,
      noticed_event_id: attempted.event.event_id,
      replaces_wake_id: wake_id,
      idempotency_key: "renotify-#{suffix}"
    })
  end

  defp cancel_wake(db, wake_id, suffix) do
    liveness =
      Wakes.schedule(db, %{
        session_key: Org.personal_session_key("holder_owner"),
        origin: "process:tightbeam",
        prompt: "cancellation liveness #{suffix}",
        due_at: System.system_time(:millisecond) + 60_000,
        work_item_id: "wi_matrix",
        assignment_id: "asg_matrix"
      })

    assert {:ok, true} =
             DB.transaction(db, fn txn ->
               Wakes.cancel_in_txn(txn, %{
                 wake_id: wake_id,
                 requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
                 reason_kind: "consumer_unavailable",
                 causal_source: %{kind: "scheduler_delivery", id: wake_id},
                 outcome: %{
                   kind: "no_replacement",
                   liveness_trigger: %{kind: "pending_wake", id: liveness.wake_id}
                 }
               })
             end)

    :ok
  end

  defp unrelated_wake(db, suffix) do
    Wakes.schedule(db, %{
      session_key: Org.personal_session_key("holder_owner"),
      origin: "process:tightbeam",
      prompt: "unrelated #{suffix}",
      due_at: System.system_time(:millisecond) + 60_000,
      work_item_id: "wi_matrix",
      assignment_id: "asg_matrix"
    }).wake_id
  end

  defp counts(db) do
    {:ok, [[events]]} = DB.query(db, "SELECT COUNT(*) FROM activation_events")
    {:ok, [[wakes]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
    %{events: events, wakes: wakes}
  end

  defp identity(id), do: %{"namespace" => "example", "id" => id}
  defp code(value), do: %{"namespace" => "example", "code" => value}
  defp resource(id, sha), do: %{"namespace" => "example", "id" => id, "sha256" => sha}
  defp origin({:session, session}), do: "agent:" <> session
  defp origin({:user, user}), do: "user:" <> user

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
