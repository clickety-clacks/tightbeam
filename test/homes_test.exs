defmodule Tightbeam.HomesTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Homes

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-homes-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{base_dir: base_dir}
  end

  test "projects one generic home without minting a credential", %{base_dir: base_dir} do
    projected = Homes.project(base_dir, %{harness: :codex, machine: "machine-a", rails: "{}"})

    assert projected.home_path == Path.join([base_dir, "homes", "machine-a", "codex"])
    refute Map.has_key?(projected, :linked_auth_files)
    refute File.exists?(Path.join(projected.home_path, "auth.json"))
    assert File.regular?(Path.join(projected.home_path, "hooks.json"))
  end

  test "regeneration preserves the exact regular credential and durable harness state", %{
    base_dir: base_dir
  } do
    home = Homes.home_path(base_dir, "eezo", :codex)
    credential = Path.join(home, "auth.json")
    transcript = Path.join(home, "history/transcript")
    File.mkdir_p!(Path.dirname(transcript))
    File.write!(credential, "rotated-in-home")
    File.write!(transcript, "durable")

    Homes.project(base_dir, %{harness: :codex, machine: "eezo", rails: "v1"})
    Homes.project(base_dir, %{harness: :codex, machine: "eezo", rails: "v2"})

    assert File.read!(credential) == "rotated-in-home"
    assert File.lstat!(credential).type == :regular
    assert File.read!(transcript) == "durable"
    refute File.exists?(Path.join([base_dir, "auth", "codex", "auth.json"]))
  end

  test "a stale legacy auth file is ignored and never projected", %{base_dir: base_dir} do
    legacy = Path.join([base_dir, "auth", "codex", "auth.json"])
    File.mkdir_p!(Path.dirname(legacy))
    File.write!(legacy, "stale-secret")

    projected = Homes.project(base_dir, %{harness: :codex, machine: "eezo", rails: nil})

    refute File.exists?(Path.join(projected.home_path, "auth.json"))
    assert File.read!(legacy) == "stale-secret"
  end

  test "credential readiness accepts only a regular file in the requested home", %{
    base_dir: base_dir
  } do
    home = Homes.home_path(base_dir, "eezo", :codex)
    credential = Path.join(home, "auth.json")
    outside = Path.join(base_dir, "outside-auth.json")
    target = %{host_config: %{ssh: nil}}
    File.mkdir_p!(home)

    refute Homes.credential_ready?(target, home, ["auth.json"])
    File.write!(outside, "outside")
    File.ln_s!(outside, credential)
    refute Homes.credential_ready?(target, home, ["auth.json"])
    File.rm!(credential)
    File.write!(credential, "home-owned")
    assert Homes.credential_ready?(target, home, ["auth.json"])
  end

  test "remote reconciliation never emits credential copy, harvest, or link commands", %{
    base_dir: base_dir
  } do
    owner = self()
    stale_stage = Homes.home_path(Path.join([base_dir, "staging", "worker"]), "worker", :codex)
    File.mkdir_p!(stale_stage)
    File.write!(Path.join(stale_stage, "auth.json"), "must-not-project")

    sh = fn command ->
      send(owner, {:command, command})

      if List.first(command) == "ssh" and "cat" in command,
        do: {"stale-manifest", 0},
        else: {"", 0}
    end

    target = %{
      base_dir: base_dir,
      host_name: "worker",
      host_config: %{ssh: "worker", base_dir: "/remote/tb"},
      sh: sh
    }

    Tightbeam.Harness.Codex.reconcile_home(
      target,
      "/remote/tb/homes/worker/codex",
      %{harness: :codex, machine: "worker", rails: "{}"}
    )

    commands = collect_commands([])
    rendered = inspect(commands)
    refute rendered =~ "credential-harvest"
    refute rendered =~ "auth/codex"
    refute rendered =~ "ln -s"
    refute rendered =~ "auth.json"
    refute rendered =~ "rm -rf"
    refute File.exists?(Path.join(stale_stage, "auth.json"))
  end

  test "manifest changes only with owned projection inputs", %{base_dir: base_dir} do
    spec = %{harness: :claude, machine: "eezo", rails: "v1"}
    first = Homes.project(base_dir, spec)
    before = File.read!(first.manifest_path)
    credential = Path.join(first.home_path, ".credentials.json")
    File.write!(credential, "vendor-rotated")

    second = Homes.project(base_dir, spec)

    assert File.read!(second.manifest_path) == before
    assert File.read!(credential) == "vendor-rotated"
  end

  defp collect_commands(acc) do
    receive do
      {:command, command} -> collect_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
