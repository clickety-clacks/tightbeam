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
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn',0,1),('kay',0,1),('root',1,1)"
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

  # A retire that is BLOCKED by an unresolved process has to say so. The cascade
  # already knew — it returns `blocked` — but the reply dropped that list and
  # still announced `deletedSessionKey`, so a caller whose session sat behind an
  # open process fence was told the session had been deleted (review
  # att_c36308f5 F4). MAIN `a18d8b30` had no blocking at all, so this was a
  # false success the custody series introduced, not one it inherited.
  test "a blocked retire reports the blocker and its repair verb, not a deletion", ctx do
    session!(ctx.db, "flynns-blocked", "flynn")

    {:ok, {:ok, row}} =
      DB.transaction(ctx.db, fn txn ->
        Tightbeam.ManagedProcesses.insert_preparing(txn, %{
          process_id: "mp_blocks_retire",
          owner_user_id: "flynn",
          owner_session_key: "flynns-blocked",
          session_generation: 0,
          launch_turn_seq: nil,
          host: "testhost",
          purpose: "onboarding_ceremony",
          command_descriptor: "codex login",
          launch_token: "tok_blocks",
          launch_deadline: 10_000,
          lease_expires_at: 60_000,
          now: 1_000
        })
      end)

    result = retire(ctx, "user:flynn", {:user, "flynn"}, "flynns-blocked")

    assert result.blocked == ["flynns-blocked"]
    assert result.retired_session_keys == []

    assert result.deleted_session_key == nil,
           "retire announced a deletion for a session still behind a process fence"

    # §B5 wants the blocker reported WITH the verb that repairs it. `processes`
    # on a blocked key lists the rows and their launch deadlines from there, so
    # the repair path is reachable by an agent without a database console.
    assert result.repair_verb == "process-reconcile"

    # The durable rows agree with the reply, which is the whole point of the
    # finding: the announcement and the truth had come apart.
    refute Org.get(ctx.db, "flynns-blocked").state == "retired"
    assert Tightbeam.ManagedProcesses.get(ctx.db, row.processId)
  end

  # One verb, one reply shape. The blocking fix above gave the cascade branch two
  # new keys, and the already-retired branch has to carry them too — a caller
  # that pattern-matches on `blocked` must not have it appear and disappear
  # depending on which path answered.
  test "an already-retired session answers in the same shape as a live retire", ctx do
    session!(ctx.db, "twice", "flynn")

    first = retire(ctx, "user:flynn", {:user, "flynn"}, "twice")
    assert first.deleted_session_key == "twice"
    assert Org.get(ctx.db, "twice").state == "retired"

    second = retire(ctx, "user:flynn", {:user, "flynn"}, "twice")

    assert Map.keys(second) |> Enum.sort() == Map.keys(first) |> Enum.sort()

    # Idempotent success, and nothing terminal can still be blocking.
    assert second == %{
             deleted_session_key: "twice",
             retired_session_keys: [],
             deferred: [],
             blocked: [],
             repair_verb: nil
           }
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
