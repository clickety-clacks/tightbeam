defmodule Tightbeam.MementoEffectSourceTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Gateway, MementoCutover, Mementos, Rules}
  @moduletag tmp_dir: true

  setup %{tmp_dir: base} do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',1,1)")

    :ok =
      DB.execute(db, """
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,state,createdAt,updatedAt)
      VALUES('holder','holder','owner','user:owner','coder','claude','anthropic','fable','active',1,1)
      """)

    for id <- ["historical", "generic"] do
      assert {:ok, []} =
               DB.query(
                 db,
                 """
                 INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,state)
                 VALUES(?1,?1,'holder','owner',1,'open')
                 """,
                 [id]
               )
    end

    :ok =
      DB.execute(
        db,
        "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES('historical','code')"
      )

    rules = Path.join(base, "identity/rules")
    bundle = Path.join(base, "identity/kungfu/agentic-engineering")
    File.mkdir_p!(rules)
    File.mkdir_p!(bundle)
    File.cp!("priv/kungfu/agentic-engineering/manifest.toml", Path.join(bundle, "manifest.toml"))
    path = Path.join(rules, "memento-cutover.toml")
    File.cp!("priv/kungfu/agentic-engineering/rules/memento-cutover.toml", path)
    handlers = Gateway.handlers(%{db: db})
    candidate = Rules.prepare!(base, Map.keys(handlers), revision: "candidate")

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               for id <- ["historical", "generic"] do
                 Mementos.append_in_txn!(
                   txn,
                   "assignment",
                   id,
                   [{"agentic-engineering/effect-kind", ["code"]}],
                   {:user, "owner"},
                   "candidate"
                 )
               end

               :ok
             end)

    %{db: db, base: base, path: path, candidate: candidate, verbs: Map.keys(handlers)}
  end

  test "full census retains generic assignments but maps only actual legacy sources", ctx do
    assert {:ok, before_rows} = DB.query(ctx.db, "SELECT * FROM assignments ORDER BY id")

    assert {:ok, before_heads} =
             DB.query(ctx.db, "SELECT * FROM memento_current ORDER BY recordId")

    assert {:ok, census} = census(ctx)

    assert Enum.map(census.effects, &{&1.id, &1.selected}) == [
             {"generic", false},
             {"historical", true}
           ]

    assert Enum.find(census.effects, &(&1.id == "historical")).mapping.value == "code"
    assert Enum.find(census.effects, &(&1.id == "generic")).legacy_value == nil
    assert {:ok, ^before_rows} = DB.query(ctx.db, "SELECT * FROM assignments ORDER BY id")

    assert {:ok, ^before_heads} =
             DB.query(ctx.db, "SELECT * FROM memento_current ORDER BY recordId")

    :ok =
      DB.execute(
        ctx.db,
        "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES('generic','policy')"
      )

    assert {:error, error} = census(ctx)
    assert Exception.message(error) =~ "generic"
    assert Exception.message(error) =~ "value"
  end

  test "presence is cutover-only and cannot come from a host call", ctx do
    original = File.read!(ctx.path)

    File.write!(
      ctx.path,
      String.replace(original, ~s(edges = ["cutover"]), ~s(edges = ["verb"]), global: false)
    )

    assert_raise Mementos.Refusal, ~r/selector rule engineering-cutover-effects is missing/, fn ->
      Rules.prepare!(ctx.base, ctx.verbs, revision: "invalid")
    end

    # Without the dependent declaration, the normal loader records the same
    # invalid ordinary rule as unavailable instead of raising for its selector.
    standalone = ctx.path |> File.read!() |> String.split("[[rule]]", parts: 3) |> Enum.at(1)
    File.write!(ctx.path, "[[rule]]" <> standalone)
    invalid = Rules.prepare!(ctx.base, ctx.verbs, revision: "invalid-rule")
    assert Map.has_key?(invalid.unavailable_verbs, "attest")
    assert invalid.rules == []

    evidence =
      Tightbeam.RuleRuntime.with_policy_snapshot(ctx.candidate, fn ->
        Rules.condition_evidence(
          ctx.db,
          %{
            "cutover.assignment.has_legacy_effect" => true,
            verb: "attest",
            params: %{assignment_id: "historical", has_legacy_effect: true}
          },
          [%{fact: "cutover.assignment.has_legacy_effect", op: "eq", value: true}]
        )
      end)

    refute evidence.matched
  end

  defp census(ctx),
    do: DB.transaction(ctx.db, &MementoCutover.census_in_txn!(&1, ctx.candidate))
end
