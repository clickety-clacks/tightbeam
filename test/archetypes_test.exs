defmodule Tightbeam.ArchetypesTest do
  use ExUnit.Case, async: false

  alias Tightbeam.Archetypes

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-archetypes-#{System.unique_integer([:positive])}")
    manifests = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)
    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{base_dir: base_dir, manifests: manifests}
  end

  test "loads all fields, merges the built-in default, and permits default override", ctx do
    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"
    where = ["work-1", "work-2"]

    [defaults]
    harness = "codex"
    model = "gpt-5.6-sol[medium]"

    [references]
    repo = { location = "work-1:~/src/example-repo", access = "git; gate: run the tests" }
    brief = { location = "work-1:~/brief.md" }

    [guidance]
    text = "Ship the requested change."
    """)

    loaded = Archetypes.load!(ctx.base_dir)

    assert loaded["default"] == Archetypes.builtin_default()

    assert loaded["coder"] == %{
             name: "coder",
             where: ["work-1", "work-2"],
             defaults: %{harness: :codex, model: "gpt-5.6-sol[medium]"},
             references: [
               %{name: "brief", location: "work-1:~/brief.md", access: nil},
               %{
                 name: "repo",
                 location: "work-1:~/src/example-repo",
                 access: "git; gate: run the tests"
               }
             ],
             guidance: "Ship the requested change."
           }

    assert Archetypes.get("coder") == loaded["coder"]
    assert Archetypes.names() == ["coder", "default"]

    File.write!(Path.join(ctx.manifests, "default.toml"), """
    name = "default"
    where = ["work-1"]
    """)

    assert Archetypes.load!(ctx.base_dir)["default"].where == ["work-1"]
  end

  test "unknown top-level keys raise", ctx do
    File.write!(Path.join(ctx.manifests, "bad.toml"), "name = \"bad\"\nware = [\"local\"]\n")

    assert_raise ArgumentError, ~r/unknown top-level archetype keys.*ware/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "bad defaults harness raises", ctx do
    File.write!(Path.join(ctx.manifests, "bad.toml"), """
    name = "bad"
    [defaults]
    harness = "other"
    """)

    assert_raise ArgumentError, ~r/defaults.harness must be claude or codex/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "reference without location raises", ctx do
    File.write!(Path.join(ctx.manifests, "bad.toml"), """
    name = "bad"
    [references]
    repo = { access = "read" }
    """)

    assert_raise ArgumentError, ~r/reference repo is missing location/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "guidance renders exact sections in order and is pure" do
    archetype = %{
      name: "coder",
      where: ["local"],
      defaults: %{},
      references: [
        %{name: "repo", location: "work-1:~/src/example-repo", access: "git"},
        %{name: "brief", location: "work-1:~/brief.md", access: nil}
      ],
      guidance: "## Assignment\nImplement E4a."
    }

    expected =
      """
      # Tightbeam · coder

      You are an agent in a Tightbeam dark factory. You can talk to other
      sessions and schedule your own follow-ups with the `tightbeam` CLI.
      See the scheduling-wakes skill below.

      ## Skill: scheduling-wakes
      Use the `tightbeam` CLI to coordinate with other sessions. Run
      `tightbeam help` any time for full, authoritative usage of every command and
      flag. Your identity for every call is your own handle, passed with
      `--as <handle>` (this is WHO the call is from, not the target).

      - DM another session now (delivers a prompt it will act on):
          tightbeam wake <sessionKeyOrHandle> --prompt "..." --as <your-handle>
      - Schedule a follow-up for yourself or another session later:
          tightbeam wake <target> --prompt "..." --after 5m --as <your-handle>
          (durations: 30s, 5m, 2h)
      - Hire a worker session:
          tightbeam spawn --display "Reviewer" --name reviewer:x --harness codex \\
            --model "gpt-5.6-sol[high]" --as <your-handle>
      - See the org you can address:
          tightbeam list --as <your-handle>
      - Cancel a pending wake:
          tightbeam cancel-wake <wakeId> --as <your-handle>

      A wake always carries a prompt — there is no content-free ping. A wake is not
      an obligation to reply; act only if you have something to add.

      ## Your materials
      - repo: work-1:~/src/example-repo
        access: git
      - brief: work-1:~/brief.md

      ## Assignment
      Implement E4a.
      """
      |> String.trim_trailing()

    first = Archetypes.guidance(archetype)
    assert first == expected
    assert Archetypes.guidance(archetype) == first

    without_references = %{archetype | references: [], guidance: "Additional law."}
    compiled = Archetypes.guidance(without_references)
    refute compiled =~ "## Your materials"
    assert String.ends_with?(compiled, "something to add.\n\nAdditional law.")
  end
end
