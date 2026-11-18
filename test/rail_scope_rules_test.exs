defmodule Tightbeam.RailScopeRulesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Rules}

  @kungfu "sample-kungfu"
  @archetype "org-example-analyst"
  @other_archetype "org-example-auditor"
  @qualified "sample-kungfu.org-example-analyst"
  @qualified_other "sample-kungfu.org-example-auditor"

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)

    base_dir =
      Path.join(System.tmp_dir!(), "rail-scope-rules-#{System.unique_integer([:positive])}")

    write_identity!(base_dir)

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{db: db, base_dir: base_dir}
  end

  test "terminal scope snapshots include an actor distinct from opener and holder", ctx do
    seed_sessions!(ctx.db)

    event = %{
      "kind" => "assignment",
      "principal" => %{"kind" => "session", "id" => "sample-substrate"},
      "terminal" => %{
        "owner_user_id" => "sample-owner",
        "opened_by_id" => "sample-creator",
        "child_session_key" => "sample-coordinator",
        "assignment_id" => "scope-terminal",
        "work_item_id" => nil
      }
    }

    assert {:ok, facts} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.RowReactions.Snapshot.current(txn, event, %{})
             end)

    actor = Enum.find(facts["sessions"], &(&1["sessionKey"] == "sample-substrate"))
    assert actor["archetype"] == "support-agent"
    assert Tightbeam.RailScope.matches_agents?(["*"], [actor["archetype"], @qualified])
    refute Tightbeam.RailScope.matches_agents?([@qualified], [actor["archetype"], @qualified])
  end

  test "agentless kungfu rails fire only when the zero-agent record belongs to their source",
       ctx do
    seed_sessions!(ctx.db)
    seed_work_items!(ctx.db)
    load_rules!(ctx.base_dir)

    assert_denied_by(
      Rules.evaluate(ctx.db, call("work-item-close", "work-owned")),
      "sample-kungfu.agentless-close"
    )

    assert :ok = Rules.evaluate(ctx.db, call("work-item-close", "work-foreign"))
    assert :ok = Rules.evaluate(ctx.db, call("work-item-close", "work-user"))
  end

  test "zero-agent membership applies even when a kungfu rail lists archetypes", ctx do
    seed_sessions!(ctx.db)
    seed_work_items!(ctx.db)
    load_rules!(ctx.base_dir)

    assert_denied_by(
      Rules.evaluate(ctx.db, call("work-item-reopen", "work-owned")),
      "sample-kungfu.scoped-reopen"
    )

    assert :ok = Rules.evaluate(ctx.db, call("work-item-reopen", "work-foreign"))
    assert :ok = Rules.evaluate(ctx.db, call("work-item-reopen", "work-user"))
  end

  test "agentless declarations do not fire on an interaction with a session", ctx do
    seed_sessions!(ctx.db)
    seed_work_items!(ctx.db)
    load_rules!(ctx.base_dir)

    assert :ok =
             Rules.evaluate(ctx.db, %{
               verb: "work-item-close",
               origin: "agent:sample-creator",
               principal: {:session, "sample-creator"},
               params: %{work_item_id: "work-owned"}
             })
  end

  test "rule conditions keep positional facts while scope checks every participant", ctx do
    seed_sessions!(ctx.db)
    load_rules!(ctx.base_dir)

    assert_denied_by(
      Rules.evaluate(ctx.db, session_call("work-item-close", "sample-creator", "sample-auditor")),
      "sample-kungfu.positional-target"
    )

    assert :ok =
             Rules.evaluate(
               ctx.db,
               session_call("work-item-close", "sample-auditor", "sample-creator")
             )

    assert :ok =
             Rules.evaluate(
               ctx.db,
               session_call("work-item-reopen", "sample-creator", "sample-auditor")
             )

    assert_denied_by(
      Rules.evaluate(
        ctx.db,
        session_call("work-item-reopen", "sample-creator", "sample-coordinator")
      ),
      "sample-kungfu.single-scope"
    )

    assert :ok =
             Rules.evaluate(
               ctx.db,
               session_call("work-item-close", "sample-creator", "sample-substrate")
             )
  end

  test "a notice is suppressed when its resolved recipient is outside the rail scope", ctx do
    seed_sessions!(ctx.db)
    load_rules!(ctx.base_dir)

    assert {:allow, [], []} =
             Rules.decide(ctx.db, session_call("work-item-fail", "sample-creator", nil))
  end

  test "substrate wildcard rails remain eligible for zero-agent records", ctx do
    seed_sessions!(ctx.db)
    seed_work_items!(ctx.db)
    load_rules!(ctx.base_dir)

    for work_item_id <- ["work-owned", "work-foreign", "work-user"] do
      assert_denied_by(
        Rules.evaluate(ctx.db, call("work-item-icebox", work_item_id)),
        "substrate-any"
      )
    end
  end

  test "kungfu rail loading refuses foreign lists and archetype comparisons", ctx do
    foreign_list = """
    [[rule]]
    name = "foreign-list"
    verb = "work-item-close"
    text = "denied"
    archetypes = ["support-agent"]
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
    """

    path = Path.join(ctx.base_dir, "identity/kungfu/#{@kungfu}/rules/scoped.toml")
    File.write!(path, foreign_list)

    log = ExUnit.CaptureLog.capture_log(fn -> load_rules!(ctx.base_dir) end)
    assert log =~ "foreign-list"
    assert log =~ "support-agent"
    assert log =~ @qualified
    assert log =~ "may name only its own archetypes"

    foreign_condition = """
    [[rule]]
    name = "foreign-condition"
    verb = "work-item-close"
    text = "denied"
    archetypes = ["#{@qualified}"]
    deny_when = [{ fact = "target.archetype", op = "in", value = ["support-agent"] }]
    """

    File.write!(path, foreign_condition)
    log = ExUnit.CaptureLog.capture_log(fn -> load_rules!(ctx.base_dir) end)
    assert log =~ "foreign-condition"
    assert log =~ "support-agent"
    assert log =~ "archetype comparison"
  end

  defp write_identity!(base_dir) do
    identity_dir = Path.join(base_dir, "identity")
    own_archetype = Path.join(identity_dir, "kungfu/#{@kungfu}/archetypes/#{@archetype}.toml")

    other_archetype =
      Path.join(identity_dir, "kungfu/#{@kungfu}/archetypes/#{@other_archetype}.toml")

    own_rules = Path.join(identity_dir, "kungfu/#{@kungfu}/rules/scoped.toml")
    substrate_rules = Path.join(identity_dir, "rules/substrate.toml")

    File.mkdir_p!(Path.dirname(own_archetype))
    File.mkdir_p!(Path.dirname(own_rules))
    File.mkdir_p!(Path.dirname(substrate_rules))

    File.write!(own_archetype, "name = \"#{@archetype}\"\nskills = []\nwhere = [\"*\"]\n")
    File.write!(other_archetype, "name = \"#{@other_archetype}\"\nskills = []\nwhere = [\"*\"]\n")

    File.write!(
      Path.join(identity_dir, "kungfu/#{@kungfu}/installed.toml"),
      "name = \"#{@kungfu}\"\npaths = [\"kungfu/#{@kungfu}/archetypes/#{@archetype}.toml\", \"kungfu/#{@kungfu}/archetypes/#{@other_archetype}.toml\", \"kungfu/#{@kungfu}/rules/scoped.toml\"]\n"
    )

    File.write!(own_rules, """
    [[rule]]
    name = "agentless-close"
    verb = "work-item-close"
    text = "denied"
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]

    [[rule]]
    name = "scoped-reopen"
    verb = "work-item-reopen"
    text = "denied"
    archetypes = ["#{@qualified}"]
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]

    [[rule]]
    name = "positional-target"
    verb = "work-item-close"
    text = "denied"
    archetypes = ["#{@qualified}", "#{@qualified_other}"]
    deny_when = [{ fact = "target.archetype", op = "eq", value = "#{@qualified_other}" }]

    [[rule]]
    name = "single-scope"
    verb = "work-item-reopen"
    text = "denied"
    archetypes = ["#{@qualified}"]
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]

    [[rule]]
    name = "notice-outside-scope"
    verb = "work-item-fail"
    text = "notify the target"
    archetypes = ["#{@qualified}"]
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]
    effect = "notice"

    [rule.notice]
    target_session = "sample-substrate"
    prompt = "fixture notice"
    """)

    File.write!(substrate_rules, """
    [[rule]]
    name = "substrate-any"
    verb = "work-item-icebox"
    text = "denied"
    archetypes = ["*"]
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
    """)
  end

  defp seed_sessions!(db) do
    for {key, owner, archetype} <- [
          {"sample-creator", "sample-owner", @qualified},
          {"sample-coordinator", "sample-owner", @qualified},
          {"sample-auditor", "sample-owner", @qualified_other},
          {"sample-substrate", "other-owner", "support-agent"}
        ] do
      assert {:ok, _} =
               DB.query(
                 db,
                 "INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt) VALUES(?1,?1,?2,?3,?4,'claude','anthropic','fixture-model',1,1)",
                 [key, owner, "user:#{owner}", archetype]
               )
    end
  end

  defp seed_work_items!(db) do
    for {id, created_by, delivery_owner} <- [
          {"work-owned", "sample-creator", "sample-coordinator"},
          {"work-foreign", "sample-creator", "sample-substrate"},
          {"work-user", nil, nil}
        ] do
      created_by_user = if is_nil(created_by), do: "sample-owner", else: nil

      assert {:ok, _} =
               DB.query(
                 db,
                 "INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdBySession,createdAt,deliveryOwnerSessionKey) VALUES(?1,?1,'sample-owner','open',?2,?3,1,?4)",
                 [id, created_by_user, created_by, delivery_owner]
               )
    end
  end

  defp load_rules!(base_dir) do
    Rules.load!(base_dir, ~w(work-item-close work-item-reopen work-item-icebox work-item-fail))
  end

  defp call(verb, work_item_id) do
    %{
      verb: verb,
      origin: "user:sample-owner",
      principal: {:user, "sample-owner"},
      params: %{work_item_id: work_item_id}
    }
  end

  defp session_call(verb, caller, target) do
    %{
      verb: verb,
      origin: "agent:#{caller}",
      principal: {:session, caller},
      session_key: target,
      params: %{}
    }
  end

  defp assert_denied_by({:deny, error}, name), do: assert(error.message =~ name)
  defp assert_denied_by(other, _name), do: flunk("expected a rail denial, got: #{inspect(other)}")
end
