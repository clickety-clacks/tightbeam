defmodule Tightbeam.ImplementationRequiresPostureTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model
  alias Tightbeam.{Archetypes, DB, Dispatch, Gateway, Identity, Rules, WorkItems}

  setup do
    db = :"proportionate_dispatch_db_#{System.unique_integer([:positive])}"
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

    coder = session(db, "proportionate-coder", "coder")
    orchestrator = session(db, "proportionate-orchestrator", "orchestrator")
    reviewer = session(db, "proportionate-reviewer", "reviewer-spec")

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-proportionate-dispatch-#{System.unique_integer([:positive])}"
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

    %{
      db: db,
      handlers: handlers,
      coder: coder,
      orchestrator: orchestrator,
      reviewer: reviewer,
      rules: rules
    }
  end

  test "the shipped bundle omits posture-token admission rails", ctx do
    names = Enum.map(ctx.rules, & &1.name)
    refute "implementation-requires-posture" in names
    refute "implementation-dispatch-requires-posture" in names
  end

  test "coder assignment and dispatch proceed without a posture receipt", ctx do
    item = work_item(ctx)

    assert {:ok, assigned} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               assign_call(ctx.coder.session_key, item.id, "implement the bounded repair")
             )

    assert assigned.subject == "implement the bounded repair"

    assert {:ok, dispatched} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               dispatch_call(ctx.coder.session_key, item.id, "implement the follow-up")
             )

    assert dispatched.subject == "implement the follow-up"
  end

  test "a legacy posture-light verdict remains ordinary evidence, not an admission token", ctx do
    item = work_item(ctx)

    assert {:ok, slice} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               assign_call(ctx.orchestrator.session_key, item.id, "coordinate the repair")
             )

    assert {:ok, %{attest: %{verdictKind: "posture-light"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.orchestrator.session_key, slice.id, "posture-light")
             )

    assert {:ok, implementation} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               assign_call(ctx.coder.session_key, item.id, "implement after judgment")
             )

    assert implementation.subject == "implement after judgment"
  end

  test "a legacy posture-heavy verdict does not select a mechanical workflow", ctx do
    item = work_item(ctx)

    assert {:ok, slice} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               assign_call(ctx.orchestrator.session_key, item.id, "coordinate consequential work")
             )

    assert {:ok, %{attest: %{verdictKind: "posture-heavy"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.orchestrator.session_key, slice.id, "posture-heavy")
             )

    assert {:ok, implementation} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               dispatch_call(ctx.coder.session_key, item.id, "implement the authorized slice")
             )

    assert implementation.subject == "implement the authorized slice"
  end

  test "a non-coder assignment remains admitted without a posture receipt", ctx do
    item = work_item(ctx)

    assert {:ok, review} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               assign_call(ctx.reviewer.session_key, item.id, "review the specification")
             )

    assert review.subject == "review the specification"
  end

  test "posture evidence on another item has no admission effect", ctx do
    item = work_item(ctx)
    other = work_item(ctx)

    assert {:ok, slice} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               assign_call(ctx.orchestrator.session_key, other.id, "coordinate another item")
             )

    assert {:ok, _} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.orchestrator.session_key, slice.id, "posture-light")
             )

    assert {:ok, implementation} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               assign_call(ctx.coder.session_key, item.id, "implement independently")
             )

    assert implementation.subject == "implement independently"
  end

  defp work_item(ctx) do
    WorkItems.__handle__(ctx.db, "work-item-create", %{
      principal: {:user, "flynn"},
      params: %{title: "Proportionate work #{System.unique_integer([:positive])}"}
    })
  end

  defp assign_call(holder_key, item_id, subject) do
    %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      params: %{subject: subject, work_item_id: item_id}
    }
  end

  defp dispatch_call(holder_key, item_id, subject) do
    %{
      verb: "dispatch",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      params: %{subject: subject, brief: "Implement #{subject}.", work_item_id: item_id}
    }
  end

  defp verdict_call(session_key, assignment_id, kind) do
    %{
      verb: "attest",
      origin: "session:#{session_key}",
      principal: {:session, session_key},
      session_key: session_key,
      params: %{assignment_id: assignment_id, kind: "verdict", verdict_kind: kind}
    }
  end

  defp session(db, key, archetype) do
    Tightbeam.Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: archetype,
      harness: "codex",
      provider: "openai",
      host: "eezo",
      model: Model.new("sonnet", effort: "medium"),
      spawned_by: nil,
      is_built_in: false
    })
  end
end
