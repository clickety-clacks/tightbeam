defmodule Tightbeam.RetireOwnershipTest do
  @moduledoc """
  Proofs for task #34: `retire` derived the caller's owner by string-stripping
  `call.origin`, so an agent whose origin is `agent:<role>` — the normal spawned
  agent — resolved to a non-username, matched no row, and got `not_found`. No
  agent could retire anything, including sessions its own owner controls, while
  the guidance tightbeam SHIPS tells agents to do exactly that
  (`priv/guidance/operating-manual.md`, orchestrator guidance).

  Admin is deliberately NOT granted cross-owner retire: Flynn's ruling is that
  admin's role is approving newly registered devices, so widening it here would
  put authority in a role that does not mean that — even though
  `session_mutation_allowed/3` happens to grant admins for other mutations.
  """
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Assignments,
    ConnRegistry,
    DB,
    EffortCheckin,
    Gateway,
    Org,
    Roles
  }

  setup do
    db = :"retire_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})

    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('flynn',0,'admin_add',1),('kay',0,'admin_add',1),('root',1,'admin_add',1)"
      )

    # An ordinary spawned agent: a session holding a role, owned by flynn.
    session!(db, "agent:worker:app", "flynn")
    Roles.create!(db, "worker", "flynn", "agent:worker:app")

    %{
      db: db,
      handlers: Gateway.handlers(%{db: db, base_dir: System.tmp_dir!(), wake_tick_ms: 1_000})
    }
  end

  test "a role-origin agent retires a session its own owner owns", ctx do
    session!(ctx.db, "target", "flynn")

    # THE BUG: this returned %{code: "not_found"} for every agent origin.
    assert %{deleted_session_key: "target", retired_session_keys: ["target"]} =
             retire(ctx, "agent:worker", {:session, "agent:worker:app"}, "target")

    assert Org.get(ctx.db, "target").state == "retired"
  end

  test "a cross-owner retire still gets not_found", ctx do
    session!(ctx.db, "kays-session", "kay")

    assert %{code: "not_found"} =
             retire(ctx, "agent:worker", {:session, "agent:worker:app"}, "kays-session")

    assert Org.get(ctx.db, "kays-session").state == "active"
  end

  test "admin is NOT granted cross-owner retire", ctx do
    session!(ctx.db, "kays-other", "kay")

    # Flynn's ruling: admin approves devices; it is not a cross-owner mutation
    # grant. This asserts the authority was NOT widened while fixing the bug.
    assert %{code: "not_found"} = retire(ctx, "user:root", {:user, "root"}, "kays-other")
    assert Org.get(ctx.db, "kays-other").state == "active"
  end

  test "a process origin still gets not_found", ctx do
    session!(ctx.db, "process-target", "flynn")

    # `resolve_caller/2` gives a process a nil owner, and ownerUserId is NOT NULL,
    # so the fall-through to not_found is by construction rather than by guard.
    assert %{code: "not_found"} = retire(ctx, "process:cron", nil, "process-target")
    assert Org.get(ctx.db, "process-target").state == "active"
  end

  test "an unknown origin still gets not_found", ctx do
    session!(ctx.db, "unknown-target", "flynn")

    assert %{code: "not_found"} = retire(ctx, "agent:no-such-role", nil, "unknown-target")
    assert Org.get(ctx.db, "unknown-target").state == "active"
  end

  test "the idempotency key is scoped to the resolved user, not the origin string", ctx do
    session!(ctx.db, "idem-target", "flynn")

    assert %{deleted_session_key: "idem-target"} =
             retire(ctx, "agent:worker", {:session, "agent:worker:app"}, "idem-target", "key-1")

    # The record is keyed on the OWNER, so the same key replays for the same user
    # regardless of which origin string presented it.
    {:ok, rows} =
      DB.query(ctx.db, "SELECT ownerUserId FROM wire_idempotency WHERE idempotencyKey = 'key-1'")

    assert rows == [["flynn"]]
    refute rows == [["agent:worker"]]

    # And the replay returns the original answer rather than retiring again.
    assert %{deleted_session_key: "idem-target"} =
             retire(ctx, "user:flynn", {:user, "flynn"}, "idem-target", "key-1")
  end

  test "the effort menu offers retire exactly when the handler would authorize it", ctx do
    # A holder owned by flynn, dispatched by a SESSION rung also owned by flynn.
    session!(ctx.db, "holder", "flynn", spawned_by: "agent:worker:app")

    assignment =
      Assignments.__handle__(ctx.db, "dispatch", %{
        verb: "dispatch",
        origin: "agent:worker",
        principal: {:session, "agent:worker:app"},
        session_key: "holder",
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{subject: "menu check", brief: "menu check"},
        effort_config: %{db: ctx.db, base_dir: System.tmp_dir!()}
      })

    assert is_binary(assignment.id)

    session_rung = %{
      session_key: "agent:worker:app",
      user_id: nil,
      owner_user_id: "flynn",
      principal_user_id: "flynn",
      rung: 0
    }

    {:ok, menu} =
      DB.transaction(ctx.db, fn txn ->
        EffortCheckin.menu_in_txn(txn, assignment_row(txn, assignment.id), session_rung)
      end)

    # The handler WOULD authorize this rung — same owner as the holder — so per
    # the spec's per-power rule the menu must offer it.
    assert "retire" in menu

    assert %{deleted_session_key: "holder"} =
             retire(ctx, "agent:worker", {:session, "agent:worker:app"}, "holder")

    # A rung whose principal does NOT own the holder gets no retire item, and the
    # handler agrees.
    session!(ctx.db, "kays-holder", "kay")

    foreign_rung = %{
      session_key: "agent:worker:app",
      user_id: nil,
      owner_user_id: "kay",
      principal_user_id: "flynn",
      rung: 0
    }

    kays_assignment =
      Assignments.__handle__(ctx.db, "assign", %{
        verb: "assign",
        origin: "user:kay",
        principal: {:user, "kay"},
        session_key: "kays-holder",
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{subject: "foreign"}
      })

    {:ok, foreign_menu} =
      DB.transaction(ctx.db, fn txn ->
        EffortCheckin.menu_in_txn(txn, assignment_row(txn, kays_assignment.id), foreign_rung)
      end)

    refute "retire" in foreign_menu
    assert %{code: "not_found"} = retire(ctx, "user:flynn", {:user, "flynn"}, "kays-holder")
  end

  ## Helpers

  defp retire(ctx, origin, principal, session_key, idempotency_key \\ nil) do
    params = if idempotency_key, do: %{idempotency_key: idempotency_key}, else: %{}

    call = %{
      verb: "retire",
      origin: origin,
      session_key: session_key,
      params: params
    }

    call = if principal, do: Map.put(call, :principal, principal), else: call
    ctx.handlers["retire"].(call)
  end

  defp session!(db, key, owner, opts \\ []) do
    Org.create(
      db,
      Map.merge(
        %{
          session_key: key,
          display_name: key,
          owner_user_id: owner,
          origin: "user:#{owner}",
          archetype: "default",
          host: "testhost",
          harness: "claude",
          provider: "anthropic",
          model: Model.new("fable")
        },
        Map.new(opts)
      )
    )
  end

  defp assignment_row(txn, id) do
    [[holder_key, opened_by_session, opened_by_user]] =
      Tightbeam.DB.Txn.q(
        txn,
        "SELECT holderKey, openedBySession, openedByUser FROM assignments WHERE id = ?1",
        [id]
      )

    %{
      id: id,
      holder_key: holder_key,
      opened_by_session: opened_by_session,
      opened_by_user: opened_by_user
    }
  end
end
