defmodule Tightbeam.ServedIdentityPlacementTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Placement, Rails}

  setup do
    base =
      Path.join(System.tmp_dir!(), "tb-served-placement-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    db = :"served_placement_db_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    old_local = Application.get_env(:tightbeam, :local_host_name)
    old_url = Application.get_env(:tightbeam, :advertised_url)

    Application.put_env(:tightbeam, :local_host_name, "eezo")
    Application.put_env(:tightbeam, :advertised_url, "http://eezo:4321")

    register_hosts(db, %{
      "worker" => %{ssh: "agent@worker", base_dir: "/srv/tightbeam", cli_bin: "/srv/bin"}
    })

    Rails.load!(base)

    on_exit(fn ->
      File.rm_rf!(base)
      :persistent_term.erase(Tightbeam.Rails)

      if old_local,
        do: Application.put_env(:tightbeam, :local_host_name, old_local),
        else: Application.delete_env(:tightbeam, :local_host_name)

      if old_url,
        do: Application.put_env(:tightbeam, :advertised_url, old_url),
        else: Application.delete_env(:tightbeam, :advertised_url)
    end)

    %{base: base, db: db}
  end

  test "remote home regeneration harvests before owned removal and never removes the home", ctx do
    owner = self()

    sh = fn command ->
      send(owner, {:command, command})

      case command do
        ["ssh", _opt, _batch, _opt2, _timeout, "agent@worker", "cat", _manifest] ->
          {"stale", 0}

        _ ->
          {"", 0}
      end
    end

    config = %{base_dir: ctx.base, db: ctx.db, sh: sh}
    home = Placement.deliver_home(config, {:codex, "shared", "worker"}, sh: sh)
    commands = collect_commands([])
    assert home == "/srv/tightbeam/homes/worker/codex"

    regeneration =
      Enum.find(commands, fn command ->
        Enum.any?(command, &String.contains?(&1, "runtime-rotated"))
      end) ||
        Enum.find(commands, fn command ->
          Enum.any?(command, &String.contains?(&1, "auth.json"))
        end)

    script = Enum.join(regeneration, " ")
    assert script =~ "cp"
    assert script =~ "chmod 600"
    assert script =~ "rm -f"
    assert script =~ ".tightbeam"
    refute script =~ "rm -rf \"#{home}\""
    refute Enum.any?(commands, &(Enum.join(&1, " ") =~ "rm -rf #{home}"))
  end

  test "remote regeneration preserves durable bytes and harvests a rotated credential first",
       ctx do
    remote = Path.join(ctx.base, "remote")
    home = Path.join([remote, "homes", "worker", "codex"])
    store = Path.join([remote, "auth", "codex", "auth.json"])
    File.mkdir_p!(Path.join(home, "sessions"))
    File.mkdir_p!(Path.dirname(store))
    File.mkdir_p!(Path.join(home, ".tightbeam"))
    File.write!(Path.join(home, "sessions/rollout.jsonl"), "rollout")
    File.write!(Path.join(home, "history.jsonl"), "history")
    File.write!(Path.join(home, "auth.json"), "rotated")
    File.write!(store, "stale")
    File.write!(Path.join(home, "hooks.json"), "old")
    File.write!(Path.join(home, ".tightbeam/manifest"), "stale")

    register_hosts(ctx.db, %{
      "worker" => %{ssh: "agent@worker", base_dir: remote, cli_bin: "/srv/bin"}
    })

    owner = self()

    sh = fn command ->
      send(owner, {:command, command})
      joined = Enum.join(command, " ")

      cond do
        "cat" in command ->
          {File.read!(Path.join(home, ".tightbeam/manifest")), 0}

        String.contains?(joined, "chmod 600") ->
          File.cp!(Path.join(home, "auth.json"), store)
          File.chmod!(store, 0o600)
          File.rm!(Path.join(home, "auth.json"))
          File.rm(Path.join(home, "hooks.json"))
          File.rm_rf!(Path.join(home, ".tightbeam"))
          send(owner, :harvested)
          {"", 0}

        hd(command) == "rsync" ->
          source = Enum.at(command, -2) |> String.trim_trailing("/")

          for entry <- File.ls!(source) do
            File.cp_r!(Path.join(source, entry), Path.join(home, entry))
          end

          send(owner, :projected)
          {"", 0}

        String.contains?(joined, "ln -s") ->
          File.ln_s!(store, Path.join(home, "auth.json"))
          {"", 0}

        true ->
          {"", 0}
      end
    end

    assert Placement.deliver_home(
             %{base_dir: ctx.base, db: ctx.db, sh: sh},
             {:codex, "shared", "worker"},
             sh: sh
           ) == home

    assert_receive :harvested
    assert_receive :projected
    assert File.read!(store) == "rotated"
    assert File.lstat!(Path.join(home, "auth.json")).type == :symlink
    assert File.read!(Path.join(home, "sessions/rollout.jsonl")) == "rollout"
    assert File.read!(Path.join(home, "history.jsonl")) == "history"
  end

  test "remote session projection carries only reserved skills and no credentials", ctx do
    owner = self()

    sh = fn command ->
      send(owner, {:command, command})
      {"", 0}
    end

    snapshot = %{
      revision: "abc",
      archetype: %{name: "coder"},
      guidance: "served guidance",
      skills: %{"review" => "review body"}
    }

    session = %{
      session_key: "agent:coder:app",
      host: "worker",
      harness: "codex",
      cli_token: "tbs_test"
    }

    config = %{base_dir: ctx.base, db: ctx.db, port: 4321, sh: sh, sh_out: sh}

    assert Placement.materialize_identity(config, session, snapshot, sh: sh) == snapshot

    commands = collect_commands([])
    joined = Enum.map_join(commands, "\n", &Enum.join(&1, " "))
    assert joined =~ ~r{/srv/tightbeam/work/[a-f0-9]+/\.codex/skills}
    assert joined =~ "tightbeam__*"
    assert joined =~ "rsync"
    refute joined =~ "auth.json"
    refute joined =~ "oauth-token"
  end

  test "many Claude sessions read one non-rotating local setup-token", ctx do
    token = Path.join([ctx.base, "auth", "claude", "oauth-token"])
    File.mkdir_p!(Path.dirname(token))
    File.write!(token, "sk-ant-oat01-shared")

    config = %{base_dir: ctx.base, db: ctx.db, cwd: "/work", cli_bin: "/bin"}

    for _index <- 1..20 do
      opts = Placement.adapter_opts(config, {:claude, "shared", "eezo"})
      assert {"CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-shared"} in opts[:env]
      refute Enum.any?(opts[:env], fn {name, _} -> name == "CLAUDE_CONFIG_CREDENTIALS" end)
      refute inspect(opts) =~ ".credentials.json"
      refute inspect(opts) =~ "refresh_token"
      refute inspect(opts) =~ "invalid_grant"
    end
  end

  defp collect_commands(acc) do
    receive do
      {:command, command} -> collect_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
