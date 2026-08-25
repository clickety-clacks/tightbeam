defmodule Tightbeam.ActivationsTest do
  use ExUnit.Case, async: true

  alias Tightbeam.{Activations, DB, Schema}

  @sha String.duplicate("a", 64)

  test "fresh schema adds one exact inert activation store" do
    db = database("fresh")

    assert {:ok,
            [
              ["seq"],
              ["eventId"],
              ["activationId"],
              ["kind"],
              ["predecessorEventId"],
              ["rootAssignmentId"],
              ["workItemId"],
              ["actorAssignmentId"],
              ["bySession"],
              ["byUser"],
              ["idempotencyKey"],
              ["requestSha256"],
              ["payload"],
              ["noticeWakeId"],
              ["ts"]
            ]} =
             DB.query(db, "SELECT name FROM pragma_table_info('activation_events') ORDER BY cid")

    expected_indexes =
      Enum.map(
        ~w(
          activation_notice_requeue
          activation_one_acknowledgement
          activation_one_attempted
          activation_one_declared
          activation_one_observed
          activation_one_reconciled
          activation_one_withdrawn
          activation_session_idempotency
          activation_stream
          activation_user_idempotency
          activation_work_item
        ),
        &[&1]
      )

    assert {:ok, ^expected_indexes} =
             DB.query(
               db,
               "SELECT name FROM pragma_index_list('activation_events') WHERE name NOT LIKE 'sqlite_autoindex%' ORDER BY name"
             )

    assert Activations.kinds() ==
             ~w(declared authority-attached attempted observed reconciled withdrawn notice-requeued acknowledged)

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE type='table' AND name='production_deploy_facts'"
             )

    assert {:ok, [["coordination-fabric-v1-phase1-v5"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")
  end

  test "database constraints enforce the closed row identity and uniqueness shape" do
    db = database("constraints")
    seed_graph(db)

    assert :ok = insert_declaration(db, "aev_declared", "act_constraints", "key-one")

    assert {:error, _} =
             insert_event(db,
               event_id: "aev_second_declaration",
               activation_id: "act_constraints",
               kind: "declared",
               predecessor_event_id: nil,
               by_session: "root_session",
               idempotency_key: "key-two",
               payload: declared_payload("activation_owner")
             )

    assert :ok =
             insert_event(db,
               event_id: "aev_attempted",
               activation_id: "act_constraints",
               kind: "attempted",
               predecessor_event_id: "aev_declared",
               by_session: "actor_session",
               actor_assignment_id: "asg_actor",
               idempotency_key: "attempt-one",
               payload: attempted_payload()
             )

    assert {:error, _} =
             insert_event(db,
               event_id: "aev_second_attempt",
               activation_id: "act_constraints",
               kind: "attempted",
               predecessor_event_id: "aev_attempted",
               by_session: "actor_session",
               actor_assignment_id: "asg_actor",
               idempotency_key: "attempt-two",
               payload: attempted_payload()
             )

    assert {:error, _} =
             insert_event(db,
               event_id: "bad_event",
               activation_id: "act_other",
               kind: "declared",
               predecessor_event_id: nil,
               by_user: "filer_user",
               idempotency_key: "bad-prefix",
               payload: declared_payload("activation_owner")
             )

    assert {:error, _} =
             insert_event(db,
               event_id: "aev_bad_principal",
               activation_id: "act_other",
               kind: "declared",
               predecessor_event_id: nil,
               by_user: "filer_user",
               by_session: "filer_session",
               idempotency_key: "both-principals",
               payload: declared_payload("activation_owner")
             )

    assert {:error, _} =
             insert_event(db,
               event_id: "aev_bad_key",
               activation_id: "act_other",
               kind: "declared",
               predecessor_event_id: nil,
               by_user: "filer_user",
               idempotency_key: "has space",
               payload: declared_payload("activation_owner")
             )

    assert {:error, _} =
             insert_event(db,
               event_id: "aev_bad_digest",
               activation_id: "act_other",
               kind: "declared",
               predecessor_event_id: nil,
               by_user: "filer_user",
               idempotency_key: "bad-digest",
               request_sha256: String.duplicate("a", 63) <> "Z",
               payload: declared_payload("activation_owner")
             )
  end

  test "every event kind has a closed neutral payload" do
    payloads = valid_payloads()

    for {kind, payload} <- payloads do
      assert Activations.payload?(kind, payload), "expected valid #{kind} payload"

      [required_key | _] = Map.keys(payload)
      refute Activations.payload?(kind, Map.delete(payload, required_key))
      refute Activations.payload?(kind, Map.put(payload, "unexpected", true))
      refute Activations.payload?(kind, Map.put(payload, required_key, %{}))
    end

    refute Activations.payload?("unknown", %{})

    refute Activations.payload?(
             "declared",
             put_in(payloads["declared"]["preparedInput"]["sha256"], nil)
           )

    refute Activations.payload?(
             "authority-attached",
             put_in(payloads["authority-attached"]["basis"]["sha256"], nil)
           )

    refute Activations.payload?(
             "observed",
             put_in(payloads["observed"]["evidence"]["sha256"], nil)
           )

    refute Activations.payload?(
             "reconciled",
             put_in(payloads["reconciled"]["targetStateAfter"]["sha256"], nil)
           )

    refute Activations.payload?(
             "withdrawn",
             put_in(payloads["withdrawn"]["basis"]["sha256"], nil)
           )

    refute Activations.payload?(
             "attempted",
             Map.put(payloads["attempted"], "authorityEventIds", List.duplicate("aev_same", 2))
           )

    refute Activations.payload?(
             "attempted",
             Map.put(
               payloads["attempted"],
               "authorityEventIds",
               Enum.map(1..33, &"aev_#{&1}")
             )
           )

    refute Activations.payload?(
             "observed",
             Map.put(payloads["observed"], "externalOccurredAtMs", 9_223_372_036_854_775_808)
           )

    refute Activations.opaque_token?("has space")
    refute Activations.opaque_token?("has\ncontrol")
    refute Activations.opaque_token?(String.duplicate("a", 201), 200)
  end

  test "semantic request hashing uses RFC 8785 key order and rejects non-closed values" do
    semantic_request = %{"b" => [true, nil], "a" => 1}

    assert Activations.canonical_json!(semantic_request) == ~s({"a":1,"b":[true,null]})

    assert Activations.canonical_sha256!(semantic_request) ==
             "1cc69c7fa23616ca2ec3ee70d24390a6225c8832db8a4c814c7e0e7f942f8668"

    assert Activations.canonical_json!(%{"\u{FB33}" => 2, "\u{1F600}" => 1}) ==
             ~s({"😀":1,"דּ":2})

    assert_raise ArgumentError, fn -> Activations.canonical_json!(1.0) end
    assert_raise ArgumentError, fn -> Activations.canonical_json!(%{atom_key: 1}) end
    assert_raise ArgumentError, fn -> Activations.canonical_json!({:not, :json}) end
  end

  test "the internal read predicate implements every relation without identifier-only access" do
    db = database("access")
    seed_graph(db)

    assert :ok = insert_declaration(db, "aev_access_declared", "act_access", "access-declare")

    assert :ok =
             insert_event(db,
               event_id: "aev_access_authority",
               activation_id: "act_access",
               kind: "authority-attached",
               predecessor_event_id: "aev_access_declared",
               actor_assignment_id: "asg_actor",
               by_session: "filer_session",
               idempotency_key: "access-authority",
               payload: valid_payloads()["authority-attached"]
             )

    for principal <- [
          {:user, "activation_owner"},
          {:session, "activation_owner_session"},
          {:user, "work_owner"},
          {:session, "work_owner_session"},
          {:user, "root_owner"},
          {:session, "root_session"},
          {:user, "actor_owner"},
          {:session, "actor_session"},
          {:user, "filer_user"},
          {:session, "filer_session"},
          {:user, "admin"},
          {:session, "admin_session"}
        ] do
      assert Activations.readable?(db, "act_access", principal),
             "expected #{inspect(principal)} to have a named read relation"
    end

    refute Activations.readable?(db, "act_access", {:user, "unrelated"})
    refute Activations.readable?(db, "act_access", {:session, "unrelated_session"})
    refute Activations.readable?(db, "act_access", {:session, "root_owner_other_session"})
    refute Activations.readable?(db, "act_access", {:user, "filer_owner"})
    refute Activations.readable?(db, "act_missing", {:user, "admin"})
  end

  test "additive upgrade preserves old rows and synthesizes no activation events" do
    db = database("upgrade")
    seed_graph(db)
    :ok = DB.execute(db, "DROP TABLE activation_events")

    assert {:ok, before_users} = DB.query(db, "SELECT * FROM users ORDER BY userId")
    assert {:ok, before_items} = DB.query(db, "SELECT * FROM work_items ORDER BY id")

    assert :ok = Schema.ensure_all(db)

    assert {:ok, ^before_users} = DB.query(db, "SELECT * FROM users ORDER BY userId")
    assert {:ok, ^before_items} = DB.query(db, "SELECT * FROM work_items ORDER BY id")
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM activation_events")

    assert {:ok, [["coordination-fabric-v1-phase1-v5"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")
  end

  test "activation rows leave existing non-activation data readable at the unchanged stamp" do
    db = database("downgrade")
    seed_graph(db)
    assert :ok = insert_declaration(db, "aev_downgrade", "act_downgrade", "downgrade")

    assert {:ok, [["wi_activation", "Activation fixture", "work_owner", "open"]]} =
             DB.query(
               db,
               "SELECT id,title,ownerUserId,state FROM work_items WHERE id='wi_activation'"
             )

    assert {:ok, [["coordination-fabric-v1-phase1-v5"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM activation_events")
  end

  defp database(label) do
    db = String.to_atom("activation_#{label}_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    db
  end

  defp seed_graph(db) do
    :ok =
      DB.execute(db, """
      INSERT INTO users (userId, isAdmin, createdAt) VALUES
        ('activation_owner',0,1), ('work_owner',0,1), ('root_owner',0,1),
        ('actor_owner',0,1), ('filer_user',0,1), ('filer_owner',0,1),
        ('admin',1,1), ('unrelated',0,1);

      INSERT INTO sessions
        (sessionKey, displayName, kind, ownerUserId, origin, operationalParent,
         archetype, harness, provider, model, createdAt, updatedAt)
      VALUES
        ('activation_owner_session','activation owner','custom','activation_owner','user:activation_owner','activation_owner_session','default','claude','anthropic','claude-sonnet-5',1,1),
        ('work_owner_session','work owner','custom','work_owner','user:work_owner','work_owner_session','default','claude','anthropic','claude-sonnet-5',1,1),
        ('root_session','root holder','custom','root_owner','user:root_owner','root_session','default','claude','anthropic','claude-sonnet-5',1,1),
        ('root_owner_other_session','root non-holder','custom','root_owner','user:root_owner','root_owner_other_session','default','claude','anthropic','claude-sonnet-5',1,1),
        ('actor_session','actor holder','custom','actor_owner','user:actor_owner','actor_session','default','claude','anthropic','claude-sonnet-5',1,1),
        ('filer_session','event filer','custom','filer_owner','user:filer_owner','filer_session','default','claude','anthropic','claude-sonnet-5',1,1),
        ('admin_session','admin','custom','admin','user:admin','admin_session','default','claude','anthropic','claude-sonnet-5',1,1),
        ('unrelated_session','unrelated','custom','unrelated','user:unrelated','unrelated_session','default','claude','anthropic','claude-sonnet-5',1,1);

      INSERT INTO work_items (id,title,ownerUserId,state,createdByUser,createdAt)
      VALUES ('wi_activation','Activation fixture','work_owner','open','work_owner',1);

      INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,workItemId)
      VALUES
        ('asg_root','root activation work','root_session','work_owner',1,'wi_activation'),
        ('asg_actor','actor activation work','actor_session','work_owner',2,'wi_activation');
      """)
  end

  defp insert_declaration(db, event_id, activation_id, idempotency_key) do
    insert_event(db,
      event_id: event_id,
      activation_id: activation_id,
      kind: "declared",
      predecessor_event_id: nil,
      by_user: "filer_user",
      idempotency_key: idempotency_key,
      payload: declared_payload("activation_owner")
    )
  end

  defp insert_event(db, opts) do
    values =
      Keyword.merge(
        [
          actor_assignment_id: nil,
          by_session: nil,
          by_user: nil,
          request_sha256: @sha,
          ts: 1
        ],
        opts
      )

    case DB.query(
           db,
           """
           INSERT INTO activation_events
             (eventId,activationId,kind,predecessorEventId,rootAssignmentId,workItemId,
              actorAssignmentId,bySession,byUser,idempotencyKey,requestSha256,payload,ts)
           VALUES (?1,?2,?3,?4,'asg_root','wi_activation',?5,?6,?7,?8,?9,?10,?11)
           """,
           [
             values[:event_id],
             values[:activation_id],
             values[:kind],
             values[:predecessor_event_id],
             values[:actor_assignment_id],
             values[:by_session],
             values[:by_user],
             values[:idempotency_key],
             values[:request_sha256],
             JSON.encode!(values[:payload]),
             values[:ts]
           ]
         ) do
      {:ok, _rows} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp valid_payloads do
    %{
      "declared" => declared_payload("activation_owner"),
      "authority-attached" => %{
        "authorizer" => domain_identity(),
        "basis" => resource_ref("basis", @sha),
        "decision" => domain_code()
      },
      "attempted" => attempted_payload(),
      "observed" => %{
        "attemptEventId" => "aev_attempted",
        "certainty" => "indeterminate",
        "result" => domain_code(),
        "targetStateAfter" => resource_ref("target-after", @sha),
        "outputs" => [resource_ref("output", nil)],
        "evidence" => resource_ref("evidence", @sha),
        "externalOccurredAtMs" => nil
      },
      "reconciled" => %{
        "observedEventId" => "aev_observed",
        "certainty" => "irrecoverable",
        "result" => domain_code(),
        "targetStateAfter" => resource_ref("target-after", @sha),
        "outputs" => [],
        "evidence" => resource_ref("evidence", @sha),
        "externalOccurredAtMs" => 9_223_372_036_854_775_807
      },
      "withdrawn" => %{
        "reason" => domain_code(),
        "basis" => resource_ref("withdrawal-basis", @sha)
      },
      "notice-requeued" => %{
        "noticedEventId" => "aev_attempted",
        "replacesWakeId" => "w_canceled"
      },
      "acknowledged" => %{
        "noticedEventId" => "aev_attempted",
        "acknowledgedWakeId" => "w_fired"
      }
    }
  end

  defp declared_payload(owner_user_id) do
    %{
      "ownerUserId" => owner_user_id,
      "domain" => "neutral.v1",
      "correlationKey" => "correlation:1",
      "preparedInput" => resource_ref("prepared", @sha),
      "target" => resource_ref("target", nil),
      "prior" => nil
    }
  end

  defp attempted_payload do
    %{
      "authorityEventIds" => ["aev_authority"],
      "executor" => domain_identity(),
      "externalAttempt" => resource_ref("external-attempt", nil),
      "targetStateBefore" => resource_ref("target-before", @sha)
    }
  end

  defp resource_ref(id, digest),
    do: %{"namespace" => "neutral.v1", "id" => id, "sha256" => digest}

  defp domain_identity, do: %{"namespace" => "neutral.v1", "id" => "actor"}
  defp domain_code, do: %{"namespace" => "neutral.v1", "code" => "opaque"}
end
