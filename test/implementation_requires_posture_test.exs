defmodule Tightbeam.ImplementationRequiresPostureTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Archetypes,
    DB,
    Dispatch,
    Gateway,
    Identity,
    Rules,
    WorkItems
  }

  # The posture gate (Mike, 2026-08-31): implementation runs under a posture the
  # orchestrator rules on receiving the slice, heavy or light, filed as a verdict on
  # a card on the work item. These tests prove the two rails refuse to open a coder
  # card without that verdict, on assign and on dispatch alike, that the verdict
  # releases both, and that a non-coder card on the same item is never gated.
  setup do
    db = :"posture_gate_db_#{System.unique_integer([:positive])}"
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

    coder = session(db, "posture-coder", "coder", "codex", "openai")
    orchestrator = session(db, "posture-orchestrator", "orchestrator", "codex", "openai")
    reviewer = session(db, "posture-reviewer", "reviewer-spec", "claude", "anthropic")

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-posture-gate-#{System.unique_integer([:positive])}"
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

  defp session(db, key, archetype, harness, provider) do
    Tightbeam.Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: archetype,
      harness: harness,
      provider: provider,
      host: "eezo",
      model: Model.new("sonnet", effort: "medium"),
      spawned_by: nil,
      is_built_in: false
    })
  end

  defp work_item(ctx) do
    WorkItems.__handle__(ctx.db, "work-item-create", %{
      principal: {:user, "flynn"},
      params: %{title: "Posture subject #{System.unique_integer([:positive])}"}
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
      params: %{
        subject: subject,
        brief: "Implement #{subject}.",
        work_item_id: item_id
      }
    }
  end

  defp verdict_call(session_key, assignment_id, kind, note) do
    %{
      verb: "attest",
      origin: "session:#{session_key}",
      principal: {:session, session_key},
      session_key: session_key,
      params: %{
        assignment_id: assignment_id,
        kind: "verdict",
        verdict_kind: kind,
        note: note
      }
    }
  end

  test "both rails load from the shipped bundle", ctx do
    names = Enum.map(ctx.rules, & &1.name)
    assert "implementation-requires-posture" in names
    assert "implementation-dispatch-requires-posture" in names
  end

  test "a coder card on an unpostured work item is refused on assign and on dispatch",
       ctx do
    item = work_item(ctx)

    assert {:error,
            %{code: "rule_denied", rule: "implementation-requires-posture", message: message}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               assign_call(ctx.coder.session_key, item.id, "implement the fix")
             )

    assert message =~ "posture"

    assert {:error,
            %{
              code: "rule_denied",
              rule: "implementation-dispatch-requires-posture",
              message: dispatch_message
            }} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               dispatch_call(ctx.coder.session_key, item.id, "implement the fix")
             )

    assert dispatch_message =~ "posture"
  end

  test "the orchestrator's posture verdict on its own card releases the coder card", ctx do
    item = work_item(ctx)

    # The orchestrator's slice card sits on the same work item; the rail never
    # gates it (its holder is not a coder).
    assert {:ok, slice} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               assign_call(ctx.orchestrator.session_key, item.id, "orchestrate the slice")
             )

    assert {:ok, %{attest: %{verdictKind: "posture-light"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(
                 ctx.orchestrator.session_key,
                 slice.id,
                 "posture-light",
                 "already-adjudicated fix inside the existing architecture; the input is the spec"
               )
             )

    assert {:ok, assigned} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               assign_call(ctx.coder.session_key, item.id, "implement the fix")
             )

    assert assigned.subject == "implement the fix"

    assert {:ok, dispatched} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               dispatch_call(ctx.coder.session_key, item.id, "implement the follow-up")
             )

    assert dispatched.subject == "implement the follow-up"
  end

  test "posture-heavy releases the coder card too", ctx do
    item = work_item(ctx)

    {:ok, slice} =
      Dispatch.dispatch(
        ctx.db,
        ctx.handlers,
        assign_call(ctx.orchestrator.session_key, item.id, "orchestrate the slice")
      )

    {:ok, _} =
      Dispatch.dispatch(
        ctx.db,
        ctx.handlers,
        verdict_call(
          ctx.orchestrator.session_key,
          slice.id,
          "posture-heavy",
          "new infrastructure; full spec cycle"
        )
      )

    assert {:ok, _} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               dispatch_call(ctx.coder.session_key, item.id, "implement goal 1")
             )
  end

  test "a non-coder card on an unpostured work item is not gated", ctx do
    item = work_item(ctx)

    assert {:ok, review} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               assign_call(ctx.reviewer.session_key, item.id, "review the spec")
             )

    assert review.subject == "review the spec"
  end

  test "a posture verdict on another work item does not release this one", ctx do
    item = work_item(ctx)
    other = work_item(ctx)

    {:ok, slice} =
      Dispatch.dispatch(
        ctx.db,
        ctx.handlers,
        assign_call(ctx.orchestrator.session_key, other.id, "orchestrate the other slice")
      )

    {:ok, _} =
      Dispatch.dispatch(
        ctx.db,
        ctx.handlers,
        verdict_call(ctx.orchestrator.session_key, slice.id, "posture-light", "elsewhere")
      )

    assert {:error, %{code: "rule_denied", rule: "implementation-requires-posture"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               assign_call(ctx.coder.session_key, item.id, "implement the fix")
             )
  end
end
