defmodule Tightbeam.HarnessSeamTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Harness, Homes}

  test "unknown harnesses raise and the fixture follows the runtime default path" do
    assert_raise ArgumentError, ~r/unknown harness "nonesuch"/, fn ->
      Harness.parse!("nonesuch")
    end

    previous = System.get_env("TIGHTBEAM_DEFAULT_HARNESS")
    System.put_env("TIGHTBEAM_DEFAULT_HARNESS", "fixture")

    on_exit(fn ->
      if previous,
        do: System.put_env("TIGHTBEAM_DEFAULT_HARNESS", previous),
        else: System.delete_env("TIGHTBEAM_DEFAULT_HARNESS")
    end)

    config = Config.Reader.read!("config/runtime.exs", env: :prod)
    assert get_in(config, [:tightbeam, :default_harness]) == :fixture
  end

  test "the shipped offline registry is the production registry projection" do
    rows =
      Application.app_dir(:tightbeam, "priv/harness_registry.json")
      |> File.read!()
      |> JSON.decode!()

    enabled_rows = Enum.reject(rows, &(&1["enabled"] == false))
    modules = Enum.map(enabled_rows, &(&1["module"] |> String.split(".") |> Module.concat()))
    assert modules == Enum.reject(Harness.all(), &(&1 == Harness.Fixture))

    Enum.zip(enabled_rows, modules)
    |> Enum.each(fn {row, module} ->
      assert row |> Map.drop(["module", "enabled"]) == JSON.decode!(module.wire_projection())
    end)

    assert Enum.find(rows, &(&1["wire_name"] == "cursor"))["enabled"] == false
  end

  test "fixture fetches a catalog and reconciles its home through the shared seam" do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-fixture-seam-#{System.unique_integer([:positive])}")

    auth_dir = Homes.home_path(base_dir, "testhost", :fixture)
    home = Homes.home_path(base_dir, "testhost", :fixture)
    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "fixture.json"), "fixture-token")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "durable-session"), "unchanged")
    on_exit(fn -> File.rm_rf!(base_dir) end)

    assert {:ok, [%{family: "fixture-model", context: nil, provider: :fixture_provider}]} =
             Harness.Fixture.fetch_catalog(%{})

    assert %{home_path: ^home} =
             Homes.project(base_dir, %{
               harness: :fixture,
               machine: "testhost",
               rails: nil
             })

    assert File.read!(Path.join(home, "durable-session")) == "unchanged"

    assert File.read!(Path.join(home, "fixture.json")) == "fixture-token"
    assert File.lstat!(Path.join(home, "fixture.json")).type == :regular
    refute File.exists?(Path.join(base_dir, "auth"))
  end

  test "literal scan passes, fails on a scoped reintroduction, and wire projection has two consumers" do
    scan_root = Path.join(System.tmp_dir!(), "harness-seam-scan")

    Enum.each(
      [
        "lib",
        "config",
        "scripts",
        "cli/src",
        "docs/SMOKE.md",
        "priv/provider_literal_sites.txt",
        "test/harness_conformance_test.exs"
      ],
      fn path ->
        destination = Path.join(scan_root, path)
        File.mkdir_p!(Path.dirname(destination))
        File.cp_r!(path, destination)
      end
    )

    scan = Path.join(scan_root, "scripts/check_harness_seam.sh")

    assert {"", 0} =
             System.cmd(scan, [], cd: scan_root, stderr_to_stdout: true)

    probe = Path.join(scan_root, "lib/tightbeam/harness_literal_probe.ex")
    File.write!(probe, ~s(defmodule Tightbeam.HarnessLiteralProbe, do: @value "CODEX_HOME"\n))

    assert {_output, 1} =
             System.cmd(scan, [], cd: scan_root, stderr_to_stdout: true)

    File.rm!(probe)

    File.write!(
      probe,
      """
      defmodule Tightbeam.HarnessLiteralProbe do
        def bad(session), do: case session.harness do
          value -> value
        end
      end
      """
    )

    assert {_output, 1} =
             System.cmd(scan, [], cd: scan_root, stderr_to_stdout: true)

    File.rm!(probe)

    # grep, not rg: the test harness's System.cmd PATH carries no rg.
    {calls, 0} =
      System.cmd(
        "grep",
        [
          "-RlE",
          "\\.wire_projection\\(\\)",
          "lib",
          "--exclude-dir=harness"
        ],
        cd: scan_root
      )

    assert calls |> String.split("\n", trim: true) |> Enum.sort() ==
             ["lib/tightbeam/boot.ex", "lib/tightbeam/wire/router.ex"]

    assert {"", 1} =
             System.cmd(
               "grep",
               [
                 "-RnE",
                 "\"(wire_name|install_package|cli_binary|process_markers)\"",
                 "lib",
                 "--exclude-dir=harness"
               ],
               cd: scan_root
             )
  end

  test "claude has no compiled model allowlist or manual catalog filter" do
    source = File.read!(Path.join(File.cwd!(), "lib/tightbeam/harness/claude.ex"))
    refute function_exported?(Tightbeam.Harness.Claude, :adapter_selectable_models, 0)
    refute source =~ "@adapter_selectable_models"
    refute source =~ "claude_selectable_models"
    refute source =~ "keep_selectable"
    assert source =~ ~s(@adapter_version "0.79.0")
  end

  test "claude carries no model alias table" do
    config = Tightbeam.Harness.Claude.session_config(%{}, "guidance")

    refute Map.has_key?(config, :model_option_aliases)
    assert Tightbeam.Harness.Claude.adapter_version() == "0.79.0"
  end
end
