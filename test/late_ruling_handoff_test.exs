defmodule Tightbeam.LateRulingHandoffTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assignments, ConnRegistry, DB, Escalation, Model, Org, Wakes, WorkItems}

  @incident_request_id "dr_07bdef13-45ae-435f-bc79-b2dc6b0a5ebf"

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, _session_key}, _from, parent),
      do: {:reply, :ok, parent}
  end

  setup do
    db = :"late_ruling_db_#{System.unique_integer([:positive])}"
    scheduler = :"late_ruling_scheduler_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    insert_user!(db, "flynn")

    ensure_main_session(db, "flynn")
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    register_hosts(db, %{
      "fixture" => %{
        ssh: nil,
        base_dir: Application.fetch_env!(:tightbeam, :base_dir),
        cli_bin: nil
      }
    })

    opener = session(db, "agent:opener:test", "flynn")
    raiser = session(db, "agent:raiser:test", "flynn")
    replacement_holder = session(db, "agent:replacement:test", "flynn")

    start_supervised!(
      {Wakes, db: db, name: scheduler, tick_ms: 60_000, deliver: fn _wake -> :ok end}
    )

    %{
      db: db,
      scheduler: scheduler,
      opener: opener,
      raiser: raiser,
      replacement_holder: replacement_holder
    }
  end

  test "dr_07bdef13_survives_revocation_late_ruling_successor_and_consumption", ctx do
    source_item = work_item(ctx.db, ctx.opener.session_key, "source item")

    source =
      assign(
        ctx.db,
        ctx.opener.session_key,
        ctx.raiser.session_key,
        "source assignment",
        source_item.id
      )

    generated =
      Escalation.operator_ask(ctx.db, %{
        verb: "operator-ask",
        origin: ctx.raiser.session_key,
        principal: {:session, ctx.raiser.session_key},
        transport_session_key: ctx.raiser.session_key,
        params: %{question: "apply the incident ruling?", assignment_id: source.id}
      })

    rename_request!(ctx.db, generated.id, @incident_request_id)

    revoked =
      Assignments.__handle__(ctx.db, "revoke-assignment", %{
        verb: "revoke-assignment",
        origin: ctx.opener.session_key,
        principal: {:session, ctx.opener.session_key},
        params: %{assignment_id: source.id, reason: "replace the failed producer"}
      })

    assert revoked.state == "closed"
    assert revoked.outcome == "revoked"

    Org.retire(ctx.db, ctx.raiser.session_key, "session:#{ctx.opener.session_key}", 1_000)

    assert %{id: @incident_request_id, status: "ruled"} =
             Escalation.operator_rule(
               ctx.db,
               %{
                 verb: "operator-rule",
                 origin: "user:flynn",
                 principal: {:user, "flynn"},
                 transport_session_key: nil,
                 params: %{request: @incident_request_id, decision: "accept"}
               },
               scheduler: ctx.scheduler
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='operator-ruling-late-routed' AND scope=?1 AND origin='process:tightbeam'",
               [@incident_request_id]
             )

    assert {:ok, [[session_key]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope=?1",
               [@incident_request_id]
             )

    assert session_key == ctx.opener.session_key
    refute session_key == ctx.raiser.session_key

    replacement_item = work_item(ctx.db, ctx.opener.session_key, "replacement item")

    replacement =
      assign(
        ctx.db,
        ctx.opener.session_key,
        ctx.replacement_holder.session_key,
        "replacement assignment",
        replacement_item.id,
        succeeds: source.id,
        key: "incident-replacement"
      )

    expected_subject =
      "replacement assignment\n\n" <>
        "Ruled-but-unconsumed decisions carried from #{source.id}: #{@incident_request_id}"

    assert replacement.subject == expected_subject

    assert {:ok, [[^expected_subject]]} =
             DB.query(ctx.db, "SELECT subject FROM assignments WHERE id=?1", [replacement.id])

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='assignment-successor-created' AND scope=?1 AND origin='process:tightbeam'",
               [replacement.id]
             )

    replayed_assignment =
      assign(
        ctx.db,
        ctx.opener.session_key,
        ctx.replacement_holder.session_key,
        "ignored replay subject",
        replacement_item.id,
        succeeds: "asg_missing",
        key: "incident-replacement"
      )

    assert replayed_assignment.id == replacement.id
    assert replayed_assignment.subject == expected_subject

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='assignment-successor-created' AND scope=?1",
               [replacement.id]
             )

    commit = git_head!()
    commit_ref = %{repo: "fixture:#{File.cwd!()}", commit: commit}
    verdict_kind = "ruling-consumed:" <> @incident_request_id

    receipt_call = %{
      verb: "attest",
      origin: ctx.opener.session_key,
      principal: {:session, ctx.opener.session_key},
      params: %{
        assignment_id: source.id,
        kind: "verdict",
        verdict_kind: verdict_kind,
        commit_refs: [commit_ref]
      }
    }

    before_source = assignment_row(ctx.db, source.id)
    before_request = request_row(ctx.db, @incident_request_id)

    assert %{attest: first_receipt} = Assignments.__handle__(ctx.db, "attest", receipt_call)
    assert first_receipt.verdictKind == verdict_kind
    assert first_receipt.commitRefs == [%{"commit" => commit, "repo" => commit_ref.repo}]
    assert first_receipt.note == nil
    assert assignment_row(ctx.db, source.id) == before_source
    assert request_row(ctx.db, @incident_request_id) == before_request

    assert %{attest: replayed_receipt} = Assignments.__handle__(ctx.db, "attest", receipt_call)
    assert replayed_receipt.id == first_receipt.id

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM attests WHERE assignmentId=?1 AND kind='verdict' AND verdictKind=?2",
               [source.id, verdict_kind]
             )

    assert %{code: "ruling_consumption_conflict"} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               put_in(receipt_call, [:params, :commit_refs], nil)
               |> put_in([:params, :note], "operational-action: duplicate target")
             )

    assert %{assignment: %{state: "closed", outcome: "completed"}} =
             Assignments.__handle__(ctx.db, "attest", %{
               verb: "attest",
               origin: ctx.replacement_holder.session_key,
               principal: {:session, ctx.replacement_holder.session_key},
               params: %{assignment_id: replacement.id, kind: "completion"}
             })

    second =
      assign(
        ctx.db,
        ctx.opener.session_key,
        ctx.replacement_holder.session_key,
        "second successor",
        replacement_item.id,
        succeeds: replacement.id
      )

    assert second.subject ==
             "second successor\n\n" <>
               "Ruled-but-unconsumed decisions carried from #{replacement.id}: none"

    refute second.subject =~ @incident_request_id
  end

  test "late ruling and successor refusals leave every mutation surface unchanged", ctx do
    source_item = work_item(ctx.db, ctx.opener.session_key, "refusal source")

    source =
      assign(
        ctx.db,
        ctx.opener.session_key,
        ctx.raiser.session_key,
        "refusal source assignment",
        source_item.id
      )

    request =
      Escalation.operator_ask(ctx.db, %{
        verb: "operator-ask",
        origin: ctx.raiser.session_key,
        principal: {:session, ctx.raiser.session_key},
        transport_session_key: ctx.raiser.session_key,
        params: %{question: "unroutable ruling?", assignment_id: source.id}
      })

    assert %{code: "predecessor_not_terminal"} =
             assign(
               ctx.db,
               ctx.opener.session_key,
               ctx.replacement_holder.session_key,
               "too early",
               source_item.id,
               succeeds: source.id
             )

    revoked =
      Assignments.__handle__(ctx.db, "revoke-assignment", %{
        verb: "revoke-assignment",
        origin: ctx.opener.session_key,
        principal: {:session, ctx.opener.session_key},
        params: %{assignment_id: source.id, reason: "terminal for refusal proof"}
      })

    assert revoked.state == "closed"

    insert_user!(ctx.db, "other")
    ensure_main_session(ctx.db, "other")
    outsider = session(ctx.db, "agent:outsider:test", "other")

    before_successor_refusals = mutation_counts(ctx.db)

    assert %{code: "unknown_assignment"} =
             assign(
               ctx.db,
               outsider.session_key,
               outsider.session_key,
               "invisible predecessor",
               nil,
               succeeds: source.id
             )

    assert %{code: "unknown_assignment"} =
             assign(
               ctx.db,
               ctx.opener.session_key,
               ctx.replacement_holder.session_key,
               "missing predecessor",
               nil,
               succeeds: "asg_missing"
             )

    assert %{code: "successor_brief_too_long"} =
             assign(
               ctx.db,
               ctx.opener.session_key,
               ctx.replacement_holder.session_key,
               String.duplicate("x", 2000),
               source_item.id,
               succeeds: source.id
             )

    assert mutation_counts(ctx.db) == before_successor_refusals

    Org.retire(ctx.db, ctx.raiser.session_key, "user:flynn", 1_000)
    Org.retire(ctx.db, ctx.opener.session_key, "user:flynn", 1_000)
    Org.retire(ctx.db, Org.personal_session_key("flynn"), "user:flynn", 1_000)

    before_ruling = mutation_counts(ctx.db)

    assert %{code: "late_ruling_recipient_unavailable"} =
             Escalation.operator_rule(ctx.db, %{
               verb: "operator-rule",
               origin: "user:flynn",
               principal: {:user, "flynn"},
               transport_session_key: nil,
               params: %{request: request.id, decision: "accept"}
             })

    assert mutation_counts(ctx.db) == before_ruling
    assert hd(request_row(ctx.db, request.id)) == "open"
  end

  test "receipt boundary is opaque and operational targets are singular", ctx do
    source_item = work_item(ctx.db, ctx.opener.session_key, "receipt source")

    source =
      assign(
        ctx.db,
        ctx.opener.session_key,
        ctx.raiser.session_key,
        "receipt source assignment",
        source_item.id
      )

    request =
      Escalation.operator_ask(ctx.db, %{
        verb: "operator-ask",
        origin: ctx.raiser.session_key,
        principal: {:session, ctx.raiser.session_key},
        transport_session_key: ctx.raiser.session_key,
        params: %{question: "consume this ruling?", assignment_id: source.id}
      })

    assert %{state: "closed"} =
             Assignments.__handle__(ctx.db, "revoke-assignment", %{
               verb: "revoke-assignment",
               origin: ctx.opener.session_key,
               principal: {:session, ctx.opener.session_key},
               params: %{assignment_id: source.id, reason: "route the late ruling"}
             })

    Org.retire(ctx.db, ctx.raiser.session_key, "user:flynn", 1_000)

    assert %{status: "ruled"} =
             Escalation.operator_rule(
               ctx.db,
               %{
                 verb: "operator-rule",
                 origin: "user:flynn",
                 principal: {:user, "flynn"},
                 transport_session_key: nil,
                 params: %{request: request.id, decision: "accept"}
               },
               scheduler: ctx.scheduler
             )

    insert_user!(ctx.db, "other")
    ensure_main_session(ctx.db, "other")
    outsider = session(ctx.db, "agent:receipt-outsider:test", "other")
    verdict_kind = "ruling-consumed:" <> request.id

    receipt = %{
      verb: "attest",
      origin: ctx.opener.session_key,
      principal: {:session, ctx.opener.session_key},
      params: %{assignment_id: source.id, kind: "verdict", verdict_kind: verdict_kind}
    }

    known_outside =
      Assignments.__handle__(
        ctx.db,
        "attest",
        %{receipt | origin: outsider.session_key, principal: {:session, outsider.session_key}}
      )

    unknown_outside =
      Assignments.__handle__(
        ctx.db,
        "attest",
        receipt
        |> Map.put(:origin, outsider.session_key)
        |> Map.put(:principal, {:session, outsider.session_key})
        |> put_in(
          [:params, :verdict_kind],
          "ruling-consumed:dr_00000000-0000-4000-8000-000000000000"
        )
      )

    assert known_outside == unknown_outside
    assert known_outside.code == "not_found"

    assert %{code: "invalid_ruling_consumption_target"} =
             Assignments.__handle__(ctx.db, "attest", receipt)

    assert %{code: "invalid_ruling_consumption_target"} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               put_in(receipt, [:params, :note], "not-an-operational-action")
             )

    assert %{code: "invalid_ruling_consumption_target"} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               put_in(receipt, [:params, :commit_refs], [
                 %{repo: "fixture:#{File.cwd!()}", commit: "missing"}
               ])
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM attests WHERE assignmentId=?1 AND verdictKind=?2",
               [source.id, verdict_kind]
             )

    action_receipt =
      receipt
      |> Map.put(:origin, "user:flynn")
      |> Map.put(:principal, {:user, "flynn"})
      |> put_in([:params, :note], "operational-action: reloaded the affected session")

    assert %{attest: first} = Assignments.__handle__(ctx.db, "attest", action_receipt)
    assert first.note == "operational-action: reloaded the affected session"
    assert first.commitRefs == nil

    assert %{attest: replay} = Assignments.__handle__(ctx.db, "attest", action_receipt)
    assert replay.id == first.id

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM attests WHERE assignmentId=?1 AND verdictKind=?2",
               [source.id, verdict_kind]
             )
  end

  defp mutation_counts(db) do
    {:ok, [counts]} =
      DB.query(
        db,
        "SELECT (SELECT COUNT(*) FROM assignments), (SELECT COUNT(*) FROM wakes), " <>
          "(SELECT COUNT(*) FROM condition_facts), (SELECT COUNT(*) FROM attests), " <>
          "(SELECT COUNT(*) FROM lifecycle_events)"
      )

    counts
  end

  defp rename_request!(db, generated_id, literal_id) do
    {:ok, _} =
      DB.query(db, "UPDATE decision_requests SET id=?2 WHERE id=?1", [generated_id, literal_id])

    {:ok, _} =
      DB.query(db, "UPDATE lifecycle_events SET subject=?2 WHERE subject=?1", [
        generated_id,
        literal_id
      ])

    {:ok, _} =
      DB.query(
        db,
        "UPDATE wakes SET prompt=replace(prompt, ?1, ?2) WHERE prompt LIKE '%' || ?1 || '%'",
        [
          generated_id,
          literal_id
        ]
      )

    :ok
  end

  defp insert_user!(db, user_id) do
    {:ok, columns} = DB.query(db, "PRAGMA table_info(users)")

    sql =
      if Enum.any?(columns, fn [_position, name | _rest] -> name == "creationKind" end) do
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES (?1, 0, 'admin_add', 1)"
      else
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES (?1, 0, 1)"
      end

    {:ok, _} = DB.query(db, sql, [user_id])
    :ok
  end

  defp work_item(db, opener, title) do
    WorkItems.__handle__(db, "work-item-create", %{
      verb: "work-item-create",
      origin: opener,
      principal: {:session, opener},
      session_key: nil,
      supervision_interval_ms: 1_000,
      params: %{title: title}
    })
  end

  defp assign(db, opener, holder, subject, work_item_id, opts \\ []) do
    params = %{
      subject: subject,
      work_item_id: work_item_id,
      idempotency_key: opts[:key],
      succeeds_assignment_id: opts[:succeeds]
    }

    Assignments.__handle__(db, "assign", %{
      verb: "assign",
      origin: opener,
      principal: {:session, opener},
      session_key: holder,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: params
    })
  end

  defp assignment_row(db, assignment_id) do
    {:ok, [row]} =
      DB.query(
        db,
        "SELECT state,outcome,closedAt,closedByUser,closedBySession,closingAttestId FROM assignments WHERE id=?1",
        [assignment_id]
      )

    row
  end

  defp request_row(db, request_id) do
    {:ok, [row]} =
      DB.query(
        db,
        "SELECT status,decision,ruledAt,rulingFactId,consumedAt FROM decision_requests WHERE id=?1",
        [request_id]
      )

    row
  end

  defp git_head! do
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true)
    String.trim(commit)
  end

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "fixture",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end
end
