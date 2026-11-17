defmodule Tightbeam.AttestFyiTest do
  @moduledoc """
  Attest checks that compare a well-formed request with recorded state accept
  the write and state each mismatch as one neutral FYI line. Checks that keep
  a record from being stored, or that guard custody or ownership, still refuse.
  """

  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ArtifactContent, DB, Gateway, Model, Org, Placement, Schema}

  @suffix "; decide for yourself whether that is acceptable"
  @judgment_words ~w(must required requires should please invalid error forbidden refus denied violat cannot) ++
                    ["not allowed", "blocked by"]

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    :ok = ArtifactContent.ensure_schema(db)

    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1)")

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

    agent = fn key ->
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "owner",
        origin: "user:owner",
        spawned_by: main.session_key,
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "codex",
        provider: "openai",
        model: Model.new("fable")
      })
    end

    holder = agent.("agent:fyi-holder").session_key
    reviewer = agent.("agent:fyi-reviewer").session_key
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})

    item =
      handlers["work-item-create"].(%{
        principal: {:user, "owner"},
        origin: "user:owner",
        params: %{title: "FYI attest checks"}
      })

    card = fn id, holder_key, effect, reviews ->
      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO assignments
            (id,subject,holderKey,openedBySession,openedAt,workItemId,reviewsAssignmentId)
          VALUES(?1,?1,?2,?3,1,?4,?5)
          """,
          [id, holder_key, main.session_key, item.id, reviews]
        )

      {:ok, _} =
        DB.query(db, "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES(?1,?2)", [
          id,
          effect
        ])

      id
    end

    %{
      db: db,
      handlers: handlers,
      holder: holder,
      reviewer: reviewer,
      item_id: item.id,
      card: card,
      code: card.("asg_fyi_code", holder, "code", nil),
      review: card.("asg_fyi_review", reviewer, "review", "asg_fyi_code"),
      evidence: card.("asg_fyi_evidence", holder, "evidence", nil)
    }
  end

  test "a code completion whose clean review omits a verified commit is recorded with an FYI",
       ctx do
    a = String.duplicate("a", 40)
    b = String.duplicate("b", 40)

    assert %{attest: %{verdictKind: "reviewed-clean"}} =
             attest(ctx, ctx.reviewer, ctx.review, "verdict",
               verdict_kind: "reviewed-clean",
               commit_refs: refs([a])
             )

    verified =
      attest(ctx, ctx.holder, ctx.code, "verdict",
        verdict_kind: "verified",
        commit_refs: refs([a, b])
      )

    refute Map.has_key?(verified, :fyi)

    completion = attest(ctx, ctx.holder, ctx.code, "completion")
    expected = [fyi("the latest independent clean review does not list verified commit #{b}")]

    assert completion.fyi == expected
    assert completion.attest.fyi == expected
    assert completion.assignment.state == "closed"
    assert completion.assignment.outcome == "completed"
    assert read_back(ctx, ctx.code, completion.attest.id).fyi == expected
    assert_neutral(expected)

    # The closed assignment still refuses another completion.
    assert %{code: "assignment_closed"} = attest(ctx, ctx.holder, ctx.code, "completion")
  end

  test "a code completion without holder verification or independent review lists each missing fact",
       ctx do
    completion = attest(ctx, ctx.holder, ctx.code, "completion")

    expected = [
      fyi("this code assignment has no verified verdict from its holder"),
      fyi("this code assignment has no review conclusion")
    ]

    assert completion.fyi == expected
    assert completion.assignment.state == "closed"
    assert read_back(ctx, ctx.code, completion.attest.id).fyi == expected
    assert_neutral(expected)
  end

  test "a code completion with full evidence carries no FYI", ctx do
    a = String.duplicate("a", 40)

    attest(ctx, ctx.reviewer, ctx.review, "verdict",
      verdict_kind: "reviewed-clean",
      commit_refs: refs([a])
    )

    attest(ctx, ctx.holder, ctx.code, "verdict", verdict_kind: "verified", commit_refs: refs([a]))
    completion = attest(ctx, ctx.holder, ctx.code, "completion")

    refute Map.has_key?(completion, :fyi)
    refute Map.has_key?(completion.attest, :fyi)
    assert completion.assignment.state == "closed"
    refute Map.has_key?(read_back(ctx, ctx.code, completion.attest.id), :fyi)
  end

  test "a completion after a standing blocked verdict names that verdict; a cleared one does not",
       ctx do
    blocked = attest(ctx, ctx.holder, ctx.evidence, "verdict", verdict_kind: "blocked")
    completion = attest(ctx, ctx.holder, ctx.evidence, "completion")

    expected = [
      fyi(
        "the latest state verdict on this assignment is blocked (#{blocked.attest.id}) " <>
          "with no later cleared verdict"
      )
    ]

    assert completion.fyi == expected
    assert completion.assignment.state == "closed"
    assert_neutral(expected)

    cleared_card = ctx.card.("asg_fyi_cleared", ctx.holder, "evidence", nil)
    attest(ctx, ctx.holder, cleared_card, "verdict", verdict_kind: "waiting")
    attest(ctx, ctx.holder, cleared_card, "verdict", verdict_kind: "cleared")
    cleared = attest(ctx, ctx.holder, cleared_card, "completion")
    refute Map.has_key?(cleared, :fyi)
    assert cleared.assignment.state == "closed"
  end

  test "a holder verification without commit refs is recorded with an FYI", ctx do
    expected = [fyi("this verified verdict carries no commit refs")]

    no_refs = attest(ctx, ctx.holder, ctx.code, "verdict", verdict_kind: "verified")
    assert no_refs.fyi == expected
    assert no_refs.attest.verdictKind == "verified"

    empty =
      attest(ctx, ctx.holder, ctx.code, "verdict", verdict_kind: "verified", commit_refs: [])

    assert empty.fyi == expected
    assert read_back(ctx, ctx.code, empty.attest.id).fyi == expected
  end

  test "commit refs on attest kinds the completion checks do not read are recorded with an FYI",
       ctx do
    a = String.duplicate("a", 40)

    progress = attest(ctx, ctx.holder, ctx.code, "progress", note: "step", commit_refs: refs([a]))

    assert progress.attest.commitRefs == refs([a])

    assert progress.fyi == [
             fyi(
               "commit refs are recorded on this progress attest; Tightbeam's completion and " <>
                 "review-coverage checks do not read them, and the work item's commit refs include them"
             )
           ]

    blocked =
      attest(ctx, ctx.holder, ctx.code, "verdict",
        verdict_kind: "blocked",
        commit_refs: refs([a])
      )

    assert blocked.fyi == [
             fyi(
               "commit refs are recorded on this blocked verdict attest; Tightbeam's completion and " <>
                 "review-coverage checks do not read them, and the work item's commit refs include them"
             )
           ]

    review_completion =
      attest(ctx, ctx.reviewer, ctx.review, "completion", commit_refs: refs([a]))

    assert review_completion.fyi == [
             fyi(
               "commit refs are recorded on this completion attest; Tightbeam's completion and " <>
                 "review-coverage checks do not read them, and the work item's commit refs and " <>
                 "this assignment's closing commit refs include them"
             )
           ]

    assert_neutral(progress.fyi ++ blocked.fyi ++ review_completion.fyi)

    # Malformed refs still cannot be stored.
    assert %{code: "invalid_commit_refs"} =
             attest(ctx, ctx.holder, ctx.code, "progress",
               note: "bad",
               commit_refs: [%{"repo" => "r", "commit" => "not-a-commit"}]
             )
  end

  test "a revision binding to another recorded hash or producer is recorded with FYIs", ctx do
    a = String.duplicate("a", 40)
    own = capture(ctx, ctx.code, "code evidence")
    other = capture(ctx, ctx.evidence, "evidence card output")
    cited = String.duplicate("f", 64)

    mismatch =
      attest(ctx, ctx.holder, ctx.code, "verdict",
        verdict_kind: "verified",
        commit_refs: refs([a]),
        artifact_id: own.id,
        content_sha256: cited
      )

    assert mismatch.fyi == [
             fyi(
               "artifact #{own.id} is recorded with sha256 #{own.hash}; this verdict cites sha256 #{cited}"
             )
           ]

    assert mismatch.attest.artifactId == own.id
    assert mismatch.attest.contentSha256 == cited

    elsewhere =
      attest(ctx, ctx.holder, ctx.code, "verdict",
        verdict_kind: "verified",
        commit_refs: refs([a]),
        artifact_id: other.id,
        content_sha256: other.hash
      )

    assert elsewhere.fyi == [
             fyi(
               "artifact #{other.id} was produced by assignment #{ctx.evidence}, " <>
                 "not by this assignment or the assignment this card reviews"
             )
           ]

    assert_neutral(mismatch.fyi ++ elsewhere.fyi)

    # An unknown artifact or a half pair still cannot be bound.
    assert %{code: "invalid_revision_binding"} =
             attest(ctx, ctx.holder, ctx.code, "verdict",
               verdict_kind: "verified",
               commit_refs: refs([a]),
               artifact_id: "art_missing",
               content_sha256: cited
             )

    assert %{code: "invalid_revision_binding"} =
             attest(ctx, ctx.holder, ctx.code, "verdict",
               verdict_kind: "verified",
               commit_refs: refs([a]),
               artifact_id: own.id
             )
  end

  test "operational evidence differences are recorded with FYIs and malformed pairs still refuse",
       ctx do
    good = capture(ctx, ctx.evidence, "operation result")
    accepted = verified_with(ctx, ctx.evidence, good.id, good.hash)
    refute Map.has_key?(accepted, :fyi)
    assert accepted.attest.artifactId == good.id

    cited = String.duplicate("e", 64)
    digest = verified_with(ctx, ctx.evidence, good.id, cited)

    assert digest.fyi == [
             fyi(
               "the captured bytes of artifact #{good.id} have sha256 #{good.hash}; this verdict cites #{cited}"
             )
           ]

    uncaptured = capture(ctx, ctx.evidence, nil)
    missing = verified_with(ctx, ctx.evidence, uncaptured.id, cited)

    assert hd(missing.fyi) ==
             fyi(
               "artifact #{uncaptured.id} has no captured content, so its sha256 was not compared with its bytes"
             )

    from_code_card = capture(ctx, ctx.code, "code card output")
    attributed = verified_with(ctx, ctx.evidence, from_code_card.id, from_code_card.hash)

    assert attributed.fyi == [
             fyi("artifact #{from_code_card.id} was recorded for assignment #{ctx.code}")
           ]

    assert_neutral(digest.fyi ++ missing.fyi ++ attributed.fyi)

    assert %{code: "operational_evidence_invalid"} =
             verified_with(ctx, ctx.evidence, good.id, "not-a-digest")

    assert %{code: "operational_evidence_invalid"} =
             attest(ctx, ctx.holder, ctx.evidence, "verdict",
               verdict_kind: "verified",
               artifact_id: good.id,
               content_sha256: ""
             )
  end

  test "an artifact outside the selected evidence route is recorded unchecked with an FYI", ctx do
    {:ok, _} =
      DB.query(ctx.db, "INSERT INTO assignment_files(assignmentId,path) VALUES(?1,?2)", [
        ctx.evidence,
        "/example/declared-file"
      ])

    artifact = capture(ctx, ctx.evidence, "file result")
    result = verified_with(ctx, ctx.evidence, artifact.id, artifact.hash)

    assert result.fyi == [
             fyi(
               "the artifact on this verdict was not checked as operational evidence because " <>
                 "declared files are present for this assignment"
             ),
             fyi("this verified verdict carries no commit refs")
           ]

    assert result.attest.artifactId == artifact.id
    assert_neutral(result.fyi)
  end

  test "a completion while cannot-proceed stands still refuses", ctx do
    assert %{attest: %{kind: "cannot-proceed"}} =
             attest(ctx, ctx.holder, ctx.evidence, "cannot-proceed", note: "waiting on a ruling")

    assert %{code: "cannot_proceed_standing"} =
             attest(ctx, ctx.holder, ctx.evidence, "completion")
  end

  defp verified_with(ctx, assignment_id, artifact_id, digest),
    do:
      attest(ctx, ctx.holder, assignment_id, "verdict",
        verdict_kind: "verified",
        artifact_id: artifact_id,
        content_sha256: digest
      )

  defp attest(ctx, session, assignment_id, kind, params \\ []) do
    ctx.handlers["attest"].(%{
      verb: "attest",
      principal: {:session, session},
      session_key: session,
      origin: "agent:" <> session,
      params: Map.merge(%{assignment_id: assignment_id, kind: kind}, Map.new(params))
    })
  end

  defp read_back(ctx, assignment_id, attest_id) do
    %{attests: attests} =
      ctx.handlers["attests"].(%{
        verb: "attests",
        principal: {:user, "owner"},
        session_key: nil,
        origin: "user:owner",
        params: %{assignment_id: assignment_id}
      })

    Enum.find(attests, &(&1.id == attest_id))
  end

  defp capture(ctx, assignment_id, bytes) do
    params = %{
      kind: "report",
      title: "Captured evidence",
      origin_path: "/unavailable/evidence",
      work_item_id: ctx.item_id,
      produced_by_assignment_id: assignment_id
    }

    params =
      if is_binary(bytes),
        do: Map.put(params, :content_base64, Base.encode64(bytes)),
        else: params

    artifact =
      ctx.handlers["artifact-record"].(%{
        verb: "artifact-record",
        principal: {:session, ctx.holder},
        session_key: ctx.holder,
        origin: ctx.holder,
        params: params
      })

    refute Map.has_key?(artifact, :code)
    %{id: artifact.artifact_id, hash: artifact.content_sha256}
  end

  defp refs(commits), do: Enum.map(commits, &%{"repo" => "example/repo", "commit" => &1})

  defp fyi(fact), do: "FYI: " <> fact <> @suffix

  defp assert_neutral(lines) do
    Enum.each(lines, fn line ->
      assert String.starts_with?(line, "FYI: ")
      assert String.ends_with?(line, @suffix)
      fact = line |> String.trim_leading("FYI: ") |> String.trim_trailing(@suffix)
      lowered = String.downcase(fact)

      for word <- @judgment_words do
        refute String.contains?(lowered, word), "FYI #{inspect(line)} contains #{inspect(word)}"
      end
    end)
  end
end
