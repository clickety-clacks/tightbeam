defmodule Tightbeam.ArchetypesTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{Archetypes, Identity}

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-archetypes-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Tightbeam.Archetypes)
    end)

    %{base_dir: base_dir}
  end

  test "learning seeds the served identity tree once", ctx do
    assert Archetypes.init_identity!(ctx.base_dir) == :initialized
    identity_dir = Path.join(ctx.base_dir, "identity")

    for ref <- ["tightbeam/upstream", "main", "tightbeam/live"] do
      assert {oid, 0} = System.cmd("git", ["rev-parse", ref], cd: identity_dir)
      assert String.trim(oid) != ""
    end

    for name <- [
          "default",
          "orchestrator",
          "spec-writer",
          "coder",
          "reviewer",
          "recon",
          "product-owner"
        ] do
      assert File.regular?(Path.join([identity_dir, "archetypes", "#{name}.toml"]))
    end

    assert File.regular?(Path.join([identity_dir, "guidance", "operating-model.md"]))
    assert Archetypes.init_identity!(ctx.base_dir) == :noop
    assert {"", 0} = System.cmd("git", ["status", "--short"], cd: identity_dir)
  end

  test "the shipped bundle loads role guidance and elected shared skills", ctx do
    Identity.init!(ctx.base_dir)
    loaded = Archetypes.load!(ctx.base_dir)

    assert Map.keys(loaded) |> Enum.sort() ==
             ~w(coder default orchestrator product-owner recon reviewer spec-writer)

    assert loaded["product-owner"].skills == ["tightbeam-dispatching", "product-discovery"]

    assert Identity.snapshot_at!(
             ctx.base_dir,
             Identity.live_revision!(ctx.base_dir),
             "coder",
             :codex
           ).guidance =~ "Nontrivial bugs start with a causal verdict"

    assert File.read!(
             Path.join([
               ctx.base_dir,
               "identity",
               "skills",
               "tightbeam-dispatching",
               "SKILL.md"
             ])
           ) =~ "assignment"
  end

  test "one composer delivers operating guidance to every archetype for both harnesses", ctx do
    Identity.init!(ctx.base_dir)
    loaded = Archetypes.load!(ctx.base_dir)
    revision = Identity.live_revision!(ctx.base_dir)

    for name <- Map.keys(loaded), harness <- [:codex, :claude] do
      guidance = Identity.snapshot_at!(ctx.base_dir, revision, name, harness).guidance

      assert guidance =~ "tightbeam identity edit <archetype>"
      assert guidance =~ "tightbeam identity relearn"
      assert guidance =~ "tightbeam identity status"
      assert guidance =~ "tightbeam identity apply"

      case harness do
        :codex ->
          assert guidance =~ "Codex developer message"
          refute guidance =~ "Claude system prompt. It is authoritative"

        :claude ->
          assert guidance =~ "Claude system prompt"
          refute guidance =~ "Codex developer message. It is authoritative"
      end
    end
  end

  test "manifest parsing is boot-equivalent and unknown elections fail", ctx do
    Identity.init!(ctx.base_dir)
    manifest = Path.join([ctx.base_dir, "identity", "archetypes", "default.toml"])

    File.write!(manifest, """
    name = "default"
    skills = ["does-not-exist"]
    where = ["testhost"]
    """)

    assert_raise ArgumentError, ~r/elects unknown skills/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end
end
