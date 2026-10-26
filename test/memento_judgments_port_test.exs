defmodule Tightbeam.MementoJudgmentsPortTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, MementoFacts, MementoJudgments, Mementos, Model, Org, Placement, Schema}

  test "holder and linked-review selectors retain their distinct authorship" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    :ok = MementoJudgments.ensure_schema(db)
    :ok = Mementos.ensure_schema(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1)"
      )

    main =
      Org.create(db, %{
        session_key: Org.personal_session_key("owner"),
        display_name: "Main",
        kind: "main",
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "codex",
        provider: "openai",
        model: Model.new("fable")
      })

    holder = create_session(db, "agent:holder", main.session_key)
    reviewer = create_session(db, "agent:reviewer", main.session_key)

    for {id, key, reviewed} <- [
          {"asg_producer", holder.session_key, nil},
          {"asg_review", reviewer.session_key, "asg_producer"}
        ] do
      {:ok, _} =
        DB.query(
          db,
          "INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,reviewsAssignmentId) VALUES(?1,'subject',?2,?3,1,?4)",
          [id, key, main.session_key, reviewed]
        )
    end

    assert MementoJudgments.latest(db, "asg_producer", "holder") == nil

    for {id, assignment, author, verdict, ts} <- [
          {"att_1", "asg_producer", holder.session_key, "verified", 10},
          {"att_2", "asg_producer", holder.session_key, "verified", 20},
          {"att_3", "asg_review", reviewer.session_key, "reviewed-clean", 30}
        ] do
      {:ok, _} =
        DB.query(
          db,
          "INSERT INTO attests(id,assignmentId,kind,verdictKind,bySession,ts) VALUES(?1,?2,'verdict',?3,?4,?5)",
          [id, assignment, verdict, author, ts]
        )
    end

    assert MementoJudgments.latest(db, "asg_producer", "holder") == %{
             id: "att_2",
             judgment_kind: "verified",
             independent: false
           }

    assert MementoJudgments.latest(db, "asg_producer", "linked_review") == %{
             id: "att_3",
             judgment_kind: "reviewed-clean",
             independent: true
           }

    assert {:ok, _} =
             DB.transaction(db, fn txn ->
               Mementos.append_in_txn!(
                 txn,
                 "attest",
                 "att_3",
                 [{"example/evidence", ["file-evidence/v1:example:digest"]}],
                 {:session, reviewer.session_key},
                 "revision"
               )
             end)

    selected = MementoFacts.select(db, "asg_producer", "latest_linked_review")

    assert MementoFacts.judgment_value(db, selected, "memento_matches_call.example/evidence", [
             {"example/evidence", ["file-evidence/v1:example:digest"]}
           ])

    refute MementoFacts.judgment_value(db, selected, "memento_matches_call.example/evidence", [
             {"example/evidence", ["different"]}
           ])

    assert MementoFacts.judgment_value(db, nil, "has_memento.example/evidence", []) == false
  end

  defp create_session(db, key, parent) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "owner",
      origin: "user:owner",
      spawned_by: parent,
      archetype: "default",
      host: Placement.local_host_name(),
      harness: "codex",
      provider: "openai",
      model: Model.new("fable")
    })
  end
end
