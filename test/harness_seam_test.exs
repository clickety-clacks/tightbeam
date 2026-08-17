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

  # Task #41 (Flynn: "hard code it and leave a note"). The claude adapter accepts a
  # NARROWER model vocabulary than the derived catalog, and every substitution for a
  # refused model is a silent downgrade — `claude-opus-5` -> `opus` delivers Opus 4.8,
  # and `claude-fable-5` has no equivalent at all. This pins the recorded table AND the
  # rule that no substitution is smuggled in later: a request the adapter refuses must
  # fail, not quietly become a different model.
  test "the recorded claude model vocabulary never substitutes a refused model" do
    selectable = Tightbeam.Harness.Claude.adapter_selectable_models()

    # Recorded live 2026-07-26 (claude CLI 2.1.220 / claude-agent-acp 0.59.0);
    # fable added 2026-08-05 after a live re-measurement on gibson (CLI 2.1.221,
    # the production grant) answered a real prompt on claude-fable-5 — the July
    # REJECTED row was one environment's snapshot, not an account property.
    assert Enum.sort(selectable) ==
             Enum.sort(~w(default sonnet opus haiku fable claude-sonnet-5 claude-opus-4-8
                          claude-haiku-4-5-20251001 claude-fable-5 claude-opus-5))

    # Values the adapter REFUSES must never appear here — listing one would make the
    # gateway offer a model the adapter cannot select. Fable left this list
    # 2026-08-05: measured answering a real prompt on gibson with the production
    # grant, so the July refusal was environmental, not categorical. Opus 5 left
    # 2026-08-06 the same way: pin-probed offered+accepted and answered a live
    # prompt on gibson with the production grant.
    for refused <- ~w(claude-opus-4-7 claude-sonnet-4-6
                      claude-opus-4-6 claude-opus-4-5-20251101 claude-sonnet-4-5-20250929
                      claude-opus-4-1-20250805) do
      refute refused in selectable,
             "#{refused} is refused by claude-agent-acp 0.66.0 and must not be listed " <>
               "as selectable; if a newer adapter accepts it, re-probe and update the " <>
               "note in claude.ex together with the version stamp"
    end

    # The note is the load-bearing half — it must carry the version it was probed at.
    source = File.read!(Path.join(File.cwd!(), "lib/tightbeam/harness/claude.ex"))
    assert source =~ "claude CLI 2.1.220"
    assert source =~ "claude-agent-acp 0.59.0"
    assert source =~ ~s(@adapter_version "0.66.0")
    assert source =~ "silent downgrade"

    # The codex half is PROBED now, and kind-scoped: the 2026-07-28 api-key
    # exercise (#99) recorded the codex adapter refusing a platform id at
    # set_config_option (-32602), so the note must carry that evidence — and it
    # must never grow back into a wholesale "cannot diverge" claim, which the
    # exercise disproved for the platform route.
    assert source =~ "kind-scoped"
    assert source =~ "-32602"
    refute source =~ "come from one artifact and cannot diverge"
    refute source =~ "divergence is structurally unlikely"
  end
end
