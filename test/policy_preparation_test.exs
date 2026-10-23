defmodule Tightbeam.PolicyPreparationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Mementos, Rules}

  setup do
    root =
      Path.join(System.tmp_dir!(), "policy-preparation-#{System.unique_integer([:positive])}")

    active = Path.join(root, "active")
    candidate = Path.join(root, "candidate")
    File.mkdir_p!(Path.join(active, "identity/rules"))
    File.mkdir_p!(Path.join(candidate, "identity/rules"))

    File.write!(
      Path.join(active, "identity/rules/old.toml"),
      rule("old", "caller.origin_class", ~s("user"))
    )

    Rules.load!(active, ["post"], revision: "old-revision")
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)
    on_exit(fn -> File.rm_rf!(root) end)
    %{active: active, candidate: candidate, db: db}
  end

  test "preflight resolves candidate declarations without publishing them or changing admission",
       ctx do
    declare(ctx.candidate)
    write(ctx, rule("new", "call.has_memento.example/value", "false"))
    before = active_state()

    snapshot =
      Rules.prepare!(ctx.active, ["post"], law_base: ctx.candidate, revision: "candidate")

    assert snapshot.revision == "candidate"
    assert snapshot.declarations.revision == "candidate"
    assert Map.has_key?(snapshot.declarations.names, "example/value")
    assert [%{name: "new"}] = snapshot.rules
    assert snapshot.unavailable_verbs == %{}
    assert snapshot.requested_admission_contract == %{}
    assert active_state() == before
    assert {:deny, %{rule: "old"}} = Rules.evaluate(ctx.db, call())
  end

  test "ordinary load keeps a replacement admission contract classified as legacy", ctx do
    write(
      ctx,
      rule("new", "caller.origin_class", ~s("process")) <> contract("replacement", ["new"])
    )

    before = active_state()

    snapshot =
      Rules.prepare!(ctx.active, ["post"], law_base: ctx.candidate, revision: "candidate")

    assert snapshot.requested_admission_contract["post"].classification == "replacement"
    assert snapshot.active_admission_contract == %{"post" => "legacy"}
    assert active_state() == before

    assert [%{name: "new"}] =
             Rules.load!(ctx.active, ["post"], law_base: ctx.candidate, revision: "candidate")

    loaded = Rules.effective_snapshot()
    assert loaded.revision == "candidate"
    assert loaded.requested_admission_contract["post"].classification == "replacement"
    assert loaded.active_admission_contract == %{"post" => "legacy"}
    assert Rules.active_admission_contract("post") == "legacy"
  end

  test "a policy binds related request surfaces to the same admission contract", ctx do
    before = active_state()

    source =
      rule("new", "caller.origin_class", ~s("process")) <>
        contract("replacement", ["new"]) <> "\nrequest_verbs = [\"assign\", \"memento-set\"]\n"

    write(ctx, source)
    verbs = ["post", "assign", "memento-set"]
    snapshot = Rules.prepare!(ctx.active, verbs, law_base: ctx.candidate, revision: "candidate")
    assert Enum.sort(Map.keys(snapshot.requested_admission_contract)) == verbs |> Enum.sort()
    assert Enum.all?(snapshot.active_admission_contract, fn {_, value} -> value == "legacy" end)
    selected = %{snapshot | active_admission_contract: Map.new(verbs, &{&1, "replacement"})}

    Tightbeam.RuleRuntime.with_policy_snapshot(selected, fn ->
      for verb <- verbs, do: assert(Rules.active_admission_contract(verb) == "replacement")
      assert Rules.active_admission_contract("work-item-get") == "legacy"
    end)

    assert active_state() == before

    for suffix <- [
          "\n[[admission_contract]]\nverb = \"assign\"\nclassification = \"legacy\"\nrequired_rules = []\n",
          "\n[[admission_contract]]\nverb = \"memento-set\"\nclassification = \"legacy\"\nrequired_rules = []\n"
        ] do
      write(ctx, source <> suffix)

      assert_raise Mementos.Refusal, ~r/duplicate admission contract/, fn ->
        Rules.prepare!(ctx.active, verbs, law_base: ctx.candidate, revision: "candidate")
      end
    end

    for scope <- ["[\"missing\"]", "[\"post\"]", "[\"assign\", \"assign\"]", "false"] do
      write(
        ctx,
        rule("new", "caller.origin_class", ~s("process")) <>
          contract("replacement", ["new"]) <> "\nrequest_verbs = " <> scope <> "\n"
      )

      assert_raise Mementos.Refusal, ~r/malformed admission contract/, fn ->
        Rules.prepare!(ctx.active, verbs, law_base: ctx.candidate, revision: "candidate")
      end
    end
  end

  test "replacement classification refuses incomplete loaded readback", ctx do
    write(
      ctx,
      rule("new", "caller.origin_class", ~s("process")) <> contract("replacement", ["new"])
    )

    candidate =
      Rules.prepare!(ctx.active, ["post"], law_base: ctx.candidate, revision: "candidate")

    selected = %{candidate | active_admission_contract: %{"post" => "replacement"}}

    assert "replacement" ==
             Tightbeam.RuleRuntime.with_policy_snapshot(selected, fn ->
               Rules.active_admission_contract("post")
             end)

    for invalid <- [
          %{selected | rules: []},
          %{selected | active_admission_contract: nil},
          %{selected | requested_admission_contract: %{"post" => %{}}},
          %{selected | requested_admission_contract: %{}},
          %{selected | unavailable_verbs: %{"post" => "unavailable"}},
          %{selected | declarations: %{revision: "other", names: %{}}},
          %{selected | active_admission_contract: %{"post" => "unknown"}}
        ] do
      error =
        assert_raise Mementos.Refusal, fn ->
          Tightbeam.RuleRuntime.with_policy_snapshot(invalid, fn ->
            Rules.active_admission_contract("post")
          end)
        end

      assert error.code == "policy_revision_unavailable"
    end

    assert Rules.active_admission_contract("post") == "legacy"
  end

  test "loaded rule inventory preserves legacy predicates before replacement",
       ctx do
    write(ctx, """
    [[rule]]
    name = "inventory"
    verb = "attest"
    text = "inventory predicate provenance"
    deny_when = [{fact = "caller.origin_class", op = "eq", value = "user"}]
    require = [{fact = "assignment.latest_holder_verdict.present", op = "eq", value = true}]
    """)

    candidate =
      Rules.prepare!(ctx.active, ["attest"], law_base: ctx.candidate, revision: "candidate")

    assert Rules.policy_rule_inventory(candidate) == [
             %{
               name: "inventory",
               verb: "attest",
               identity_revision: "candidate",
               facts: ["assignment.latest_holder_verdict.present", "caller.origin_class"]
             }
           ]

    before = active_state()
    write(ctx, rule("retired", "assignment.effect_kind", ~s("code")))

    retired =
      Rules.prepare!(ctx.active, ["post"], law_base: ctx.candidate, revision: "retired")

    assert [%{name: "retired", verb: "post", facts: ["assignment.effect_kind"]}] =
             Rules.policy_rule_inventory(retired)

    refute Map.has_key?(retired.unavailable_verbs, "post")
    assert active_state() == before
    assert Rules.active_identity_manifest_sha() == "old-revision"
  end

  test "legacy metadata and memento declarations preserve the old admission contract", ctx do
    declare(ctx.candidate)
    write(ctx, rule("migration", "caller.origin_class", ~s("user")) <> contract("legacy", []))

    assert [%{name: "migration"}] =
             Rules.load!(ctx.active, ["post"], law_base: ctx.candidate, revision: "migration")

    assert Mementos.declarations().revision == "migration"
    assert {:deny, %{rule: "migration"}} = Rules.evaluate(ctx.db, call())
  end

  test "missing, invalid and unavailable required rules cannot stage replacement", ctx do
    for contents <- [
          rule("other", "caller.origin_class", ~s("user")) <> contract("replacement", ["missing"]),
          rule("new", "unrecognized.fact", "true") <> contract("replacement", ["new"]),
          rule("new", "caller.origin_class", ~s("user")) <> contract("replacement", []),
          rule("new", "caller.origin_class", ~s("user")) <> contract("invalid", ["new"]),
          "admission_contract = true\n" <> rule("new", "caller.origin_class", ~s("user"))
        ] do
      write(ctx, contents)
      before = active_state()

      result =
        try do
          {:ok,
           Rules.prepare!(ctx.active, ["post"], law_base: ctx.candidate, revision: "candidate")}
        rescue
          error in Mementos.Refusal -> {:refused, error.code}
        end

      case result do
        {:refused, code} ->
          assert code == "policy_revision_unavailable"

        {:ok, snapshot} ->
          # Invalid TOML/rule shape is quarantined and cannot expose replacement.
          assert snapshot.requested_admission_contract == %{}
          assert Map.has_key?(snapshot.unavailable_verbs, "post")
      end

      assert active_state() == before
    end
  end

  test "a replacement candidate without a revision cannot be staged", ctx do
    write(ctx, rule("new", "caller.origin_class", ~s("user")) <> contract("replacement", ["new"]))
    before = active_state()

    error =
      assert_raise Mementos.Refusal, fn ->
        Rules.prepare!(ctx.candidate, ["post"])
      end

    assert error.code == "policy_revision_unavailable"
    assert active_state() == before
  end

  test "candidate declaration scope is private to preparation and restores after failure", ctx do
    declare(ctx.candidate)
    prepared = Mementos.read_declarations!(ctx.candidate, "candidate")
    before = active_state()
    parent = self()

    task =
      Task.async(fn ->
        assert_raise RuntimeError, "preflight stopped", fn ->
          Mementos.with_declarations(prepared, fn ->
            assert Mementos.declarations() == prepared
            send(parent, {:candidate_visible, self()})

            receive do
              :resume -> raise "preflight stopped"
            end
          end)
        end

        Mementos.declarations()
      end)

    assert_receive {:candidate_visible, pid}
    assert active_state() == before
    send(pid, :resume)
    assert Task.await(task) == elem(before, 0)
    assert active_state() == before
  end

  test "duplicate scopes and wrong-operation required rules refuse without replacing active state",
       ctx do
    for content <- [
          rule("new", "caller.origin_class", ~s("user")) <>
            contract("replacement", ["new"]) <> contract("legacy", []),
          String.replace(
            rule("new", "caller.origin_class", ~s("user")),
            ~s(verb = "post"),
            ~s(verb = "wake")
          ) <>
            contract("replacement", ["new"])
        ] do
      write(ctx, content)
      before = active_state()

      error =
        assert_raise Mementos.Refusal, fn ->
          Rules.prepare!(ctx.active, ["post", "wake"],
            law_base: ctx.candidate,
            revision: "candidate"
          )
        end

      assert error.code == "policy_revision_unavailable"
      assert active_state() == before
    end
  end

  test "failed declaration parsing leaves the old snapshot intact", ctx do
    declare(ctx.candidate)

    File.write!(
      Path.join(ctx.candidate, "identity/kungfu/example/manifest.toml"),
      "mementos = false"
    )

    before = active_state()

    assert_raise ArgumentError, fn ->
      Rules.prepare!(ctx.active, ["post"], law_base: ctx.candidate, revision: "candidate")
    end

    assert active_state() == before
    assert {:deny, %{rule: "old"}} = Rules.evaluate(ctx.db, call())
  end

  test "an evaluation observes the active policy after an atomic reload", ctx do
    declare(ctx.candidate)
    write(ctx, rule("new", "caller.origin_class", ~s("process")))
    before = Rules.effective_snapshot()
    assert before.revision == "old-revision"
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:waiting, self()})

        receive do
          :reloaded -> :ok
        end

        snapshot = Rules.effective_snapshot()
        assert snapshot.revision == "new-revision"
        assert Mementos.declarations() == snapshot.declarations
        assert Rules.active_admission_contract("post") == "legacy"
        assert :ok = Rules.evaluate(ctx.db, call())

        Rules.effective_snapshot()
      end)

    assert_receive {:waiting, pid}
    Rules.load!(ctx.active, ["post"], law_base: ctx.candidate, revision: "new-revision")
    after_reload = Rules.effective_snapshot()
    assert after_reload.revision == "new-revision"
    assert Mementos.declarations() == after_reload.declarations
    assert Map.has_key?(after_reload.declarations.names, "example/value")
    assert :ok = Rules.evaluate(ctx.db, call())
    send(pid, :reloaded)
    assert Task.await(task) == after_reload
  end

  test "unscoped dispatch observes the active policy after a reload", ctx do
    declare(ctx.candidate)
    write(ctx, rule("new", "caller.origin_class", ~s("process")))
    before = Rules.effective_snapshot()
    assert before.revision == "old-revision"
    parent = self()
    :ok = DB.execute(ctx.db, "CREATE TABLE policy_write(revision TEXT)")
    invocation = %{call() | origin: "process:fixture"}

    handler = fn _ ->
      send(parent, {:handler_entered, self()})
      receive do: (:continue -> :ok)
      assert Rules.effective_snapshot().revision == "new-revision"

      {:ok, result} =
        DB.transaction(ctx.db, fn txn ->
          assert Rules.effective_snapshot().revision == "new-revision"
          assert Rules.active_admission_contract("post") == "legacy"
          assert {:deny, %{rule: "new"}} = Rules.evaluate(txn, invocation)
          DB.Txn.q(txn, "INSERT INTO policy_write VALUES(?1)", ["new-revision"])
          %{revision: Rules.effective_snapshot().revision}
        end)

      result
    end

    task =
      Task.async(fn -> Tightbeam.Dispatch.dispatch(ctx.db, %{"post" => handler}, invocation) end)

    assert_receive {:handler_entered, pid}
    Rules.load!(ctx.active, ["post"], law_base: ctx.candidate, revision: "new-revision")
    assert {:deny, %{rule: "new"}} = Rules.evaluate(ctx.db, invocation)
    send(pid, :continue)
    assert {:ok, %{revision: "new-revision"}} = Task.await(task)
    assert {:ok, [["new-revision"]]} = DB.query(ctx.db, "SELECT revision FROM policy_write")

    assert {:ok, "new-revision"} =
             DB.transaction(ctx.db, fn _ -> Rules.effective_snapshot().revision end)
  end

  test "transaction callbacks observe reloads after crossing the owner boundary", ctx do
    write(ctx, rule("new", "caller.origin_class", ~s("process")))
    parent = self()

    prepare = fn _txn ->
      send(parent, {:owner_entered, self()})
      receive do: (:continue -> :ok)
      assert Rules.effective_snapshot().revision == "new-revision"
      %{revision: Rules.effective_snapshot().revision}
    end

    task =
      Task.async(fn ->
        DB.transaction_then(ctx.db, prepare, fn _txn, result ->
          assert Rules.effective_snapshot().revision == "new-revision"
          result
        end)
      end)

    assert_receive {:owner_entered, owner}
    Rules.load!(ctx.active, ["post"], law_base: ctx.candidate, revision: "new-revision")
    send(owner, :continue)
    assert {:ok, %{revision: "new-revision"}} = Task.await(task)
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM pending_recognition")
  end

  defp active_state do
    {Mementos.declarations(), Rules.effective_snapshot()}
  end

  defp write(ctx, bytes),
    do: File.write!(Path.join(ctx.candidate, "identity/rules/new.toml"), bytes)

  defp declare(base) do
    path = Path.join(base, "identity/kungfu/example")
    File.mkdir_p!(path)

    File.write!(Path.join(path, "manifest.toml"), """
    [[mementos]]
    name = "value"
    records = ["assignment"]
    """)
  end

  defp rule(name, fact, value) do
    """
    [[rule]]
    name = "#{name}"
    verb = "post"
    text = "predicate refused"
    deny_when = [{fact = "#{fact}", op = "eq", value = #{value}}]
    """
  end

  defp contract(classification, required) do
    """

    [[admission_contract]]
    verb = "post"
    classification = "#{classification}"
    required_rules = [#{Enum.map_join(required, ", ", &inspect/1)}]
    """
  end

  defp call, do: %{verb: "post", origin: "user:operator", params: %{}}
end
