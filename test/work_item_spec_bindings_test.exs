defmodule Tightbeam.WorkItemSpecBindingsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Devices, Dispatch, WorkItems, WorkItemSpecBindings}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Hub

  @digest String.duplicate("a", 64)

  setup do
    db = :"spec_binding_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    unless Process.whereis(Hub) do
      start_supervised!({Hub, name: Hub})
    end

    :ok = Hub.register(Hub, self())
    seed_identities(db)
    %{db: db}
  end

  test "schema is exact, additive, and refuses a malformed existing object", %{db: db} do
    assert {:ok,
            [
              ["workItemId"],
              ["specRefName"],
              ["specRefSha256"],
              ["specArtifactId"],
              ["producerAssignmentId"],
              ["reviewAssignmentId"],
              ["reviewAttestId"],
              ["reviewReportArtifactId"],
              ["boundByUser"],
              ["boundBySession"],
              ["boundAt"]
            ]} =
             DB.query(
               db,
               "SELECT name FROM pragma_table_info('work_item_spec_bindings') ORDER BY cid"
             )

    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM work_item_spec_bindings")

    :ok = DB.execute(db, "DROP TABLE work_item_spec_bindings")
    :ok = DB.execute(db, "CREATE TABLE work_item_spec_bindings (workItemId TEXT PRIMARY KEY)")

    assert_raise Tightbeam.Schema.ShapeError,
                 ~r/^incompatible_work_item_spec_binding_v1:/,
                 fn -> WorkItemSpecBindings.ensure_schema(db) end
  end

  test "owner, owner session, administrator, and administrator session may bind", %{db: db} do
    assert %{is_admin: false} = Devices.user(db, "owner")
    assert %{is_admin: true} = Devices.user(db, "admin")

    for {suffix, principal} <- [
          {"owner", {:user, "owner"}},
          {"owner_session", {:session, "owner-session"}},
          {"admin", {:user, "admin"}},
          {"admin_session", {:session, "admin-session"}}
        ] do
      fixture = evidence_fixture(db, suffix)

      assert {:accepted_effect_in_txn, event_id, %{changed: true} = response} =
               WorkItemSpecBindings.bind(db, call(fixture, principal))

      assert event_id > 0
      assert response.workItem.specRefName == fixture.name
      assert response.specBinding.specArtifactId == fixture.spec_artifact

      expected_user = if elem(principal, 0) == :user, do: elem(principal, 1), else: nil
      expected_session = if elem(principal, 0) == :session, do: elem(principal, 1), else: nil
      assert response.specBinding.boundByUser == expected_user
      assert response.specBinding.boundBySession == expected_session
    end
  end

  test "principal order, invisible items, exact ids, and malformed raw inputs are typed", %{
    db: db
  } do
    fixture = evidence_fixture(db, "authority")

    assert %{code: "process_denied"} =
             WorkItemSpecBindings.bind(
               db,
               call(fixture, {:process, "job"}) |> put_in([:params], %{})
             )

    assert %{code: "principal_required"} =
             WorkItemSpecBindings.bind(db, call(fixture, nil) |> put_in([:params], %{}))

    assert %{code: "not_found", message: "work item not found"} =
             WorkItemSpecBindings.bind(db, call(fixture, {:user, "foreign"}))

    missing = put_in(call(fixture), [:params, :work_item_id], "wi_missing")

    assert %{code: "not_found", message: "work item not found"} =
             WorkItemSpecBindings.bind(db, missing)

    for mutation <- [
          &Map.delete(&1, :spec_ref_name),
          &Map.put(&1, :spec_ref_name, "  "),
          &Map.put(&1, :spec_ref_sha256, String.duplicate("A", 64)),
          &Map.put(&1, :spec_ref_sha256, "abc"),
          &Map.put(&1, :spec_artifact_id, 7),
          &Map.put(&1, :review_attest_id, "  ")
        ] do
      malformed = mutation.(call(fixture).params)

      assert %{code: "invalid_spec_binding"} =
               WorkItemSpecBindings.bind(db, %{call(fixture) | params: malformed})
    end

    prefix = put_in(call(fixture), [:params, :spec_artifact_id], "art_spec")

    assert %{code: "spec_provenance_unverified", message: message} =
             WorkItemSpecBindings.bind(db, prefix)

    assert message =~ "specArtifactId"
    refute message =~ fixture.work_item
  end

  test "path alternatives and deterministic spec snapshot boundaries are verified", %{db: db} do
    for {suffix, origin_path, home} <- [
          {"path_equal", "governing.md", nil},
          {"path_slash", "/specs/governing.md", nil},
          {"path_colon", "github:governing.md", nil},
          {"home", "/wrong", "/canonical/governing.md"}
        ] do
      fixture = evidence_fixture(db, suffix, origin_path: origin_path, home: home)

      assert {:accepted_effect_in_txn, _, %{changed: true}} =
               WorkItemSpecBindings.bind(db, call(fixture))
    end

    bad_path = evidence_fixture(db, "bad_path", origin_path: "/not-a-boundary-governing.md")
    assert_unverified(db, bad_path, "specArtifactId")

    late = evidence_fixture(db, "late_spec")

    update!(db, "UPDATE artifacts SET createdAt = 201, updatedAt = 201 WHERE artifactId = ?1", [
      late.spec_artifact
    ])

    assert_unverified(db, late, "specArtifactId")

    older = evidence_fixture(db, "superseded")

    insert_artifact(db, "art_spec_superseding", "spec", older.work_item, "producer", 150,
      origin_path: older.name,
      digest: older.digest
    )

    assert_unverified(db, older, "specArtifactId")

    same_ms = evidence_fixture(db, "spec_tie", spec_artifact: "art_spec_tie_a")

    insert_artifact(db, "art_spec_tie_z", "spec", same_ms.work_item, "producer", 100,
      origin_path: same_ms.name,
      digest: same_ms.digest
    )

    assert_unverified(db, same_ms, "specArtifactId")

    spec_at_open = evidence_fixture(db, "spec_at_open")

    update!(db, "UPDATE artifacts SET createdAt=200, updatedAt=200 WHERE artifactId=?1", [
      spec_at_open.spec_artifact
    ])

    assert {:accepted_effect_in_txn, _, %{changed: true}} =
             WorkItemSpecBindings.bind(db, call(spec_at_open))
  end

  test "review and report joins require independent latest completed structured evidence", %{
    db: db
  } do
    cases = [
      {"bad_kind",
       fn db, f ->
         update!(db, "UPDATE attests SET kind='progress', verdictKind=NULL WHERE id=?1", [
           f.review_attest
         ])
       end},
      {"bad_author",
       fn db, f ->
         update!(db, "UPDATE attests SET bySession='producer' WHERE id=?1", [f.review_attest])
       end},
      {"bad_effect",
       fn db, f ->
         update!(db, "UPDATE assignment_effects SET effectKind='code' WHERE assignmentId=?1", [
           f.review_assignment
         ])
       end},
      {"open_review",
       fn db, f ->
         update!(
           db,
           "UPDATE assignments SET state='open', outcome=NULL, closedAt=NULL, closedBySession=NULL, closingAttestId=NULL WHERE id=?1",
           [f.review_assignment]
         )
       end},
      {"equal_holder",
       fn db, f ->
         update!(db, "UPDATE assignments SET holderKey='producer' WHERE id=?1", [
           f.review_assignment
         ])
       end},
      {"bad_report_kind",
       fn db, f ->
         update!(db, "UPDATE artifacts SET kind='doc' WHERE artifactId=?1", [f.review_report])
       end},
      {"bad_report_author",
       fn db, f ->
         update!(db, "UPDATE artifacts SET createdBySession='producer' WHERE artifactId=?1", [
           f.review_report
         ])
       end},
      {"late_report",
       fn db, f ->
         update!(db, "UPDATE artifacts SET createdAt=301, updatedAt=301 WHERE artifactId=?1", [
           f.review_report
         ])
       end}
    ]

    for {suffix, break_fixture} <- cases do
      fixture = evidence_fixture(db, suffix)
      break_fixture.(db, fixture)
      assert %{code: "spec_provenance_unverified"} = WorkItemSpecBindings.bind(db, call(fixture))
    end

    latest_verdict = evidence_fixture(db, "latest_verdict")

    insert_attest(
      db,
      "att_later_bad",
      latest_verdict.review_assignment,
      "verdict",
      "reviewer",
      301,
      verdict: "changes-requested"
    )

    assert_unverified(db, latest_verdict, "reviewAttestId")

    report_tie = evidence_fixture(db, "report_tie", review_report: "art_report_tie_a")
    insert_artifact(db, "art_report_tie_z", "report", report_tie.work_item, "reviewer", 250)
    assert_unverified(db, report_tie, "reviewReportArtifactId")

    report_before_open = evidence_fixture(db, "report_before_open")

    update!(db, "UPDATE artifacts SET createdAt=199, updatedAt=199 WHERE artifactId=?1", [
      report_before_open.review_report
    ])

    assert_unverified(db, report_before_open, "reviewReportArtifactId")

    for {suffix, boundary} <- [{"report_at_open", 200}, {"report_at_verdict", 300}] do
      fixture = evidence_fixture(db, suffix)

      update!(db, "UPDATE artifacts SET createdAt=?2, updatedAt=?2 WHERE artifactId=?1", [
        fixture.review_report,
        boundary
      ])

      assert {:accepted_effect_in_txn, _, %{changed: true}} =
               WorkItemSpecBindings.bind(db, call(fixture))
    end
  end

  test "first bind, adoption, lifecycle refusal, replay, and identity conflicts are immutable", %{
    db: db
  } do
    bound = evidence_fixture(db, "bind")

    assert {:accepted_effect_in_txn, _, %{changed: true} = first} =
             WorkItemSpecBindings.bind(db, call(bound))

    first_at = first.specBinding.boundAt

    update!(db, "UPDATE work_items SET state='closed' WHERE id=?1", [bound.work_item])

    assert {:accepted_effect_in_txn, _, %{changed: false} = replay} =
             WorkItemSpecBindings.bind(db, call(bound))

    assert replay.specBinding.boundAt == first_at

    for {field, value} <- [
          {:spec_ref_name, "different.md"},
          {:spec_ref_sha256, String.duplicate("b", 64)},
          {:spec_artifact_id, "art_other"},
          {:review_attest_id, "att_other"},
          {:review_report_artifact_id, "art_report_other"}
        ] do
      assert %{code: "spec_binding_conflict"} =
               WorkItemSpecBindings.bind(db, put_in(call(bound), [:params, field], value))
    end

    adopt = evidence_fixture(db, "adopt", pair: {@digest, "governing.md"})

    assert {:accepted_effect_in_txn, _, %{changed: true}} =
             WorkItemSpecBindings.bind(db, call(adopt))

    different =
      evidence_fixture(db, "legacy_conflict", pair: {String.duplicate("b", 64), "old.md"})

    assert %{code: "spec_binding_conflict"} = WorkItemSpecBindings.bind(db, call(different))

    for state <- ~w(iceboxed closed failed) do
      fixture = evidence_fixture(db, "state_#{state}", state: state)
      assert %{code: "work_item_not_open"} = WorkItemSpecBindings.bind(db, call(fixture))
      assert WorkItemSpecBindings.get(db, fixture.work_item) == nil
    end
  end

  test "reviewed projection rejects raw replacement but preserves unrelated metadata", %{db: db} do
    fixture = evidence_fixture(db, "raw")

    assert {:accepted_effect_in_txn, _, %{changed: true}} =
             WorkItemSpecBindings.bind(db, call(fixture))

    update_call = fn params ->
      %{
        verb: "work-item-update",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: nil,
        params: Map.put(params, :work_item_id, fixture.work_item)
      }
    end

    assert %{code: "spec_binding_conflict"} =
             WorkItems.__handle__(db, "work-item-update", update_call.(%{spec_ref_name: nil}))

    assert %{code: "spec_binding_conflict"} =
             WorkItems.__handle__(db, "work-item-update", update_call.(%{spec_ref_sha256: nil}))

    assert %{code: "spec_binding_conflict"} =
             WorkItems.__handle__(
               db,
               "work-item-update",
               update_call.(%{spec_ref_name: nil, spec_ref_sha256: fixture.digest})
             )

    assert %{code: "spec_binding_conflict"} =
             WorkItems.__handle__(
               db,
               "work-item-update",
               update_call.(%{
                 spec_ref_name: "other.md",
                 spec_ref_sha256: String.duplicate("b", 64)
               })
             )

    assert %{title: "Renamed", specRefName: "governing.md"} =
             WorkItems.__handle__(
               db,
               "work-item-update",
               update_call.(%{
                 title: "Renamed",
                 spec_ref_name: fixture.name,
                 spec_ref_sha256: fixture.digest
               })
             )

    assert WorkItemSpecBindings.get(db, fixture.work_item).specRefSha256 == fixture.digest

    assert {:ok, [[fixture.name, fixture.digest]]} ==
             DB.query(db, "SELECT specRefName,specRefSha256 FROM work_items WHERE id=?1", [
               fixture.work_item
             ])

    unbound = evidence_fixture(db, "raw_unbound", pair: {fixture.digest, fixture.name})

    assert %{code: "invalid_spec_ref"} =
             WorkItems.__handle__(
               db,
               "work-item-update",
               raw_call(unbound, {nil, unbound.digest})
             )
  end

  test "review completion and first bind serialize on both sides of a transaction barrier", %{
    db: db
  } do
    parent = self()
    bind_first = pending_review_fixture(db, "review_bind_first")
    bind_token = make_ref()

    bind_task =
      Task.async(fn ->
        WorkItemSpecBindings.bind(
          db,
          Map.put(call(bind_first), :on_spec_binding_before_provenance, fn _txn ->
            transaction_barrier(parent, bind_token)
          end)
        )
      end)

    assert_receive {:transaction_barrier, ^bind_token}
    completion_task = Task.async(fn -> complete_review(db, bind_first) end)
    await_queued_db_call(db)
    release_transaction(db, bind_token)

    assert %{code: "spec_provenance_unverified"} = Task.await(bind_task)
    assert {:ok, :ok} = Task.await(completion_task)
    assert WorkItemSpecBindings.get(db, bind_first.work_item) == nil

    assert {:accepted_effect_in_txn, _, %{changed: true}} =
             WorkItemSpecBindings.bind(db, call(bind_first))

    completion_first = pending_review_fixture(db, "review_completion_first")
    completion_token = make_ref()

    completion_task =
      Task.async(fn ->
        complete_review(db, completion_first, fn _txn ->
          transaction_barrier(parent, completion_token)
        end)
      end)

    assert_receive {:transaction_barrier, ^completion_token}
    bind_task = Task.async(fn -> WorkItemSpecBindings.bind(db, call(completion_first)) end)
    await_queued_db_call(db)
    release_transaction(db, completion_token)

    assert {:ok, :ok} = Task.await(completion_task)
    assert {:accepted_effect_in_txn, _, %{changed: true}} = Task.await(bind_task)
    assert WorkItemSpecBindings.get(db, completion_first.work_item)
  end

  test "raw metadata and first bind serialize in both orders for equal and different pairs", %{
    db: db
  } do
    parent = self()

    for relation <- [:equal, :different] do
      bind_first = evidence_fixture(db, "raw_bind_first_#{relation}")
      pair = raw_pair(bind_first, relation)
      bind_token = make_ref()

      bind_task =
        Task.async(fn ->
          WorkItemSpecBindings.bind(
            db,
            Map.put(call(bind_first), :on_spec_binding_before_audit, fn _txn ->
              transaction_barrier(parent, bind_token)
            end)
          )
        end)

      assert_receive {:transaction_barrier, ^bind_token}

      raw_task =
        Task.async(fn ->
          WorkItems.__handle__(db, "work-item-update", raw_call(bind_first, pair))
        end)

      await_queued_db_call(db)
      release_transaction(db, bind_token)

      assert {:accepted_effect_in_txn, _, %{changed: true}} = Task.await(bind_task)

      case relation do
        :equal ->
          assert %{specRefName: name} = Task.await(raw_task)
          assert name == bind_first.name

        :different ->
          assert %{code: "spec_binding_conflict"} = Task.await(raw_task)
      end

      assert_complete_pair(db, bind_first.work_item, bind_first.name, bind_first.digest, true)

      raw_first = evidence_fixture(db, "raw_update_first_#{relation}")
      pair = raw_pair(raw_first, relation)
      raw_token = make_ref()

      raw_task =
        Task.async(fn ->
          WorkItems.__handle__(
            db,
            "work-item-update",
            Map.put(raw_call(raw_first, pair), :on_work_item_update_before_guard, fn _txn ->
              transaction_barrier(parent, raw_token)
            end)
          )
        end)

      assert_receive {:transaction_barrier, ^raw_token}
      bind_task = Task.async(fn -> WorkItemSpecBindings.bind(db, call(raw_first)) end)
      await_queued_db_call(db)
      release_transaction(db, raw_token)

      assert %{specRefName: raw_name} = Task.await(raw_task)
      assert raw_name == elem(pair, 0)

      case relation do
        :equal ->
          assert {:accepted_effect_in_txn, _, %{changed: true}} = Task.await(bind_task)
          assert_complete_pair(db, raw_first.work_item, raw_first.name, raw_first.digest, true)

        :different ->
          assert %{code: "spec_binding_conflict"} = Task.await(bind_task)
          assert_complete_pair(db, raw_first.work_item, elem(pair, 0), elem(pair, 1), false)
      end
    end
  end

  test "transaction owns audit and state publication; failures roll back and redact", %{db: db} do
    fixture = evidence_fixture(db, "effects")
    handlers = %{"work-item-bind-spec" => &WorkItemSpecBindings.bind(db, &1)}
    callback = fn id, kind -> send(self(), {:callback, id, kind}) end
    first_call = Map.put(call(fixture), :on_work_item_change, callback)

    assert {:ok, %{changed: true}} = Dispatch.dispatch(db, handlers, first_call)
    assert_receive {:callback, work_item_id, "metadata"}
    assert work_item_id == fixture.work_item
    assert_notice_counts(1, 1)

    assert {:ok, %{changed: false}} = Dispatch.dispatch(db, handlers, first_call)
    refute_receive {:callback, _, _}
    assert_notice_counts(1, 0)

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT count(*) FROM events WHERE verb='work-item-bind-spec'")

    failing = evidence_fixture(db, "rollback", origin_path: "/secret/PATH_SENTINEL/governing.md")

    raised_call =
      call(failing)
      |> Map.put(:on_spec_binding_before_audit, fn _txn -> raise "EXCEPTION_SENTINEL" end)

    assert {:error, %{code: "server_error", message: "work-item bind failed"}} =
             Dispatch.dispatch(db, handlers, raised_call)

    assert WorkItemSpecBindings.get(db, failing.work_item) == nil

    assert {:ok, [[nil, nil]]} =
             DB.query(db, "SELECT specRefName, specRefSha256 FROM work_items WHERE id=?1", [
               failing.work_item
             ])

    {:ok, [[payload]]} = DB.query(db, "SELECT payload FROM events ORDER BY id DESC LIMIT 1")
    refute payload =~ "PATH_SENTINEL"
    refute payload =~ "EXCEPTION_SENTINEL"
    assert [%{"class" => "verb.denied"}] = receive_notices(1, [])

    callback_failure = evidence_fixture(db, "callback_failure")

    raising_callback = fn id, "metadata" ->
      send(self(), {:callback_attempt, id})
      raise "doorbell unavailable"
    end

    assert {:ok, %{changed: true}} =
             Dispatch.dispatch(
               db,
               handlers,
               Map.put(call(callback_failure), :on_work_item_change, raising_callback)
             )

    assert_receive {:callback_attempt, callback_id}
    assert callback_id == callback_failure.work_item
    assert WorkItemSpecBindings.get(db, callback_failure.work_item)
    assert_notice_counts(1, 1)

    assert {:ok, %{changed: false}} =
             Dispatch.dispatch(
               db,
               handlers,
               Map.put(call(callback_failure), :on_work_item_change, raising_callback)
             )

    refute_receive {:callback_attempt, _}
    assert_notice_counts(1, 0)
  end

  test "equal concurrent calls converge and different calls produce one complete winner", %{
    db: db
  } do
    equal = evidence_fixture(db, "concurrent_equal")
    equal_results = concurrently(fn -> WorkItemSpecBindings.bind(db, call(equal)) end)

    assert Enum.sort(Enum.map(equal_results, fn {:accepted_effect_in_txn, _, r} -> r.changed end)) ==
             [false, true]

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM work_item_spec_bindings WHERE workItemId=?1", [
               equal.work_item
             ])

    different = evidence_fixture(db, "concurrent_different")
    alternate = alternate_bundle(db, different)

    [left, right] =
      concurrently([
        fn -> WorkItemSpecBindings.bind(db, call(different)) end,
        fn -> WorkItemSpecBindings.bind(db, call(alternate)) end
      ])

    assert Enum.count([left, right], &match?({:accepted_effect_in_txn, _, %{changed: true}}, &1)) ==
             1

    assert Enum.count([left, right], &match?(%{code: "spec_binding_conflict"}, &1)) == 1

    stored = WorkItemSpecBindings.get(db, different.work_item)

    assert {stored.specRefName, stored.specArtifactId} in [
             {different.name, different.spec_artifact},
             {alternate.name, alternate.spec_artifact}
           ]

    raw_race = evidence_fixture(db, "concurrent_raw")

    raw_call = %{
      verb: "work-item-update",
      origin: "user:owner",
      principal: {:user, "owner"},
      session_key: nil,
      params: %{
        work_item_id: raw_race.work_item,
        spec_ref_name: "raw-winner.md",
        spec_ref_sha256: String.duplicate("d", 64)
      }
    }

    [bind_result, update_result] =
      concurrently([
        fn -> WorkItemSpecBindings.bind(db, call(raw_race)) end,
        fn -> WorkItems.__handle__(db, "work-item-update", raw_call) end
      ])

    assert Enum.count(
             [bind_result, update_result],
             &match?(%{code: "spec_binding_conflict"}, &1)
           ) == 1

    item = WorkItems.__handle__(db, "work-item-get", call(raw_race)).workItem

    case WorkItemSpecBindings.get(db, raw_race.work_item) do
      nil -> assert item.specRefName == "raw-winner.md"
      binding -> assert binding.specRefName == raw_race.name and item.specRefName == raw_race.name
    end
  end

  test "readback is nullable and a file-backed restart preserves replay identity" do
    path =
      Path.join(
        System.tmp_dir!(),
        "spec-binding-restart-#{System.unique_integer([:positive])}.sqlite3"
      )

    db = :"spec_binding_restart_#{System.unique_integer([:positive])}"
    {:ok, pid} = DB.start_link(path: path, name: db)
    :ok = Tightbeam.Schema.ensure_all(db)
    seed_identities(db)
    legacy = evidence_fixture(db, "legacy")
    assert %{specBinding: nil} = WorkItems.__handle__(db, "work-item-get", call(legacy))

    fixture = evidence_fixture(db, "restart")

    assert {:accepted_effect_in_txn, _, %{changed: true} = first} =
             WorkItemSpecBindings.bind(db, call(fixture))

    Process.unlink(pid)
    GenServer.stop(pid)

    {:ok, restarted} = DB.start_link(path: path, name: db)
    :ok = Tightbeam.Schema.ensure_all(db)
    read = WorkItems.__handle__(db, "work-item-get", call(fixture))
    assert read.specBinding == first.specBinding

    assert {:accepted_effect_in_txn, _, %{changed: false} = replay} =
             WorkItemSpecBindings.bind(db, call(fixture))

    assert replay.specBinding.boundAt == first.specBinding.boundAt
    Process.unlink(restarted)
    GenServer.stop(restarted)
    File.rm!(path)
  end

  defp evidence_fixture(db, suffix, opts \\ []) do
    work_item = "wi_#{suffix}"
    producer_assignment = "asg_producer_#{suffix}"
    review_assignment = "asg_review_#{suffix}"
    review_attest = "att_review_#{suffix}"
    completion_attest = "att_completion_#{suffix}"
    spec_artifact = Keyword.get(opts, :spec_artifact, "art_spec_#{suffix}")
    review_report = Keyword.get(opts, :review_report, "art_report_#{suffix}")
    name = "governing.md"
    digest = @digest
    state = Keyword.get(opts, :state, "open")
    {pair_digest, pair_name} = Keyword.get(opts, :pair, {nil, nil})

    query!(
      db,
      "INSERT INTO work_items (id,title,specRefName,specRefSha256,ownerUserId,state,createdByUser,createdAt) VALUES (?1,?2,?3,?4,'owner',?5,'owner',1)",
      [work_item, "Item #{suffix}", pair_name, pair_digest, state]
    )

    query!(
      db,
      "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state,workItemId) VALUES (?1,?2,'producer','owner',10,'open',?3)",
      [producer_assignment, "Producer #{suffix}", work_item]
    )

    query!(
      db,
      "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state,reviewsAssignmentId) VALUES (?1,?2,'reviewer','owner',200,'open',?3)",
      [review_assignment, "Reviewer #{suffix}", producer_assignment]
    )

    query!(db, "INSERT INTO assignment_effects (assignmentId,effectKind) VALUES (?1,'review')", [
      review_assignment
    ])

    insert_artifact(db, spec_artifact, "spec", work_item, "producer", 100,
      origin_path: Keyword.get(opts, :origin_path, name),
      home: Keyword.get(opts, :home),
      digest: digest
    )

    insert_artifact(db, review_report, "report", work_item, "reviewer", 250)

    insert_attest(db, review_attest, review_assignment, "verdict", "reviewer", 300,
      verdict: "reviewed-clean"
    )

    insert_attest(db, completion_attest, review_assignment, "completion", "reviewer", 310)

    query!(
      db,
      "UPDATE assignments SET state='closed',outcome='completed',closedAt=310,closedBySession='reviewer',closingAttestId=?2 WHERE id=?1",
      [review_assignment, completion_attest]
    )

    %{
      work_item: work_item,
      producer_assignment: producer_assignment,
      review_assignment: review_assignment,
      review_attest: review_attest,
      completion_attest: completion_attest,
      spec_artifact: spec_artifact,
      review_report: review_report,
      name: name,
      digest: digest
    }
  end

  defp alternate_bundle(db, fixture) do
    name = "alternate.md"

    update!(db, "UPDATE artifacts SET state='archived', home=?2 WHERE artifactId=?1", [
      fixture.spec_artifact,
      name
    ])

    %{fixture | name: name}
  end

  defp call(fixture, principal \\ {:user, "owner"}) do
    %{
      verb: "work-item-bind-spec",
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      params: %{
        work_item_id: fixture.work_item,
        spec_ref_name: fixture.name,
        spec_ref_sha256: fixture.digest,
        spec_artifact_id: fixture.spec_artifact,
        review_attest_id: fixture.review_attest,
        review_report_artifact_id: fixture.review_report
      }
    }
  end

  defp pending_review_fixture(db, suffix) do
    fixture = evidence_fixture(db, suffix)

    update!(
      db,
      "UPDATE assignments SET state='open',outcome=NULL,closedAt=NULL,closedBySession=NULL,closingAttestId=NULL WHERE id=?1",
      [fixture.review_assignment]
    )

    update!(db, "DELETE FROM attests WHERE id=?1", [fixture.completion_attest])
    fixture
  end

  defp complete_review(db, fixture, before_close \\ fn _txn -> :ok end) do
    DB.transaction(db, fn txn ->
      :ok = before_close.(txn)

      Txn.q(
        txn,
        "INSERT INTO attests (id,assignmentId,kind,note,bySession,ts) VALUES (?1,?2,'completion','NOTE_SENTINEL','reviewer',310)",
        [fixture.completion_attest, fixture.review_assignment]
      )

      Txn.q(
        txn,
        "UPDATE assignments SET state='closed',outcome='completed',closedAt=310,closedBySession='reviewer',closingAttestId=?2 WHERE id=?1",
        [fixture.review_assignment, fixture.completion_attest]
      )

      :ok
    end)
  end

  defp raw_call(fixture, {name, digest}) do
    %{
      verb: "work-item-update",
      origin: "user:owner",
      principal: {:user, "owner"},
      session_key: nil,
      params: %{
        work_item_id: fixture.work_item,
        spec_ref_name: name,
        spec_ref_sha256: digest
      }
    }
  end

  defp raw_pair(fixture, :equal), do: {fixture.name, fixture.digest}
  defp raw_pair(_fixture, :different), do: {"raw-winner.md", String.duplicate("d", 64)}

  defp transaction_barrier(parent, token) do
    send(parent, {:transaction_barrier, token})

    receive do
      {:release_transaction, ^token} -> :ok
    after
      5_000 -> raise "transaction barrier was not released"
    end
  end

  defp release_transaction(db, token) do
    send(Process.whereis(db), {:release_transaction, token})
  end

  defp await_queued_db_call(db) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    await_queued_db_call(db, deadline)
  end

  defp await_queued_db_call(db, deadline) do
    {:messages, messages} = Process.info(Process.whereis(db), :messages)

    if Enum.any?(messages, fn
         {:"$gen_call", _from, _request} -> true
         _ -> false
       end) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("no serialized DB call queued behind transaction barrier")
      else
        Process.sleep(1)
        await_queued_db_call(db, deadline)
      end
    end
  end

  defp assert_complete_pair(db, work_item_id, name, digest, bound?) do
    assert {:ok, [[^name, ^digest]]} =
             DB.query(db, "SELECT specRefName,specRefSha256 FROM work_items WHERE id=?1", [
               work_item_id
             ])

    case {bound?, WorkItemSpecBindings.get(db, work_item_id)} do
      {true, %{specRefName: ^name, specRefSha256: ^digest}} -> :ok
      {false, nil} -> :ok
      other -> flunk("mixed raw/binding winner: #{inspect(other)}")
    end
  end

  defp origin({:user, user}), do: "user:#{user}"
  defp origin({:session, session}), do: "agent:#{session}"
  defp origin({:process, process}), do: "process:#{process}"
  defp origin(nil), do: "system"

  defp seed_identities(db) do
    assert {:paired, %{user_id: "bootstrap", is_admin: true}} =
             claim_org(db, %{
               device_id: "spec-binding-bootstrap",
               claimed_name: "Bootstrap",
               platform: nil,
               model: nil
             })

    assert %{user_id: "owner", is_admin: false} = Devices.add_user(db, "owner", false)
    assert %{user_id: "admin", is_admin: true} = Devices.add_user(db, "admin", true)
    assert %{user_id: "foreign", is_admin: false} = Devices.add_user(db, "foreign", false)

    for {session, owner} <- [
          {"owner-session", "owner"},
          {"admin-session", "admin"},
          {"foreign-session", "foreign"},
          {"producer", "owner"},
          {"reviewer", "owner"}
        ] do
      query!(
        db,
        "INSERT OR IGNORE INTO sessions (sessionKey,displayName,ownerUserId,origin,operationalParent,archetype,harness,provider,model,host,createdAt,updatedAt) VALUES (?1,?1,?2,?3,?1,'default','claude','anthropic','fable','testhost',1,1)",
        [session, owner, "user:#{owner}"]
      )
    end
  end

  defp insert_artifact(db, id, kind, work_item, creator, at, opts \\ []) do
    query!(
      db,
      "INSERT INTO artifacts (artifactId,kind,title,description,createdBySession,workItemId,originPath,contentSha256,state,home,createdAt,updatedAt) VALUES (?1,?2,?3,'DESCRIPTION_SENTINEL',?4,?5,?6,?7,?8,?9,?10,?10)",
      [
        id,
        kind,
        id,
        creator,
        work_item,
        Keyword.get(opts, :origin_path, id),
        Keyword.get(opts, :digest),
        if(Keyword.get(opts, :home), do: "archived", else: "in-workspace"),
        Keyword.get(opts, :home),
        at
      ]
    )
  end

  defp insert_attest(db, id, assignment, kind, author, at, opts \\ []) do
    query!(
      db,
      "INSERT INTO attests (id,assignmentId,kind,verdictKind,note,bySession,ts) VALUES (?1,?2,?3,?4,'NOTE_SENTINEL',?5,?6)",
      [id, assignment, kind, Keyword.get(opts, :verdict), author, at]
    )
  end

  defp assert_unverified(db, fixture, field) do
    assert %{code: "spec_provenance_unverified", message: message} =
             WorkItemSpecBindings.bind(db, call(fixture))

    assert message =~ field
    assert WorkItemSpecBindings.get(db, fixture.work_item) == nil
  end

  defp concurrently(fun) when is_function(fun, 0), do: concurrently([fun, fun])

  defp concurrently(funs) do
    parent = self()

    tasks =
      Enum.map(funs, fn fun ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> fun.()
          end
        end)
      end)

    pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:ready, pid}
        pid
      end)

    Enum.each(pids, &send(&1, :go))
    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp assert_notice_counts(accepted, state) do
    notices = receive_notices(accepted + state, [])

    assert Enum.count(notices, &(&1["class"] == "verb.accepted")) == accepted
    assert Enum.count(notices, &(&1["class"] == "work_item.spec_bound")) == state
  end

  defp receive_notices(0, notices), do: Enum.reverse(notices)

  defp receive_notices(remaining, notices) do
    receive do
      {:firehose_notice, notice} ->
        Hub.delivered(Hub, self())
        receive_notices(remaining - 1, [notice | notices])
    after
      1_000 -> flunk("missing firehose notice; received #{inspect(Enum.reverse(notices))}")
    end
  end

  defp query!(db, sql, params) do
    assert {:ok, _} = DB.query(db, sql, params)
    :ok
  end

  defp update!(db, sql, params), do: query!(db, sql, params)
end
