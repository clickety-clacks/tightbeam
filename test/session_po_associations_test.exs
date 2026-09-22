defmodule Tightbeam.SessionPoAssociationsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    DB,
    Gateway,
    Ledger,
    Model,
    Org,
    Roles,
    Schema,
    SessionPoAssociations,
    SessionReparent,
    StateResources,
    Wakes
  }

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    Tightbeam.Archetypes.load!(System.tmp_dir!())

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1),('other',0,1)"
      )

    owner_main = session(db, Org.personal_session_key("owner"), "owner", kind: "main")
    other_main = session(db, Org.personal_session_key("other"), "other", kind: "main")
    parent = session(db, "parent", "owner")
    new_parent = session(db, "new-parent", "owner")
    target = session(db, "orchestrator", "owner", spawned_by: parent.session_key)
    po = session(db, "po", "owner")
    po_two = session(db, "po-two", "owner")
    peer = session(db, "peer", "owner")
    foreign_po = session(db, "foreign-po", "other")

    Roles.create!(db, "product-owner:one", "owner", po.session_key)
    Roles.create!(db, "product-owner:two", "owner", po_two.session_key)
    Roles.create!(db, "product-owner:foreign", "other", foreign_po.session_key)

    %{
      db: db,
      owner_main: owner_main,
      other_main: other_main,
      parent: parent,
      new_parent: new_parent,
      target: target,
      peer: peer
    }
  end

  test "production handler creates one attributed association and ordinary durable notice", ctx do
    before = StateResources.query_session(ctx.db, "orchestrator") |> StateResources.session()
    result = set(ctx.db, {:user, "owner"}, "product-owner:one", "first")

    assert result["changed"]

    assert %{
             "sessionKey" => "orchestrator",
             "ownerUserId" => "owner",
             "poRole" => "product-owner:one",
             "revision" => 1,
             "noticeWakeId" => wake_id,
             "setBy" => "user:owner",
             "cause" => "explicit_set"
           } = result["association"]

    assert %{session_key: "orchestrator", state: "pending", assignment_id: nil} =
             wake = Wakes.get(ctx.db, wake_id)

    assert wake.origin == "topology:addressed-po-association"
    assert wake.prompt =~ "`product-owner:one`"
    assert wake.prompt =~ "revision `1`"
    assert wake.prompt =~ "does not block otherwise authorized staffing"

    assert SessionPoAssociations.get(ctx.db, "orchestrator") == result["association"]

    public = StateResources.query_session(ctx.db, "orchestrator") |> StateResources.session()
    assert public == before
    assert public["rowVersion"] == before["updatedAt"]
    refute Enum.any?(Map.keys(public), &String.starts_with?(&1, "po"))

    inspected =
      Gateway.handlers(%{db: ctx.db, base_dir: System.tmp_dir!()})["inspect"].(%{
        verb: "inspect",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: nil,
        params: %{}
      })

    target = Enum.find(inspected.sessions, &(&1.session_key == "orchestrator"))
    assert target.po_association == result["association"]
  end

  test "same-key replay, fresh-key no-op, replacement, and old replay deduplicate exactly", ctx do
    first = set(ctx.db, {:user, "owner"}, "product-owner:one", "first")
    assert set(ctx.db, {:user, "owner"}, "product-owner:one", "first") == first
    assert count(ctx.db, "wakes") == 1

    assert :ok = Roles.bind(ctx.db, "product-owner:one", "po-two")
    assert SessionPoAssociations.get(ctx.db, "orchestrator") == first["association"]
    assert count(ctx.db, "wakes") == 1

    unchanged = set(ctx.db, {:user, "owner"}, "product-owner:one", "unchanged")
    refute unchanged["changed"]
    assert unchanged["association"] == first["association"]
    assert count(ctx.db, "wakes") == 1
    assert count(ctx.db, "wire_idempotency") == 2

    second = set(ctx.db, {:user, "owner"}, "product-owner:two", "replace")
    assert second["changed"]
    assert second["association"]["revision"] == 2
    assert second["association"]["noticeWakeId"] != first["association"]["noticeWakeId"]
    assert count(ctx.db, "wakes") == 2

    post_replace_noop = set(ctx.db, {:user, "owner"}, "product-owner:two", "post-replace-noop")

    refute post_replace_noop["changed"]
    assert post_replace_noop["association"] == second["association"]
    assert count(ctx.db, "wakes") == 2

    assert set(ctx.db, {:user, "owner"}, "product-owner:one", "first") == first
    assert SessionPoAssociations.get(ctx.db, "orchestrator") == second["association"]
    assert count(ctx.db, "wakes") == 2

    assert %{code: "idempotency_conflict"} =
             set(ctx.db, {:user, "owner"}, "product-owner:one", "replace")

    assert count(ctx.db, "wakes") == 2
  end

  test "fresh-key unchanged replay after replacement preserves current association", ctx do
    first = set(ctx.db, {:user, "owner"}, "product-owner:one", "set-a")

    unchanged = set(ctx.db, {:user, "owner"}, "product-owner:one", "unchanged-k")
    refute unchanged["changed"]
    assert unchanged["association"] == first["association"]

    second = set(ctx.db, {:user, "owner"}, "product-owner:two", "set-b")
    revision = second["association"]["revision"]
    wake_count = count(ctx.db, "wakes")

    assert set(ctx.db, {:user, "owner"}, "product-owner:one", "unchanged-k") == unchanged
    assert SessionPoAssociations.get(ctx.db, "orchestrator") == second["association"]
    assert SessionPoAssociations.get(ctx.db, "orchestrator")["revision"] == revision
    assert count(ctx.db, "wakes") == wake_count
  end

  test "concurrent identical settings serialize to one logical revision and notice", ctx do
    results =
      1..8
      |> Task.async_stream(
        fn n -> set(ctx.db, {:user, "owner"}, "product-owner:one", "concurrent-#{n}") end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, & &1["changed"]) == 1
    assert Enum.uniq(Enum.map(results, & &1["association"]["noticeWakeId"])) |> length() == 1
    assert count(ctx.db, "session_po_associations") == 1
    assert count(ctx.db, "wakes") == 1
    assert count(ctx.db, "wire_idempotency") == 8
  end

  test "only owner, exact target, or current parent has authority", ctx do
    assert set(ctx.db, {:session, ctx.target.session_key}, "product-owner:one", "self")[
             "changed"
           ]

    assert set(ctx.db, {:session, ctx.parent.session_key}, "product-owner:two", "parent")[
             "changed"
           ]

    reparent_fixture(ctx.db, ctx.target.session_key, ctx.new_parent.session_key)

    assert %{code: "not_authorized"} =
             set(ctx.db, {:session, ctx.parent.session_key}, "product-owner:one", "stale")

    assert set(ctx.db, {:session, ctx.new_parent.session_key}, "product-owner:one", "current")[
             "changed"
           ]

    assert %{code: "not_authorized"} =
             set(ctx.db, {:session, ctx.peer.session_key}, "product-owner:two", "peer")

    assert SessionPoAssociations.get(ctx.db, "orchestrator")["revision"] == 3
    assert count(ctx.db, "wakes") == 3
  end

  test "invalid, retired, cross-owner and implicit-name cases leave no partial effects", ctx do
    assert %{code: "unknown_session"} =
             set_target(
               ctx.db,
               {:user, "owner"},
               "missing-session",
               "product-owner:one",
               "unknown-target"
             )

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='orchestrator'")

    assert %{code: "session_retired"} =
             set(ctx.db, {:user, "owner"}, "product-owner:one", "retired")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='active' WHERE sessionKey='orchestrator'")

    assert %{code: "po_role_unresolved"} =
             set(ctx.db, {:user, "owner"}, "product-owner:missing", "missing")

    assert %{code: "cross_owner_po_role"} =
             set(ctx.db, {:user, "owner"}, "product-owner:foreign", "foreign")

    assert %{code: "not_authorized"} =
             set(ctx.db, {:session, ctx.peer.session_key}, "product-owner:one", "peer")

    assert SessionPoAssociations.get(ctx.db, "orchestrator") == nil
    assert count(ctx.db, "session_po_associations") == 0
    assert count(ctx.db, "wakes") == 0
    assert count(ctx.db, "wire_idempotency") == 0

    # Matching words and pre-existing sessions never establish or backfill an association.
    session(ctx.db, "product-owner-one", "owner")
    assert count(ctx.db, "session_po_associations") == 0
  end

  test "association notice remains claimable through liveness suppression", ctx do
    result = set(ctx.db, {:user, "owner"}, "product-owner:one", "claimable")
    wake = Wakes.get(ctx.db, result["association"]["noticeWakeId"])

    assert {:ok, {:appended, "orchestrator", _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 wake.session_key,
                 wake.origin,
                 wake.prompt,
                 wake_id: wake.wake_id,
                 sender: wake.origin,
                 device_id: "session-po-association-test",
                 client_message_id: wake.wake_id,
                 target_gate: wake
               )
             end)

    assert {:ok, [[seq]]} =
             DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1", [wake.wake_id])

    assert {:ok, []} =
             DB.query(ctx.db, "SELECT 1 FROM queued_message_scopes WHERE turnSeq=?1", [seq])

    assert {:ok, %{seq: ^seq, prompt: prompt}} =
             Ledger.claim_next(ctx.db, "orchestrator", "association-notice")

    assert prompt =~ "product-owner:one"
  end

  test "delayed replaced-association notice preserves its revision and directs current readback",
       ctx do
    first = set(ctx.db, {:user, "owner"}, "product-owner:one", "delayed-a")
    second = set(ctx.db, {:user, "owner"}, "product-owner:two", "replace-with-b")
    wake = Wakes.get(ctx.db, first["association"]["noticeWakeId"])

    assert second["association"]["poRole"] == "product-owner:two"
    assert second["association"]["revision"] == 2

    assert {:ok, {:appended, "orchestrator", _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 wake.session_key,
                 wake.origin,
                 wake.prompt,
                 wake_id: wake.wake_id,
                 sender: wake.origin,
                 device_id: "session-po-delayed-notice-test",
                 client_message_id: wake.wake_id,
                 target_gate: wake
               )
             end)

    assert {:ok, %{prompt: prompt}} =
             Ledger.claim_next(ctx.db, "orchestrator", "delayed-association-notice")

    assert prompt =~ "product-owner:one"
    assert prompt =~ "association revision `1`"
    assert prompt =~ "Read the current association"

    inspected =
      Gateway.handlers(%{db: ctx.db, base_dir: System.tmp_dir!()})["inspect"].(%{
        verb: "inspect",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: nil,
        params: %{}
      })

    target = Enum.find(inspected.sessions, &(&1.session_key == "orchestrator"))
    assert target.po_association == second["association"]
  end

  test "association and pending wake do not gate assignment", ctx do
    result = set(ctx.db, {:user, "owner"}, "product-owner:one", "durable")
    wake_id = result["association"]["noticeWakeId"]

    assign = Gateway.handlers(%{db: ctx.db, wake_tick_ms: 1_000})["assign"]

    assert %{state: "open", holderKey: "orchestrator"} =
             assign.(%{
               verb: "assign",
               origin: "user:owner",
               principal: {:user, "owner"},
               session_key: "orchestrator",
               target_role: nil,
               role_fallback: false,
               params: %{subject: "staffing remains available"}
             })

    assert %{wake_id: ^wake_id, state: "pending"} = Wakes.get(ctx.db, wake_id)
  end

  test "staffing remains available after the associated PO becomes unavailable", ctx do
    result = set(ctx.db, {:user, "owner"}, "product-owner:one", "po-unavailable")
    wake_id = result["association"]["noticeWakeId"]

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='po'")

    assert %{state: "retired"} = Org.get(ctx.db, "po")
    assert %{bound_session_key: "po"} = Roles.get(ctx.db, "product-owner:one")

    assign = Gateway.handlers(%{db: ctx.db, wake_tick_ms: 1_000})["assign"]

    assert %{state: "open", holderKey: "orchestrator"} =
             assign.(%{
               verb: "assign",
               origin: "user:owner",
               principal: {:user, "owner"},
               session_key: "orchestrator",
               target_role: nil,
               role_fallback: false,
               params: %{subject: "staffing survives unavailable PO"}
             })

    assert SessionPoAssociations.get(ctx.db, "orchestrator") == result["association"]
    assert %{wake_id: ^wake_id, state: "pending"} = Wakes.get(ctx.db, wake_id)
  end

  @tag :tmp_dir
  test "association and pending wake survive guarded database restart", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "session_po_association_restart.exs",
      "session-po-association-restart: ok"
    )
  end

  test "wire atomization preserves exact setter spelling" do
    assert Tightbeam.Wire.Router.atomize_params_for_test("session-po-set", %{
             "sessionKey" => "session exact",
             "poRole" => "product-owner:one",
             "idempotencyKey" => "request"
           }) == %{
             session_key: "session exact",
             po_role: "product-owner:one",
             idempotency_key: "request"
           }
  end

  defp set(db, principal, po_role, key),
    do: set_target(db, principal, "orchestrator", po_role, key)

  defp set_target(db, principal, session_key, po_role, key) do
    Gateway.handlers(%{db: db})["session-po-set"].(%{
      verb: "session-po-set",
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      params: %{session_key: session_key, po_role: po_role, idempotency_key: key}
    })
  end

  defp origin({:user, owner}), do: "user:" <> owner
  defp origin({:session, key}), do: "agent:test-" <> key

  defp session(db, key, owner, options \\ []) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:" <> owner,
      spawned_by: options[:spawned_by],
      kind: options[:kind] || "custom",
      archetype: "default",
      harness: "fixture",
      provider: "fixture_provider",
      model: Model.new("fixture"),
      host: "synthetic-host"
    })
  end

  defp reparent_fixture(db, target, new_parent) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdContextKnown,createdAt) VALUES('wi','item','owner','open','owner',0,1)"
      )

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,state,workItemId) VALUES('asg','work',?1,'owner',1,'open','wi')",
        [target]
      )

    SessionReparent.handle(db, %{
      principal: {:user, "owner"},
      params: %{
        session_key: target,
        parent_session_key: new_parent,
        assignment_id: "asg",
        idempotency_key: "reparent"
      }
    })
  end

  defp count(db, table) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM #{table}")
    count
  end
end
