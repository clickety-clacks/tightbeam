defmodule Tightbeam.RefixRequiresDiagnosisTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Archetypes,
    Assignments,
    DB,
    Dispatch,
    Gateway,
    Identity,
    Org,
    RailRemedy,
    Roles,
    Rules,
    WorkItems
  }

  setup do
    db = :"refix_diagnosis_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

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
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('flynn', 1, 'admin_add', 1)"
      )

    ensure_main_session(db, "flynn")

    holder = session(db, "fix-holder", "coder", "claude", "anthropic")
    recon = session(db, "recon-holder", "recon", "codex", "openai")
    Roles.create!(db, "recon", "flynn", recon.session_key)

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-refix-diagnosis-#{System.unique_integer([:positive])}"
      )

    assert :initialized = Archetypes.init_identity!(base_dir)
    assert {:ok, _revision} = Identity.learn!(base_dir, "agentic-engineering", "flynn")
    archetypes = Archetypes.load!(base_dir)

    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})

    rules = Rules.load!(base_dir, Map.keys(handlers))

    on_exit(fn ->
      Tightbeam.TestCase.cleanup_dir!(base_dir)
      :persistent_term.erase(Rules)
      :persistent_term.erase(Archetypes)
    end)

    %{
      archetypes: archetypes,
      base_dir: base_dir,
      db: db,
      handlers: handlers,
      holder: holder,
      recon: recon,
      rules: rules
    }
  end

  test "shipped statute loads through satisfiability and first-attempt bugs proceed", ctx do
    assert Enum.map(ctx.rules, & &1.name) == [
             "completion-requires-review",
             "refix-requires-diagnosis",
             "code-review-requires-passing-tests",
             "spec-dispatch-requires-spirit",
             "review-rounds-doorbell",
             "completion-requires-verification",
             "completion-requires-results-artifact"
           ]

    item = work_item(ctx, true)

    assert {:ok, assignment} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               dispatch_call(ctx.holder.session_key, item.id, "first fix")
             )

    assert assignment.subject == "first fix"
    assert no_diagnosis_assignments(ctx.db, item.id)
  end

  test "completed prior bug fix redirects re-dispatch once to a bug-provenance recon", ctx do
    item = work_item(ctx, true)
    prior = completed_fix(ctx, item.id)
    call = dispatch_call(ctx.holder.session_key, item.id, "repeat fix")

    assert {:error,
            %{
              reason: "remedy_fired",
              producer: diagnosis_id,
              ref: work_item_id,
              rule: "refix-requires-diagnosis"
            }} = Dispatch.dispatch(ctx.db, ctx.handlers, call)

    assert work_item_id == item.id

    diagnosis = assignment(ctx.db, diagnosis_id)
    assert diagnosis.holderKey == ctx.recon.session_key
    assert diagnosis.holderRole == "recon"
    assert diagnosis.reviewsAssignmentId == prior.id
    assert diagnosis.workItemId == item.id
    assert diagnosis.subject == "diagnosis of prior fix for work item #{item.id}"
    assert "bug-provenance" in ctx.archetypes["recon"].skills

    assert %{status: "live", producer_key: ^diagnosis_id} =
             RailRemedy.episode(ctx.db, "refix-requires-diagnosis", item.id)

    assert {:error, %{reason: "remedy_fired", producer: ^diagnosis_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, call)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               """
               SELECT count(*)
               FROM assignments
               WHERE workItemId = ?1 AND reviewsAssignmentId = ?2
               """,
               [item.id, prior.id]
             )
  end

  test "independent diagnosed verdict releases the re-fix dispatch", ctx do
    item = work_item(ctx, true)
    prior = completed_fix(ctx, item.id)
    call = dispatch_call(ctx.holder.session_key, item.id, "diagnosed repeat fix")

    assert {:error, %{producer: diagnosis_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, call)

    assert {:ok, %{attest: %{verdictKind: "diagnosed"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.recon.session_key, diagnosis_id, "diagnosed")
             )

    assert {:ok, refix} = Dispatch.dispatch(ctx.db, ctx.handlers, call)
    assert refix.subject == "diagnosed repeat fix"
    assert refix.id != prior.id

    assert %{status: "closed", producer_key: ^diagnosis_id} =
             RailRemedy.episode(ctx.db, "refix-requires-diagnosis", item.id)
  end

  test "non-bug work item with a completed prior fix is unaffected", ctx do
    item = work_item(ctx, false)
    prior = completed_fix(ctx, item.id)

    assert {:ok, next} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               dispatch_call(ctx.holder.session_key, item.id, "ordinary follow-up")
             )

    assert next.id != prior.id
    assert next.subject == "ordinary follow-up"
    assert no_diagnosis_assignments(ctx.db, item.id)
    assert RailRemedy.episode(ctx.db, "refix-requires-diagnosis", item.id) == nil
  end

  test "open fixes and completed review aspects do not count as completed prior fixes", ctx do
    item = work_item(ctx, true)
    open_fix = assign(ctx, ctx.holder.session_key, item.id, "open fix")

    review =
      assign(
        ctx,
        ctx.recon.session_key,
        item.id,
        "completed review aspect",
        reviews_assignment_id: open_fix.id
      )

    complete(ctx, ctx.recon.session_key, review.id)

    assert {:ok, next} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               dispatch_call(ctx.holder.session_key, item.id, "still first completed fix")
             )

    assert next.subject == "still first completed fix"
    assert no_diagnosis_assignments(ctx.db, item.id)
  end

  test "Proof 12: a disposed item beats the rail — no remedy episode, no diagnosis assignment",
       ctx do
    for verb <- ["work-item-close", "work-item-fail", "work-item-icebox"] do
      item = work_item(ctx, true)
      _prior = completed_fix(ctx, item.id)

      # Dispose the item (its prior fix is closed, so zero open assignments).
      assert %{ok: true} =
               ctx.handlers[verb].(%{
                 verb: verb,
                 origin: "user:flynn",
                 principal: {:user, "flynn"},
                 session_key: nil,
                 params: %{work_item_id: item.id}
               })

      # Dispatching the refix flow against the disposed item is refused by the
      # pre-statute terminal guard: no remedy episode, no diagnosis assignment.
      assert {:error, %{code: "work_item_not_open"}} =
               Dispatch.dispatch(
                 ctx.db,
                 ctx.handlers,
                 dispatch_call(ctx.holder.session_key, item.id, "repeat fix")
               )

      assert RailRemedy.episode(ctx.db, "refix-requires-diagnosis", item.id) == nil
      assert no_diagnosis_assignments(ctx.db, item.id)
    end
  end

  defp work_item(ctx, is_bug) do
    WorkItems.__handle__(ctx.db, "work-item-create", %{
      principal: {:user, "flynn"},
      params: %{title: "Bug #{System.unique_integer([:positive])}", is_bug: is_bug}
    })
  end

  defp completed_fix(ctx, work_item_id) do
    assignment = assign(ctx, ctx.holder.session_key, work_item_id, "completed fix")
    complete(ctx, ctx.holder.session_key, assignment.id)
    assignment
  end

  defp assign(ctx, holder_key, work_item_id, subject, opts \\ []) do
    Assignments.__handle__(ctx.db, "assign", %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: %{
        subject: subject,
        work_item_id: work_item_id,
        reviews_assignment_id: opts[:reviews_assignment_id]
      }
    })
  end

  defp complete(ctx, holder_key, assignment_id) do
    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "agent:#{holder_key}",
      principal: {:session, holder_key},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: "completion"}
    })
  end

  defp dispatch_call(holder_key, work_item_id, subject) do
    %{
      verb: "dispatch",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      params: %{
        subject: subject,
        brief: "Implement #{subject}.",
        work_item_id: work_item_id
      }
    }
  end

  defp verdict_call(holder_key, assignment_id, kind) do
    %{
      verb: "attest",
      origin: "agent:recon",
      principal: {:session, holder_key},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: "verdict", verdict_kind: kind}
    }
  end

  defp assignment(db, assignment_id) do
    Assignments.__handle__(db, "assignment-get", %{
      principal: {:user, "flynn"},
      params: %{assignment_id: assignment_id}
    })
  end

  defp no_diagnosis_assignments(db, work_item_id) do
    match?(
      {:ok, [[0]]},
      DB.query(
        db,
        "SELECT count(*) FROM assignments WHERE workItemId = ?1 AND holderRole = 'recon'",
        [work_item_id]
      )
    )
  end

  defp session(db, key, archetype, harness, provider) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: "custom",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: archetype,
      host: "eezo",
      harness: harness,
      provider: provider,
      model: Model.new("test")
    })
  end
end
