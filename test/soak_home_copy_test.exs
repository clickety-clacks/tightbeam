Code.require_file("../scripts/support/soak_gateway.exs", __DIR__)

defmodule Tightbeam.SoakHomeCopyTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Soak.GatewayProcess
  @moduletag :selected_home_copy

  setup do
    root = Path.join(System.tmp_dir!(), "soak-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root = Tightbeam.LiveBaseAdmission.canonical!(root)
    source = Path.join(root, "source")
    arena = Path.join(root, "arena")
    home = Tightbeam.Homes.home_path(source, "testhost", :claude)

    for {name, bytes} <- [
          {".credentials.json", "synthetic-claude-token"},
          {".tightbeam/credential.json", "synthetic-metadata"},
          {"sessions/preserved", "synthetic-history"}
        ] do
      path = Path.join(home, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    File.mkdir_p!(arena)
    File.write!(Path.join(arena, ".soak-arena"), "synthetic arena")
    on_exit(fn -> File.rm_rf!(root) end)
    %{source: source, arena: arena, home: home}
  end

  test "copies only the exact machine Claude home, preserving source and ignoring legacy auth",
       c do
    for rel <- ["auth/claude/token", "homes/other/claude/token", "homes/testhost/codex/auth.json"] do
      path = Path.join(c.source, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not-selected")
    end

    plan = GatewayProcess.home_plan!(c.arena, c.source, "testhost")
    assert :ok = GatewayProcess.seed_home!(c.arena, plan)
    target = Tightbeam.Homes.home_path(c.arena, "testhost", :claude)

    for rel <- [".credentials.json", ".tightbeam/credential.json", "sessions/preserved"] do
      assert File.read!(Path.join(target, rel)) == File.read!(Path.join(c.home, rel))
    end

    for rel <- ["auth", "homes/other", "homes/testhost/codex"] do
      refute File.exists?(Path.join(c.arena, rel))
    end
  end

  test "wrong machine, overlap, and unmarked target refuse", c do
    assert_raise RuntimeError, ~r/refusing/, fn ->
      GatewayProcess.home_plan!(c.arena, c.source, "other")
    end

    assert_raise RuntimeError, ~r/overlapping/, fn ->
      GatewayProcess.home_plan!(c.source, c.source, "testhost")
    end

    assert_raise RuntimeError, ~r/invalid/, fn ->
      GatewayProcess.home_plan!(c.arena, c.source, "../other")
    end

    plan = GatewayProcess.home_plan!(c.arena, c.source, "testhost")
    File.rm!(Path.join(c.arena, ".soak-arena"))
    assert_raise RuntimeError, ~r/unmarked/, fn -> GatewayProcess.seed_home!(c.arena, plan) end
    refute File.exists?(Path.join(c.arena, "homes"))
  end

  test "missing metadata and symlinked credential refuse without copying", c do
    metadata = Path.join(c.home, ".tightbeam/credential.json")
    File.rm!(metadata)

    assert_raise RuntimeError, ~r/without regular/, fn ->
      GatewayProcess.home_plan!(c.arena, c.source, "testhost")
    end

    File.write!(metadata, "synthetic-metadata")
    secret = Path.join(c.home, ".credentials.json")
    File.rename!(secret, secret <> ".original")
    File.ln_s!(secret <> ".original", secret)

    assert_raise RuntimeError, ~r/linked or special/, fn ->
      GatewayProcess.home_plan!(c.arena, c.source, "testhost")
    end

    refute File.exists?(Path.join(c.arena, "homes"))
  end
end
