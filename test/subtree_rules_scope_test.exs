defmodule Tightbeam.SubtreeRulesScopeTest do
  @moduledoc """
  Role-anchored rule scope and the `roles` filter (subtree rules, behind the
  `subtree_rules` flag), on statutes and on reactions, with the flag on and off.
  """
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, RailScope, Rules, SubtreeScope}
  alias Tightbeam.RowReactions.Plan

  @owner "sample-owner"
  @main "agent:main:clawline:sample-owner:main"
  @kungfu "sample-kungfu"
  @qualified "sample-kungfu.org-example-analyst"
  @verbs ~w(work-item-close work-item-reopen work-item-icebox work-item-fail attest spawn assign)

  setup do
    previous = Application.get_env(:tightbeam, :subtree_rules)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :subtree_rules),
        else: Application.put_env(:tightbeam, :subtree_rules, previous)
    end)

    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)

    base_dir =
      Path.join(System.tmp_dir!(), "subtree-rules-#{System.unique_integer([:positive])}")

    write_identity!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    # main
    # ├── lead          holds team:alpha
    # │   └── member
    # │       └── grandchild
    # ├── outsider
    # └── reviewer      holds review:alpha (another agent type)
    seed_session!(db, @main, nil, "default")
    seed_session!(db, "lead", nil, "default")
    seed_session!(db, "member", "lead", "default")
    seed_session!(db, "grandchild", "member", "default")
    seed_session!(db, "outsider", nil, "default")
    seed_session!(db, "reviewer", nil, "other-agent")
    seed_session!(db, "analyst", nil, @qualified)
    seed_session!(db, "successor", nil, "default")
    create_role!(db, "team:alpha", "lead")
    create_role!(db, "review:alpha", "reviewer")

    %{db: db, base_dir: base_dir}
  end

  describe "with the flag off" do
    test "scope and roles stay unknown keys and refuse the rule, as before", ctx do
      write_org_rules!(ctx.base_dir, """
      [[rule]]
      name = "scoped-close"
      verb = "work-item-close"
      text = "denied"
      archetypes = ["*"]
      scope = { subtree_of = "role:team:alpha" }
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]

      [[rule]]
      name = "role-filtered-reopen"
      verb = "work-item-reopen"
      text = "denied"
      archetypes = ["*"]
      roles = ["review:*"]
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
      """)

      log = ExUnit.CaptureLog.capture_log(fn -> load!(ctx.base_dir) end)
      assert log =~ "unknown keys: scope"
      assert log =~ "unknown keys: roles"

      assert %{unavailable_verbs: unavailable} = Rules.status()

      assert Enum.map(unavailable, & &1.verb) |> Enum.sort() ==
               ["work-item-close", "work-item-reopen"]
    end

    test "an org rule without archetypes still warns and still applies to no agent", ctx do
      write_org_rules!(ctx.base_dir, """
      [[rule]]
      name = "no-who"
      verb = "work-item-close"
      text = "denied"
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]
      """)

      log = ExUnit.CaptureLog.capture_log(fn -> load!(ctx.base_dir) end)
      assert log =~ ~s(rule "no-who" omits archetypes)
      assert :ok = Rules.evaluate(ctx.db, session_call("work-item-close", "member"))
    end

    test "{anchor_session} is not a binding token", ctx do
      write_org_rules!(ctx.base_dir, notice_rule(""))
      log = ExUnit.CaptureLog.capture_log(fn -> load!(ctx.base_dir) end)
      assert log =~ "unknown binding token {anchor_session}"
    end

    test "loaded rules carry no subtree fields", ctx do
      write_org_rules!(ctx.base_dir, scoped_rule("plain", "work-item-close", nil))
      [rule] = load!(ctx.base_dir)
      refute Map.has_key?(rule, :scope_role)
      refute Map.has_key?(rule, :roles)
    end

    test "reaction scope and roles keys stay invalid" do
      assert_raise ArgumentError, "invalid reaction fields", fn ->
        Plan.compile!(reaction(%{"scope" => %{"subtree_of" => "role:team:alpha"}}), %{})
      end

      assert_raise ArgumentError, "invalid reaction fields", fn ->
        Plan.compile!(reaction(%{"roles" => ["review:*"]}), %{})
      end
    end
  end

  describe "statute scope with the flag on" do
    setup :enable

    test "covers work owed to the anchor's holder and everything under it", ctx do
      seed_work_item!(ctx.db, "wi-lead", "lead", nil)
      seed_work_item!(ctx.db, "wi-member", "member", nil)
      seed_work_item!(ctx.db, "wi-grandchild", "grandchild", nil)
      seed_work_item!(ctx.db, "wi-outsider", "outsider", nil)
      seed_work_item!(ctx.db, "wi-main", @main, nil)
      # No delivery owner: the creator decides.
      seed_work_item!(ctx.db, "wi-created-inside", nil, "member")
      write_org_rules!(ctx.base_dir, scoped_rule("alpha-close", "work-item-close", "team:alpha"))
      load!(ctx.base_dir)

      for id <- ~w(wi-lead wi-member wi-grandchild wi-created-inside) do
        assert_denied_by(Rules.evaluate(ctx.db, user_call("work-item-close", id)), "alpha-close")
      end

      # Outside the subtree, and above it: the scope never widens to Main.
      for id <- ~w(wi-outsider wi-main) do
        assert :ok = Rules.evaluate(ctx.db, user_call("work-item-close", id))
      end
    end

    test "a rule with no scope is rooted at Main and covers everything", ctx do
      seed_work_item!(ctx.db, "wi-outsider", "outsider", nil)
      seed_work_item!(ctx.db, "wi-member", "member", nil)
      write_org_rules!(ctx.base_dir, scoped_rule("root-close", "work-item-close", nil))
      load!(ctx.base_dir)

      for id <- ~w(wi-outsider wi-member) do
        assert_denied_by(Rules.evaluate(ctx.db, user_call("work-item-close", id)), "root-close")
      end
    end

    test "an unknown, unbound or retired anchor covers nobody, with no fallback", ctx do
      seed_work_item!(ctx.db, "wi-member", "member", nil)
      seed_work_item!(ctx.db, "wi-main", @main, nil)

      write_org_rules!(
        ctx.base_dir,
        scoped_rule("ghost-close", "work-item-close", "team:ghost") <>
          scoped_rule("alpha-close", "work-item-close", "team:alpha")
      )

      load!(ctx.base_dir)

      assert_denied_by(
        Rules.evaluate(ctx.db, user_call("work-item-close", "wi-member")),
        "alpha-close"
      )

      assert :ok = Rules.evaluate(ctx.db, user_call("work-item-close", "wi-main"))

      # Unbound: the role exists but nobody holds it.
      {:ok, _} = DB.query(ctx.db, "UPDATE roles SET boundSessionKey=NULL WHERE name='team:alpha'")
      assert :ok = Rules.evaluate(ctx.db, user_call("work-item-close", "wi-member"))
      assert :ok = Rules.evaluate(ctx.db, user_call("work-item-close", "wi-main"))

      # Held by a retired session.
      {:ok, _} =
        DB.query(ctx.db, "UPDATE roles SET boundSessionKey='lead' WHERE name='team:alpha'")

      {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='lead'")
      assert is_nil(SubtreeScope.anchor_holder(ctx.db, "team:alpha"))
      assert :ok = Rules.evaluate(ctx.db, user_call("work-item-close", "wi-member"))
    end

    test "reassigning the role moves the rule from the next evaluation", ctx do
      seed_work_item!(ctx.db, "wi-member", "member", nil)
      seed_work_item!(ctx.db, "wi-successor", "successor", nil)
      write_org_rules!(ctx.base_dir, scoped_rule("alpha-close", "work-item-close", "team:alpha"))
      load!(ctx.base_dir)

      assert_denied_by(
        Rules.evaluate(ctx.db, user_call("work-item-close", "wi-member")),
        "alpha-close"
      )

      assert :ok = Rules.evaluate(ctx.db, user_call("work-item-close", "wi-successor"))

      :ok = Tightbeam.Roles.bind(ctx.db, "team:alpha", "successor")

      assert :ok = Rules.evaluate(ctx.db, user_call("work-item-close", "wi-member"))

      assert_denied_by(
        Rules.evaluate(ctx.db, user_call("work-item-close", "wi-successor")),
        "alpha-close"
      )
    end

    test "membership follows the session tree when a session moves", ctx do
      seed_work_item!(ctx.db, "wi-grandchild", "grandchild", nil)
      write_org_rules!(ctx.base_dir, scoped_rule("alpha-close", "work-item-close", "team:alpha"))
      load!(ctx.base_dir)

      assert_denied_by(
        Rules.evaluate(ctx.db, user_call("work-item-close", "wi-grandchild")),
        "alpha-close"
      )

      {:ok, _} =
        DB.query(ctx.db, "UPDATE sessions SET spawnedBy='outsider' WHERE sessionKey='grandchild'")

      assert :ok = Rules.evaluate(ctx.db, user_call("work-item-close", "wi-grandchild"))
    end

    test "an assignment belongs where it is owed: its opener, else its holder", ctx do
      # An outsider working on what a subtree member opened is covered for that work.
      seed_assignment!(ctx.db, "asg-opened-inside", "outsider", {:session, "member"})
      # A member lent to work opened elsewhere is not.
      seed_assignment!(ctx.db, "asg-opened-outside", "member", {:session, "outsider"})
      # Opened by a person: the holder decides.
      seed_assignment!(ctx.db, "asg-user-opened", "grandchild", {:user, @owner})
      write_org_rules!(ctx.base_dir, scoped_rule("alpha-attest", "attest", "team:alpha"))
      load!(ctx.base_dir)

      assert_denied_by(
        Rules.evaluate(ctx.db, assignment_call("outsider", "asg-opened-inside")),
        "alpha-attest"
      )

      assert :ok = Rules.evaluate(ctx.db, assignment_call("member", "asg-opened-outside"))

      assert_denied_by(
        Rules.evaluate(ctx.db, assignment_call("grandchild", "asg-user-opened")),
        "alpha-attest"
      )

      # Custody moves with the current opener.
      {:ok, _} =
        DB.query(
          ctx.db,
          "UPDATE assignments SET currentOpenerSessionKey='lead' WHERE id='asg-opened-outside'"
        )

      assert_denied_by(
        Rules.evaluate(ctx.db, assignment_call("member", "asg-opened-outside")),
        "alpha-attest"
      )
    end

    test "a command touching no work is judged by the calling session", ctx do
      write_org_rules!(
        ctx.base_dir,
        scoped_rule("alpha-icebox", "work-item-icebox", "team:alpha")
      )

      load!(ctx.base_dir)

      assert_denied_by(
        Rules.evaluate(ctx.db, session_call("work-item-icebox", "grandchild")),
        "alpha-icebox"
      )

      assert :ok = Rules.evaluate(ctx.db, session_call("work-item-icebox", "outsider"))
      # A person calling with no work has no place in the tree.
      assert :ok = Rules.evaluate(ctx.db, user_call("work-item-icebox", nil))
    end

    test "opening an assignment is judged by the opener", ctx do
      write_org_rules!(ctx.base_dir, scoped_rule("alpha-assign", "assign", "team:alpha"))
      load!(ctx.base_dir)

      call = fn caller, holder ->
        %{
          verb: "assign",
          origin: "agent:#{caller}",
          principal: {:session, caller},
          params: %{session_key: holder, work_item_id: "wi-anything"}
        }
      end

      assert_denied_by(Rules.evaluate(ctx.db, call.("member", "outsider")), "alpha-assign")
      assert :ok = Rules.evaluate(ctx.db, call.("outsider", "member"))
    end

    test "an org rule naming no agent types or roles applies to every session", ctx do
      write_org_rules!(ctx.base_dir, """
      [[rule]]
      name = "no-who"
      verb = "work-item-close"
      text = "denied"
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]
      """)

      log = ExUnit.CaptureLog.capture_log(fn -> load!(ctx.base_dir) end)
      refute log =~ "omits archetypes"

      for caller <- ~w(member reviewer analyst) do
        assert_denied_by(
          Rules.evaluate(ctx.db, session_call("work-item-close", caller)),
          "no-who"
        )
      end
    end

    test "{anchor_session} addresses the anchor role's current holder", ctx do
      write_org_rules!(ctx.base_dir, notice_rule(~s(scope = { subtree_of = "role:team:alpha" })))
      [rule] = load!(ctx.base_dir)

      assert {:ok, %{bound_session: "lead"}} =
               DB.transaction(ctx.db, fn txn ->
                 Rules.resolve_notice_in_txn(txn, rule, session_call("work-item-fail", "member"))
               end)
               |> elem(1)

      :ok = Tightbeam.Roles.bind(ctx.db, "team:alpha", "successor")

      assert {:ok, %{bound_session: "successor"}} =
               DB.transaction(ctx.db, fn txn ->
                 Rules.resolve_notice_in_txn(txn, rule, session_call("work-item-fail", "member"))
               end)
               |> elem(1)
    end

    test "scope declarations are validated at load", ctx do
      write_org_rules!(ctx.base_dir, """
      [[rule]]
      name = "bad-anchor"
      verb = "work-item-close"
      text = "denied"
      scope = { subtree_of = "session:lead" }
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]

      [[rule]]
      name = "bad-roles"
      verb = "work-item-reopen"
      text = "denied"
      roles = ["review:*:*"]
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
      """)

      log = ExUnit.CaptureLog.capture_log(fn -> load!(ctx.base_dir) end)
      assert log =~ ~s(scope must be a table with only subtree_of = "role:<name>")
      assert log =~ ~s(roles entry "review:*:*")
    end
  end

  describe "the roles filter with the flag on" do
    setup :enable

    test "a session passes by agent type or by a role it holds now", ctx do
      write_org_rules!(ctx.base_dir, """
      [[rule]]
      name = "review-close"
      verb = "work-item-close"
      text = "denied"
      roles = ["review:*"]
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]

      [[rule]]
      name = "exact-reopen"
      verb = "work-item-reopen"
      text = "denied"
      archetypes = ["default"]
      roles = ["review:alpha"]
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]
      """)

      load!(ctx.base_dir)

      assert_denied_by(
        Rules.evaluate(ctx.db, session_call("work-item-close", "reviewer")),
        "review-close"
      )

      assert :ok = Rules.evaluate(ctx.db, session_call("work-item-close", "member"))

      # Either filter admits; every involved session must pass one.
      assert_denied_by(
        Rules.evaluate(ctx.db, session_call("work-item-reopen", "reviewer")),
        "exact-reopen"
      )

      assert_denied_by(
        Rules.evaluate(ctx.db, session_call("work-item-reopen", "member")),
        "exact-reopen"
      )

      assert :ok = Rules.evaluate(ctx.db, session_call("work-item-reopen", "analyst"))

      assert :ok =
               Rules.evaluate(
                 ctx.db,
                 session_call("work-item-reopen", "member") |> Map.put(:session_key, "analyst")
               )

      # Checked against who holds the role at this moment.
      :ok = Tightbeam.Roles.bind(ctx.db, "review:alpha", "analyst")
      assert :ok = Rules.evaluate(ctx.db, session_call("work-item-close", "reviewer"))

      assert_denied_by(
        Rules.evaluate(ctx.db, session_call("work-item-close", "analyst")),
        "review-close"
      )
    end

    test "role matching is exact or by prefix" do
      assert SubtreeScope.role_admits?(["review:*"], ["review:alpha"])
      assert SubtreeScope.role_admits?(["review:*"], ["review:alpha:beta"])
      refute SubtreeScope.role_admits?(["review:*"], ["review"])
      refute SubtreeScope.role_admits?(["review:*"], ["reviewer:alpha"])
      assert SubtreeScope.role_admits?(["team:alpha"], ["other", "team:alpha"])
      refute SubtreeScope.role_admits?(["team:alpha"], ["team:alpha:sub"])
      refute SubtreeScope.role_admits?([], ["team:alpha"])
    end

    test "without roles the matcher is exactly agent-type matching" do
      for {archetypes, participants} <- [
            {["*"], ["a", "b"]},
            {["a"], ["a", "b"]},
            {[], ["a"]},
            {["a"], []},
            {["*", "a"], ["a"]},
            {["a"], [nil]}
          ] do
        assert RailScope.matches_participants?(
                 archetypes,
                 [],
                 Enum.map(participants, &%{archetype: &1, roles: ["x:y"]})
               ) == RailScope.matches_agents?(archetypes, participants)
      end
    end

    test "a kungfu rule naming a role reaches its holder whatever the agent type", ctx do
      write_kungfu_rules!(ctx.base_dir, """
      [[rule]]
      name = "kungfu-close"
      verb = "work-item-close"
      text = "denied"
      archetypes = ["#{@qualified}"]
      roles = ["review:alpha"]
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]
      """)

      load!(ctx.base_dir)

      for caller <- ~w(analyst reviewer) do
        assert_denied_by(
          Rules.evaluate(ctx.db, session_call("work-item-close", caller)),
          "sample-kungfu.kungfu-close"
        )
      end

      assert :ok = Rules.evaluate(ctx.db, session_call("work-item-close", "member"))
    end

    test "kungfu archetypes stay confined while roles may be anything", ctx do
      write_kungfu_rules!(ctx.base_dir, """
      [[rule]]
      name = "foreign-type"
      verb = "work-item-close"
      text = "denied"
      archetypes = ["default"]
      roles = ["review:alpha"]
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]
      """)

      log = ExUnit.CaptureLog.capture_log(fn -> load!(ctx.base_dir) end)
      assert log =~ "may name only its own archetypes"
    end

    test "a refused kungfu rule closes its verb for its types and named role holders only",
         ctx do
      write_kungfu_rules!(ctx.base_dir, """
      [[rule]]
      name = "refused-close"
      verb = "work-item-close"
      text = "denied"
      archetypes = ["#{@qualified}"]
      roles = ["review:alpha"]
      deny_when = [{ fact = "no.such.fact", op = "eq", value = "user" }]
      """)

      ExUnit.CaptureLog.capture_log(fn -> load!(ctx.base_dir) end)

      for caller <- ~w(analyst reviewer) do
        assert {:deny, %{code: "rule_unavailable"}} =
                 Rules.evaluate(ctx.db, session_call("work-item-close", caller))
      end

      assert :ok = Rules.evaluate(ctx.db, session_call("work-item-close", "member"))
      assert :ok = Rules.evaluate(ctx.db, session_call("work-item-reopen", "reviewer"))
    end

    test "scope and the who filter combine", ctx do
      seed_work_item!(ctx.db, "wi-member", "member", nil)
      seed_work_item!(ctx.db, "wi-outsider", "outsider", nil)

      write_org_rules!(ctx.base_dir, """
      [[rule]]
      name = "alpha-review-close"
      verb = "work-item-close"
      text = "denied"
      roles = ["review:*"]
      scope = { subtree_of = "role:team:alpha" }
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]
      """)

      load!(ctx.base_dir)

      call = fn caller, id ->
        %{
          verb: "work-item-close",
          origin: "agent:#{caller}",
          principal: {:session, caller},
          params: %{work_item_id: id}
        }
      end

      assert_denied_by(
        Rules.evaluate(ctx.db, call.("reviewer", "wi-member")),
        "alpha-review-close"
      )

      assert :ok = Rules.evaluate(ctx.db, call.("reviewer", "wi-outsider"))
      assert :ok = Rules.evaluate(ctx.db, call.("member", "wi-member"))
    end
  end

  describe "reaction scope with the flag on" do
    setup :enable

    test "compiles scope and roles, and defaults an org reaction to every session" do
      rail =
        Plan.compile!(
          reaction(%{"scope" => %{"subtree_of" => "role:team:alpha"}, "roles" => ["review:*"]}),
          %{}
        )

      assert rail.scope_role == "team:alpha"
      assert rail.roles == ["review:*"]
      assert rail.archetypes == []

      assert Plan.compile!(reaction(%{}), %{}).archetypes == ["*"]

      assert_raise ArgumentError, ~r/subtree_of/, fn ->
        Plan.compile!(reaction(%{"scope" => %{"subtree_of" => "team:alpha"}}), %{})
      end

      assert_raise ArgumentError, "invalid reaction binding", fn ->
        Plan.compile!(
          reaction(%{"bind" => [%{"name" => "anchor", "value" => true}]}),
          %{}
        )
      end
    end

    test "selects only work under the anchor's active holder and exposes anchor" do
      rail = Plan.compile!(reaction(%{"scope" => %{"subtree_of" => "role:team:alpha"}}), %{})

      facts = fn lineage, holders ->
        %{
          "scope_participant_archetypes" => [],
          "scope_record_session_groups" => [[]],
          "scope_subtree" => %{
            "participants" => [],
            "role_bindings" => %{"team:alpha" => "lead"},
            "active_role_holders" => holders,
            "holder_archetypes" => %{"lead" => "default"},
            "owner_lineage" => lineage
          }
        }
      end

      event = %{"kind" => "work_item_observation", "org" => @owner, "id" => "e1"}

      [plan] =
        Plan.evaluate([rail], event, facts.(["member", "lead", @main], %{"team:alpha" => "lead"}))

      assert plan.selected
      assert plan.value["session_key"] == "lead"

      [plan] =
        Plan.evaluate([rail], event, facts.(["outsider", @main], %{"team:alpha" => "lead"}))

      refute plan.selected

      # Unbound or inactive holder: nobody.
      [plan] = Plan.evaluate([rail], event, facts.(["member", "lead", @main], %{}))
      refute plan.selected

      # Missing subtree facts never widen to the root.
      [plan] = Plan.evaluate([rail], event, Map.delete(facts.(["lead"], %{}), "scope_subtree"))
      refute plan.selected
    end

    test "the roles filter admits participants holding a matching role" do
      rail = Plan.compile!(reaction(%{"roles" => ["review:*"]}), %{})
      event = %{"kind" => "work_item_observation", "org" => @owner, "id" => "e1"}

      facts = fn key ->
        %{
          "scope_participant_archetypes" => ["other-agent"],
          "scope_record_session_groups" => [[]],
          "sessions" => [],
          "scope_subtree" => %{
            "participants" => [key],
            "role_bindings" => %{"review:alpha" => "reviewer"},
            "active_role_holders" => %{"review:alpha" => "reviewer"},
            "owner_lineage" => []
          }
        }
      end

      assert [%{selected: true}] = Plan.evaluate([rail], event, facts.("reviewer"))
      assert [%{selected: false}] = Plan.evaluate([rail], event, facts.("member"))
    end

    test "a pending scoped notice is withdrawn at delivery once the role moves", ctx do
      write_org_rules!(ctx.base_dir, scoped_reaction_toml())
      load!(ctx.base_dir)
      seed_work_item!(ctx.db, "wi-member", "member", nil)
      seed_work_item!(ctx.db, "wi-outsider", "outsider", nil)

      {:ok, wake_ids} =
        DB.transaction(ctx.db, fn txn ->
          for id <- ~w(wi-member wi-outsider) do
            Tightbeam.RowReactions.observe_work_item_in_txn(
              txn,
              id,
              "created",
              %{kind: "fixture", id: id, at: 1_000, principal: {:user, @owner}},
              %{}
            )

            case Tightbeam.DB.Txn.q(
                   txn,
                   "SELECT json_extract(result,'$.wake_id') FROM row_reaction_actions a JOIN row_reaction_events e ON e.org=a.org AND e.eventId=a.eventId WHERE json_extract(e.event,'$.workItemId')=?1",
                   [id]
                 ) do
              [[wake_id]] -> wake_id
              [] -> nil
            end
          end
        end)

      # Only the work inside the subtree produced a notice, addressed to the anchor.
      assert [wake_id, nil] = wake_ids
      assert is_binary(wake_id)

      assert {:ok, [["lead", "pending"]]} =
               DB.query(ctx.db, "SELECT sessionKey,state FROM wakes WHERE wakeId=?1", [wake_id])

      # Nothing about the subtree is stored with the event.
      assert {:ok, [_, _] = stored} = DB.query(ctx.db, "SELECT facts FROM row_reaction_events")
      for [facts] <- stored, do: refute(facts =~ "scope_subtree")

      # Still in scope at delivery: delivered.
      assert {:ok, :ready} =
               DB.transaction(ctx.db, &Tightbeam.RowReactions.prepare_in_txn(&1, wake_id))

      # The role moves to a session the work is not under: the notice is dropped.
      :ok = Tightbeam.Roles.bind(ctx.db, "team:alpha", "successor")

      assert {:ok, :held} =
               DB.transaction(ctx.db, &Tightbeam.RowReactions.prepare_in_txn(&1, wake_id))

      assert {:ok, [["canceled"]]} =
               DB.query(ctx.db, "SELECT state FROM wakes WHERE wakeId=?1", [wake_id])
    end
  end

  describe "subtree lookups" do
    test "lineage walks to Main and the work owner follows the spec's order", ctx do
      assert SubtreeScope.lineage(ctx.db, "grandchild") == ["grandchild", "member", "lead", @main]
      assert SubtreeScope.lineage(ctx.db, @main) == [@main]

      seed_work_item!(ctx.db, "wi-both", "outsider", "member")
      seed_assignment!(ctx.db, "asg-1", "grandchild", {:session, "member"})

      assert SubtreeScope.work_owner(ctx.db, %{work_item_id: "wi-both", caller: "lead"}) ==
               "outsider"

      assert SubtreeScope.work_owner(ctx.db, %{
               assignment_id: "asg-1",
               work_item_id: "wi-both",
               caller: "lead"
             }) == "member"

      assert SubtreeScope.work_owner(ctx.db, %{caller: "lead"}) == "lead"
      assert SubtreeScope.covers?(ctx.db, nil, %{})
      refute SubtreeScope.covers?(ctx.db, "team:alpha", %{})
    end
  end

  # -- fixtures ----------------------------------------------------------------

  defp enable(_ctx) do
    Application.put_env(:tightbeam, :subtree_rules, true)
    :ok
  end

  defp load!(base_dir), do: Rules.load!(base_dir, @verbs)

  defp scoped_rule(name, verb, role) do
    scope = if role, do: ~s(scope = { subtree_of = "role:#{role}" }\n), else: ""

    """
    [[rule]]
    name = "#{name}"
    verb = "#{verb}"
    text = "denied"
    archetypes = ["*"]
    #{scope}deny_when = [{ fact = "caller.origin_class", op = "in", value = ["user", "agent"] }]

    """
  end

  defp notice_rule(scope_line) do
    """
    [[rule]]
    name = "anchor-notice"
    verb = "work-item-fail"
    text = "tell the anchor"
    archetypes = ["*"]
    #{scope_line}
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]
    effect = "notice"

    [rule.notice]
    target_session = "{anchor_session}"
    prompt = "fixture notice"
    """
  end

  defp scoped_reaction_toml do
    """
    [[reaction]]
    name = "scoped-observe"
    family = "scoped-observe"
    events = ["work_item_observation"]
    scope = { subtree_of = "role:team:alpha" }
    when = { op = "eq", args = [{ ref = "event.operation" }, "created"] }
    bind = [{ name = "wake_id", value = { op = "concat", args = ["w_scoped_", { op = "sha256", args = [{ ref = "event.id" }] }] } }]
    [[reaction.effects]]
    slot = "notice"
    kind = "notice"
    when = true
    value = { wake_id = { ref = "wake_id" }, session_key = { ref = "anchor.session_key" }, owner_user_id = { ref = "event.org" }, origin = "process:tightbeam", prompt = "scoped notice", due_at = { op = "add", args = [{ ref = "event.at" }, 3600000] }, sender_scheduled = true, on_unavailable = "skip" }
    """
  end

  defp reaction(extra) do
    Map.merge(
      %{
        "name" => "fixture-reaction",
        "family" => "fixture-family",
        "events" => ["work_item_observation"],
        "when" => true,
        "effects" => [
          %{
            "slot" => "notice",
            "kind" => "notice",
            "when" => true,
            "value" => %{"session_key" => %{"ref" => "anchor.session_key"}}
          }
        ]
      },
      extra
    )
  end

  defp write_identity!(base_dir) do
    identity = Path.join(base_dir, "identity")
    kungfu = Path.join(identity, "kungfu/#{@kungfu}")
    File.mkdir_p!(Path.join(identity, "rules"))
    File.mkdir_p!(Path.join(kungfu, "archetypes"))
    File.mkdir_p!(Path.join(kungfu, "rules"))

    File.write!(
      Path.join(kungfu, "archetypes/org-example-analyst.toml"),
      "name = \"org-example-analyst\"\nskills = []\nwhere = [\"*\"]\n"
    )

    File.write!(
      Path.join(kungfu, "installed.toml"),
      "name = \"#{@kungfu}\"\npaths = [\"kungfu/#{@kungfu}/archetypes/org-example-analyst.toml\", \"kungfu/#{@kungfu}/rules/scoped.toml\"]\n"
    )
  end

  defp write_org_rules!(base_dir, toml),
    do: File.write!(Path.join(base_dir, "identity/rules/org.toml"), toml)

  defp write_kungfu_rules!(base_dir, toml),
    do: File.write!(Path.join(base_dir, "identity/kungfu/#{@kungfu}/rules/scoped.toml"), toml)

  defp seed_session!(db, key, spawned_by, archetype) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt,spawnedBy) VALUES(?1,?1,?2,?3,?4,'claude','anthropic','fixture-model',1,1,?5)",
        [key, @owner, "user:#{@owner}", archetype, spawned_by]
      )
  end

  defp create_role!(db, name, holder) do
    %{name: ^name} = Tightbeam.Roles.create!(db, name, @owner, holder)
  end

  defp seed_work_item!(db, id, delivery_owner, created_by) do
    created_by_user = if is_nil(created_by), do: @owner, else: nil

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdBySession,createdAt,deliveryOwnerSessionKey) VALUES(?1,?1,?2,'open',?3,?4,1,?5)",
        [id, @owner, created_by_user, created_by, delivery_owner]
      )
  end

  defp seed_assignment!(db, id, holder, opener) do
    {by_session, by_user} =
      case opener do
        {:session, key} -> {key, nil}
        {:user, user} -> {nil, user}
      end

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments(id,subject,holderKey,openedBySession,openedByUser,openedAt,state) VALUES(?1,'fixture',?2,?3,?4,1,'open')",
        [id, holder, by_session, by_user]
      )
  end

  defp user_call(verb, work_item_id) do
    %{
      verb: verb,
      origin: "user:#{@owner}",
      principal: {:user, @owner},
      params: if(work_item_id, do: %{work_item_id: work_item_id}, else: %{})
    }
  end

  defp session_call(verb, caller) do
    %{verb: verb, origin: "agent:#{caller}", principal: {:session, caller}, params: %{}}
  end

  defp assignment_call(caller, assignment_id) do
    %{
      verb: "attest",
      origin: "agent:#{caller}",
      principal: {:session, caller},
      params: %{assignment_id: assignment_id}
    }
  end

  defp assert_denied_by({:deny, error}, name), do: assert(error.message =~ name)
  defp assert_denied_by(other, _name), do: flunk("expected a rule denial, got: #{inspect(other)}")
end
