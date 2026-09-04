defmodule Tightbeam.HarnessSeamTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Harness, Homes}

  test "unknown harnesses raise and the fixture follows the runtime default path" do
    assert_raise ArgumentError, ~r/unknown harness "opencode"/, fn ->
      Harness.parse!("opencode")
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

    modules = Enum.map(rows, &(&1["module"] |> String.split(".") |> Module.concat()))
    assert modules == Enum.reject(Harness.all(), &(&1 == Harness.Fixture))

    Enum.zip(rows, modules)
    |> Enum.each(fn {row, module} ->
      assert Map.delete(row, "module") == JSON.decode!(module.wire_projection())
    end)
  end

  test "fixture fetches a catalog and reconciles its home through the shared seam" do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-fixture-seam-#{System.unique_integer([:positive])}")

    auth_dir = Path.join([base_dir, "auth", "fixture"])
    home = Homes.home_path(base_dir, "testhost", :fixture)
    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "fixture.json"), "fixture-token")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "durable-session"), "unchanged")
    on_exit(fn -> File.rm_rf!(base_dir) end)

    assert {:ok,
            [
              %{family: "fixture-model", context: nil, provider: :fixture_provider},
              %{family: "fixture-tiered", context: nil, provider: :fixture_provider}
            ]} =
             Harness.Fixture.fetch_catalog(%{})

    assert %{home_path: ^home, linked_auth_files: ["fixture.json"]} =
             Homes.project(base_dir, %{
               harness: :fixture,
               machine: "testhost",
               rails: nil
             })

    assert File.read!(Path.join(home, "durable-session")) == "unchanged"

    assert File.read_link!(Path.join(home, "fixture.json")) ==
             Path.join(auth_dir, "fixture.json")
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

  test "claude offered models come from the manifest, not a compiled accessor" do
    refute function_exported?(Tightbeam.Harness.Claude, :adapter_selectable_models, 0)

    assert {:ok, provider, _health} = Tightbeam.ModelManifest.provider("claude")

    assert Enum.map(provider["models"], & &1["slug"]) ==
             ~w(claude-fable-5-1 claude-fable-5 claude-opus-5 claude-opus-4-8
                claude-sonnet-5 claude-haiku-4-5-20251001)

    source = File.read!(Path.join(File.cwd!(), "lib/tightbeam/harness/claude.ex"))
    refute source =~ "@adapter_selectable_models"
    refute source =~ "/v1/models?limit=100"
  end

  test "claude 0.73.0 aliases select Fable 5.1 at both context widths" do
    config = Tightbeam.Harness.Claude.session_config(%{}, "guidance")

    assert config.model_option_aliases["fable"] == "claude-fable-5-1"
    assert config.model_option_aliases["fable[1m]"] == "claude-fable-5-1[1m]"
    assert Tightbeam.Harness.Claude.adapter_version() == "0.73.0"
  end
end
