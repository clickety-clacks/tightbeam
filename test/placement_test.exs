defmodule Tightbeam.PlacementTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{Archetypes, DB, EventLog, Org, Placement, Rails}

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
    old_model_pins = Application.get_env(:tightbeam, :model_pins)
    Application.delete_env(:tightbeam, :model_pins)

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Tightbeam.Rails)

      if old_hosts,
        do: Application.put_env(:tightbeam, :hosts, old_hosts),
        else: Application.delete_env(:tightbeam, :hosts)

      if old_url,
        do: Application.put_env(:tightbeam, :advertised_url, old_url),
        else: Application.delete_env(:tightbeam, :advertised_url)

      if old_model_pins,
        do: Application.put_env(:tightbeam, :model_pins, old_model_pins),
        else: Application.delete_env(:tightbeam, :model_pins)
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

    assert_raise ArgumentError, ~r/no active session carries identity/, fn ->
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

    assert :ok =
             Placement.move_workdir(%{base_dir: base_dir}, "session-1", "old-local", "new-local")

    assert File.read!(Path.join(test_workdir(new_base, "session-1"), "memory.md")) == "remember"
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

    assert [probe, rsync] = collect_commands([])

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

    assert [probe, pull, mkdir, push] = collect_commands([])

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
    refute File.exists?(stage)
  end

  test "adapter_opts preserves the pre-placement local shape", %{base_dir: base_dir} do
    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin", default_model: "fable"}
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
             "TIGHTBEAM_TOKEN=tbc_test",
             "PATH=/srv/tb/bin:$PATH",
             "/srv/tb/adapters/node_modules/.bin/codex-acp"
           ]

    assert opts[:home] == remote_home
    assert opts[:stderr_path] == Path.join(base_dir, "adapter-codex:default@worker.stderr.log")
    assert opts[:env] == []

    claude_opts = Placement.adapter_opts(config, {:claude, "default", "worker"})

    assert "CLAUDE_CODE_OAUTH_TOKEN=$(cat /srv/tb/auth/claude/oauth-token 2>/dev/null)" in claude_opts[
             :cmd
           ]

    # Harness-scoped: codex remote env never carries claude's token expansion.
    refute Enum.any?(opts[:cmd], &String.contains?(&1, "CLAUDE_CODE_OAUTH_TOKEN"))
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
    assert [stamp, wipe, rsync, lib_mkdir, lib_rsync, lib_rsync_h, lib_rsync_2, auth] = commands

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

    # Library replica catch-up: the satellite's replica receives every
    # elected skill so the staged home's links resolve on arrival.
    assert lib_mkdir == [
             "ssh",
             "-o",
             "BatchMode=yes",
             "-o",
             "ConnectTimeout=5",
             "worker",
             "mkdir",
             "-p",
             "/remote/tb/identity/skills"
           ]

    assert lib_rsync == [
             "rsync",
             "-a",
             "-e",
             "ssh -o BatchMode=yes -o ConnectTimeout=5",
             Path.join([base_dir, "identity", "skills", "tightbeam-assimilate"]),
             "worker:/remote/tb/identity/skills/"
           ]

    assert Enum.at(lib_rsync_h, -2) =~ "tightbeam-harnesses"
    assert List.last(lib_rsync_2) == "worker:/remote/tb/identity/skills/"
    assert Enum.at(lib_rsync_2, -2) =~ "tightbeam-skills"

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

    # The staged link dangles HERE and resolves on the satellite — it
    # points into the satellite's replica, not the gateway's library.
    assert staged_home
           |> Path.join("skills/tightbeam-assimilate")
           |> File.read_link!() == "/remote/tb/identity/skills/tightbeam-assimilate"

    refute File.exists?(Path.join(staged_home, "auth.json"))
  end

  test "deliver_home pins the default Claude model without statutes", %{base_dir: base_dir} do
    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin", default_model: "fable"}

    settings =
      config
      |> Placement.deliver_home({:claude, "default", "testhost"})
      |> Path.join("settings.json")
      |> File.read!()
      |> JSON.decode!()

    assert settings == %{"model" => "claude-fable-5[1m]"}
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
    model = "sonnet"
    """)

    Archetypes.load!(base_dir)

    Application.put_env(:tightbeam, :model_pins, %{
      "fable" => "claude-fable-5[1m]",
      "sonnet" => "claude-sonnet-4-6"
    })

    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin", default_model: "fable"}

    settings =
      config
      |> Placement.deliver_home({:claude, "coder", "testhost"})
      |> Path.join("settings.json")
      |> File.read!()
      |> JSON.decode!()

    assert settings == %{"model" => "claude-sonnet-4-6"}
  end

  test "deliver_home projects gate hooks for local Claude only and guidance stays law-free", %{
    base_dir: base_dir
  } do
    rails_dir = Path.join([base_dir, "identity", "rails"])
    File.mkdir_p!(rails_dir)

    File.write!(Path.join(rails_dir, "law.toml"), """
    [[statute]]
    name = "no-history-rewrites"
    on = "tool-call"
    tool = "Bash"
    pattern = "git (reset|stash|rebase)"
    text = "History-rewriting git commands are forbidden here."
    """)

    Rails.load!(base_dir)
    config = %{base_dir: base_dir, cwd: "/work", cli_bin: "/local/bin", default_model: "fable"}

    claude_home = Placement.deliver_home(config, {:claude, "default", "testhost"})
    codex_home = Placement.deliver_home(config, {:codex, "default", "testhost"})

    assert claude_home
           |> Path.join("settings.json")
           |> File.read!()
           |> JSON.decode!() ==
             Map.merge(Rails.claude_settings(), %{"model" => "claude-fable-5[1m]"})

    # THE INVARIANT (bible §rails): rails never add guidance — the
    # instruction files are byte-identical to a lawless org's, and no
    # statute text exists anywhere a model reads standing context.
    archetype = Tightbeam.Archetypes.get("default")

    assert claude_home |> Path.join("CLAUDE.md") |> File.read!() ==
             Tightbeam.Archetypes.guidance(archetype)

    assert codex_home |> Path.join("AGENTS.md") |> File.read!() ==
             Tightbeam.Archetypes.guidance(archetype)

    refute claude_home |> Path.join("CLAUDE.md") |> File.read!() =~ "no-history-rewrites"
    refute File.exists?(Path.join(codex_home, "settings.json"))
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
end
