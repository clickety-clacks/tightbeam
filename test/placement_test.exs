defmodule Tightbeam.PlacementTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{Archetypes, DB, EventLog, Homes, Org, Placement, Rails}

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-placement-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base_dir)
    File.write!(Path.join(base_dir, "gateway.json"), JSON.encode!(%{cliToken: "tbc_test"}))
    db = :"placement_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Org.ensure_schema(db)
    :ok = EventLog.ensure_schema(db)
    Archetypes.load!(base_dir)
    Rails.load!(base_dir)

    old_hosts = Application.get_env(:tightbeam, :hosts)
    old_url = Application.get_env(:tightbeam, :advertised_url)

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Tightbeam.Rails)

      if old_hosts,
        do: Application.put_env(:tightbeam, :hosts, old_hosts),
        else: Application.delete_env(:tightbeam, :hosts)

      if old_url,
        do: Application.put_env(:tightbeam, :advertised_url, old_url),
        else: Application.delete_env(:tightbeam, :advertised_url)
    end)

    %{base_dir: base_dir, db: db}
  end

  test "overridden identities normalize their name and reconstruct identical homes from session rows",
       %{base_dir: base_dir, db: db} do
    Archetypes.put_skill!(base_dir, "review", "# Review")
    base = Archetypes.load!(base_dir)["default"]

    {:ok, first} =
      Archetypes.normalize_overrides(base_dir, base, %{
        "skills_add" => ["review", "review"],
        "guidance_extra" => "  Review carefully.  "
      })

    {:ok, reordered} =
      Archetypes.normalize_overrides(base_dir, base, %{
        "guidance_extra" => "Review carefully.",
        "skills_add" => ["review"]
      })

    config = %{
      base_dir: base_dir,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "fable",
      db: db
    }

    identity_name = Placement.identity_name(config, base, first, :codex)
    assert identity_name == Placement.identity_name(config, base, reordered, :codex)
    assert identity_name =~ ~r/^default--[0-9a-f]{16}$/

    different =
      Placement.identity_name(
        config,
        base,
        %{"guidance_extra" => "Different guidance."},
        :codex
      )

    refute different == identity_name

    Org.create(db, %{
      session_key: "overridden",
      display_name: "Overridden",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      overrides: first,
      identity_name: identity_name,
      host: "testhost",
      harness: "codex",
      provider: "openai",
      model: "gpt-5.6-sol[medium]"
    })

    opts = Placement.adapter_opts(config, {:codex, identity_name, "testhost"})
    assert opts[:home] == Path.join([base_dir, "homes", identity_name, "codex"])
    assert opts[:stderr_path] =~ "adapter-codex:#{identity_name}@testhost"
    assert File.read!(Path.join(opts[:home], "AGENTS.md")) =~ "# Tightbeam · default"
    assert File.read!(Path.join(opts[:home], "AGENTS.md")) =~ "Review carefully."

    manifest = opts[:home] |> Path.join(".tightbeam-manifest") |> File.read!() |> JSON.decode!()
    assert manifest["identity_sha256"] =~ ~r/^[0-9a-f]{64}$/

    assert %{
             "name" => "review",
             "provenance" => "override",
             "linkage" => "linked"
           } in manifest["skills"]

    bytes = File.read!(Path.join(opts[:home], "AGENTS.md"))
    File.rm_rf!(opts[:home])
    restarted = Placement.adapter_opts(config, {:codex, identity_name, "testhost"})
    assert File.read!(Path.join(restarted[:home], "AGENTS.md")) == bytes

    Org.retire(db, "overridden")

    restarted = Placement.adapter_opts(config, {:codex, identity_name, "testhost"})
    assert File.read!(Path.join(restarted[:home], "AGENTS.md")) == bytes
  end

  test "reconstruction refuses retired sessions with colliding effective content", %{
    base_dir: base_dir,
    db: db
  } do
    base = Archetypes.load!(base_dir)["default"]
    first = %{"guidance_extra" => "First"}
    second = %{"guidance_extra" => "Second"}

    config = %{
      base_dir: base_dir,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "fable",
      db: db
    }

    identity_name = Placement.identity_name(config, base, first, :codex)

    for {session_key, overrides} <- [{"first", first}, {"second", second}] do
      Org.create(db, %{
        session_key: session_key,
        display_name: session_key,
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        overrides: overrides,
        identity_name: identity_name,
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })
    end

    Org.retire(db, "second")

    assert_raise ArgumentError, ~r/identity name collision/, fn ->
      Placement.adapter_opts(config, {:codex, identity_name, "testhost"})
    end
  end

  test "overridden adapters keep MCP and model pins on the base while all identity paths use --",
       %{base_dir: base_dir, db: db} do
    manifests = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)

    File.write!(Path.join(manifests, "coder.toml"), """
    name = "coder"

    [defaults]
    model = "base-model"

    [mcp.files]
    command = "files-mcp"
    """)

    Archetypes.put_skill!(base_dir, "review", "# Review")
    base = Archetypes.load!(base_dir)["coder"]

    {:ok, overrides} =
      Archetypes.normalize_overrides(base_dir, base, %{"skills_add" => ["review"]})

    config = %{
      base_dir: base_dir,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "org-model",
      db: db
    }

    identity_name = Placement.identity_name(config, base, overrides, :claude)

    Org.create(db, %{
      session_key: "dual-accessor",
      display_name: "Dual accessor",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "coder",
      overrides: overrides,
      identity_name: identity_name,
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "session-model"
    })

    {resolved_base, effective, ^overrides} = Placement.resolve_identity!(config, identity_name)

    assert Archetypes.acp_mcp_servers(resolved_base) == [
             %{"name" => "files", "command" => "files-mcp", "args" => [], "env" => []}
           ]

    assert "review" in effective.skills

    opts = Placement.adapter_opts(config, {:claude, identity_name, "testhost"})
    assert opts[:home] =~ "/homes/#{identity_name}/claude"
    assert opts[:stderr_path] =~ identity_name

    assert opts[:home]
           |> Path.join("settings.json")
           |> File.read!()
           |> JSON.decode!() == %{"model" => "base-model"}

    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:4000")

    Application.put_env(:tightbeam, :hosts, %{
      "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: "/remote/tb/bin"}
    })

    parent = self()

    sh = fn command ->
      send(parent, {:command, command})
      if "cat" in command, do: {"", 1}, else: {"", 0}
    end

    remote_opts =
      config
      |> Map.put(:sh, sh)
      |> Placement.adapter_opts({:claude, identity_name, "worker"})

    assert remote_opts[:home] == "/remote/tb/homes/#{identity_name}/claude"
    assert Enum.any?(remote_opts[:cmd], &String.contains?(&1, identity_name))

    assert Enum.any?(collect_commands([]), fn command ->
             Enum.any?(command, &String.contains?(&1, "/staging/worker/homes/#{identity_name}/"))
           end)
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

  test "move_workdir copies local to local", %{base_dir: base_dir} do
    old_base = Path.join(base_dir, "old-local")
    new_base = Path.join(base_dir, "new-local")

    Application.put_env(:tightbeam, :hosts, %{
      "old-local" => %{ssh: nil, base_dir: old_base, cli_bin: nil},
      "new-local" => %{ssh: nil, base_dir: new_base, cli_bin: nil}
    })

    source = test_workdir(old_base, "session-1")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "memory.md"), "remember")
    File.write!(Path.join(source, ".tightbeam-session"), "secret")

    assert :ok =
             Placement.move_workdir(%{base_dir: base_dir}, "session-1", "old-local", "new-local")

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

  test "move_workdir fails on a real local token removal error", %{base_dir: base_dir} do
    old_base = Path.join(base_dir, "old-remove-error")
    new_base = Path.join(base_dir, "new-remove-error")

    Application.put_env(:tightbeam, :hosts, %{
      "old-remove-error" => %{ssh: nil, base_dir: old_base, cli_bin: nil},
      "new-remove-error" => %{ssh: nil, base_dir: new_base, cli_bin: nil}
    })

    source = test_workdir(old_base, "remove-error")
    File.mkdir_p!(Path.join(source, ".tightbeam-session"))

    assert {:error, message} =
             Placement.move_workdir(
               %{base_dir: base_dir},
               "remove-error",
               "old-remove-error",
               "new-remove-error"
             )

    assert message =~ "source session token removal failed"
  end

  test "move_workdir rsyncs local to remote", %{base_dir: base_dir} do
    old_base = Path.join(base_dir, "old-local")

    Application.put_env(:tightbeam, :hosts, %{
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
               %{base_dir: base_dir, sh: sh},
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

  test "move_workdir rsyncs remote to local", %{base_dir: base_dir} do
    new_base = Path.join(base_dir, "new-local")

    Application.put_env(:tightbeam, :hosts, %{
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
               %{base_dir: base_dir, sh: sh},
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

  test "move_workdir stages remote to remote through the gateway", %{base_dir: base_dir} do
    Application.put_env(:tightbeam, :hosts, %{
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
               %{base_dir: base_dir, sh: sh},
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

  test "adapter_opts preserves the pre-placement local shape", %{base_dir: base_dir} do
    parent = self()

    config = %{
      base_dir: base_dir,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "fable",
      sh: fn command ->
        send(parent, {:unexpected_sh, command})
        {"", 0}
      end
    }

    opts = Placement.adapter_opts(config, {:codex, "default", "testhost"})

    expected_binary = Path.expand("../tightbeam/node_modules/.bin/codex-acp", File.cwd!())
    expected_home = Path.join([base_dir, "homes", "default", "codex"])

    assert opts == [
             harness: :codex,
             cmd: [expected_binary],
             home: expected_home,
             cwd: "/work",
             stderr_path: Path.join(base_dir, "adapter-codex:default@testhost.stderr.log"),
             env: [
               {"TIGHTBEAM_HOME", base_dir},
               {"PATH", "/local/bin:" <> (System.get_env("PATH") || "")},
               {"TIGHTBEAM_LINEAGE", "tb1-ZGVmYXVsdEB0ZXN0aG9zdA"}
             ]
           ]

    refute Keyword.has_key?(opts, :contained)
    refute Keyword.has_key?(opts, :probe_cwd)
    refute Keyword.has_key?(opts, :probe_model)
    refute Enum.any?(opts[:env], fn {key, _value} -> key == "CODEX_CONFIG" end)
    refute Enum.any?(opts[:env], fn {key, _value} -> key == "CODEX_PATH" end)
    refute_receive {:unexpected_sh, _}
  end

  test "adapter_opts prepares a local codex gate probe without CODEX_CONFIG", %{
    base_dir: base_dir
  } do
    install_statute(base_dir)
    Rails.load!(base_dir)

    probe_cwd = Path.join(base_dir, "work/gate-probe")
    File.mkdir_p!(probe_cwd)
    File.write!(Path.join(probe_cwd, "stale"), "remove me")

    cli_bin = Path.join(base_dir, "bin")
    codex_shim = Path.join(cli_bin, "codex")
    File.mkdir_p!(cli_bin)
    File.write!(codex_shim, "#!/bin/sh\n")

    config = %{base_dir: base_dir, cwd: "/work", cli_bin: cli_bin, default_model: "fable"}
    opts = Placement.adapter_opts(config, {:codex, "default", "testhost"})

    refute Enum.any?(opts[:env], fn {key, _value} -> key == "CODEX_CONFIG" end)
    assert {"CODEX_PATH", codex_shim} in opts[:env]
    assert opts[:probe_cwd] == probe_cwd
    assert opts[:probe_model] == "gpt-5.6-sol[medium]"
    refute opts[:probe_model] == config.default_model
    refute File.exists?(Path.join(probe_cwd, "stale"))

    claude_opts = Placement.adapter_opts(config, {:claude, "default", "testhost"})
    refute Keyword.has_key?(claude_opts, :probe_cwd)
    refute Keyword.has_key?(claude_opts, :probe_model)
    refute Enum.any?(claude_opts[:env], fn {key, _value} -> key == "CODEX_CONFIG" end)
    refute Enum.any?(claude_opts[:env], fn {key, _value} -> key == "CODEX_PATH" end)
  end

  test "adapter_opts injects the org's claude token env when the store holds one", %{
    base_dir: base_dir
  } do
    token_dir = Path.join([base_dir, "auth", "claude"])
    File.mkdir_p!(token_dir)
    File.write!(Path.join(token_dir, "oauth-token"), "sk-ant-oat01-test\n")

    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin", default_model: "fable"}

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

    config = %{
      base_dir: base_dir,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "fable",
      sh: sh
    }

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
             "PATH=/srv/tb/bin:$PATH",
             "TIGHTBEAM_LINEAGE=tb1-ZGVmYXVsdEB3b3JrZXI",
             "/srv/tb/adapters/node_modules/.bin/codex-acp"
           ]

    assert opts[:home] == remote_home
    assert opts[:stderr_path] == Path.join(base_dir, "adapter-codex:default@worker.stderr.log")
    assert opts[:env] == [{"TIGHTBEAM_LINEAGE", "tb1-ZGVmYXVsdEB3b3JrZXI"}]

    lineage_assignment = Enum.find(opts[:cmd], &String.starts_with?(&1, "TIGHTBEAM_LINEAGE="))
    assert lineage_assignment == "TIGHTBEAM_LINEAGE=tb1-ZGVmYXVsdEB3b3JrZXI"
    refute Enum.any?(opts[:cmd], &String.contains?(&1, "'TIGHTBEAM_LINEAGE="))

    claude_opts = Placement.adapter_opts(config, {:claude, "default", "worker"})

    assert "CLAUDE_CODE_OAUTH_TOKEN=$(cat /srv/tb/auth/claude/oauth-token 2>/dev/null)" in claude_opts[
             :cmd
           ]

    # Harness-scoped: codex remote env never carries claude's token expansion.
    refute Enum.any?(opts[:cmd], &String.contains?(&1, "CLAUDE_CODE_OAUTH_TOKEN"))
  end

  test "adapter_opts prepares the remote codex probe without CODEX_CONFIG", %{
    base_dir: base_dir
  } do
    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:4000")

    Application.put_env(:tightbeam, :hosts, %{
      "worker" => %{ssh: "codex@worker", base_dir: "/srv/tb", cli_bin: "/srv/tb/bin"}
    })

    install_statute(base_dir)
    Rails.load!(base_dir)
    parent = self()

    sh = fn command ->
      send(parent, {:remote_gate_command, command})
      {"", 0}
    end

    config = %{
      base_dir: base_dir,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "fable",
      sh: sh
    }

    opts = Placement.adapter_opts(config, {:codex, "default", "worker"})
    refute Enum.any?(opts[:cmd], &String.starts_with?(&1, "CODEX_CONFIG="))
    assert opts[:probe_cwd] == "/srv/tb/work/gate-probe"
    assert opts[:probe_model] == "gpt-5.6-sol[medium]"

    assert Enum.any?(collect_remote_gate_commands([]), fn command ->
             List.last(command) == "/srv/tb/work/gate-probe" and "rm" in command and
               "-rf" in command
           end)

    claude_opts = Placement.adapter_opts(config, {:claude, "default", "worker"})
    refute Enum.any?(claude_opts[:cmd], &String.starts_with?(&1, "CODEX_CONFIG="))
    refute Keyword.has_key?(claude_opts, :probe_cwd)

    File.rm_rf!(Path.join([base_dir, "identity", "rails"]))
    Rails.load!(base_dir)
    lawless_opts = Placement.adapter_opts(config, {:codex, "default", "worker"})
    refute Enum.any?(lawless_opts[:cmd], &String.starts_with?(&1, "CODEX_CONFIG="))
    refute Keyword.has_key?(lawless_opts, :probe_cwd)
    refute Keyword.has_key?(lawless_opts, :probe_model)
  end

  test "contained local adapter validates, probes once, wraps argv, and records exact grants", %{
    base_dir: base_dir,
    db: db
  } do
    canonical_base = canonical(base_dir)
    write_containment_manifest(canonical_base, "default", "workdir")
    Archetypes.load!(canonical_base)
    auth_dir = Path.join([canonical_base, "auth", "codex"])
    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "auth.json"), "credential")
    parent = self()

    sh = fn command ->
      send(parent, {:probe, command})
      {"", 0}
    end

    config = %{
      base_dir: canonical_base,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "fable",
      db: db,
      sh: sh
    }

    opts = Placement.adapter_opts(config, {:codex, "default", "testhost"})
    assert opts[:contained] == true
    assert ["/usr/bin/sandbox-exec", "-p", profile, binary] = opts[:cmd]
    assert binary == Path.expand("../tightbeam/node_modules/.bin/codex-acp", File.cwd!())

    work_root = Path.join(canonical_base, "work")
    home = Path.join([canonical_base, "homes", "default", "codex"])

    assert profile =~
             ~s|(subpath "#{work_root}")\n  (subpath "#{home}")\n  (subpath "#{auth_dir}")|

    assert_receive {:probe,
                    [
                      "/usr/bin/sandbox-exec",
                      "-p",
                      "(version 1)(allow default)",
                      "/usr/bin/true"
                    ]}

    refute_receive {:probe, _}

    assert File.read_link!(Path.join(home, "auth.json")) == Path.join(auth_dir, "auth.json")

    assert [%{kind: "containment", subject: "codex:default@testhost", detail: detail}] =
             EventLog.lifecycle_events(db)

    assert detail ==
             "assembled; fs=workdir network=open; write-roots=#{work_root},#{home},#{auth_dir}"
  end

  test "contained local probe failures refuse and record DENIED", %{base_dir: base_dir, db: db} do
    canonical_base = canonical(base_dir)
    write_containment_manifest(canonical_base, "default", "workdir")
    Archetypes.load!(canonical_base)

    config = %{
      base_dir: canonical_base,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "fable",
      db: db,
      sh: fn _ -> {"no", 1} end
    }

    assert_raise ArgumentError, ~r/testhost.*sandbox-exec probe failed with exit 1/, fn ->
      Placement.adapter_opts(config, {:claude, "default", "testhost"})
    end

    assert [%{detail: "DENIED: sandbox-exec probe failed with exit 1"}] =
             EventLog.lifecycle_events(db)
  end

  test "contained local runner exceptions refuse like probe failures", %{
    base_dir: base_dir,
    db: db
  } do
    canonical_base = canonical(base_dir)
    write_containment_manifest(canonical_base, "default", "workdir")
    Archetypes.load!(canonical_base)

    config = %{
      base_dir: canonical_base,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "fable",
      db: db,
      sh: fn _ -> raise ErlangError, original: :enoent end
    }

    assert_raise ArgumentError, ~r/sandbox-exec probe failed/, fn ->
      Placement.adapter_opts(config, {:codex, "default", "testhost"})
    end

    assert [%{detail: "DENIED: sandbox-exec probe failed:" <> _}] = EventLog.lifecycle_events(db)
  end

  test "contained noncanonical ssh:nil host is refused by name before delivery and probe", %{
    base_dir: base_dir,
    db: db
  } do
    canonical_base = canonical(base_dir)
    write_containment_manifest(canonical_base, "default", "workdir")
    Archetypes.load!(canonical_base)

    Application.put_env(:tightbeam, :hosts, %{
      "alias" => %{ssh: nil, base_dir: canonical_base, cli_bin: nil}
    })

    parent = self()

    config = %{
      base_dir: canonical_base,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "fable",
      db: db,
      sh: fn command ->
        send(parent, {:command, command})
        {"", 0}
      end
    }

    assert_raise ArgumentError, ~r/contained_noncanonical_local_host/, fn ->
      Placement.adapter_opts(config, {:codex, "default", "alias"})
    end

    refute File.exists?(Path.join([canonical_base, "homes", "default", "codex"]))
    refute_receive {:command, _}

    assert [%{detail: "DENIED: contained_noncanonical_local_host"}] =
             EventLog.lifecycle_events(db)

    write_containment_manifest(canonical_base, "default", "off")
    Archetypes.load!(canonical_base)
    opts = Placement.adapter_opts(config, {:codex, "default", "alias"})
    refute Keyword.has_key?(opts, :contained)
    refute_receive {:command, _}
  end

  test "contained remote delivery is refused in the resolved core before every ssh touch", %{
    base_dir: base_dir,
    db: db
  } do
    write_containment_manifest(base_dir, "default", "workdir")
    Archetypes.load!(base_dir)

    Application.put_env(:tightbeam, :hosts, %{
      "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: nil}
    })

    parent = self()

    sh = fn command ->
      send(parent, {:command, command})
      {"", 0}
    end

    config = %{
      base_dir: base_dir,
      cwd: "/work",
      cli_bin: "/bin",
      default_model: "fable",
      db: db,
      sh: sh
    }

    assert_raise ArgumentError, ~r/contained_remote_unsupported/, fn ->
      Placement.adapter_opts(config, {:codex, "default", "worker"})
    end

    assert_raise ArgumentError, ~r/contained_remote_unsupported/, fn ->
      Placement.deliver_home(config, {:codex, "default", "worker"}, sh: sh)
    end

    refute_receive {:command, _}

    assert Enum.map(EventLog.lifecycle_events(db), & &1.detail) == [
             "DENIED: contained_remote_unsupported",
             "DENIED: contained_remote_unsupported"
           ]
  end

  test "adapter_opts resolves an overridden identity exactly once with posture off and on", %{
    base_dir: base_dir,
    db: db
  } do
    canonical_base = canonical(base_dir)
    base = Archetypes.load!(canonical_base)["default"]
    overrides = %{"skills_add" => ["missing-override-dependency"]}

    config = %{
      base_dir: canonical_base,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "fable",
      db: db,
      sh: fn _ -> {"", 0} end
    }

    identity_name = Placement.identity_name(config, base, overrides, :codex)

    Org.create(db, %{
      session_key: "resolution-count",
      display_name: "Resolution count",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      overrides: overrides,
      identity_name: identity_name,
      host: "testhost",
      harness: "codex",
      provider: "openai",
      model: "gpt-5.6-sol[medium]"
    })

    Placement.adapter_opts(config, {:codex, identity_name, "testhost"})
    assert discrepancy_count(db) == 1

    write_containment_manifest(canonical_base, "default", "workdir")
    Archetypes.load!(canonical_base)
    Placement.adapter_opts(config, {:codex, identity_name, "testhost"})
    assert discrepancy_count(db) == 2
  end

  test "posture edit regenerates home while harvesting credentials and preserving work", %{
    base_dir: base_dir,
    db: db
  } do
    canonical_base = canonical(base_dir)
    auth_dir = Path.join([canonical_base, "auth", "codex"])
    File.mkdir_p!(auth_dir)
    auth_path = Path.join(auth_dir, "auth.json")
    File.write!(auth_path, "old")

    config = %{
      base_dir: canonical_base,
      cwd: "/work",
      cli_bin: "/bin",
      default_model: "fable",
      db: db
    }

    home = Placement.deliver_home(config, {:codex, "default", "testhost"})
    nested = Path.join(home, "sessions/state.json")
    File.mkdir_p!(Path.dirname(nested))
    File.write!(nested, "memory")
    home_auth = Path.join(home, "auth.json")
    File.rm!(home_auth)
    File.write!(home_auth, "rotated")
    work_file = Path.join([canonical_base, "work", "session", "artifact"])
    File.mkdir_p!(Path.dirname(work_file))
    File.write!(work_file, "durable")

    write_containment_manifest(canonical_base, "default", "workdir")
    Archetypes.load!(canonical_base)

    opts =
      config
      |> Map.put(:sh, fn _ -> {"", 0} end)
      |> Placement.adapter_opts({:codex, "default", "testhost"})

    assert opts[:contained]
    refute File.exists?(nested)
    assert File.read!(auth_path) == "rotated"
    assert File.read!(work_file) == "durable"
  end

  test "adapter lineage marker roundtrips arbitrary identity text", %{base_dir: base_dir} do
    archetypes_dir = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(archetypes_dir)
    identity_name = "name with space:/@$('<é"
    File.write!(Path.join(archetypes_dir, "spaced.toml"), ~s(name = "#{identity_name}"\n))
    Archetypes.load!(base_dir)

    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin", default_model: "fable"}
    opts = Placement.adapter_opts(config, {:codex, identity_name, "testhost"})

    {"TIGHTBEAM_LINEAGE", "tb1-" <> encoded} =
      Enum.find(opts[:env], fn {key, _value} -> key == "TIGHTBEAM_LINEAGE" end)

    assert Base.url_decode64!(encoded, padding: false) == "#{identity_name}@testhost"
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

    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin", default_model: "fable"}

    assert Placement.deliver_home(config, {:codex, "default", "worker"}, sh: sh) ==
             "/remote/tb/homes/default/codex"

    commands = collect_commands([])

    assert [stamp, wipe, rsync, auth] = commands

    assert stamp == [
             "ssh",
             "-o",
             "BatchMode=yes",
             "-o",
             "ConnectTimeout=5",
             "worker",
             "cat",
             "/remote/tb/homes/default/codex/.tightbeam-manifest"
           ]

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

    assert Enum.take(auth, 8) == [
             "ssh",
             "-o",
             "BatchMode=yes",
             "-o",
             "ConnectTimeout=5",
             "worker",
             "sh",
             "-c"
           ]

    assert List.last(auth) =~ "/remote/tb/auth/codex\"/*"
    assert List.last(auth) =~ "ln -s"

    staged_home = Path.join([base_dir, "staging", "worker", "homes", "default", "codex"])
    assert Enum.sort(File.ls!(staged_home)) == [".tightbeam-manifest", "AGENTS.md", "skills"]

    # Baseline skills come from the substrate's shipped priv, never the org
    # library replica.
    assert staged_home
           |> Path.join("skills/tightbeam-assimilate")
           |> File.read_link!() ==
             Application.app_dir(:tightbeam, "priv/skills/tightbeam-assimilate")

    refute File.exists?(Path.join(staged_home, "auth.json"))
  end

  test "deliver_home projects the provider-id default Claude model", %{base_dir: base_dir} do
    config = %{
      base_dir: base_dir,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "claude-fable-5"
    }

    settings =
      config
      |> Placement.deliver_home({:claude, "default", "testhost"})
      |> Path.join("settings.json")
      |> File.read!()
      |> JSON.decode!()

    assert settings == %{"model" => "claude-fable-5"}
  end

  test "deliver_home lets the archetype default model override the org default", %{
    base_dir: base_dir
  } do
    manifests = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)

    File.write!(Path.join(manifests, "coder.toml"), """
    name = "coder"
    where = ["testhost"]

    [defaults]
    model = "claude-sonnet-4-6"
    """)

    Archetypes.load!(base_dir)

    config = %{
      base_dir: base_dir,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "claude-fable-5"
    }

    settings =
      config
      |> Placement.deliver_home({:claude, "coder", "testhost"})
      |> Path.join("settings.json")
      |> File.read!()
      |> JSON.decode!()

    assert settings == %{"model" => "claude-sonnet-4-6"}
  end

  test "deliver_home projects shared gate hooks for claude and codex while guidance stays law-free",
       %{
         base_dir: base_dir
       } do
    config = %{
      base_dir: base_dir,
      cwd: "/work",
      cli_bin: "/local/bin",
      default_model: "claude-fable-5"
    }

    lawless_codex_home = Placement.deliver_home(config, {:codex, "default", "testhost"})
    lawless_agents = File.read!(Path.join(lawless_codex_home, "AGENTS.md"))
    lawless_manifest = File.read!(Path.join(lawless_codex_home, ".tightbeam-manifest"))
    refute File.exists?(Path.join(lawless_codex_home, "hooks.json"))

    install_statute(base_dir)
    Rails.load!(base_dir)

    claude_home = Placement.deliver_home(config, {:claude, "default", "testhost"})
    codex_home = Placement.deliver_home(config, {:codex, "default", "testhost"})

    assert claude_home
           |> Path.join("settings.json")
           |> File.read!()
           |> JSON.decode!() ==
             Map.merge(Rails.hook_settings(), %{"model" => "claude-fable-5"})

    refute claude_home |> Path.join("settings.json") |> File.read!() =~ "tightbeam-probe"

    expected_codex =
      update_in(Rails.hook_settings(), ["hooks", "PreToolUse"], &(&1 ++ [Rails.probe_entry()]))

    assert codex_home |> Path.join("hooks.json") |> File.read!() == JSON.encode!(expected_codex)

    assert %{"hooks" => %{"PreToolUse" => [org_entry, probe_entry]}} =
             codex_home |> Path.join("hooks.json") |> File.read!() |> JSON.decode!()

    assert org_entry["matcher"] == "Bash"
    assert probe_entry == Rails.probe_entry()
    refute File.exists?(Path.join(codex_home, "settings.json"))

    # THE INVARIANT (bible §rails): rails never add guidance — the
    # instruction files are byte-identical to a lawless org's, and no
    # statute text exists anywhere a model reads standing context.
    archetype = Tightbeam.Archetypes.get("default")

    assert claude_home |> Path.join("CLAUDE.md") |> File.read!() ==
             Tightbeam.Archetypes.guidance(archetype)

    assert codex_home |> Path.join("AGENTS.md") |> File.read!() ==
             Tightbeam.Archetypes.guidance(archetype)

    assert codex_home |> Path.join("AGENTS.md") |> File.read!() == lawless_agents

    refute claude_home |> Path.join("CLAUDE.md") |> File.read!() =~ "no-history-rewrites"

    File.rm_rf!(Path.join([base_dir, "identity", "rails"]))
    Rails.load!(base_dir)
    Placement.deliver_home(config, {:codex, "default", "testhost"})
    assert File.read!(Path.join(codex_home, ".tightbeam-manifest")) == lawless_manifest
    refute File.exists?(Path.join(codex_home, "hooks.json"))
  end

  test "deliver_home preserves the manifest and nested state with zero statutes", %{
    base_dir: base_dir
  } do
    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin", default_model: "fable"}
    home = Placement.deliver_home(config, {:codex, "default", "testhost"})
    stamp_path = Path.join(home, ".tightbeam-manifest")
    stamp_before = File.read!(stamp_path)
    marker = Path.join([home, "sessions", "nested-marker"])
    File.mkdir_p!(Path.dirname(marker))
    File.write!(marker, "keep")

    assert Placement.deliver_home(config, {:codex, "default", "testhost"}) == home
    assert File.read!(stamp_path) == stamp_before
    assert File.read!(marker) == "keep"
    refute File.exists?(Path.join(home, "settings.json"))
    refute File.exists?(Path.join(home, "hooks.json"))
  end

  test "statute content changes codex projection manifest bytes", %{base_dir: base_dir} do
    install_statute(base_dir, "First refusal text.")
    Rails.load!(base_dir)
    first_hooks = codex_hooks_bytes()

    install_statute(base_dir, "Changed refusal text.")
    Rails.load!(base_dir)
    second_hooks = codex_hooks_bytes()

    spec = %{
      harness: :codex,
      archetype: "default",
      base_archetype: "default",
      parent_source: nil,
      guidance: "guidance",
      skills: []
    }

    refute Homes.manifest_bytes(Map.put(spec, :extra_files, %{"hooks.json" => first_hooks})) ==
             Homes.manifest_bytes(Map.put(spec, :extra_files, %{"hooks.json" => second_hooks}))
  end

  test "parent manifest file-byte changes are recorded and regenerate the home", %{
    base_dir: base_dir
  } do
    manifests = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)
    path = Path.join(manifests, "coder.toml")
    File.write!(path, "name = \"coder\"\n")
    Archetypes.load!(base_dir)
    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin", default_model: "fable"}
    home = Placement.deliver_home(config, {:codex, "coder", "testhost"})
    first = home |> Path.join(".tightbeam-manifest") |> File.read!() |> JSON.decode!()
    marker = Path.join(home, "nested-marker")
    File.write!(marker, "old body")

    File.write!(path, "name = \"coder\"\n# changed bytes\n")
    Archetypes.load!(base_dir)
    Placement.deliver_home(config, {:codex, "coder", "testhost"})
    second = home |> Path.join(".tightbeam-manifest") |> File.read!() |> JSON.decode!()

    assert first["parent_manifest"]["file"] == "identity/archetypes/coder.toml"
    refute first["parent_manifest"]["sha256"] == second["parent_manifest"]["sha256"]
    refute File.exists?(marker)
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

  test "push_skill syncs every remote replica and degrades per host", %{base_dir: base_dir} do
    Application.put_env(:tightbeam, :hosts, %{
      "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: nil},
      "flaky" => %{ssh: "flaky", base_dir: "/r2", cli_bin: nil}
    })

    parent = self()

    sh = fn command ->
      send(parent, {:command, command})

      if Enum.at(command, 5) == "flaky" or List.last(command) =~ "flaky:",
        do: {"boom", 255},
        else: {"", 0}
    end

    config = %{base_dir: base_dir}
    results = Placement.push_skill(config, "swift", :put, sh: sh)
    assert results["worker"] == "ok"
    assert results["flaky"] =~ "error"

    assert Placement.push_skill(config, "swift", :rm, sh: sh)["worker"] == "ok"

    commands = collect_commands([])

    assert Enum.any?(commands, fn c ->
             "rsync" in c and List.last(c) == "worker:/remote/tb/identity/skills/" and
               "--delete" in c
           end)

    assert Enum.any?(commands, fn c ->
             "rm" in c and List.last(c) == "/remote/tb/identity/skills/swift"
           end)
  end

  test "hosts.json registry merges under env config and register_host records", %{} do
    base = Path.join(System.tmp_dir!(), "tb-reg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    assert {:ok, entry} =
             Placement.register_host(base, "work-1", %{
               ssh: "work-1.example",
               base_dir: "/home/u/.tightbeam"
             })

    assert entry.ssh == "work-1.example"

    hosts = Placement.hosts(base)
    assert hosts["work-1"].base_dir == "/home/u/.tightbeam"
    assert hosts["testhost"].ssh == nil

    # env config overrides the registry entry-for-entry
    Application.put_env(:tightbeam, :hosts, %{
      "work-1" => %{ssh: "override", base_dir: "/o", cli_bin: nil}
    })

    on_exit(fn -> Application.delete_env(:tightbeam, :hosts) end)
    assert Placement.hosts(base)["work-1"].ssh == "override"

    # re-register updates in place
    assert {:ok, _} = Placement.register_host(base, "work-1", %{ssh: "w2", base_dir: "/z"})
    Application.delete_env(:tightbeam, :hosts)
    assert Placement.hosts(base)["work-1"].ssh == "w2"
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

  defp write_containment_manifest(base_dir, name, fs) do
    dir = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "#{name}.toml"), """
    name = "#{name}"

    [containment]
    fs = "#{fs}"
    network = "open"
    """)
  end

  defp discrepancy_count(db) do
    db
    |> EventLog.lifecycle_events()
    |> Enum.count(&(&1.kind == "override_discrepancy"))
  end

  defp canonical(path) do
    {resolved, 0} = System.cmd("/bin/realpath", [path])
    String.trim(resolved)
  end
end
