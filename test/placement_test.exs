defmodule Tightbeam.PlacementTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{Archetypes, Placement}

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-placement-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base_dir)
    File.write!(Path.join(base_dir, "gateway.json"), JSON.encode!(%{cliToken: "tbc_test"}))
    Archetypes.load!(base_dir)

    old_hosts = Application.get_env(:tightbeam, :hosts)
    old_url = Application.get_env(:tightbeam, :advertised_url)

    on_exit(fn ->
      File.rm_rf!(base_dir)

      if old_hosts,
        do: Application.put_env(:tightbeam, :hosts, old_hosts),
        else: Application.delete_env(:tightbeam, :hosts)

      if old_url,
        do: Application.put_env(:tightbeam, :advertised_url, old_url),
        else: Application.delete_env(:tightbeam, :advertised_url)
    end)

    %{base_dir: base_dir}
  end

  test "hosts registers the gateway machine under its real name; nothing redefines it", %{
    base_dir: base_dir
  } do
    Application.put_env(:tightbeam, :hosts, %{
      "remote" => %{ssh: "worker", base_dir: "/srv/tightbeam", cli_bin: "/srv/bin"},
      "testhost" => %{ssh: "forbidden", base_dir: "/wrong", cli_bin: "/wrong/bin"}
    })

    hosts = Placement.hosts(base_dir)
    assert Placement.local_host_name() == "testhost"
    assert hosts["testhost"] == %{ssh: nil, base_dir: base_dir, cli_bin: nil}
    refute Map.has_key?(hosts, "local")
    assert hosts["remote"].ssh == "worker"
  end

  test "resolve defaults to first allowed host and explains denials" do
    archetype = %{Archetypes.builtin_default() | where: ["work-1", "work-2"]}
    hosts = %{"work-1" => %{ssh: "e", base_dir: "/e"}}

    assert Placement.resolve(archetype, nil, hosts) == {:ok, "work-1"}
    assert Placement.resolve(archetype, "work-1", hosts) == {:ok, "work-1"}

    assert {:error, %{code: "host_not_allowed", message: message}} =
             Placement.resolve(archetype, "tars", hosts)

    assert message =~ "tars"
    assert message =~ "work-1, work-2"

    assert {:error, %{code: "unknown_host", message: unknown}} =
             Placement.resolve(archetype, "work-2", hosts)

    assert unknown =~ "work-2"
  end

  test "adapter_opts preserves the pre-placement local shape", %{base_dir: base_dir} do
    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin"}
    opts = Placement.adapter_opts(config, {:codex, "default", "testhost"})

    expected_binary = Path.expand("../tightbeam/node_modules/.bin/codex-acp", File.cwd!())
    expected_home = Path.join([base_dir, "homes", "default", "codex"])

    assert opts == [
             harness: :codex,
             cmd: [expected_binary],
             home: expected_home,
             cwd: "/work",
             stderr_path: Path.join(base_dir, "adapter-codex:default.stderr.log"),
             env: [
               {"TIGHTBEAM_HOME", base_dir},
               {"PATH", "/local/bin:" <> (System.get_env("PATH") || "")}
             ]
           ]
  end

  test "adapter_opts injects the org's claude token env when the store holds one", %{
    base_dir: base_dir
  } do
    token_dir = Path.join([base_dir, "auth", "claude"])
    File.mkdir_p!(token_dir)
    File.write!(Path.join(token_dir, "oauth-token"), "sk-ant-oat01-test\n")

    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin"}

    claude_env = Placement.adapter_opts(config, {:claude, "default", "testhost"})[:env]
    assert {"CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-test"} in claude_env

    # The token is harness-scoped: codex adapters never receive claude's.
    codex_env = Placement.adapter_opts(config, {:codex, "default", "testhost"})[:env]
    refute Enum.any?(codex_env, fn {k, _} -> k == "CLAUDE_CODE_OAUTH_TOKEN" end)
  end

  test "adapter_opts embeds every remote agent env in the ssh command", %{base_dir: base_dir} do
    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:4000")

    Application.put_env(:tightbeam, :hosts, %{
      "worker" => %{
        ssh: "codex@worker",
        base_dir: "/srv/tb",
        cli_bin: "/srv/tb/bin",
        adapter_bin_dir: "/opt/acp"
      }
    })

    sh = fn _command -> {"", 0} end
    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin", sh: sh}
    opts = Placement.adapter_opts(config, {:codex, "default", "worker"})
    remote_home = "/srv/tb/homes/default/codex"

    assert opts[:cmd] == [
             "ssh",
             "-o",
             "BatchMode=yes",
             "-o",
             "ConnectTimeout=5",
             "codex@worker",
             "exec",
             "env",
             "CODEX_HOME=#{remote_home}",
             "TIGHTBEAM_HOME=/srv/tb",
             "TIGHTBEAM_URL=http://gateway.example:4000",
             "TIGHTBEAM_TOKEN=tbc_test",
             "PATH=/srv/tb/bin:$PATH",
             "/opt/acp/codex-acp"
           ]

    assert opts[:home] == remote_home
    assert opts[:env] == []
  end

  test "deliver_home stages without auth and performs the remote flow in order", %{
    base_dir: base_dir
  } do
    Application.put_env(:tightbeam, :hosts, %{
      "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: "/remote/tb/bin"}
    })

    auth_dir = Path.join([base_dir, "auth", "codex"])
    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "auth.json"), "secret")
    parent = self()

    sh = fn command ->
      send(parent, {:command, command})
      if "cat" in command, do: {"", 1}, else: {"", 0}
    end

    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin"}

    assert Placement.deliver_home(config, {:codex, "default", "worker"}, sh: sh) ==
             "/remote/tb/homes/default/codex"

    commands = collect_commands([])
    assert [stamp, wipe, rsync, auth] = commands
    assert stamp == ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "worker", "cat", "/remote/tb/homes/default/codex/.tightbeam-manifest"]

    assert wipe == [
             "ssh",
             "-o",
             "BatchMode=yes",
             "-o",
             "ConnectTimeout=5",
             "worker",
             "rm",
             "-rf",
             "/remote/tb/homes/default/codex",
             "&&",
             "mkdir",
             "-p",
             "/remote/tb/homes/default/codex"
           ]

    assert rsync == [
             "rsync",
             "-a",
             "-e",
             "ssh -o BatchMode=yes -o ConnectTimeout=5",
             Path.join([base_dir, "staging", "worker", "homes", "default", "codex"]) <> "/",
             "worker:/remote/tb/homes/default/codex/"
           ]

    refute "--delete" in rsync
    assert Enum.take(auth, 8) == ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "worker", "sh", "-c"]
    assert List.last(auth) =~ "/remote/tb/auth/codex\"/*"
    assert List.last(auth) =~ "ln -s"

    staged_home = Path.join([base_dir, "staging", "worker", "homes", "default", "codex"])
    assert Enum.sort(File.ls!(staged_home)) == [".tightbeam-manifest", "AGENTS.md", "skills"]

    assert staged_home
           |> Path.join("skills/tightbeam-assimilate/SKILL.md")
           |> File.read!() =~ "name: tightbeam-assimilate"
    refute File.exists?(Path.join(staged_home, "auth.json"))
  end

  defp collect_commands(acc) do
    receive do
      {:command, command} -> collect_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "hosts.json registry merges under env config and register_host records", %{} do
    base = Path.join(System.tmp_dir!(), "tb-reg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    assert {:ok, entry} =
             Placement.register_host(base, "work-1", %{ssh: "work-1.example", base_dir: "/home/u/.tightbeam"})

    assert entry.ssh == "work-1.example"

    hosts = Placement.hosts(base)
    assert hosts["work-1"].base_dir == "/home/u/.tightbeam"
    assert hosts["testhost"].ssh == nil

    # env config overrides the registry entry-for-entry
    Application.put_env(:tightbeam, :hosts, %{"work-1" => %{ssh: "override", base_dir: "/o", cli_bin: nil}})
    on_exit(fn -> Application.delete_env(:tightbeam, :hosts) end)
    assert Placement.hosts(base)["work-1"].ssh == "override"

    # re-register updates in place
    assert {:ok, _} = Placement.register_host(base, "work-1", %{ssh: "w2", base_dir: "/z"})
    Application.delete_env(:tightbeam, :hosts)
    assert Placement.hosts(base)["work-1"].ssh == "w2"
  end

  test "where [\"*\"] grants any configured host; empty stays an error upstream" do
    anywhere = %{name: "roamer", where: ["*"], defaults: %{}, references: [], guidance: nil}
    hosts = %{"testhost" => %{ssh: nil, base_dir: "/b", cli_bin: nil}, "work-1" => %{ssh: "w", base_dir: "/b", cli_bin: nil}}

    assert {:ok, "testhost"} = Placement.resolve(anywhere, nil, hosts)
    assert {:ok, "work-1"} = Placement.resolve(anywhere, "work-1", hosts)
    assert {:error, %{code: "unknown_host"}} = Placement.resolve(anywhere, "nope", hosts)
  end
end
