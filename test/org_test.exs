defmodule Tightbeam.OrgTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  doctest Tightbeam.Org

  alias Tightbeam.{DB, NoticeBatcher, Org, Roles, Wakes}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = Tightbeam.Schema.ensure_all(name)
    %{db: name}
  end

  defp base(overrides \\ %{}) do
    Map.merge(
      %{
        display_name: "Main",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      },
      overrides
    )
  end

  test "create persists provenance, wire metadata, and boolean flags", %{db: db} do
    key = Org.personal_session_key("flynn")

    session =
      Org.create(db, base(%{session_key: key, kind: "main", is_built_in: true, adopted: true}))

    assert session.session_key == "agent:main:clawline:flynn:main"

    assert %{
             archetype: "default",
             identity_name: "default",
             overrides: nil,
             host: "testhost",
             provider: "anthropic",
             state: "active",
             is_built_in: true,
             adopted: true
           } = session

    assert Org.get(db, key).display_name == "Main"

    {:ok, rows} =
      DB.query(db, "SELECT isBuiltIn, adopted, state FROM sessions WHERE sessionKey = ?1", [key])

    assert rows == [[1, 1, "active"]]
  end

  test "overrides and derived identity names round-trip and active reconstruction ignores retired rows",
       %{
         db: db
       } do
    overrides = %{"skills_add" => ["review"], "guidance_extra" => "Be concise."}

    session =
      Org.create(
        db,
        base(%{
          session_key: "overridden",
          overrides: overrides,
          identity_name: "default--0123456789abcdef"
        })
      )

    assert session.overrides == overrides
    assert session.identity_name == "default--0123456789abcdef"
    assert Org.active_by_identity_name(db, session.identity_name).session_key == "overridden"

    {:ok, [[stored]]} =
      DB.query(db, "SELECT overrides FROM sessions WHERE sessionKey = 'overridden'")

    assert JSON.decode!(stored) == overrides

    updated = Org.set_identity(db, "overridden", nil, "default")
    assert updated.overrides == nil
    assert updated.identity_name == "default"
    refute Org.identity_name_exists?(db, "default--0123456789abcdef")

    retired =
      Org.create(
        db,
        base(%{session_key: "retired-id", identity_name: "default--fedcba9876543210"})
      )
      |> then(&Org.retire(db, &1.session_key, "user:flynn", 1_000))

    assert retired.state == "retired"
    assert Org.active_by_identity_name(db, retired.identity_name) == nil
    assert Org.identity_name_exists?(db, retired.identity_name)
  end

  test "custom keys use the TypeScript s_ suffix format", %{db: db} do
    session = Org.create(db, base())
    assert session.session_key =~ ~r/^agent:main:clawline:flynn:main s_[0-9a-f]{8}$/
  end

  test "organization settings put and get through the KV seam", %{db: db} do
    assert Org.get_setting(db, "default-archetype") == nil
    assert :ok = Org.put_setting(db, "default-archetype", "coder")
    assert Org.get_setting(db, "default-archetype") == "coder"

    assert :ok = Org.put_setting(db, "default-archetype", "reviewer")
    assert Org.get_setting(db, "default-archetype") == "reviewer"

    assert {:ok, [["default-archetype", "reviewer", updated_at]]} =
             DB.query(db, "SELECT key, value, updatedAt FROM org_settings")

    assert is_integer(updated_at)
  end

  test "session CLI tokens are unique, active-only, and indexed", %{db: db} do
    first = Org.create(db, base(%{session_key: "token-1"}))
    second = Org.create(db, base(%{session_key: "token-2"}))

    assert first.cli_token =~ ~r/^tbs_[A-Za-z0-9_-]{32}$/
    assert second.cli_token =~ ~r/^tbs_[A-Za-z0-9_-]{32}$/
    refute first.cli_token == second.cli_token
    assert Org.by_cli_token(db, first.cli_token).session_key == first.session_key
    assert Org.by_cli_token(db, "tbs_unknown") == nil

    Org.retire(db, first.session_key, "user:flynn", 1_000)
    assert Org.by_cli_token(db, first.cli_token) == nil

    {:ok, [[index_sql]]} =
      DB.query(
        db,
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'sessions_cli_token'"
      )

    assert index_sql =~ "UNIQUE INDEX"
  end

  test "list scopes active sessions by owner unless admin and preserves ordering", %{db: db} do
    Org.create(db, base(%{session_key: "k2", order_index: 2}))
    Org.create(db, base(%{session_key: "k1", order_index: 1}))
    Org.create(db, base(%{session_key: "sam", owner_user_id: "sam", origin: "user:sam"}))

    assert Enum.map(Org.list_for_user(db, "flynn", false), & &1.session_key) == ["k1", "k2"]
    assert length(Org.list_for_user(db, "flynn", true)) == 3

    retired = Org.retire(db, "k1", "user:flynn", 1_000)
    assert retired.state == "retired"
    assert Enum.map(Org.list_for_user(db, "flynn", false), & &1.session_key) == ["k2"]

    {:ok, [["retired"]]} = DB.query(db, "SELECT state FROM sessions WHERE sessionKey = 'k1'")
  end

  test "retirement cancels gated direct and role targets, replaces the role, and preserves ungated delivery",
       %{db: db} do
    main_key = Org.personal_session_key("flynn")
    Org.create(db, base(%{session_key: main_key, kind: "main", is_built_in: true}))
    Org.create(db, base(%{session_key: "retiring"}))
    Roles.create!(db, "reviewer", "flynn", "retiring")

    direct =
      Wakes.schedule(db, %{
        session_key: "retiring",
        origin: "user:flynn",
        prompt: "direct",
        due_at: 9_000
      })

    role =
      Wakes.schedule(db, %{
        session_key: "retiring",
        target_role: "reviewer",
        origin: "user:flynn",
        prompt: "role",
        due_at: 9_001
      })

    ungated =
      Wakes.schedule(db, %{
        session_key: "retiring",
        origin: "user:flynn",
        prompt: "ungated",
        due_at: 9_002,
        target_gate: 0
      })

    encoded_attachments = "[ {\"name\": \"retained.png\", \"url\": \"attachment://original\"} ]"

    identity = %{
      "targetSessionKey" => "retiring",
      "deviceId" => "original-device",
      "clientMessageId" => "original-client",
      "sourceWakeId" => role.wake_id,
      "payloadSha256" => Base.encode16(:crypto.hash(:sha256, role.prompt), case: :lower),
      "createdAt" => role.created_at
    }

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE wakes SET sourceAttachments=?2,sourceClientIdentity=?3 WHERE wakeId=?1",
               [role.wake_id, encoded_attachments, JSON.encode!(identity)]
             )

    assert {:ok, [[address, scope]]} =
             DB.query(
               db,
               "SELECT sourceAddress,sourceVisibilityScope FROM wakes WHERE wakeId=?1",
               [role.wake_id]
             )

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)
    assert %{state: "canceled"} = Wakes.get(db, direct.wake_id)

    assert %{
             requester: "tightbeam:retirement",
             reason: "target_retired",
             source_kind: "session_transition",
             source_id: "retiring",
             outcome: "no_replacement",
             replacement_wake_id: nil,
             work_impact: "no_linked_work",
             action_needed: 0
           } = cancellation(db, direct.wake_id)

    assert %{state: "canceled"} = Wakes.get(db, role.wake_id)

    assert %{
             requester: "tightbeam:retirement",
             reason: "target_retired",
             outcome: "replacement",
             replacement_wake_id: replacement_wake_id
           } = cancellation(db, role.wake_id)

    assert %{
             state: "pending",
             session_key: ^main_key,
             target_role: "reviewer",
             prompt: "role",
             due_at: 9_001
           } = Wakes.get(db, replacement_wake_id)

    assert {:ok, [[^encoded_attachments, ^address, ^scope, nil]]} =
             DB.query(
               db,
               "SELECT sourceAttachments,sourceAddress,sourceVisibilityScope,sourceClientIdentity FROM wakes WHERE wakeId=?1",
               [replacement_wake_id]
             )

    assert {:ok, [[^encoded_attachments, original_identity]]} =
             DB.query(
               db,
               "SELECT sourceAttachments,sourceClientIdentity FROM wakes WHERE wakeId=?1",
               [role.wake_id]
             )

    assert JSON.decode!(original_identity) == identity

    assert {:ok, [[role_id]]} =
             DB.query(
               db,
               "SELECT wakeId FROM wakes WHERE json_extract(sourceClientIdentity,'$.clientMessageId')='original-client'"
             )

    assert role_id == role.wake_id

    assert {:ok, retained} =
             DB.transaction(
               db,
               &NoticeBatcher.delivery_attachments_in_txn(&1, replacement_wake_id)
             )

    assert retained == JSON.decode!(encoded_attachments)

    assert %{state: "pending"} = Wakes.get(db, ungated.wake_id)
    assert cancellation(db, ungated.wake_id) == nil

    {:ok, [[wake_count]]} = DB.query(db, "SELECT count(*) FROM wakes")
    {:ok, [[cancellation_count]]} = DB.query(db, "SELECT count(*) FROM wake_cancellations")

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)
    assert {:ok, [[^wake_count]]} = DB.query(db, "SELECT count(*) FROM wakes")

    assert {:ok, [[^cancellation_count]]} =
             DB.query(db, "SELECT count(*) FROM wake_cancellations")
  end

  test "retirement before readiness preserves one delivery path on the replacement", %{
    db: db
  } do
    main_key = Org.personal_session_key("flynn")
    ensure_legacy_main(db)
    Org.create(db, base(%{session_key: "retiring"}))
    Roles.create!(db, "reviewer", "flynn", "retiring")
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO turns(seq,sessionKey,messageId,origin,prompt,status,createdAt,startedAt) VALUES (1,?1,'busy-main','user:flynn','active turn','running',1,1)",
               [main_key]
             )

    original =
      Wakes.schedule(db, %{
        session_key: "retiring",
        target_role: "reviewer",
        origin: "process:tightbeam",
        creator_session_key: "agent:sender",
        prompt: "selected source survives retirement",
        due_at: 0,
        class: "fyi"
      })

    assert {:deferred, %{code: "recipient_readiness_required"}} =
             NoticeBatcher.enqueue_or_recover(
               db,
               original.wake_id,
               NoticeBatcher.policy_ref(original.wake_id)
             )

    assert original.delivery_rule == NoticeBatcher.rule()
    assert NoticeBatcher.source_refs(db, original.wake_id) == []
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM notice_batches")

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)

    assert %{
             requester: "tightbeam:retirement",
             reason: "target_retired",
             source_kind: "session_transition",
             source_id: "retiring",
             outcome: "replacement",
             replacement_wake_id: replacement_wake_id
           } = cancellation(db, original.wake_id)

    assert %{state: "canceled", prompt: original_prompt} = Wakes.get(db, original.wake_id)
    assert original_prompt == original.prompt
    replacement = Wakes.get(db, replacement_wake_id)
    assert replacement.state == "pending"
    assert replacement.session_key == main_key
    assert replacement.target_role == "reviewer"
    assert replacement.prompt == original.prompt
    assert replacement.origin == original.origin
    assert replacement.creator_session_key == original.creator_session_key
    assert replacement.delivery_rule == NoticeBatcher.rule()
    assert replacement.due_at == original.due_at
    assert NoticeBatcher.source_refs(db, original.wake_id) == []
    assert NoticeBatcher.source_refs(db, replacement_wake_id) == []

    # The replacement is still its own editable source while Main is busy.
    assert NoticeBatcher.recover(db) == []
    assert Wakes.get(db, replacement_wake_id).state == "pending"
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM notice_batches")
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM turns")

    assert {:ok, _} =
             DB.query(db, "UPDATE turns SET status='delivered',endedAt=2 WHERE seq=1")

    assert [carrier_id] = Wakes.materialize_digests(db)
    assert Enum.map(Wakes.digest_members(db, carrier_id), & &1.wake_id) == [replacement_wake_id]
    assert Wakes.get(db, carrier_id).state == "fired"
    assert Wakes.get(db, replacement_wake_id).state == "fired"
    assert Wakes.get(db, original.wake_id).state == "canceled"

    assert [%{member_state: "included", delivery_wake_id: ^carrier_id, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(db, replacement_wake_id)

    assert NoticeBatcher.source_refs(db, original.wake_id) == []

    assert {:ok, [[^main_key, "queued", delivered_prompt]]} =
             DB.query(db, "SELECT sessionKey,status,prompt FROM turns WHERE wakeId=?1", [
               carrier_id
             ])

    assert delivered_prompt =~ original.prompt
    assert Wakes.materialize_digests(db) == []
    assert NoticeBatcher.recover(db) == []

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE digest=1 AND wakeId=?1", [carrier_id])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM turns WHERE wakeId=?1", [carrier_id])
  end

  test "retirement preserves sealed historical bytes but regroups an unclaimed source", %{
    db: db
  } do
    main_key = Org.personal_session_key("flynn")
    ensure_legacy_main(db)
    Org.create(db, base(%{session_key: "retiring"}))
    Roles.create!(db, "reviewer", "flynn", "retiring")
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})

    original =
      Wakes.schedule(db, %{
        session_key: "retiring",
        target_role: "reviewer",
        origin: "process:tightbeam",
        creator_session_key: "agent:sender",
        prompt: "historical sealed retirement source",
        due_at: 0,
        class: "fyi"
      })

    assert {:ok, [[address, scope]]} =
             DB.query(
               db,
               "SELECT sourceAddress,sourceVisibilityScope FROM wakes WHERE wakeId=?1",
               [
                 original.wake_id
               ]
             )

    # Captured predecessor transport is historical input, not normal seal/arm admission.
    batch_id = "historical-sealed:" <> original.wake_id
    envelope = "historical sealed bytes\n" <> original.prompt
    envelope_sha256 = Base.encode16(:crypto.hash(:sha256, envelope), case: :lower)

    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO notice_batches(batchId,recipientAddress,sessionKey,targetRole,visibilityScope,
                 policyRevision,state,dueAt,openedAt,sealedAt,releaseCause,deliveryToken,envelope,
                 envelopeSha256,memberCount,renderedBytes)
               VALUES(?1,?2,'retiring','reviewer',?3,'captured-predecessor','sealed',0,1,1,'idle',?4,?5,?6,1,?7)
               """,
               [
                 batch_id,
                 address,
                 scope,
                 "historical-token:" <> original.wake_id,
                 envelope,
                 envelope_sha256,
                 byte_size(envelope)
               ]
             )

    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO notice_batch_members(memberId,batchId,sourceWakeId,policyRef,recipientAddress,
                 visibilityScope,publicationSeq,policyRevision,senderPrincipal,cause,class,payload,
                 renderedBytes,state,addedAt)
               VALUES(?1,?2,?3,?4,?5,?6,1,'captured-predecessor',?7,'wake','fyi',?8,?9,'included',1)
               """,
               [
                 "historical-member:" <> original.wake_id,
                 batch_id,
                 original.wake_id,
                 NoticeBatcher.policy_ref(original.wake_id),
                 address,
                 scope,
                 original.origin,
                 original.prompt,
                 byte_size(original.prompt)
               ]
             )

    sealed = NoticeBatcher.batch(db, batch_id)
    assert sealed.state == "sealed"
    assert sealed.envelope == envelope
    assert sealed.envelope_sha256 == envelope_sha256
    assert sealed.delivery_wake_id == nil
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM turns")

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)

    assert %{
             requester: "tightbeam:retirement",
             reason: "target_retired",
             source_kind: "session_transition",
             source_id: "retiring",
             outcome: "replacement",
             replacement_wake_id: replacement_id
           } = cancellation(db, original.wake_id)

    replacement = Wakes.get(db, replacement_id)
    assert replacement.state == "pending"
    assert replacement.session_key == main_key
    assert replacement.target_role == original.target_role
    assert replacement.prompt == original.prompt
    assert replacement.origin == original.origin
    assert replacement.creator_session_key == original.creator_session_key
    assert replacement.due_at == original.due_at
    assert replacement.delivery_rule == original.delivery_rule
    assert NoticeBatcher.source_refs(db, replacement_id) == []
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM turns")

    [carrier_id] = NoticeBatcher.recover(db)
    historical = NoticeBatcher.batch(db, batch_id)
    assert historical.state == "canceled"
    assert historical.envelope == sealed.envelope
    assert historical.envelope_sha256 == sealed.envelope_sha256
    assert historical.delivery_token == sealed.delivery_token
    assert historical.sealed_at == sealed.sealed_at
    assert historical.delivery_wake_id == nil

    assert [%{member_state: "canceled", batch_id: ^batch_id, batch_state: "canceled"}] =
             NoticeBatcher.source_refs(db, original.wake_id)

    assert Enum.map(NoticeBatcher.members(db, batch_id), & &1.payload) == [original.prompt]
    assert Wakes.get(db, original.wake_id).state == "canceled"
    assert Wakes.get(db, original.wake_id).prompt == original.prompt
    assert Wakes.get(db, replacement_id).state == "fired"
    assert Enum.map(Wakes.digest_members(db, carrier_id), & &1.wake_id) == [replacement_id]

    assert [%{member_state: "included", delivery_wake_id: ^carrier_id, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(db, replacement_id)

    assert {:ok, [[^main_key, "queued", actual_prompt]]} =
             DB.query(db, "SELECT sessionKey,status,prompt FROM turns WHERE wakeId=?1", [
               carrier_id
             ])

    assert actual_prompt =~ original.prompt
    assert NoticeBatcher.recover(db) == []
    assert Wakes.materialize_digests(db) == []
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM turns")
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes WHERE digest=1")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  test "retirement preserves an immutable bounded carrier formed from the ready queue", %{db: db} do
    %{original: original, batch_id: batch_id} =
      selected_retirement_source(db, "overflow retirement 1")

    added =
      for n <- 2..51 do
        wake =
          Wakes.schedule(db, %{
            session_key: "retiring",
            target_role: "reviewer",
            origin: "process:tightbeam",
            creator_session_key: "agent:sender",
            prompt: "overflow retirement #{n}",
            due_at: 0,
            class: "fyi"
          })

        {wake, enqueue_ready_source!(db, wake)}
      end

    assert NoticeBatcher.batch(db, batch_id).member_count == 50
    {last_wake, {:deferred, %{code: "batch_capacity_waiting"}}} = List.last(added)
    assert NoticeBatcher.source_refs(db, last_wake.wake_id) == []

    carrier_ids = NoticeBatcher.recover(db, original.due_at)
    assert length(carrier_ids) == 2

    ready_batch = NoticeBatcher.batch(db, batch_id)
    assert ready_batch.state == "delivery_pending"
    assert ready_batch.release_cause == "idle"
    carrier_id = ready_batch.delivery_wake_id
    assert carrier_id in carrier_ids

    assert [%{batch_id: second_batch_id, member_state: "included"}] =
             NoticeBatcher.source_refs(db, last_wake.wake_id)

    assert NoticeBatcher.batch(db, second_batch_id).delivery_wake_id in carrier_ids

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)
    retired_batch = NoticeBatcher.batch(db, batch_id)
    assert retired_batch.state == "delivery_pending"
    assert retired_batch.delivery_wake_id == carrier_id
    assert retired_batch.envelope == ready_batch.envelope
    assert retired_batch.envelope_sha256 == ready_batch.envelope_sha256

    assert %{replacement_wake_id: replacement_wake_id} = cancellation(db, original.wake_id)
    assert Wakes.get(db, replacement_wake_id).state == "canceled"
    assert original.wake_id in Enum.map(Wakes.digest_members(db, carrier_id), & &1.wake_id)
    refute replacement_wake_id in Enum.map(Wakes.digest_members(db, carrier_id), & &1.wake_id)

    assert %{
             requester: "tightbeam:batcher",
             reason: "superseded",
             source_id: ^carrier_id,
             outcome: "replacement",
             replacement_wake_id: ^carrier_id
           } = cancellation(db, replacement_wake_id)

    assert length(Wakes.digest_members(db, carrier_id)) == 50
  end

  test "retirement after actual admission preserves the immutable carrier and turn", %{db: db} do
    ensure_legacy_main(db)
    Org.create(db, base(%{session_key: "retiring"}))
    Roles.create!(db, "reviewer", "flynn", "retiring")
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})

    original =
      Wakes.schedule(db, %{
        session_key: "retiring",
        target_role: "reviewer",
        origin: "process:tightbeam",
        creator_session_key: "agent:sender",
        prompt: "retirement after actual admission",
        due_at: 0,
        class: "fyi"
      })

    assert [carrier_id] = Wakes.materialize_digests(db, original.due_at)

    assert [%{batch_id: batch_id, member_state: "included", batch_state: "delivered"}] =
             NoticeBatcher.source_refs(db, original.wake_id)

    committed = NoticeBatcher.batch(db, batch_id)
    assert committed.delivery_wake_id == carrier_id
    assert committed.envelope =~ original.prompt
    assert Wakes.get(db, original.wake_id).state == "fired"
    assert Wakes.get(db, carrier_id).state == "fired"

    assert {:ok, [["retiring", "queued", actual_prompt]]} =
             DB.query(db, "SELECT sessionKey,status,prompt FROM turns WHERE wakeId=?1", [
               carrier_id
             ])

    assert actual_prompt == "[from process:tightbeam]\n\n" <> committed.envelope

    assert {:ok, [actual_turn]} =
             DB.query(db, "SELECT * FROM turns WHERE wakeId=?1", [carrier_id])

    members = NoticeBatcher.members(db, batch_id)
    carrier = Wakes.get(db, carrier_id)

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)
    assert NoticeBatcher.batch(db, batch_id) == committed
    assert NoticeBatcher.members(db, batch_id) == members
    assert Wakes.get(db, carrier_id) == carrier
    assert Wakes.get(db, original.wake_id).state == "fired"
    assert Wakes.get(db, original.wake_id).prompt == original.prompt
    assert cancellation(db, original.wake_id) == nil
    assert Enum.map(Wakes.digest_members(db, carrier_id), & &1.wake_id) == [original.wake_id]

    assert {:ok, [^actual_turn]} =
             DB.query(db, "SELECT * FROM turns WHERE wakeId=?1", [carrier_id])

    assert NoticeBatcher.recover(db) == []
    assert Wakes.materialize_digests(db) == []
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM turns")
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes WHERE digest=1")
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes WHERE digest=0")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  test "retirement after terminal carrier preserves the one fired delivery path", %{db: db} do
    ensure_legacy_main(db)
    Org.create(db, base(%{session_key: "retiring"}))
    Roles.create!(db, "reviewer", "flynn", "retiring")
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})

    original =
      Wakes.schedule(db, %{
        session_key: "retiring",
        target_role: "reviewer",
        origin: "process:tightbeam",
        creator_session_key: "agent:sender",
        prompt: "after terminal carrier",
        due_at: 0,
        class: "fyi"
      })

    assert [carrier_id] = Wakes.materialize_digests(db, original.due_at)

    assert [%{batch_id: batch_id, member_state: "included", batch_state: "delivered"}] =
             NoticeBatcher.source_refs(db, original.wake_id)

    committed = NoticeBatcher.batch(db, batch_id)
    assert committed.delivery_wake_id == carrier_id
    assert committed.envelope =~ original.prompt

    assert {:ok, %{seq: seq, wake_id: ^carrier_id, owner_lease: lease}} =
             Tightbeam.Ledger.claim_next(db, "retiring", "org-terminal-carrier-fixture")

    assert :ok =
             Tightbeam.Ledger.finish(db, seq, "failed", "fixture terminal failure",
               owner_lease: lease
             )

    assert {:ok, [["failed", "fixture terminal failure", actual_prompt]]} =
             DB.query(db, "SELECT status,error,prompt FROM turns WHERE seq=?1", [seq])

    assert actual_prompt == "[from process:tightbeam]\n\n" <> committed.envelope

    # A terminal turn does not undo the already committed delivery boundary.
    NoticeBatcher.delivery_terminal_failure(db, carrier_id, :skipped, 1_000)
    assert NoticeBatcher.batch(db, batch_id) == committed

    assert {:ok, [terminal_turn]} = DB.query(db, "SELECT * FROM turns WHERE seq=?1", [seq])
    members = NoticeBatcher.members(db, batch_id)
    carrier = Wakes.get(db, carrier_id)
    assert Wakes.get(db, original.wake_id).state == "fired"
    assert Wakes.get(db, carrier_id).state == "fired"

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)
    assert NoticeBatcher.batch(db, batch_id) == committed
    assert NoticeBatcher.members(db, batch_id) == members
    assert Wakes.get(db, carrier_id) == carrier
    assert Enum.map(Wakes.digest_members(db, carrier_id), & &1.wake_id) == [original.wake_id]
    assert Wakes.get(db, original.wake_id).state == "fired"
    assert Wakes.get(db, original.wake_id).prompt == original.prompt
    assert cancellation(db, original.wake_id) == nil
    assert {:ok, [^terminal_turn]} = DB.query(db, "SELECT * FROM turns WHERE seq=?1", [seq])
    assert NoticeBatcher.recover(db) == []
    assert Wakes.materialize_digests(db) == []
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM turns")
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM wakes WHERE digest=1")
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM wakes WHERE digest=0")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  test "retirement validates its explicit caller context before state or wake mutation", %{db: db} do
    session = Org.create(db, base(%{session_key: "retiring"}))

    wake =
      Wakes.schedule(db, %{
        session_key: "retiring",
        origin: "user:flynn",
        prompt: "still pending",
        due_at: 9_000
      })

    for {principal, interval} <- [
          {"", 1_000},
          {nil, 1_000},
          {"user:flynn", 0},
          {"user:flynn", -1}
        ] do
      assert_raise ArgumentError, ~r/non-empty principal and positive supervision interval/, fn ->
        Org.retire(db, "retiring", principal, interval)
      end

      assert %{state: "active", updated_at: updated_at} = Org.get(db, "retiring")
      assert updated_at == session.updated_at
      assert Wakes.get(db, wake.wake_id).state == "pending"
      assert cancellation(db, wake.wake_id) == nil
    end
  end

  test "concurrent retirement commits one state transition and one cancellation carrier", %{
    db: db
  } do
    Org.create(db, base(%{session_key: "retiring"}))

    wake =
      Wakes.schedule(db, %{
        session_key: "retiring",
        origin: "user:flynn",
        prompt: "cancel once",
        due_at: 9_000
      })

    results =
      for _ <- 1..2 do
        Task.async(fn -> Org.retire(db, "retiring", "user:flynn", 1_000) end)
      end
      |> Task.await_many()

    assert Enum.all?(results, &(&1.state == "retired"))
    assert Wakes.get(db, wake.wake_id).state == "canceled"

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1", [
               wake.wake_id
             ])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM sessions WHERE sessionKey='retiring'")
  end

  test "retirement refuses and rolls back when linked open work has no surviving liveness", %{
    db: db
  } do
    Org.create(db, base(%{session_key: "retiring"}))

    :ok =
      DB.execute(
        db,
        "INSERT INTO work_items (id,title,ownerUserId,state,createdByUser,createdContextKnown,createdAt) VALUES ('orphan','orphan','flynn','open','flynn',0,1)"
      )

    wake =
      Wakes.schedule(db, %{
        session_key: "retiring",
        origin: "user:flynn",
        prompt: "linked",
        due_at: 9_000,
        work_item_id: "orphan"
      })

    assert_raise RuntimeError, ~r/no liveness trigger/, fn ->
      Org.retire(db, "retiring", "user:flynn", 1_000)
    end

    assert Org.get(db, "retiring").state == "active"
    assert Wakes.get(db, wake.wake_id).state == "pending"
    assert cancellation(db, wake.wake_id) == nil
  end

  test "spawned-by provenance is retained", %{db: db} do
    Org.create(db, base(%{session_key: "root", handle: "orchestrator:news"}))

    child =
      Org.create(
        db,
        base(%{
          session_key: "child",
          origin: "agent:orchestrator:news",
          spawned_by: "root",
          archetype: "reviewer",
          harness: "codex",
          provider: "openai",
          model: Model.new("gpt-5.6-sol", effort: "high")
        })
      )

    assert child.spawned_by == "root"
    assert child.provider == "openai"
  end

  test "rename and set_model update the row", %{db: db} do
    original = Org.create(db, base(%{session_key: "k1"}))
    renamed = Org.rename(db, "k1", "Renamed")
    selection = Model.new("claude-fable-5", effort: "high", context: "1m")
    updated = Org.set_model(db, "k1", selection, "anthropic")

    assert renamed.display_name == "Renamed"
    assert updated.model == selection
    assert updated.provider == "anthropic"
    assert updated.updated_at >= original.updated_at

    # The row holds the identity in COLUMNS. A context variant and a reasoning
    # level are different questions and never share a slot: stored packed, the
    # `1m` here would be indistinguishable from an effort named `1m`.
    {:ok, rows} =
      DB.query(db, """
      SELECT displayName, model, thinkingLevel, modelContext, provider
      FROM sessions WHERE sessionKey = 'k1'
      """)

    assert rows == [["Renamed", "claude-fable-5", "high", "1m", "anthropic"]]
  end

  test "pointer chain is append-only and current is latest", %{db: db} do
    Org.create(db, base(%{session_key: "k1"}))
    Org.append_pointer(db, "k1", "uuid-1", "created")
    Org.append_pointer(db, "k1", "uuid-2", "loaded")
    latest = Org.append_pointer(db, "k1", "uuid-3", "fallback")

    assert Org.current_pointer(db, "k1") == latest
    assert Enum.map(Org.pointer_chain(db, "k1"), & &1.reason) == ["created", "loaded", "fallback"]

    {:ok, [[count]]} =
      DB.query(db, "SELECT COUNT(*) FROM harness_pointers WHERE sessionKey = 'k1'")

    assert count == 3
  end

  test "pointer persists canonical source session identity with reverse uniqueness", %{db: db} do
    Org.create(db, base(%{session_key: "k1"}))
    pointer = Org.append_pointer(db, "k1", "shared-harness-id", "created")

    assert pointer.harness == "claude"
    assert pointer.machine == "testhost"

    assert pointer.source_session_ref ==
             Org.source_session_ref("claude", "testhost", "shared-harness-id")

    Org.append_pointer(db, "k1", "shared-harness-id", "loaded")
    Org.create(db, base(%{session_key: "k2"}))

    assert_raise Tightbeam.DB.Error, ~r/already belongs to another parent/, fn ->
      Org.append_pointer(db, "k2", "shared-harness-id", "created")
    end
  end

  test "schema constraints reject invalid enums and duplicate handles", %{db: db} do
    assert_raise Tightbeam.DB.Error, ~r/CHECK constraint/, fn ->
      Org.create(db, base(%{session_key: "bad", harness: "other"}))
    end

    Org.create(db, base(%{session_key: "one", handle: "agent"}))

    assert_raise Tightbeam.DB.Error, ~r/UNIQUE constraint/, fn ->
      Org.create(db, base(%{session_key: "two", handle: "agent"}))
    end

    assert_raise ArgumentError, "unknown session: missing", fn ->
      Org.rename(db, "missing", "Nope")
    end
  end

  defp cancellation(db, wake_id) do
    case DB.query(
           db,
           """
           SELECT requesterId,reasonKind,causalSourceKind,causalSourceId,outcomeKind,
                  replacementWakeId,workImpactKind,actionNeeded
           FROM wake_cancellations WHERE wakeId=?1
           """,
           [wake_id]
         ) do
      {:ok, []} ->
        nil

      {:ok,
       [
         [
           requester,
           reason,
           source_kind,
           source_id,
           outcome,
           replacement_wake_id,
           work_impact,
           action_needed
         ]
       ]} ->
        %{
          requester: requester,
          reason: reason,
          source_kind: source_kind,
          source_id: source_id,
          outcome: outcome,
          replacement_wake_id: replacement_wake_id,
          work_impact: work_impact,
          action_needed: action_needed
        }
    end
  end

  defp selected_retirement_source(db, prompt) do
    ensure_legacy_main(db)
    Org.create(db, base(%{session_key: "retiring"}))
    Roles.create!(db, "reviewer", "flynn", "retiring")

    {:ok, _policy} =
      DB.transaction(db, fn txn ->
        Org.apply_notice_batching_lane_policy_in_txn(
          txn,
          %{session_key: "retiring", target_role: "reviewer"},
          true,
          "notice-batching-org-immutable-retirement-test:#{prompt}",
          "agent:test-policy",
          "retirement-immutable-fixture",
          1_000
        )
      end)

    original =
      Wakes.schedule(db, %{
        session_key: "retiring",
        target_role: "reviewer",
        origin: "process:tightbeam",
        creator_session_key: "agent:sender",
        prompt: prompt,
        due_at: 0,
        class: "fyi"
      })

    _member = enqueue_ready_source!(db, original)

    assert [%{member_state: "active", batch_id: batch_id}] =
             NoticeBatcher.source_refs(db, original.wake_id)

    %{original: original, batch_id: batch_id}
  end

  defp enqueue_ready_source!(db, wake) do
    assert {:ok, [[policy_ref]]} =
             DB.query(
               db,
               "SELECT policyRef FROM notice_delivery_policies WHERE sourceWakeId=?1",
               [wake.wake_id]
             )

    NoticeBatcher.enqueue_or_recover(db, wake.wake_id, policy_ref)
  end

  defp ensure_legacy_main(db) do
    key = Org.personal_session_key("flynn")

    Org.create(
      db,
      base(%{session_key: key, kind: "main", is_built_in: true, adopted: true})
    )
  end

  defp assert_immutable_retirement_chain(db, original, immutable_batch) do
    final_batch = NoticeBatcher.batch(db, immutable_batch.batch_id)
    carrier_id = final_batch.delivery_wake_id

    assert final_batch.state == "delivery_pending"
    assert final_batch.envelope == immutable_batch.envelope
    assert final_batch.envelope_sha256 == immutable_batch.envelope_sha256
    assert is_binary(carrier_id)
    assert Enum.map(Wakes.digest_members(db, carrier_id), & &1.wake_id) == [original.wake_id]

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE digest=1 AND wakeId=?1", [carrier_id])

    assert %{state: "canceled"} = Wakes.get(db, original.wake_id)

    assert %{outcome: "replacement", replacement_wake_id: replacement_wake_id} =
             cancellation(db, original.wake_id)

    assert %{state: "canceled"} = Wakes.get(db, replacement_wake_id)

    assert %{
             requester: "tightbeam:batcher",
             reason: "superseded",
             source_kind: "wake",
             source_id: ^carrier_id,
             outcome: "replacement",
             replacement_wake_id: ^carrier_id
           } = cancellation(db, replacement_wake_id)

    assert [%{member_state: "included", delivery_wake_id: ^carrier_id}] =
             NoticeBatcher.source_refs(db, original.wake_id)

    assert NoticeBatcher.source_refs(db, replacement_wake_id) == []

    assert {:ok, [[2]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId IN (?1, ?2)",
               [original.wake_id, replacement_wake_id]
             )
  end
end
