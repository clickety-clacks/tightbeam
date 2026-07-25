defmodule Tightbeam.ServedIdentityPlacementTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{Placement, Rails}

  setup do
    base = Path.join(System.tmp_dir!(), "tb-served-placement-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    old_hosts = Application.get_env(:tightbeam, :hosts)
    old_local = Application.get_env(:tightbeam, :local_host_name)
    old_url = Application.get_env(:tightbeam, :advertised_url)

    Application.put_env(:tightbeam, :local_host_name, "eezo")
    Application.put_env(:tightbeam, :advertised_url, "http://eezo:4321")
    Application.put_env(:tightbeam, :hosts, %{
      "worker" => %{ssh: "agent@worker", base_dir: "/srv/tightbeam", cli_bin: "/srv/bin"}
    })

    Rails.load!(base)

    on_exit(fn ->
      File.rm_rf!(base)
      :persistent_term.erase(Tightbeam.Rails)

      if old_hosts,
        do: Application.put_env(:tightbeam, :hosts, old_hosts),
        else: Application.delete_env(:tightbeam, :hosts)

      if old_local,
        do: Application.put_env(:tightbeam, :local_host_name, old_local),
        else: Application.delete_env(:tightbeam, :local_host_name)

      if old_url,
        do: Application.put_env(:tightbeam, :advertised_url, old_url),
        else: Application.delete_env(:tightbeam, :advertised_url)
    end)

    %{base: base}
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

    config = %{base_dir: ctx.base, sh: sh}
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

    config = %{base_dir: ctx.base, port: 4321, sh: sh, sh_out: sh}

    assert Placement.materialize_identity(config, session, snapshot,
             sh: sh
           ) == snapshot

    commands = collect_commands([])
    joined = Enum.map_join(commands, "\n", &Enum.join(&1, " "))
    assert joined =~ ~r{/srv/tightbeam/work/[a-f0-9]+/\.codex/skills}
    assert joined =~ "tightbeam__*"
    assert joined =~ "rsync"
    refute joined =~ "auth.json"
    refute joined =~ "oauth-token"
  end

  defp collect_commands(acc) do
    receive do
      {:command, command} -> collect_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
