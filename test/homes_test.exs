defmodule Tightbeam.HomesTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Homes

  @hollow_vendor_record ~s({"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"refreshTokenExpiresAt":0,"scopes":[],"subscriptionType":"","rateLimitTier":""}})
  @healthy_vendor_record ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-fresh","refreshToken":"sk-ant-ort01-fresh","expiresAt":4102444800000,"refreshTokenExpiresAt":4102444800000,"scopes":["user:inference","user:sessions:claude_code"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}})

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-homes-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{base_dir: base_dir}
  end

  test "projects one generic home per machine and harness", %{base_dir: base_dir} do
    auth = Path.join(Homes.home_path(base_dir, "machine-a", :codex), "auth.json")
    File.mkdir_p!(Path.dirname(auth))
    File.write!(auth, ~S({"token":"machine-a"}))

    coder = Homes.project(base_dir, %{machine: "machine-a", harness: :codex, rails: "v1"})
    reviewer = Homes.project(base_dir, %{machine: "machine-a", harness: :codex, rails: "v1"})

    assert coder.home_path == Path.join([base_dir, "homes", "machine-a", "codex"])
    assert reviewer.home_path == coder.home_path
    assert File.read!(Path.join(coder.home_path, "hooks.json")) == "v1"
    assert File.lstat!(auth).type == :regular
    assert File.read!(auth) == ~S({"token":"machine-a"})
    refute File.exists?(Path.join(base_dir, "auth"))
    refute File.exists?(Path.join(coder.home_path, "AGENTS.md"))

    assert MapSet.new(File.ls!(Path.join(coder.home_path, "skills"))) ==
             MapSet.new(Homes.baseline_skill_names())

    for name <- Homes.baseline_skill_names() do
      assert File.read_link!(Path.join([coder.home_path, "skills", name])) ==
               Application.app_dir(:tightbeam, "priv/skills/#{name}")
    end
  end

  test "regeneration replaces only owned paths and preserves durable Codex state", %{
    base_dir: base_dir
  } do
    auth = Path.join(Homes.home_path(base_dir, "eezo", :codex), "auth.json")
    File.mkdir_p!(Path.dirname(auth))
    File.write!(auth, "old")

    projected = Homes.project(base_dir, %{machine: "eezo", harness: :codex, rails: "v1"})
    File.mkdir_p!(Path.join(projected.home_path, "sessions"))
    File.write!(Path.join(projected.home_path, "sessions/rollout.jsonl"), "rollout")
    File.write!(Path.join(projected.home_path, "history.jsonl"), "history")
    File.mkdir_p!(Path.join(projected.home_path, "projects/repo/memory"))
    File.write!(Path.join(projected.home_path, "projects/repo/transcript.jsonl"), "transcript")
    File.write!(Path.join(projected.home_path, "projects/repo/memory/notes.md"), "memory")
    File.write!(Path.join(projected.home_path, "config.toml"), "runtime-config")

    File.rm!(Path.join(projected.home_path, "auth.json"))
    File.write!(Path.join(projected.home_path, "auth.json"), "runtime-rotated")

    regenerated =
      Homes.project(base_dir, %{machine: "eezo", harness: :codex, rails: "v2"})

    assert File.read!(Path.join(regenerated.home_path, "sessions/rollout.jsonl")) == "rollout"
    assert File.read!(Path.join(regenerated.home_path, "history.jsonl")) == "history"

    assert File.read!(Path.join(regenerated.home_path, "projects/repo/transcript.jsonl")) ==
             "transcript"

    assert File.read!(Path.join(regenerated.home_path, "projects/repo/memory/notes.md")) ==
             "memory"

    assert File.read!(Path.join(regenerated.home_path, "config.toml")) == "runtime-config"
    assert File.read!(Path.join(regenerated.home_path, "hooks.json")) == "v2"
    assert File.read!(auth) == "runtime-rotated"
    assert File.lstat!(auth).type == :regular
    refute File.exists?(Path.join(base_dir, "auth"))
  end

  test "legacy credential store cannot overwrite the authoritative home with an unchanged manifest",
       %{
         base_dir: base_dir
       } do
    auth_dir = Path.join([base_dir, "auth", "codex"])
    auth = Path.join(auth_dir, "auth.json")
    File.mkdir_p!(auth_dir)
    File.write!(auth, "old")

    projected = Homes.project(base_dir, %{machine: "eezo", harness: :codex, rails: "v1"})
    entry = Path.join(projected.home_path, "auth.json")
    File.write!(entry, "runtime-rotated")
    File.write!(auth, "fresh-onboarding")

    Tightbeam.Harness.Codex.reconcile_home(
      %{
        base_dir: base_dir,
        host_name: "eezo",
        host_config: %{ssh: nil, base_dir: base_dir},
        sh: fn _ -> flunk("local reconciliation must not invoke a command") end
      },
      projected.home_path,
      %{
        harness: :codex,
        machine: "eezo",
        rails: "v1",
        credential_home: projected.home_path
      }
    )

    assert File.lstat!(entry).type == :regular
    assert File.read!(entry) == "runtime-rotated"
    assert File.read!(auth) == "fresh-onboarding"
  end

  test "regeneration preserves Claude projects and memory", %{base_dir: base_dir} do
    token = Path.join(Homes.home_path(base_dir, "eezo", :claude), ".credentials.json")
    File.mkdir_p!(Path.dirname(token))
    File.write!(token, "token")

    projected = Homes.project(base_dir, %{machine: "eezo", harness: :claude, rails: "v1"})
    File.mkdir_p!(Path.join(projected.home_path, "projects/repo/memory"))
    File.write!(Path.join(projected.home_path, "projects/repo/transcript.jsonl"), "chat")
    File.write!(Path.join(projected.home_path, "projects/repo/memory/notes.md"), "memory")

    Homes.project(base_dir, %{machine: "eezo", harness: :claude, rails: "v2"})

    assert File.read!(Path.join(projected.home_path, "projects/repo/transcript.jsonl")) == "chat"
    assert File.read!(Path.join(projected.home_path, "projects/repo/memory/notes.md")) == "memory"
    assert File.read!(Path.join(projected.home_path, "settings.json")) == "v2"
    assert File.read!(token) == "token"
    assert File.lstat!(token).type == :regular
    refute File.exists?(Path.join(base_dir, "auth"))
  end

  test "observed local write set is exactly the owned projection", %{base_dir: base_dir} do
    home = Homes.home_path(base_dir, "eezo", :codex)
    auth_dir = Path.join([base_dir, "auth", "codex"])
    File.mkdir_p!(Path.join(home, ".tightbeam"))
    File.mkdir_p!(Path.join(home, "skills/custom"))
    File.mkdir_p!(Path.join(home, "sessions"))
    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "auth.json"), "store-old")
    File.write!(Path.join(home, "auth.json"), "runtime-rotated")
    File.write!(Path.join(home, "hooks.json"), "old-rails")
    File.write!(Path.join(home, ".tightbeam/stale"), "old-manifest-state")
    File.write!(Path.join(home, "skills/custom/SKILL.md"), "custom")
    File.write!(Path.join(home, "sessions/turn.jsonl"), "durable")

    for name <- Homes.baseline_skill_names() do
      File.write!(Path.join([home, "skills", name]), "stale-baseline")
    end

    before = snapshot_files(home)
    Homes.project(base_dir, %{machine: "eezo", harness: :codex, rails: "new-rails"})
    after_snapshot = snapshot_files(home)

    changed =
      (Map.keys(before) ++ Map.keys(after_snapshot))
      |> MapSet.new()
      |> Enum.filter(&(before[&1] != after_snapshot[&1]))
      |> Enum.map(fn path ->
        cond do
          String.starts_with?(path, ".tightbeam/") -> ".tightbeam"
          true -> path
        end
      end)
      |> MapSet.new()

    expected =
      ["hooks.json", ".tightbeam"] ++
        Enum.map(Homes.baseline_skill_names(), &Path.join("skills", &1))

    assert changed == MapSet.new(expected)
    assert after_snapshot["auth.json"] == before["auth.json"]
    assert after_snapshot[".tightbeam/stale"] == before[".tightbeam/stale"]
    assert File.read!(Path.join(auth_dir, "auth.json")) == "store-old"
    assert after_snapshot["skills/custom/SKILL.md"] == before["skills/custom/SKILL.md"]
    assert after_snapshot["sessions/turn.jsonl"] == before["sessions/turn.jsonl"]
  end

  test "remote reconciliation replaces only owned paths without credential transport", %{
    base_dir: base_dir
  } do
    parent = self()

    desired = %{
      harness: :codex,
      machine: "worker",
      rails: "v1",
      auth_dir: "/remote/tb/auth/codex"
    }

    sh = fn command ->
      send(parent, {:command, command})

      cond do
        "cat" in command -> {"stale-manifest", 0}
        Enum.any?(command, &String.contains?(&1, "credential-harvest")) -> {"", 42}
        true -> {"", 0}
      end
    end

    Tightbeam.Harness.Codex.reconcile_home(
      %{
        base_dir: base_dir,
        host_name: "worker",
        host_config: %{ssh: "worker", base_dir: "/remote/tb"},
        sh: sh
      },
      "/remote/tb/homes/worker/codex",
      desired
    )

    commands = collect_commands([])
    assert [stamp, cleanup, rsync] = commands
    assert "cat" in stamp

    joined = Enum.map_join(commands, "\n", &Enum.join(&1, " "))
    refute joined =~ "credential-harvest"
    refute joined =~ "auth.json"
    refute joined =~ "/auth/"
    refute joined =~ "ln -s"
    staged_home = rsync |> Enum.at(-2) |> String.trim_trailing("/")
    refute File.exists?(Path.join(staged_home, "auth.json"))

    cleanup_script = List.last(cleanup)
    refute cleanup_script =~ "cp \"/remote/tb/homes/worker/codex/auth.json\""
    refute cleanup_script =~ "rm -f \"/remote/tb/homes/worker/codex/auth.json\""
    refute cleanup_script =~ "rm -rf \"/remote/tb/homes/worker/codex\""
    refute cleanup_script =~ "sessions"
    refute cleanup_script =~ "history"
    refute cleanup_script =~ "projects"
    refute cleanup_script =~ "memory"
    refute "--delete" in rsync
  end

  test "remote reconciliation leaves hollow credentials untouched and admission still refuses them",
       %{
         base_dir: base_dir
       } do
    remote = Path.join(base_dir, "remote-hollow")
    home = Path.join([remote, "homes", "worker", "claude"])
    store = Path.join([remote, "auth", "claude", ".credentials.json"])
    manifest = Path.join(home, ".tightbeam/manifest")
    entry = Path.join(home, ".credentials.json")
    good = String.replace(@healthy_vendor_record, "fresh", "standing")
    File.mkdir_p!(Path.dirname(manifest))
    File.mkdir_p!(Path.dirname(store))
    File.write!(manifest, "stale")
    File.write!(entry, @hollow_vendor_record)
    File.write!(store, good)
    parent = self()

    sh = fn command ->
      send(parent, {:command, command})
      if hd(command) == "rsync", do: {"", 0}, else: run_local_ssh(command)
    end

    assert %{home_path: ^home} =
             Tightbeam.Harness.Claude.reconcile_home(
               %{
                 base_dir: base_dir,
                 host_name: "worker",
                 host_config: %{ssh: "worker", base_dir: remote},
                 sh: sh
               },
               home,
               %{harness: :claude, machine: "worker", rails: "v1"}
             )

    assert_raise RuntimeError, ~r/accessToken is empty/, fn ->
      Tightbeam.Credentials.refuse_hollow!(:anthropic, File.read!(entry), entry)
    end

    assert File.lstat!(entry).type == :regular

    assert File.read!(store) == good
    assert File.read!(entry) == @hollow_vendor_record
    assert Path.wildcard(Path.join([remote, "staging", "credential-harvest", "*"])) == []

    commands = collect_commands([])
    joined = Enum.map_join(commands, "\n", &Enum.join(&1, " "))
    refute joined =~ "sk-ant-"
    refute joined =~ @hollow_vendor_record
  end

  test "remote reconciliation preserves a concurrent credential write without promoting stale bytes",
       %{
         base_dir: base_dir
       } do
    remote = Path.join(base_dir, "remote-race")
    home = Path.join([remote, "homes", "worker", "claude"])
    store = Path.join([remote, "auth", "claude", ".credentials.json"])
    manifest = Path.join(home, ".tightbeam/manifest")
    entry = Path.join(home, ".credentials.json")
    File.mkdir_p!(Path.dirname(manifest))
    File.mkdir_p!(Path.dirname(store))
    File.write!(manifest, "stale")
    File.write!(entry, @healthy_vendor_record)
    File.write!(store, "standing")
    parent = self()

    sh = fn command ->
      send(parent, {:command, command})

      if hd(command) == "rsync" do
        File.write!(entry, @hollow_vendor_record)
        {"", 0}
      else
        run_local_ssh(command)
      end
    end

    assert %{home_path: ^home} =
             Tightbeam.Harness.Claude.reconcile_home(
               %{
                 base_dir: base_dir,
                 host_name: "worker",
                 host_config: %{ssh: "worker", base_dir: remote},
                 sh: sh
               },
               home,
               %{
                 harness: :claude,
                 machine: "worker",
                 rails: "v1",
                 auth_dir: Path.dirname(store)
               }
             )

    assert File.read!(store) == "standing"
    assert File.lstat!(entry).type == :regular
    assert File.read!(entry) == @hollow_vendor_record
    assert Path.wildcard(Path.join([remote, "staging", "credential-harvest", "*"])) == []

    commands = collect_commands([])
    joined = Enum.map_join(commands, "\n", &Enum.join(&1, " "))
    refute joined =~ "sk-ant-"
    refute joined =~ @healthy_vendor_record
  end

  test "unchanged remote reconciliation preserves the credential when rsync fails", %{
    base_dir: base_dir
  } do
    desired = %{
      harness: :codex,
      machine: "worker",
      rails: "v1",
      auth_dir: "/remote/tb/auth/codex"
    }

    {:ok, link_state} = Agent.start_link(fn -> true end)

    sh = fn command ->
      cond do
        "cat" in command ->
          {Homes.manifest_bytes(desired), 0}

        hd(command) == "rsync" ->
          {"transient failure", 23}

        true ->
          script = List.last(command)

          if String.contains?(script, ~s(rm -f "/remote/tb/homes/worker/codex/auth.json")) do
            Agent.update(link_state, fn _ -> false end)
          end

          {"", 0}
      end
    end

    assert_raise RuntimeError, ~r/command failed/, fn ->
      Tightbeam.Harness.Codex.reconcile_home(
        %{
          base_dir: base_dir,
          host_name: "worker",
          host_config: %{ssh: "worker", base_dir: "/remote/tb"},
          sh: sh
        },
        "/remote/tb/homes/worker/codex",
        desired
      )
    end

    assert Agent.get(link_state, & &1)
  end

  defp collect_commands(acc) do
    receive do
      {:command, command} -> collect_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp run_local_ssh(command) do
    command
    |> Enum.drop(6)
    |> Enum.join(" ")
    |> then(&System.cmd("sh", ["-c", &1], stderr_to_stdout: true))
  end

  defp snapshot_files(root) do
    snapshot_path(root, root, %{})
  end

  defp snapshot_path(path, root, acc) do
    path
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce(acc, fn name, snapshot ->
      child = Path.join(path, name)
      relative = Path.relative_to(child, root)

      case File.lstat!(child).type do
        :directory -> snapshot_path(child, root, snapshot)
        :symlink -> Map.put(snapshot, relative, {:symlink, File.read_link!(child)})
        _ -> Map.put(snapshot, relative, {:file, File.read!(child)})
      end
    end)
  end
end
