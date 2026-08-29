defmodule Tightbeam.PlacementTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Archetypes,
    Credentials,
    DB,
    HarnessHealth,
    Homes,
    Identity,
    Org,
    Placement,
    Rails
  }

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-placement-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base_dir)
    File.write!(Path.join(base_dir, "gateway.json"), JSON.encode!(%{cliToken: "tbc_test"}))
    db = :"placement_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    Archetypes.load!(base_dir)
    Rails.load!(base_dir)

    old_url = Application.get_env(:tightbeam, :advertised_url)

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Tightbeam.Rails)

      if old_url,
        do: Application.put_env(:tightbeam, :advertised_url, old_url),
        else: Application.delete_env(:tightbeam, :advertised_url)
    end)

    %{base_dir: base_dir, db: db}
  end

  test "harness binary probe resolves versions and classifies missing and failed executables", %{
    base_dir: base_dir
  } do
    cli_bin = Path.join(base_dir, "bin")
    shim = Path.join(cli_bin, "codex")
    File.mkdir_p!(cli_bin)
    File.write!(shim, "#!/bin/sh\n")

    parent = self()

    assert {:ok, %{bin: ^shim, version: "codex-cli 1.2.3"}} =
             Placement.harness_binary_probe(:codex, cli_bin,
               find_executable: fn _ -> flunk("projected codex shim was not preferred") end,
               run: fn command ->
                 send(parent, {:probe_command, command})
                 {"codex-cli 1.2.3\n", 0}
               end
             )

    assert_receive {:probe_command, [^shim, "--version"]}

    assert {:error, :not_found} =
             Placement.harness_binary_probe(:claude, cli_bin,
               find_executable: fn "claude" -> nil end,
               run: fn _ -> flunk("missing executable must not run") end
             )

    assert {:error, {:exec_failed, detail}} =
             Placement.harness_binary_probe(:claude, cli_bin,
               find_executable: fn "claude" -> "/fake/claude" end,
               run: fn ["/fake/claude", "--version"] -> {"broken install\n", 9} end
             )

    assert detail =~ "exit=9"
    assert detail =~ "broken install"

    assert {:error, {:exec_failed, "timed out after 10ms"}} =
             Placement.harness_binary_probe(:claude, cli_bin,
               find_executable: fn "claude" -> "/fake/claude" end,
               run: fn _ -> Process.sleep(100) end,
               timeout: 10
             )
  end

  test "hosts registers the gateway machine under its real name; nothing redefines it", %{
    base_dir: base_dir,
    db: db
  } do
    register_hosts(db, %{
      "remote" => %{ssh: "worker", base_dir: "/srv/tightbeam", cli_bin: "/srv/bin"},
      "testhost" => %{ssh: "forbidden", base_dir: "/wrong", cli_bin: "/wrong/bin"}
    })

    hosts = Placement.hosts(base_dir, db)
    assert Placement.local_host_name() == "testhost"
    assert hosts["testhost"] == %{ssh: nil, base_dir: base_dir, cli_bin: nil}
    refute Map.has_key?(hosts, "local")
    assert hosts["remote"].ssh == "worker"
  end

  test "harness env overlay schema is exact and a fresh store has zero rows", %{db: db} do
    assert {:ok,
            [
              [0, "host", "TEXT", 1, nil, 1],
              [1, "harness", "TEXT", 1, nil, 2],
              [2, "name", "TEXT", 1, nil, 3],
              [3, "value", "TEXT", 1, nil, 0],
              [4, "setBy", "TEXT", 1, nil, 0],
              [5, "setAt", "INTEGER", 1, nil, 0]
            ]} = DB.query(db, "PRAGMA table_info(harness_env_overlays)")

    assert Placement.env_overlays(db) == []
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

  test "adapter context refuses an unreadable credential kind with its cause", %{
    base_dir: base_dir,
    db: db
  } do
    host = "unreadable-#{System.unique_integer([:positive])}"
    store = Path.join(base_dir, "auth/claude")
    target = Path.join(base_dir, "credential-target")
    File.mkdir_p!(target)
    File.mkdir_p!(Path.dirname(store))
    File.ln_s!(target, store)

    server = Credentials.server(host)

    start_supervised!(%{
      id: server,
      start: {Credentials, :start_link, [[name: server, base_dir: base_dir, machine: host]]}
    })

    reason =
      {:credential_store_unreadable, %{path: store, found: :symlink, expected: :directory}}

    config = %{base_dir: base_dir, db: db}

    error =
      assert_raise Placement.Refusal, fn ->
        Placement.adapter_context(config, {:claude, "shared", host})
      end

    assert error.code == "credential_store_unreadable"
    assert error.host == host
    assert error.harness == "claude"
    assert error.message =~ inspect(reason)
  end

  test "workdir_path names a disappeared host instead of falling back to the gateway", %{
    base_dir: base_dir,
    db: db
  } do
    register_hosts(db, %{
      "eurisko" => %{ssh: "eurisko", base_dir: "/srv/tightbeam", cli_bin: nil}
    })

    session = %{
      session_key: "remote-session",
      host: "eurisko",
      harness: "claude",
      cli_token: "secret"
    }

    remote_workdir = Placement.workdir_path(%{base_dir: base_dir, db: db}, session)
    assert String.starts_with?(remote_workdir, "/srv/tightbeam/work/")

    :ok = DB.execute(db, "DELETE FROM hosts WHERE name='eurisko'")

    {error, stacktrace} =
      try do
        Placement.workdir_path(%{base_dir: base_dir, db: db}, session)
        flunk("workdir_path accepted a disappeared host")
      rescue
        error in Placement.Refusal -> {error, __STACKTRACE__}
      end

    assert error.code == "unknown_host"
    assert error.host == "eurisko"
    assert error.harness == "claude"
    assert error.message =~ "host eurisko is not configured for claude"
    assert error.message =~ "tightbeam assimilate <ssh-dest> --name eurisko"
    assert {Placement, :workdir_path, 2, _location} = Enum.at(stacktrace, 1)
    refute File.exists?(Path.join(base_dir, "work"))
  end

  test "holder_workdir independently names a disappeared host instead of falling back", %{
    base_dir: base_dir,
    db: db
  } do
    register_hosts(db, %{
      "eurisko" => %{ssh: "eurisko", base_dir: "/srv/tightbeam", cli_bin: nil}
    })

    session = %{
      session_key: "remote-holder",
      host: "eurisko",
      harness: "codex",
      cli_token: "secret"
    }

    :ok = DB.execute(db, "DELETE FROM hosts WHERE name='eurisko'")

    {error, stacktrace} =
      try do
        Placement.holder_workdir(%{base_dir: base_dir, db: db, port: 4000}, session)
        flunk("holder_workdir accepted a disappeared host")
      rescue
        error in Placement.Refusal -> {error, __STACKTRACE__}
      end

    assert error.code == "unknown_host"
    assert error.host == "eurisko"
    assert error.harness == "codex"
    assert error.message =~ "host eurisko is not configured for codex"
    assert error.message =~ "tightbeam assimilate <ssh-dest> --name eurisko"
    assert {Placement, :holder_workdir, 2, _location} = Enum.at(stacktrace, 1)
    refute File.exists?(Path.join(base_dir, "work"))
  end

  test "materialize_identity names a disappeared session host", %{
    base_dir: base_dir,
    db: db
  } do
    session = %{
      session_key: "vanished-materialization",
      host: "eurisko",
      harness: "codex",
      cli_token: "secret"
    }

    expected =
      "host eurisko is not configured for codex; run tightbeam assimilate <ssh-dest> " <>
        "--name eurisko --as-user <adminUserId>"

    error =
      assert_raise Placement.Refusal, fn ->
        Placement.materialize_identity(
          %{base_dir: base_dir, db: db},
          session,
          %{revision: "abc", skills: %{}}
        )
      end

    assert error.code == "unknown_host"
    assert error.message == expected
  end

  test "effort_observation names a disappeared session host", %{
    base_dir: base_dir,
    db: db
  } do
    session = %{session_key: "vanished-effort", host: "eurisko", harness: "claude"}

    expected =
      "host eurisko is not configured for claude; run tightbeam assimilate <ssh-dest> " <>
        "--name eurisko --as-user <adminUserId>"

    error =
      assert_raise Placement.Refusal, fn ->
        Placement.effort_observation(%{base_dir: base_dir, db: db}, session, "/work")
      end

    assert error.code == "unknown_host"
    assert error.message == expected
  end

  test "move_workdir copies local to local", %{base_dir: base_dir, db: db} do
    old_base = Path.join(base_dir, "old-local")
    new_base = Path.join(base_dir, "new-local")

    register_hosts(db, %{
      "old-local" => %{ssh: nil, base_dir: old_base, cli_bin: nil},
      "new-local" => %{ssh: nil, base_dir: new_base, cli_bin: nil}
    })

    source = test_workdir(old_base, "session-1")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "memory.md"), "remember")
    File.write!(Path.join(source, ".tightbeam-session"), "secret")

    assert :ok =
             Placement.move_workdir(
               %{base_dir: base_dir, db: db},
               "session-1",
               "old-local",
               "new-local"
             )

    assert File.read!(Path.join(test_workdir(new_base, "session-1"), "memory.md")) == "remember"
    refute File.exists?(Path.join(source, ".tightbeam-session"))

    assert File.read!(Path.join(test_workdir(new_base, "session-1"), ".tightbeam-session")) ==
             "secret"
  end

  test "ensure_workdir converges local content, mode, and git exclude", %{base_dir: base_dir} do
    path = Path.join(base_dir, "local-work")
    content = JSON.encode!(%{url: "http://127.0.0.1:4321", token: "tbs_secret", sessionKey: "s1"})

    assert :ok = Placement.ensure_workdir(%{ssh: nil, base_dir: base_dir}, path, content, [])
    file = Path.join(path, ".tightbeam-session")
    assert File.read!(file) == content
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    refute File.exists?(Path.join(path, ".git"))

    File.mkdir_p!(Path.join([path, ".git", "info"]))
    exclude = Path.join([path, ".git", "info", "exclude"])
    File.write!(exclude, "*.beam")
    assert :ok = Placement.ensure_workdir(%{ssh: nil, base_dir: base_dir}, path, content, [])
    assert File.read!(exclude) == "*.beam\n.tightbeam-session\n"

    assert :ok = Placement.ensure_workdir(%{ssh: nil, base_dir: base_dir}, path, content, [])
    assert length(Regex.scan(~r/^\.tightbeam-session$/m, File.read!(exclude))) == 1

    File.write!(file, "tampered")
    assert :ok = Placement.ensure_workdir(%{ssh: nil, base_dir: base_dir}, path, content, [])
    assert File.read!(file) == content

    File.chmod!(file, 0o644)
    assert :ok = Placement.ensure_workdir(%{ssh: nil, base_dir: base_dir}, path, content, [])
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
  end

  test "ensure_workdir remote compare uses stdout-only pinned probe and stages on mismatch", %{
    base_dir: base_dir
  } do
    path = "/remote/tb/work/digest"
    content = ~s({"url":"https://gateway","token":"tbs_secret","sessionKey":"s1"})
    parent = self()

    sh_out = fn command ->
      send(parent, {:sh_out, command})
      {"", 0}
    end

    sh = fn command ->
      stage_file = Enum.at(command, -2)

      send(
        parent,
        {:stage, File.read!(stage_file), Bitwise.band(File.stat!(stage_file).mode, 0o777)}
      )

      send(parent, {:sh, command})
      {"", 0}
    end

    assert :ok =
             Placement.ensure_workdir(
               %{ssh: "worker", base_dir: "/remote/tb"},
               path,
               content,
               base_dir: base_dir,
               sh: sh,
               sh_out: sh_out
             )

    assert_receive {:sh_out, compare}
    command = List.last(compare)
    assert command =~ "mkdir -p #{path} &&"
    assert command =~ "find #{path}/.tightbeam-session -maxdepth 0 -perm 600 -print"
    assert command =~ "| grep -q . && cat #{path}/.tightbeam-session"
    assert command =~ ~s(printf "\\n%s\\n" .tightbeam-session)
    assert_receive {:stage, ^content, 0o600}
    assert_receive {:sh, rsync}
    assert List.last(rsync) == "worker:#{path}/"
    refute Enum.any?(compare ++ rsync, &String.contains?(&1, "tbs_secret"))
    refute File.exists?(Path.join([base_dir, "staging", "session-files", "digest"]))

    converged_out = fn command ->
      send(parent, {:converged, command})
      {content, 0}
    end

    assert :ok =
             Placement.ensure_workdir(
               %{ssh: "worker", base_dir: "/remote/tb"},
               path,
               content,
               base_dir: base_dir,
               sh: fn command -> flunk("unexpected command: #{inspect(command)}") end,
               sh_out: converged_out
             )

    assert_receive {:converged, _}
  end

  test "ensure_workdir remote failures raise and always remove staging", %{base_dir: base_dir} do
    path = "/remote/tb/work/failure"

    assert_raise RuntimeError, ~r/remote workdir ensure failed/, fn ->
      Placement.ensure_workdir(
        %{ssh: "worker", base_dir: "/remote/tb"},
        path,
        "tbs_content",
        base_dir: base_dir,
        sh_out: fn _ -> {"", 255} end
      )
    end

    assert_raise RuntimeError, ~r/command failed/, fn ->
      Placement.ensure_workdir(
        %{ssh: "worker", base_dir: "/remote/tb"},
        path,
        "tbs_content",
        base_dir: base_dir,
        sh_out: fn _ -> {"", 0} end,
        sh: fn _ -> {"", 1} end
      )
    end

    refute File.exists?(Path.join([base_dir, "staging", "session-files", "failure"]))
  end

  test "provision_endpoint writes only to satellites and always cleans its staging", %{
    base_dir: base_dir
  } do
    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:11373")
    parent = self()

    sh = fn command ->
      send(parent, {:sh, command})
      {"", 0}
    end

    # The gateway's own machine is not a satellite: hosts/1 shadows its registry
    # entry with the synthetic local one, and its gateway.json is boot-owned.
    assert :ok =
             Placement.provision_endpoint(
               base_dir,
               Placement.local_host_name(),
               %{ssh: "clu@#{Placement.local_host_name()}", base_dir: "/remote/tb"},
               sh: fn command -> flunk("unexpected command: #{inspect(command)}") end
             )

    assert :ok =
             Placement.provision_endpoint(base_dir, "gateway-host", %{
               ssh: nil,
               base_dir: base_dir
             })

    assert :ok =
             Placement.provision_endpoint(
               base_dir,
               "worker",
               %{ssh: "clu@worker", base_dir: "~/.tightbeam"},
               sh: sh
             )

    assert_receive {:sh, mkdir}
    assert mkdir == ["ssh"] ++ ssh_opts() ++ ["clu@worker", "mkdir", "-p", "~/.tightbeam"]
    assert_receive {:sh, rsync}
    assert List.last(rsync) == "clu@worker:~/.tightbeam/"
    refute File.exists?(Path.join([base_dir, "staging", "gateway-files", "worker"]))

    assert_raise RuntimeError, ~r/command failed/, fn ->
      Placement.provision_endpoint(
        base_dir,
        "worker",
        %{ssh: "clu@worker", base_dir: "/remote/tb"},
        sh: fn _ -> {"", 255} end
      )
    end

    refute File.exists?(Path.join([base_dir, "staging", "gateway-files", "worker"]))
  end

  defp ssh_opts, do: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]

  test "move_workdir fails on a real local token removal error", %{base_dir: base_dir, db: db} do
    old_base = Path.join(base_dir, "old-remove-error")
    new_base = Path.join(base_dir, "new-remove-error")

    register_hosts(db, %{
      "old-remove-error" => %{ssh: nil, base_dir: old_base, cli_bin: nil},
      "new-remove-error" => %{ssh: nil, base_dir: new_base, cli_bin: nil}
    })

    source = test_workdir(old_base, "remove-error")
    File.mkdir_p!(Path.join(source, ".tightbeam-session"))

    assert {:error, message} =
             Placement.move_workdir(
               %{base_dir: base_dir, db: db},
               "remove-error",
               "old-remove-error",
               "new-remove-error"
             )

    assert message =~ "source session token removal failed"
  end

  test "move_workdir rsyncs local to remote", %{base_dir: base_dir, db: db} do
    old_base = Path.join(base_dir, "old-local")

    register_hosts(db, %{
      "old-local" => %{ssh: nil, base_dir: old_base, cli_bin: nil},
      "remote" => %{ssh: "remote", base_dir: "/remote/tb", cli_bin: nil}
    })

    source = test_workdir(old_base, "session-2")
    destination = test_workdir("/remote/tb", "session-2")
    File.mkdir_p!(source)
    parent = self()

    sh = fn command ->
      send(parent, {:command, command})
      {"", 0}
    end

    assert :ok =
             Placement.move_workdir(
               %{base_dir: base_dir, db: db, sh: sh},
               "session-2",
               "old-local",
               "remote"
             )

    assert [mkdir, rsync] = collect_commands([])

    assert mkdir == [
             "ssh",
             "-o",
             "BatchMode=yes",
             "-o",
             "ConnectTimeout=5",
             "remote",
             "mkdir",
             "-p",
             destination
           ]

    assert rsync == [
             "rsync",
             "-a",
             "-e",
             "ssh -o BatchMode=yes -o ConnectTimeout=5",
             source <> "/",
             "remote:#{destination}/"
           ]
  end

  test "move_workdir rsyncs remote to local", %{base_dir: base_dir, db: db} do
    new_base = Path.join(base_dir, "new-local")

    register_hosts(db, %{
      "remote" => %{ssh: "remote", base_dir: "/remote/tb", cli_bin: nil},
      "new-local" => %{ssh: nil, base_dir: new_base, cli_bin: nil}
    })

    source = test_workdir("/remote/tb", "session-3")
    destination = test_workdir(new_base, "session-3")
    parent = self()

    sh = fn command ->
      send(parent, {:command, command})
      {"", 0}
    end

    assert :ok =
             Placement.move_workdir(
               %{base_dir: base_dir, db: db, sh: sh},
               "session-3",
               "remote",
               "new-local"
             )

    assert [probe, rsync, cleanup] = collect_commands([])

    assert probe == [
             "ssh",
             "-o",
             "BatchMode=yes",
             "-o",
             "ConnectTimeout=5",
             "remote",
             "test",
             "-d",
             source
           ]

    assert rsync == [
             "rsync",
             "-a",
             "-e",
             "ssh -o BatchMode=yes -o ConnectTimeout=5",
             "remote:#{source}/",
             destination <> "/"
           ]

    assert cleanup == [
             "ssh",
             "-o",
             "BatchMode=yes",
             "-o",
             "ConnectTimeout=5",
             "remote",
             "rm",
             "-f",
             Path.join(source, ".tightbeam-session")
           ]
  end

  test "move_workdir stages remote to remote through the gateway", %{base_dir: base_dir, db: db} do
    register_hosts(db, %{
      "old-remote" => %{ssh: "old-remote", base_dir: "/old/tb", cli_bin: nil},
      "new-remote" => %{ssh: "new-remote", base_dir: "/new/tb", cli_bin: nil}
    })

    source = test_workdir("/old/tb", "session-4")
    destination = test_workdir("/new/tb", "session-4")
    stage = Path.join([base_dir, "staging", "workdir-moves", Path.basename(source)])
    parent = self()

    sh = fn command ->
      send(parent, {:command, command})
      {"", 0}
    end

    assert :ok =
             Placement.move_workdir(
               %{base_dir: base_dir, db: db, sh: sh},
               "session-4",
               "old-remote",
               "new-remote"
             )

    assert [probe, pull, mkdir, push, cleanup] = collect_commands([])

    assert probe == [
             "ssh",
             "-o",
             "BatchMode=yes",
             "-o",
             "ConnectTimeout=5",
             "old-remote",
             "test",
             "-d",
             source
           ]

    assert Enum.at(pull, -2) == "old-remote:#{source}/"
    assert List.last(pull) == stage <> "/"

    assert mkdir == [
             "ssh",
             "-o",
             "BatchMode=yes",
             "-o",
             "ConnectTimeout=5",
             "new-remote",
             "mkdir",
             "-p",
             destination
           ]

    assert Enum.at(push, -2) == stage <> "/"
    assert List.last(push) == "new-remote:#{destination}/"
    assert List.last(cleanup) == Path.join(source, ".tightbeam-session")
    assert Enum.at(cleanup, -3) == "rm"
    assert Enum.at(cleanup, -2) == "-f"
    refute File.exists?(stage)
  end

  # #46: the local adapter must resolve under the host's OWN base_dir for EVERY
  # harness. This existed only for codex, so restoring claude's sibling-checkout
  # path passed the whole suite — the exact regression the ticket is about.
  test "every harness resolves its local adapter under base_dir, never a sibling checkout",
       %{base_dir: base_dir, db: db} do
    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: Path.join(base_dir, "bin"),
      cursor_execution_home: Path.join(base_dir, "cursor-execution-test-home"),
      credential_kind: :api_key,
      harness_target_overrides: %{
        find_executable: fn _ -> Path.join([base_dir, "2026.08.11-e8db854", "cursor-agent"]) end,
        realpath: fn path -> {:ok, path} end,
        sha256: fn path ->
          if Path.basename(path) == "index.js",
            do: "6aceb24b7c7ecddb1993946ebb18a7dd4d025842e6efda955eb0c13255b1e5f0",
            else: "eed61c5224668c9236334c4c68936a16aecc37374b592f59e31eb50433817831"
        end,
        verify_adapter_shim: fn _shim, _launcher -> :ok end
      }
    }

    cursor_auth = Path.join([base_dir, "auth", "cursor"])
    File.mkdir_p!(cursor_auth)
    File.write!(Path.join(cursor_auth, "api-key"), "fixture-cursor-key\n")

    for module <- Tightbeam.Harness.all() do
      opts = Placement.adapter_opts!(config, {module.id(), "shared", "testhost"})
      binary = hd(opts[:cmd])

      if module.id() == :cursor do
        assert opts[:cmd] == [binary, "acp"]
        assert Path.basename(Path.dirname(binary)) == "2026.08.11-e8db854"
      else
        assert String.ends_with?(
                 binary,
                 Path.join(["adapters", "node_modules", ".bin", Path.basename(binary)])
               ),
               "#{module.wire_name()} local adapter is not under <base_dir>/adapters: #{binary}"
      end

      # The base_dir's unique final segment, rather than a prefix compare: macOS
      # resolves /var through /private and the two sides disagree on which form.
      assert String.contains?(binary, Path.basename(base_dir)),
             "#{module.wire_name()} local adapter is not inside this org's base_dir: #{binary}"

      refute binary =~ "src/tightbeam/node_modules",
             "#{module.wire_name()} still resolves to the retired sibling checkout: #{binary}"
    end
  end

  test "Cursor kind refusal precedes toolchain and home side effects", %{
    base_dir: base_dir,
    db: db
  } do
    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: Path.join(base_dir, "bin"),
      credential_kind: :arbitrary_invalid,
      sh: fn _ -> flunk("credential refusal executed a target command") end,
      harness_target_overrides: %{
        find_executable: fn _ -> flunk("credential refusal resolved an executable") end
      }
    }

    assert {:error, %{code: "DIV-CURSOR-API-KEY-ONLY"}} =
             Placement.adapter_opts(config, {:cursor, "shared", "testhost"})

    refute File.exists?(Tightbeam.Homes.home_path(base_dir, "testhost", :cursor))
  end

  test "remote Cursor adapter_opts refuses local-only before credential kind read", %{
    base_dir: base_dir,
    db: db
  } do
    parent = self()

    register_hosts(db, %{
      "worker" => %{ssh: "cursor@worker", base_dir: "/srv/tb", cli_bin: "/srv/tb/bin"}
    })

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: Path.join(base_dir, "bin"),
      sh: fn _ -> flunk("remote cursor adapter_opts ran target command") end,
      credential_kind: fn provider, _host ->
        send(parent, {:credential_kind_read, provider})
        :api_key
      end
    }

    assert {:error, %{code: "DIV-CURSOR-LOCAL-ONLY"}} =
             Placement.adapter_opts(config, {:cursor, "shared", "worker"})

    refute_receive {:credential_kind_read, _}
  end

  test "adapter_opts preserves the pre-placement local shape", %{base_dir: base_dir, db: db} do
    parent = self()

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable"),
      sh: fn command ->
        send(parent, {:unexpected_sh, command})
        {"", 0}
      end
    }

    opts = Placement.adapter_opts!(config, {:codex, "default", "testhost"})

    # The adapter lives under the host's OWN base_dir, not a sibling checkout (#46).
    expected_binary =
      Path.join([base_dir, "adapters", "node_modules", ".bin", "codex-acp"])

    expected_home = Path.join([base_dir, "homes", "testhost", "codex"])

    assert opts[:harness] == :codex
    assert opts[:cmd] == [expected_binary]
    assert opts[:home] == expected_home
    assert opts[:cwd] == "/work"
    assert is_function(opts[:on_auth_event], 2)
    assert {"TIGHTBEAM_LINEAGE", "tb1-Y29kZXhAdGVzdGhvc3Q"} in opts[:env]

    # No law: no wiring-check probe. The trust seed is present regardless, because
    # the reserved observation entry is projected regardless.
    refute Keyword.has_key?(opts, :probe_cwd)
    refute Keyword.has_key?(opts, :probe_model)
    assert {"CODEX_CONFIG", ~s({"bypass_hook_trust":true})} in opts[:env]
    refute Enum.any?(opts[:env], fn {key, _value} -> key == "CODEX_PATH" end)
    refute_receive {:unexpected_sh, _}
  end

  test "a terminal provider callback opens one authoritative auth incident", %{
    base_dir: base_dir,
    db: db
  } do
    unless Process.whereis(Tightbeam.TurnTaskSupervisor) do
      start_supervised!({Task.Supervisor, name: Tightbeam.TurnTaskSupervisor})
    end

    Org.create(db, %{
      session_key: Org.personal_session_key("flynn"),
      display_name: "Main",
      kind: "main",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "operator-host",
      harness: "codex",
      provider: "openai",
      model: Model.new("gpt-5")
    })

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      sh: fn _command -> {"", 0} end
    }

    handler = Placement.adapter_opts!(config, {:codex, "default", "testhost"})[:on_auth_event]
    handler.(:transient, %{"authMode" => "chatgpt"})
    refute eventually(fn -> HarnessHealth.active(db) != [] end, 4)

    handler.(:terminal, %{"authMode" => nil, "planType" => nil})

    assert eventually(fn ->
             match?(
               [%{failureClass: "auth-dead", harness: "codex", host: "testhost"}],
               HarnessHealth.active(db)
             )
           end)

    assert Enum.any?(
             Tightbeam.EventLog.lifecycle_events(db),
             &(&1.kind == "harness_health_auth_blocker")
           )
  end

  test "adapter_opts appends a local overlay and absent rows leave env unchanged", %{
    base_dir: base_dir,
    db: db
  } do
    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable")
    }

    baseline = Placement.adapter_opts!(config, {:claude, "default", "testhost"})[:env]
    refute {"EXAMPLE_OVERLAY_VAR", "example-local"} in baseline

    assert {:ok, _row} =
             Placement.set_env_overlay(
               db,
               "testhost",
               "claude",
               "EXAMPLE_OVERLAY_VAR",
               "example-local",
               "agent:test"
             )

    assert Placement.adapter_opts!(config, {:claude, "default", "testhost"})[:env] ==
             baseline ++ [{"EXAMPLE_OVERLAY_VAR", "example-local"}]
  end

  test "host toolchain rows construct local PATH in order and clearing them restores bytes", %{
    base_dir: base_dir,
    db: db
  } do
    first = Path.join(base_dir, "toolchain-one")
    second = Path.join(base_dir, "toolchain-two")
    File.mkdir_p!(first)
    File.mkdir_p!(second)

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable")
    }

    assert {:ok, []} = DB.query(db, "SELECT host FROM host_toolchain_dirs")
    refute Map.has_key?(Placement.hosts(base_dir, db)["testhost"], :toolchain_dirs)

    baseline = Placement.adapter_opts!(config, {:claude, "default", "testhost"})[:env]

    assert {:ok, %{dirs: [^first, ^second]}} =
             Placement.set_toolchain_dirs(
               db,
               "testhost",
               [first, second],
               "user:operator"
             )

    assert Placement.hosts(base_dir, db)["testhost"].toolchain_dirs == [first, second]

    configured = Placement.adapter_opts!(config, {:claude, "default", "testhost"})[:env]

    assert {"PATH", "/local/bin:#{first}:#{second}:/usr/local/bin:/usr/bin:/bin"} in configured

    refute {"PATH", "/local/bin:" <> (System.get_env("PATH") || "")} in configured

    assert {:ok, %{dirs: []}} =
             Placement.set_toolchain_dirs(db, "testhost", [], "user:operator")

    refute Map.has_key?(Placement.hosts(base_dir, db)["testhost"], :toolchain_dirs)
    assert Placement.adapter_opts!(config, {:claude, "default", "testhost"})[:env] == baseline
  end

  test "host toolchain rows use the same constructed PATH for ssh adapters", %{
    base_dir: base_dir,
    db: db
  } do
    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:4000")

    assert {:ok, _} =
             Placement.register_host(db, "worker", %{
               ssh: "codex@worker",
               base_dir: "/srv/tb",
               cli_bin: "/srv/tb/bin"
             })

    assert {:ok, _} =
             Placement.set_toolchain_dirs(
               db,
               "worker",
               ["/tools/one", "/tools/two"],
               "user:operator"
             )

    parent = self()

    sh = fn command ->
      send(parent, {:toolchain_sh, command})

      if Enum.any?(command, &String.contains?(&1, "credential-harvest")) and
           Enum.any?(command, &String.contains?(&1, "cat")),
         do: {"", 42},
         else: {"", 0}
    end

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable"),
      sh: sh
    }

    command = Placement.adapter_opts!(config, {:codex, "default", "worker"})[:cmd]

    assert "PATH=/srv/tb/bin:/tools/one:/tools/two:/usr/local/bin:/usr/bin:/bin" in command
    refute "PATH=/srv/tb/bin:$PATH" in command

    assert_receive {:toolchain_sh,
                    [
                      "ssh",
                      "-o",
                      "BatchMode=yes",
                      "-o",
                      "ConnectTimeout=5",
                      "codex@worker",
                      "test",
                      "-d",
                      "/tools/one"
                    ]}

    assert_receive {:toolchain_sh,
                    [
                      "ssh",
                      "-o",
                      "BatchMode=yes",
                      "-o",
                      "ConnectTimeout=5",
                      "codex@worker",
                      "test",
                      "-d",
                      "/tools/two"
                    ]}
  end

  test "a configured but unavailable toolchain directory refuses adapter start loudly", %{
    base_dir: base_dir,
    db: db
  } do
    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable")
    }

    missing = Path.join(base_dir, "missing-toolchain")

    assert {:ok, _} =
             Placement.set_toolchain_dirs(db, "testhost", [missing], "user:operator")

    assert_raise RuntimeError,
                 "host testhost toolchain directory is unavailable at adapter start: #{missing}",
                 fn -> Placement.adapter_opts!(config, {:claude, "default", "testhost"}) end

    assert {:ok, _} =
             Placement.register_host(db, "worker", %{
               ssh: "codex@worker",
               base_dir: "/srv/tb",
               cli_bin: "/srv/tb/bin"
             })

    assert {:ok, _} =
             Placement.set_toolchain_dirs(db, "worker", ["/missing-remote"], "user:operator")

    remote = Map.put(config, :sh, fn _command -> {"", 1} end)

    assert_raise RuntimeError,
                 "host worker toolchain directory is unavailable at adapter start (exit 1): /missing-remote",
                 fn -> Placement.adapter_opts!(remote, {:codex, "default", "worker"}) end
  end

  test "adapter_opts always pins GH_CONFIG_DIR at the banked github dir", %{
    base_dir: base_dir,
    db: db
  } do
    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable")
    }

    # Unconditional even before onboarding: an absent banked dir makes gh
    # answer needs_onboarding, where ambient fallback would let a keyring
    # credential agents cannot read answer "live".
    gh_dir = Path.join([base_dir, "auth", "github", "gh"])
    refute File.dir?(gh_dir)

    assert {"GH_CONFIG_DIR", gh_dir} in Placement.adapter_opts!(
             config,
             {:claude, "default", "testhost"}
           )[:env]
  end

  test "adapter_opts appends an ssh overlay to remote_env", %{base_dir: base_dir, db: db} do
    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:4000")

    assert {:ok, _} =
             Placement.register_host(db, "worker", %{
               ssh: "codex@worker",
               base_dir: "/srv/tb",
               cli_bin: "/srv/tb/bin"
             })

    assert {:ok, _row} =
             Placement.set_env_overlay(
               db,
               "worker",
               "codex",
               "EXAMPLE_OVERLAY_VAR",
               "example remote",
               "user:operator"
             )

    sh = fn command ->
      if Enum.any?(command, &String.contains?(&1, "credential-harvest")) and
           Enum.any?(command, &String.contains?(&1, "cat")),
         do: {"", 42},
         else: {"", 0}
    end

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable"),
      sh: sh
    }

    command = Placement.adapter_opts!(config, {:codex, "default", "worker"})[:cmd]
    assignment = "EXAMPLE_OVERLAY_VAR='example remote'"
    assert assignment in command

    assert Enum.find_index(command, &(&1 == assignment)) >
             Enum.find_index(command, &String.starts_with?(&1, "TIGHTBEAM_LINEAGE="))
  end

  test "an overlay is isolated by both host and harness", %{base_dir: base_dir, db: db} do
    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:4000")

    for host <- ["gibson", "other-host"] do
      assert {:ok, _} =
               Placement.register_host(db, host, %{
                 ssh: host,
                 base_dir: "/srv/#{host}",
                 cli_bin: "/srv/#{host}/bin"
               })
    end

    assert {:ok, _row} =
             Placement.set_env_overlay(
               db,
               "gibson",
               "claude",
               "EXAMPLE_OVERLAY_VAR",
               "isolated",
               "user:operator"
             )

    sh = fn command ->
      if Enum.any?(command, &String.contains?(&1, "credential-harvest")) and
           Enum.any?(command, &String.contains?(&1, "cat")),
         do: {"", 42},
         else: {"", 0}
    end

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable"),
      sh: sh
    }

    gibson_claude = Placement.adapter_opts!(config, {:claude, "default", "gibson"})[:cmd]
    gibson_codex = Placement.adapter_opts!(config, {:codex, "default", "gibson"})[:cmd]
    other_claude = Placement.adapter_opts!(config, {:claude, "default", "other-host"})[:cmd]

    assert "EXAMPLE_OVERLAY_VAR='isolated'" in gibson_claude
    refute Enum.any?(gibson_codex, &String.starts_with?(&1, "EXAMPLE_OVERLAY_VAR="))
    refute Enum.any?(other_claude, &String.starts_with?(&1, "EXAMPLE_OVERLAY_VAR="))
  end

  test "adapter_opts prepares a local codex gate probe with the trust-bypass CODEX_CONFIG", %{
    base_dir: base_dir,
    db: db
  } do
    install_statute(base_dir)
    Rails.load!(base_dir)

    probe_cwd = Path.join(base_dir, "work/gate-probe")
    File.mkdir_p!(probe_cwd)
    File.write!(Path.join(probe_cwd, "stale"), "remove me")

    cli_bin = Path.join(base_dir, "bin")
    File.mkdir_p!(cli_bin)

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: cli_bin,
      default_model: Model.new("fable")
    }

    opts = Placement.adapter_opts!(config, {:codex, "default", "testhost"})

    assert {"CODEX_CONFIG", ~s({"bypass_hook_trust":true})} in opts[:env]
    refute Enum.any?(opts[:env], fn {key, _value} -> key == "CODEX_PATH" end)
    assert opts[:probe_cwd] == probe_cwd
    assert opts[:probe_model] == Model.new("gpt-5.6-sol", effort: "medium")
    refute opts[:probe_model] == config.default_model
    refute File.exists?(Path.join(probe_cwd, "stale"))

    claude_opts = Placement.adapter_opts!(config, {:claude, "default", "testhost"})
    refute Keyword.has_key?(claude_opts, :probe_cwd)
    refute Keyword.has_key?(claude_opts, :probe_model)
    refute Enum.any?(claude_opts[:env], fn {key, _value} -> key == "CODEX_CONFIG" end)
    refute Enum.any?(claude_opts[:env], fn {key, _value} -> key == "CODEX_PATH" end)
  end

  test "adapter_opts injects the org's claude token env when the store holds one", %{
    base_dir: base_dir,
    db: db
  } do
    token_dir = Path.join([base_dir, "auth", "claude"])
    File.mkdir_p!(token_dir)

    File.write!(
      Path.join(token_dir, ".credentials.json"),
      ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-test"}})
    )

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable")
    }

    # A subscription credential reaches the harness as a FILE in its home, never as an
    # environment variable: it carries a refresh token that Claude Code rotates in place,
    # and an env var has nowhere to keep one.
    claude_env = Placement.adapter_opts!(config, {:claude, "default", "testhost"})[:env]
    refute Enum.any?(claude_env, fn {k, _} -> k == "CLAUDE_CODE_OAUTH_TOKEN" end)
    assert Enum.any?(claude_env, fn {k, _} -> k == "CLAUDE_CONFIG_DIR" end)

    # And no secret is smuggled in by another name.
    refute inspect(claude_env) =~ "sk-ant-oat01-test"
  end

  test "adapter_opts embeds every remote agent env in the ssh command", %{
    base_dir: base_dir,
    db: db
  } do
    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:4000")

    register_hosts(db, %{
      "worker" => %{
        ssh: "codex@worker",
        base_dir: "/srv/tb",
        cli_bin: "/srv/tb/bin",
        adapter_bin_dir: "/opt/acp"
      }
    })

    sh = fn command ->
      if Enum.any?(command, &String.contains?(&1, "credential-harvest")) and
           Enum.any?(command, &String.contains?(&1, "cat")),
         do: {"", 42},
         else: {"", 0}
    end

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable"),
      sh: sh
    }

    opts = Placement.adapter_opts!(config, {:codex, "default", "worker"})
    remote_home = "/srv/tb/homes/worker/codex"

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
             "TIGHTBEAM_MACHINE=worker",
             "TIGHTBEAM_URL=http://gateway.example:4000",
             "PATH=/srv/tb/bin:$PATH",
             "TIGHTBEAM_LINEAGE=tb1-Y29kZXhAd29ya2Vy",
             "GH_CONFIG_DIR='/srv/tb/auth/github/gh'",
             ~s(CODEX_CONFIG='{"bypass_hook_trust":true}'),
             "/srv/tb/adapters/node_modules/.bin/codex-acp"
           ]

    assert opts[:home] == remote_home
    assert opts[:stderr_path] == Path.join(base_dir, "adapter-codex:default@worker.stderr.log")
    assert opts[:env] == [{"TIGHTBEAM_LINEAGE", "tb1-Y29kZXhAd29ya2Vy"}]

    lineage_assignment = Enum.find(opts[:cmd], &String.starts_with?(&1, "TIGHTBEAM_LINEAGE="))
    assert lineage_assignment == "TIGHTBEAM_LINEAGE=tb1-Y29kZXhAd29ya2Vy"
    refute Enum.any?(opts[:cmd], &String.contains?(&1, "'TIGHTBEAM_LINEAGE="))

    claude_opts = Placement.adapter_opts!(config, {:claude, "default", "worker"})

    # No credential expansion for a subscription: the remote reads its own home file.
    refute Enum.any?(claude_opts[:cmd], &String.contains?(&1, "CLAUDE_CODE_OAUTH_TOKEN"))
    assert Enum.any?(claude_opts[:cmd], &String.contains?(&1, "CLAUDE_CONFIG_DIR="))

    # Harness-scoped: codex remote env never carries claude's token expansion.
    refute Enum.any?(opts[:cmd], &String.contains?(&1, "CLAUDE_CODE_OAUTH_TOKEN"))
  end

  test "adapter_opts prepares the remote codex probe with the trust-bypass CODEX_CONFIG", %{
    base_dir: base_dir,
    db: db
  } do
    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:4000")

    register_hosts(db, %{
      "worker" => %{ssh: "codex@worker", base_dir: "/srv/tb", cli_bin: "/srv/tb/bin"}
    })

    install_statute(base_dir)
    Rails.load!(base_dir)
    parent = self()

    sh = fn command ->
      send(parent, {:remote_gate_command, command})

      if Enum.any?(command, &String.contains?(&1, "credential-harvest")) and
           Enum.any?(command, &String.contains?(&1, "cat")),
         do: {"", 42},
         else: {"", 0}
    end

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable"),
      sh: sh
    }

    opts = Placement.adapter_opts!(config, {:codex, "default", "worker"})
    assert ~s(CODEX_CONFIG='{"bypass_hook_trust":true}') in opts[:cmd]
    assert opts[:probe_cwd] == "/srv/tb/work/gate-probe"
    assert opts[:probe_model] == Model.new("gpt-5.6-sol", effort: "medium")

    assert Enum.any?(collect_remote_gate_commands([]), fn command ->
             List.last(command) == "/srv/tb/work/gate-probe" and "rm" in command and
               "-rf" in command
           end)

    claude_opts = Placement.adapter_opts!(config, {:claude, "default", "worker"})
    refute Enum.any?(claude_opts[:cmd], &String.starts_with?(&1, "CODEX_CONFIG="))
    refute Keyword.has_key?(claude_opts, :probe_cwd)

    # Withdrawing the law withdraws the PROBE — nothing can deny any more, so
    # nothing is worth failing a boot over. The trust seed stays: the substrate's
    # reserved observation entry is still projected, and on codex a hook only arms
    # when trust is bypassed.
    File.rm_rf!(Path.join([base_dir, "identity", "rails"]))
    Rails.load!(base_dir)
    lawless_opts = Placement.adapter_opts!(config, {:codex, "default", "worker"})
    assert ~s(CODEX_CONFIG='{"bypass_hook_trust":true}') in lawless_opts[:cmd]
    refute Keyword.has_key?(lawless_opts, :probe_cwd)
    refute Keyword.has_key?(lawless_opts, :probe_model)
  end

  test "adapter lineage identifies the shared harness runtime", %{base_dir: base_dir, db: db} do
    archetypes_dir = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(archetypes_dir)
    identity_name = "name with space:/@$('<é"
    File.write!(Path.join(archetypes_dir, "spaced.toml"), ~s(name = "#{identity_name}"\n))
    Archetypes.load!(base_dir)

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable")
    }

    opts = Placement.adapter_opts!(config, {:codex, identity_name, "testhost"})

    {"TIGHTBEAM_LINEAGE", "tb1-" <> encoded} =
      Enum.find(opts[:env], fn {key, _value} -> key == "TIGHTBEAM_LINEAGE" end)

    assert Base.url_decode64!(encoded, padding: false) == "codex@testhost"
  end

  test "deliver_home preserves the manifest and nested state with zero statutes", %{
    base_dir: base_dir,
    db: db
  } do
    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("fable")
    }

    home = Placement.deliver_home(config, {:codex, "default", "testhost"})
    stamp_path = Path.join([home, ".tightbeam", "manifest"])
    stamp_before = File.read!(stamp_path)
    marker = Path.join([home, "sessions", "nested-marker"])
    File.mkdir_p!(Path.dirname(marker))
    File.write!(marker, "keep")

    assert Placement.deliver_home(config, {:codex, "default", "testhost"}) == home
    assert File.read!(stamp_path) == stamp_before
    assert File.read!(marker) == "keep"
    refute File.exists?(Path.join(home, "settings.json"))

    # Zero statutes is no longer zero hooks: the home carries the substrate's
    # reserved entries — the observation, plus codex's own wiring-check probe —
    # and no law at all.
    hooks = File.read!(Path.join(home, "hooks.json")) |> JSON.decode!()

    assert hooks == %{
             "hooks" => %{
               "PreToolUse" => [
                 Rails.github_auth_entry(),
                 Rails.observation_entry(),
                 Rails.probe_entry()
               ]
             }
           }
  end

  test "local Cursor projection uses the dedicated account's real home" do
    expected_home =
      case :os.type() do
        {:unix, :darwin} -> "/Users/tightbeam-cursor"
        {:unix, _} -> "/home/tightbeam-cursor"
      end

    assert Tightbeam.Harness.Cursor.execution_home(nil) == expected_home

    assert Tightbeam.Harness.Cursor.execution_base(nil) ==
             Path.join(expected_home, ".tightbeam")

    assert Tightbeam.Harness.Cursor.execution_home("/test/cursor-home") ==
             "/test/cursor-home"
  end

  test "Cursor delivery keeps the Homes projection outside the execution account home", %{
    base_dir: base_dir,
    db: db
  } do
    execution_home = Path.join(base_dir, "dedicated-cursor-home")
    File.mkdir_p!(Path.join(execution_home, ".cursor"))
    File.mkdir_p!(Path.join(execution_home, ".tightbeam"))
    sentinel = Path.join(execution_home, ".tightbeam/execution-owned")
    File.write!(sentinel, "preserve")

    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("auto"),
      cursor_execution_home: execution_home
    }

    projected = Placement.deliver_home(config, {:cursor, "default", "testhost"})

    assert projected == Homes.home_path(base_dir, "testhost", :cursor)
    refute projected == execution_home
    assert File.read!(sentinel) == "preserve"
    assert File.regular?(Path.join(execution_home, ".cursor/hooks.json"))
    refute File.exists?(Path.join(execution_home, "cli-config.json"))
  end

  # wi_263814d3 — accepted-then-dead: the claude adapter's offered/accepted model
  # set follows the projected home's settings.json "model" pin (proven live —
  # scripts/probe-opus5.mjs + scripts/probe-reread.mjs: a session/new re-reads the
  # pin, so a home pinned to model X offers+accepts X and refuses everything
  # else non-alias).
  # The durable fix pins the SESSION'S RESOLVED model, not the fixed org default,
  # so acceptance tracks selection by construction. deliver_home must honour a
  # per-session :model; without it a session that SELECTED opus-5 gets a
  # sonnet-pinned home and every turn dies on "Invalid value for config option
  # model".
  test "deliver_home pins the session's selected model, not the org default", %{
    base_dir: base_dir,
    db: db
  } do
    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("claude-sonnet-5", effort: "medium")
    }

    selected = Model.new("claude-opus-5")

    home =
      Placement.deliver_home(config, {:claude, "shared", "testhost"}, model: selected)

    settings = home |> Path.join("settings.json") |> File.read!() |> JSON.decode!()
    assert settings["model"] == "claude-opus-5"
  end

  # Regression guard on the fallback: with no per-session model (adapter
  # cold-boot has no session context), the org default stays the baseline pin.
  test "deliver_home falls back to the org default model when no session model is given", %{
    base_dir: base_dir,
    db: db
  } do
    config = %{
      base_dir: base_dir,
      db: db,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: Model.new("claude-sonnet-5", effort: "medium")
    }

    home = Placement.deliver_home(config, {:claude, "shared", "testhost"})

    settings = home |> Path.join("settings.json") |> File.read!() |> JSON.decode!()
    assert settings["model"] == "claude-sonnet-5"
  end

  defp collect_commands(acc) do
    receive do
      {:command, command} -> collect_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_remote_gate_commands(acc) do
    receive do
      {:remote_gate_command, command} -> collect_remote_gate_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp test_workdir(base_dir, session_key) do
    digest =
      :crypto.hash(:sha256, session_key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    Path.join([base_dir, "work", digest])
  end

  test "the hosts table is the one registry; register_host records and updates in place", %{
    base_dir: base_dir,
    db: db
  } do
    assert {:ok, entry} =
             Placement.register_host(db, "work-1", %{
               ssh: "work-1.example",
               base_dir: "/home/u/.tightbeam"
             })

    assert entry.ssh == "work-1.example"

    hosts = Placement.hosts(base_dir, db)
    assert hosts["work-1"].base_dir == "/home/u/.tightbeam"
    assert hosts["testhost"].ssh == nil

    # re-register updates in place
    assert {:ok, _} = Placement.register_host(db, "work-1", %{ssh: "w2", base_dir: "/z"})
    assert Placement.hosts(base_dir, db)["work-1"].ssh == "w2"
    assert Placement.hosts(base_dir, db)["work-1"].base_dir == "/z"
  end

  # Fail-before evidence, measured 2026-07-28 against the hosts.json registry
  # this table replaced (40 concurrent registrations of distinct hosts, 10
  # trials, through the same public API): 371 of 400 calls returned {:ok, entry}
  # to their caller and the host was then ABSENT from the registry — roughly 3
  # of 40 survived a trial — and one reader crashed on a torn read
  # (JSON.DecodeError at position 0; File.write! truncates before it writes).
  # The DB owner serializes the row upserts, so the same shape must now leave
  # every acknowledged host present, with a concurrent reader never observing a
  # torn or partial registry (host-registry-v1 acceptance 1 and 2).
  test "concurrent registrations all land and a concurrent reader never tears", %{
    base_dir: base_dir,
    db: db
  } do
    hosts = for index <- 1..40, do: "race-host-#{index}"

    # Every task blocks on a release message, so all 40 writers and the reader
    # are alive BEFORE any of them runs — without the barrier the reader could
    # drain its reads against an empty table before the first write existed.
    reader =
      Task.async(fn ->
        receive do: (:go -> :ok)
        # hosts/2 raises on a registry it cannot read whole, so surviving the
        # write burst IS the torn-read assertion.
        Enum.each(1..200, fn _ -> _ = Placement.hosts(base_dir, db) end)
        :ok
      end)

    writers =
      Enum.map(hosts, fn name ->
        Task.async(fn ->
          receive do: (:go -> :ok)
          Placement.register_host(db, name, %{ssh: "#{name}.example", base_dir: "/srv/tb"})
        end)
      end)

    Enum.each([reader | writers], &send(&1.pid, :go))

    results = Task.await_many(writers)
    assert Task.await(reader) == :ok
    assert Enum.all?(results, &match?({:ok, _}, &1))

    # Every caller that was told {:ok, _} finds its host present — the defect
    # was exactly an acknowledgement for a registration that then vanished.
    registered = Placement.hosts(base_dir, db)
    for name <- hosts, do: assert(registered[name].ssh == "#{name}.example")
  end

  test "where [\"*\"] grants any configured host; empty stays an error upstream" do
    anywhere = %{name: "roamer", where: ["*"], defaults: %{}, references: [], guidance: nil}

    hosts = %{
      "testhost" => %{ssh: nil, base_dir: "/b", cli_bin: nil},
      "work-1" => %{ssh: "w", base_dir: "/b", cli_bin: nil}
    }

    assert {:ok, "testhost"} = Placement.resolve(anywhere, nil, hosts)
    assert {:ok, "work-1"} = Placement.resolve(anywhere, "work-1", hosts)
    assert {:error, %{code: "unknown_host"}} = Placement.resolve(anywhere, "nope", hosts)
  end

  defp eventually(fun, tries \\ 60)

  defp eventually(fun, tries) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(25)
        eventually(fun, tries - 1)
    end
  end

  defp install_statute(base_dir, text \\ "History-rewriting git commands are forbidden here.") do
    rails_dir = Path.join([base_dir, "identity", "rails"])
    File.mkdir_p!(rails_dir)

    File.write!(Path.join(rails_dir, "law.toml"), """
    [[statute]]
    name = "no-history-rewrites"
    on = "tool-call"
    tool = "Bash"
    pattern = "git (reset|stash|rebase)"
    text = "#{text}"
    """)
  end

  defp codex_hooks_bytes do
    Rails.hook_settings()
    |> update_in(["hooks", "PreToolUse"], &(&1 ++ [Rails.probe_entry()]))
    |> JSON.encode!()
  end

  defp put_skill!(base_dir, name, body) do
    Identity.init!(base_dir)
    Identity.edit!(base_dir, "default", {:skill, name, false}, body, "test")
    Archetypes.load!(base_dir)
    Path.join([base_dir, "identity", "skills", name, "SKILL.md"])
  end
end
