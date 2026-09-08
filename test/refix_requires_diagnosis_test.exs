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
    db = :"proportionate_refix_db_#{System.unique_integer([:positive])}"
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
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    holder = session(db, "fix-holder", "coder")
    recon = session(db, "recon-holder", "recon")
    Roles.create!(db, "recon", "flynn", recon.session_key)

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-proportionate-refix-#{System.unique_integer([:positive])}"
      )

    assert :initialized = Archetypes.init_identity!(base_dir)
    assert {:ok, _revision} = Identity.learn!(base_dir, "agentic-engineering", "flynn")
    _archetypes = Archetypes.load!(base_dir)

    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
    rules = Rules.load!(base_dir, Map.keys(handlers))

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Rules)
      :persistent_term.erase(Archetypes)
    end)

    %{db: db, handlers: handlers, holder: holder, rules: rules}
  end

  test "the shipped bundle omits count-triggered mandatory diagnosis", ctx do
    names = Enum.map(ctx.rules, & &1.name)

    assert names == [
             "completion-requires-review",
             "code-review-requires-passing-tests",
             "completion-requires-verification",
             "completion-requires-results-artifact",
             "wake-obligation-registration-authority"
           ]

    refute "refix-requires-diagnosis" in names
  end

  test "completed evidence work does not force recon before a repair", ctx do
    item = work_item(ctx, true)
    prior = completed_evidence(ctx, item.id)

    assert {:ok, next} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               dispatch_call(ctx.holder.session_key, item.id, "bounded repair")
             )

    assert next.id != prior.id
    assert next.subject == "bounded repair"
    assert no_diagnosis_assignments(ctx.db, item.id)
    assert RailRemedy.episode(ctx.db, "refix-requires-diagnosis", item.id) == nil
  end

  test "disposed work still refuses a new assignment before any rail remedy", ctx do
    for verb <- ["work-item-close", "work-item-fail", "work-item-icebox"] do
      item = work_item(ctx, true)
      _prior = completed_evidence(ctx, item.id)

      assert %{ok: true} =
               ctx.handlers[verb].(%{
                 verb: verb,
                 origin: "user:flynn",
                 principal: {:user, "flynn"},
                 session_key: nil,
                 params: %{work_item_id: item.id}
               })

      assert {:error, %{code: "work_item_not_open"}} =
               Dispatch.dispatch(
                 ctx.db,
                 ctx.handlers,
                 dispatch_call(ctx.holder.session_key, item.id, "repeat fix")
               )

      assert no_diagnosis_assignments(ctx.db, item.id)
    end
  end

  defp work_item(ctx, is_bug) do
    WorkItems.__handle__(ctx.db, "work-item-create", %{
      principal: {:user, "flynn"},
      params: %{title: "Bug #{System.unique_integer([:positive])}", is_bug: is_bug}
    })
  end

  defp completed_evidence(ctx, work_item_id) do
    assignment =
      Assignments.__handle__(ctx.db, "assign", %{
        verb: "assign",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: ctx.holder.session_key,
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{
          subject: "completed evidence",
          work_item_id: work_item_id,
          effect_kind: "evidence"
        }
      })

    assert assignment.effectKind == "evidence"

    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "session:#{ctx.holder.session_key}",
      principal: {:session, ctx.holder.session_key},
      session_key: nil,
      params: %{assignment_id: assignment.id, kind: "completion"}
    })

    assignment
  end

  defp dispatch_call(holder_key, work_item_id, subject) do
    %{
      verb: "dispatch",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      params: %{subject: subject, brief: "Implement #{subject}.", work_item_id: work_item_id}
    }
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

  defp session(db, key, archetype) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: "custom",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: archetype,
      host: "eezo",
      harness: "codex",
      provider: "openai",
      model: Model.new("test")
    })
  end
end
