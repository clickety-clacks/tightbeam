defmodule Tightbeam.SubtreeGuidanceTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, Model, Org, SubtreeGuidance, Wakes}

  @main Org.personal_session_key("test-owner")

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = Tightbeam.Schema.ensure_all(name)
    %{db: name}
  end

  defp base(overrides) do
    Map.merge(
      %{
        display_name: "Session",
        owner_user_id: "test-owner",
        origin: "user:test-owner",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      },
      overrides
    )
  end

  # main -> coord -> {worker-a (coder), worker-b (reviewer)}; outsider under main.
  defp tree(db) do
    Org.create(db, base(%{session_key: @main, kind: "main", display_name: "Main"}))

    Org.create(
      db,
      base(%{
        session_key: "coord",
        kind: "custom",
        spawned_by: @main,
        display_name: "Coordinator"
      })
    )

    Org.create(
      db,
      base(%{session_key: "worker-a", kind: "custom", spawned_by: "coord", archetype: "coder"})
    )

    Org.create(
      db,
      base(%{session_key: "worker-b", kind: "custom", spawned_by: "coord", archetype: "reviewer"})
    )

    Org.create(db, base(%{session_key: "outsider", kind: "custom", spawned_by: @main}))

    for key <- [@main, "coord", "worker-a", "worker-b", "outsider"] do
      Org.append_pointer(db, key, "harness-#{key}", "created")
    end
  end

  defp push_prompts(db, session_key) do
    db
    |> Wakes.list_for_session(session_key)
    |> Enum.filter(&String.starts_with?(&1.prompt, "Subtree guidance update"))
    |> Enum.map(& &1.prompt)
  end

  test "an entry applies to descendants in scope and never to the writer", %{db: db} do
    tree(db)

    {:ok, _} = SubtreeGuidance.set(db, "coord", "style", nil, "Write plainly.")

    assert SubtreeGuidance.section(db, "worker-a") =~ "Write plainly."
    assert SubtreeGuidance.section(db, "worker-b") =~ "Write plainly."
    assert SubtreeGuidance.section(db, "coord") == nil
    assert SubtreeGuidance.section(db, "outsider") == nil
  end

  test "archetype scope matches the session archetype exactly", %{db: db} do
    tree(db)

    {:ok, _} = SubtreeGuidance.set(db, "coord", "coders-only", ["coder"], "Coder rule.")

    assert SubtreeGuidance.section(db, "worker-a") =~ "Coder rule."
    assert SubtreeGuidance.section(db, "worker-b") == nil
  end

  test "section orders by writer distance then name and names each writer", %{db: db} do
    tree(db)

    {:ok, _} = SubtreeGuidance.set(db, @main, "zz-org", nil, "Org-wide rule.")
    {:ok, _} = SubtreeGuidance.set(db, "coord", "bb-lane", nil, "Lane rule.")
    {:ok, _} = SubtreeGuidance.set(db, "coord", "aa-lane", nil, "First lane rule.")

    section = SubtreeGuidance.section(db, "worker-a")

    assert section =~ "## Subtree guidance"
    assert section =~ "nearer writer"
    assert section =~ "among these entries only"

    aa = :binary.match(section, "### aa-lane") |> elem(0)
    bb = :binary.match(section, "### bb-lane") |> elem(0)
    zz = :binary.match(section, "### zz-org") |> elem(0)
    assert aa < bb and bb < zz

    assert section =~ "from Coordinator (coord), distance 1, scope: all descendants"
    assert section =~ "from Main (#{@main}), distance 2"
  end

  test "setting with the same name replaces the entry", %{db: db} do
    tree(db)

    {:ok, _} = SubtreeGuidance.set(db, "coord", "style", nil, "Old text.")
    {:ok, result} = SubtreeGuidance.set(db, "coord", "style", ["coder"], "New text.")
    refute Map.has_key?(result, :replaced)
    section = SubtreeGuidance.section(db, "worker-a")
    assert section =~ "New text."
    refute section =~ "Old text."
    assert SubtreeGuidance.section(db, "worker-b") == nil
  end

  test "a write pushes the full new section to started descendants whose section changed",
       %{db: db} do
    tree(db)

    {:ok, result} = SubtreeGuidance.set(db, "coord", "coders-only", ["coder"], "Coder rule.")

    assert result.pushed_to == ["worker-a"]

    assert [prompt] = push_prompts(db, "worker-a")
    assert prompt =~ "complete"
    assert prompt =~ "replaces any earlier subtree guidance"
    assert prompt =~ "## Subtree guidance"
    assert prompt =~ "Coder rule."

    assert push_prompts(db, "worker-b") == []
    assert push_prompts(db, "outsider") == []
    assert push_prompts(db, "coord") == []
  end

  test "a session without a harness pointer is not pushed but still composes the section",
       %{db: db} do
    tree(db)

    Org.create(
      db,
      base(%{session_key: "unstarted", kind: "custom", spawned_by: "coord", archetype: "coder"})
    )

    {:ok, result} = SubtreeGuidance.set(db, "coord", "style", nil, "Write plainly.")

    refute "unstarted" in result.pushed_to
    assert push_prompts(db, "unstarted") == []
    assert SubtreeGuidance.section(db, "unstarted") =~ "Write plainly."
  end

  test "withdrawing the last applicable entry pushes the withdrawal wording", %{db: db} do
    tree(db)

    {:ok, _} = SubtreeGuidance.set(db, "coord", "style", nil, "Write plainly.")
    {:ok, result} = SubtreeGuidance.withdraw(db, "coord", "style")

    assert result.withdrawn == "style"
    assert Enum.sort(result.pushed_to) == ["worker-a", "worker-b"]
    assert SubtreeGuidance.section(db, "worker-a") == nil

    assert Enum.any?(
             push_prompts(db, "worker-a"),
             &(&1 =~ "withdrawn" and &1 =~ "no subtree guidance now applies")
           )
  end

  test "withdrawing an unknown name reports the writer's entries", %{db: db} do
    tree(db)
    {:ok, _} = SubtreeGuidance.set(db, "coord", "style", nil, "Write plainly.")

    assert {:error, %{code: "unknown_entry", message: message}} =
             SubtreeGuidance.withdraw(db, "coord", "nope")

    assert message =~ "style"
  end

  test "retired writer's entries stay with it and no longer reach active sessions", %{db: db} do
    tree(db)

    {:ok, _} = SubtreeGuidance.set(db, "coord", "style", nil, "Write plainly.")

    result =
      Gateway.handlers(%{db: db})["retire"].(%{
        verb: "retire",
        origin: "user:test-owner",
        principal: {:user, "test-owner"},
        session_key: "coord",
        params: %{}
      })

    assert Enum.sort(result.retired_session_keys) == ["coord", "worker-a", "worker-b"]

    for session_key <- result.retired_session_keys do
      assert Org.get(db, session_key).state == "retired"
    end

    assert {:ok, %{entries: [%{name: "style"}]}} = SubtreeGuidance.show(db, "coord")
    assert SubtreeGuidance.section(db, @main) == nil
    assert SubtreeGuidance.section(db, "outsider") == nil
  end

  test "show reports a session's own entries and its applicable section", %{db: db} do
    tree(db)

    {:ok, _} = SubtreeGuidance.set(db, @main, "org", nil, "Org-wide rule.")
    {:ok, _} = SubtreeGuidance.set(db, "coord", "style", ["coder"], "Coder rule.")

    assert {:ok, shown} = SubtreeGuidance.show(db, "coord")
    assert [%{name: "style", archetypes: ["coder"], text: "Coder rule."}] = shown.entries
    refute Map.has_key?(hd(shown.entries), :created_at)
    refute Map.has_key?(hd(shown.entries), :updated_at)
    assert shown.section =~ "Org-wide rule."
    refute shown.section =~ "Coder rule."

    assert {:error, %{code: "unknown_session"}} = SubtreeGuidance.show(db, "nobody")
  end

  test "a name and text are required and archetypes must be names", %{db: db} do
    tree(db)

    assert {:error, %{code: "invalid_entry"}} = SubtreeGuidance.set(db, "coord", "", nil, "x")
    assert {:error, %{code: "invalid_entry"}} = SubtreeGuidance.set(db, "coord", "style", nil, "")

    assert {:error, %{code: "invalid_entry"}} =
             SubtreeGuidance.set(db, "coord", "style", [""], "x")
  end
end
