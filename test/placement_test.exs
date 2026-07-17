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

  test "hosts merges the reserved local host", %{base_dir: base_dir} do
    Application.put_env(:tightbeam, :hosts, %{
      "remote" => %{ssh: "worker", base_dir: "/srv/tightbeam", cli_bin: "/srv/bin"},
      "local" => %{ssh: "forbidden", base_dir: "/wrong", cli_bin: "/wrong/bin"}
    })

    hosts = Placement.hosts(base_dir)
    assert hosts["local"] == %{ssh: nil, base_dir: base_dir, cli_bin: nil}
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
    opts = Placement.adapter_opts(config, {:codex, "default", "local"})

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
    assert stamp == ["ssh", "worker", "cat", "/remote/tb/homes/default/codex/.tightbeam-manifest"]

    assert wipe == [
             "ssh",
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
             Path.join([base_dir, "staging", "worker", "homes", "default", "codex"]) <> "/",
             "worker:/remote/tb/homes/default/codex/"
           ]

    refute "--delete" in rsync
    assert Enum.take(auth, 4) == ["ssh", "worker", "sh", "-c"]
    assert List.last(auth) =~ "/remote/tb/auth/codex\"/*"
    assert List.last(auth) =~ "ln -s"

    staged_home = Path.join([base_dir, "staging", "worker", "homes", "default", "codex"])
    assert Enum.sort(File.ls!(staged_home)) == [".tightbeam-manifest", "AGENTS.md"]
    refute File.exists?(Path.join(staged_home, "auth.json"))
  end

  defp collect_commands(acc) do
    receive do
      {:command, command} -> collect_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
