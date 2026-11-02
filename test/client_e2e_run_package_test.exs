defmodule Tightbeam.ClientE2E.RunPackageTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Tightbeam.ClientE2E.{LegGateway, Provenance, RunPackage, Scorecard}

  setup do
    root = Path.join(File.cwd!(), "tmp/client-e2e-package-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    fixture = Path.join(root, "fixture")
    app = Path.join(fixture, "release/lib/tightbeam-0.1.15")
    File.mkdir_p!(Path.join(repo, "packaging"))
    File.mkdir_p!(Path.join(fixture, "bin"))
    File.mkdir_p!(Path.join(app, "ebin"))
    File.mkdir_p!(Path.join(app, "priv"))
    File.write!(Path.join(app, "ebin/tightbeam.app"), "fixture application")
    File.write!(Path.join(fixture, "package.json"), "{}")
    File.write!(Path.join(fixture, "bin/tightbeam"), "fixture CLI")
    File.write!(Path.join(fixture, "bin/tightbeam-gateway"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(fixture, "bin/tightbeam-gateway"), 0o755)
    Tightbeam.LiveBasePayload.generate!(fixture)
    script = "mkdir -p _build/npm\ncp -R '#{fixture}' _build/npm/tightbeam\n"
    File.write!(Path.join(repo, "packaging/assemble.sh"), script)
    File.write!(Path.join(repo, ".gitignore"), "/_build/\n")
    File.write!(Path.join(repo, "tracked"), "original")
    git!(repo, ["init", "-q"])
    git!(repo, ["add", "."])

    git!(repo, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "commit",
      "-qm",
      "fixture"
    ])

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, repo: repo, fixture: fixture, app: app, script: script}
  end

  test "fresh build replaces stale output and pairs every provisioned CLI", ctx do
    stale = Path.join(ctx.repo, "_build/npm/tightbeam")
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "stale"), "old")
    stamp = Provenance.stamp(ctx.repo)
    package = build(ctx.repo, stamp)
    assert package.warnings == []
    assert Provenance.stamp(ctx.repo) == stamp
    refute File.exists?(Path.join(package.path, "stale"))
    assert File.read!(package.report) =~ package.cli_sha256
    template = Path.join(ctx.root, "template")
    File.mkdir_p!(template)

    for leg <- ["one", "two"] do
      base = Path.join(ctx.root, "client-e2e-#{leg}")
      LegGateway.provision!(template, base, package.cli)
      assert File.read!(Path.join(base, "bin/tightbeam")) == File.read!(package.cli)
    end
  end

  test "build failure, missing output and missing launcher cannot reuse a stale package", ctx do
    for {script, message} <- [
          {"exit 7\n", "build failed with exit status 7"},
          {"exit 0\n", "produced no package"},
          {"mkdir -p _build/npm/tightbeam\n", "no bin/tightbeam-gateway"}
        ] do
      File.mkdir_p!(Path.join(ctx.repo, "_build/npm/tightbeam/bin"))
      File.write!(Path.join(ctx.repo, "_build/npm/tightbeam/bin/tightbeam-gateway"), "old")
      File.write!(Path.join(ctx.repo, "packaging/assemble.sh"), script)

      capture_io(fn ->
        error =
          assert_raise RuntimeError, fn ->
            RunPackage.build!(ctx.repo, Provenance.stamp(ctx.repo))
          end

        assert error.message =~ message
      end)
    end
  end

  test "manifest problems warn in run report and scorecard without changing verdict", ctx do
    manifest = Path.join(ctx.app, "build-manifest.json")
    original = File.read!(manifest)

    for problem <- [:missing, :unreadable, :malformed, :mismatched] do
      File.write!(manifest, original)

      case problem do
        :missing -> File.rm!(manifest)
        :unreadable -> File.chmod!(manifest, 0o000)
        :malformed -> File.write!(manifest, "{")
        :mismatched -> File.write!(manifest, "{}")
      end

      try do
        package = build(ctx.repo, Provenance.stamp(ctx.repo))
        assert File.regular?(Path.join(package.path, "bin/tightbeam-gateway"))
        assert [warning] = package.warnings
        assert warning =~ "manifest could not be verified"
        assert File.read!(package.report) =~ "UNVERIFIED"
        assert File.read!(package.report) =~ warning

        for status <- [:pass, :fail, :incomplete] do
          rows =
            for id <- Tightbeam.ClientE2E.Journeys.ids(),
                do: %Scorecard.Row{
                  step: id,
                  label: id,
                  journey: id,
                  status: status,
                  note: "fixture"
                }

          card = %Scorecard{
            legs: [%Scorecard.Leg{harness: "fixture", host: "fixture", rows: rows}]
          }

          warned = %{card | warnings: package.warnings}

          assert Scorecard.run_verdict(card, ["fixture"]) ==
                   Scorecard.run_verdict(warned, ["fixture"])

          assert Scorecard.to_markdown(warned, ["fixture"]) =~ warning
          assert Scorecard.to_markdown(warned, ["fixture"]) =~ "UNVERIFIED"
        end
      after
        if File.exists?(manifest), do: File.chmod!(manifest, 0o600)

        copied =
          Path.join(package_path(ctx.repo), "release/lib/tightbeam-0.1.15/build-manifest.json")

        if File.exists?(copied), do: File.chmod!(copied, 0o600)
      end
    end
  end

  test "dirty paths and post-build source changes are reported and continue", ctx do
    File.write!(Path.join(ctx.repo, "tracked"), "changed")
    File.write!(Path.join(ctx.repo, "notes.txt"), "untracked")
    stamp = Provenance.stamp(ctx.repo)
    package = build(ctx.repo, stamp)
    assert [warning] = package.warnings
    assert warning =~ "DIRTY"
    assert warning =~ "tracked"
    assert warning =~ "notes.txt"
    assert File.read!(package.report) =~ warning

    File.write!(
      Path.join(ctx.repo, "packaging/assemble.sh"),
      ctx.script <> "echo after >> tracked\n"
    )

    before = Provenance.stamp(ctx.repo)
    changed = build(ctx.repo, before)
    assert Enum.any?(changed.warnings, &String.contains?(&1, "package provenance changed"))
    assert File.read!(changed.report) =~ Provenance.to_header(before)
    assert File.read!(changed.report) =~ Provenance.to_header(Provenance.stamp(ctx.repo))
  end

  test "unavailable post-build provenance warns rather than claiming a clean stamp", ctx do
    File.write!(Path.join(ctx.repo, "packaging/assemble.sh"), ctx.script <> "rm -rf .git\n")
    package = build(ctx.repo, Provenance.stamp(ctx.repo))

    assert Enum.any?(
             package.warnings,
             &String.contains?(&1, "post-build stamp could not be taken")
           )

    assert File.read!(package.report) =~ "UNVERIFIED"
  end

  test "leg launch uses the supplied package, retains restart inputs, and has no Mix fallback",
       ctx do
    package = Path.join(ctx.root, "package with spaces")
    File.mkdir_p!(Path.join(package, "bin"))
    launcher = Path.join(package, "bin/tightbeam-gateway")

    File.write!(
      launcher,
      "#!/bin/sh\nprintf 'package-launch:%s:%s:%s:%s:%s\\n' \"$TIGHTBEAM_PORT\" \"$TIGHTBEAM_DEFAULT_HARNESS\" \"$ERL_FLAGS\" \"${RELEASE_NODE-unset}\" \"${TIGHTBEAM_NODE-unset}\"\n"
    )

    File.chmod!(launcher, 0o755)
    base = Path.join(ctx.root, "client-e2e leg")
    File.mkdir_p!(base)
    assert_raise KeyError, fn -> LegGateway.boot(base, 0) end

    assert_raise RuntimeError, ~r/no packaged gateway launcher/, fn ->
      LegGateway.boot(base, 0, package_dir: ctx.root)
    end

    assert {:error, :timeout, gateway} =
             LegGateway.boot(base, 0,
               package_dir: package,
               boot_timeout_ms: 600,
               env: [{"TIGHTBEAM_DEFAULT_HARNESS", "fixture"}]
             )

    assert File.read!(gateway.log_path) =~
             "package-launch:0:fixture:+S 4:4 +SDcpu 2 +SDio 2:unset:unset"

    assert gateway.boot_opts[:package_dir] == package
    assert gateway.boot_opts[:env] == [{"TIGHTBEAM_DEFAULT_HARNESS", "fixture"}]
    assert :ok = LegGateway.teardown(gateway)
  end

  defp package_path(repo), do: Path.join(repo, "_build/npm/tightbeam")

  defp build(repo, stamp) do
    parent = self()
    capture_io(fn -> send(parent, {:package, RunPackage.build!(repo, stamp)}) end)
    assert_receive {:package, package}
    package
  end

  defp git!(repo, args) do
    {output, status} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    assert status == 0, output
  end
end
