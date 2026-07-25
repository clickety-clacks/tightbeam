defmodule Tightbeam.HarnessSeamTest do
  use ExUnit.Case, async: false

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

    config = Config.Reader.read!("config/runtime.exs", env: :test)
    assert get_in(config, [:tightbeam, :default_harness]) == :fixture
  end

  test "fixture fetches a catalog and reconciles its home through the shared seam" do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-fixture-seam-#{System.unique_integer([:positive])}")

    auth_dir = Path.join([base_dir, "auth", "codex"])
    home = Homes.home_path(base_dir, "testhost", :fixture)
    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "auth.json"), "fixture-token")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "durable-session"), "unchanged")
    on_exit(fn -> File.rm_rf!(base_dir) end)

    assert {:ok, [%{ref: "fixture-model", provider: :openai}]} =
             Harness.Fixture.fetch_catalog(%{})

    assert %{home_path: ^home, linked_auth_files: ["auth.json"]} =
             Homes.project(base_dir, %{
               harness: :fixture,
               machine: "testhost",
               rails: nil
             })

    assert File.read!(Path.join(home, "durable-session")) == "unchanged"
    assert File.read_link!(Path.join(home, "auth.json")) == Path.join(auth_dir, "auth.json")
  end

  test "literal scan passes, fails on a scoped reintroduction, and wire projection has two consumers" do
    scan = Path.expand("scripts/check_harness_seam.sh")
    assert {"", 0} = System.cmd(scan, [], stderr_to_stdout: true)

    probe = "lib/tightbeam/harness_literal_probe.ex"
    File.write!(probe, ~s(defmodule Tightbeam.HarnessLiteralProbe, do: @value "CODEX_HOME"\n))
    on_exit(fn -> File.rm(probe) end)

    assert {_output, 1} = System.cmd(scan, [], stderr_to_stdout: true)
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

    assert {_output, 1} = System.cmd(scan, [], stderr_to_stdout: true)
    File.rm!(probe)

    {calls, 0} =
      System.cmd("rg", [
        "-l",
        "\\.wire_projection\\(\\)",
        "lib",
        "--glob",
        "!lib/tightbeam/harness/**"
      ])

    assert calls |> String.split("\n", trim: true) |> Enum.sort() ==
             ["lib/tightbeam/boot.ex", "lib/tightbeam/wire/router.ex"]

    assert {"", 1} =
             System.cmd("rg", [
               "-n",
               "\"(wire_name|install_package|process_markers)\"",
               "lib",
               "--glob",
               "!lib/tightbeam/harness/**"
             ])
  end
end
