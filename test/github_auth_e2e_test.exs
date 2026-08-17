defmodule Tightbeam.GithubAuthE2ETest do
  use Tightbeam.TestCase, async: false

  alias Mix.Tasks.Tightbeam.Doctor

  alias Tightbeam.{
    Archetypes,
    DB,
    EventLog,
    GithubAuth,
    Model,
    Org,
    Placement,
    Rails
  }

  @cli_dir Path.expand("../cli", __DIR__)
  @e2e_target_dir Path.join(@cli_dir, "target/github-auth-e2e")
  @remote "https://github.com/example/project.git"
  @secret "ghp_fixture_NEVER_PRINT"

  setup_all do
    {output, status} =
      System.cmd("cargo", ["build", "--release"],
        cd: @cli_dir,
        env: [{"CARGO_TARGET_DIR", @e2e_target_dir}],
        stderr_to_stdout: true
      )

    if status != 0 do
      flunk("isolated real CLI build failed (exit #{status}):\n#{output}")
    end

    cli = Path.join(@e2e_target_dir, "release/tightbeam")

    unless File.regular?(cli) do
      flunk("isolated real CLI build did not produce #{cli}")
    end

    {:ok, cli: cli}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "github-auth-e2e-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    local = Path.join(root, "local")
    satellite = Path.join(root, "satellite")
    ambient = Path.join(root, "ambient-gh")
    home = Path.join(root, "home")
    log = Path.join(root, "fixture.log")

    for dir <- [bin, local, satellite, ambient, home], do: File.mkdir_p!(dir)
    File.write!(log, "")
    File.write!(Path.join(ambient, "hosts.yml"), "ambient authorization must never be read\n")
    write_executable!(Path.join(bin, "gh"), gh_fixture())
    write_executable!(Path.join(bin, "git"), git_fixture())

    File.write!(Path.join(local, "gateway.json"), JSON.encode!(%{cliToken: "fixture"}))
    Archetypes.load!(local)
    Rails.load!(local)
    ensure_identity!(local)

    db = :"github_auth_e2e_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Org.ensure_schema(db)
    :ok = EventLog.ensure_schema(db)
    :ok = Placement.ensure_schema(db)

    old_url = Application.get_env(:tightbeam, :advertised_url)
    Application.put_env(:tightbeam, :advertised_url, "http://fixture-gateway:4000")

    on_exit(fn ->
      File.rm_rf!(root)
      :persistent_term.erase(Tightbeam.Rails)

      if old_url,
        do: Application.put_env(:tightbeam, :advertised_url, old_url),
        else: Application.delete_env(:tightbeam, :advertised_url)
    end)

    %{
      root: root,
      bin: bin,
      local: local,
      satellite: satellite,
      ambient: ambient,
      home: home,
      log: log,
      db: db
    }
  end

  test "real CLI banks device auth privately and the same bank probes live", ctx do
    {stdout, 0} =
      run_cli(
        ctx,
        ctx.local,
        "live",
        "local-fixture",
        [
          "onboard",
          "github",
          "--hostname",
          "github.com",
          "--remote",
          @remote
        ],
        stderr_to_stdout: false
      )

    result = JSON.decode!(stdout)
    config_dir = GithubAuth.config_dir(ctx.local)
    metadata_path = result["metadata"]
    hosts_path = Path.join(config_dir, "hosts.yml")

    assert result["status"] == "onboarded"
    assert result["storage"] == "file"
    assert result["configDir"] == config_dir
    assert result["gitReady"]

    assert_mode(Path.join(ctx.local, "auth"), 0o700)
    assert_mode(Path.join([ctx.local, "auth", "github"]), 0o700)
    assert_mode(config_dir, 0o700)
    assert_mode(hosts_path, 0o600)
    assert_mode(metadata_path, 0o600)

    metadata = File.read!(metadata_path)
    refute metadata =~ @secret
    refute metadata =~ config_dir
    assert metadata =~ ~s("storage": "file")
    assert metadata =~ ~s("status": "live")

    calls = fixture_calls(ctx)
    assert calls != []
    assert Enum.all?(calls, fn {_program, dir, _args} -> dir == config_dir end)

    login =
      Enum.find(calls, fn {program, _dir, args} -> program == "gh" and args =~ "auth login" end)

    assert {"gh", ^config_dir, login_args} = login

    assert login_args ==
             "auth login --hostname github.com --web --git-protocol https --insecure-storage"

    refute login_args =~ "--with-token"
    refute String.downcase(login_args) =~ "pat"

    assert {:ok, github_status} =
             with_fixture_env(ctx, ctx.local, "live", "local-fixture", fn ->
               GithubAuth.probe(ctx.local, "github.com", @remote)
             end)

    assert github_status.gh_path == Path.join(ctx.bin, "gh")
    assert github_status.storage == "file"
    assert github_status.account == "fixture-user"
    assert github_status.git_protocol == "https"

    {guard_output, 0} =
      run_cli(ctx, ctx.local, "live", "local-fixture", ["github-auth-check"],
        input: tool_call("git clone #{@remote}")
      )

    assert guard_output == ""

    assert Enum.any?(fixture_calls(ctx), fn {program, dir, args} ->
             program == "git" and dir == config_dir and
               args == "ls-remote #{@remote} HEAD"
           end)
  end

  test "satellite cannot borrow local or ambient auth; guard refuses before execution", ctx do
    {_stdout, 0} =
      run_cli(ctx, ctx.local, "live", "local-fixture", ["onboard", "github"],
        stderr_to_stdout: false
      )

    File.write!(ctx.log, "")

    {refusal, 1} =
      run_cli(ctx, ctx.satellite, "live", "satellite-fixture", ["github-auth-check"],
        input: tool_call("git clone #{@remote}")
      )

    satellite_dir = GithubAuth.config_dir(ctx.satellite)
    assert refusal =~ "from host satellite-fixture for github.com"
    assert refusal =~ "failed phase gh auth status"
    assert refusal =~ "needs_onboarding"

    assert refusal =~
             "Run: tightbeam onboard github --hostname github.com --remote #{@remote}"

    assert refusal =~ "Do not paste a PAT into an agent"
    refute refusal =~ @secret
    refute refusal =~ GithubAuth.config_dir(ctx.local)
    refute refusal =~ ctx.ambient

    calls = fixture_calls(ctx)
    assert calls != []
    assert Enum.all?(calls, fn {_program, dir, _args} -> dir == satellite_dir end)
    refute Enum.any?(calls, fn {program, _dir, _args} -> program == "git" end)

    File.write!(ctx.log, "")

    prose =
      tool_call(
        "tightbeam assign --subject work --brief 'Read the gh issue thread at\nhttps://github.com/example/project and summarize'",
        "A description that says git clone https://github.com/example/project.git"
      )

    assert {"", 0} =
             run_cli(
               ctx,
               ctx.satellite,
               "explode",
               "satellite-fixture",
               [
                 "github-auth-check"
               ],
               input: prose
             )

    assert File.read!(ctx.log) == ""

    File.write!(ctx.log, "")

    {named_refusal, 1} =
      run_cli(ctx, ctx.satellite, "live", "satellite-fixture", ["github-auth-check"],
        input: tool_call("git fetch origin")
      )

    assert named_refusal =~ "from host satellite-fixture for github.com"
    assert named_refusal =~ "--remote #{@remote}"

    assert Enum.any?(fixture_calls(ctx), fn {program, dir, args} ->
             program == "git" and dir == satellite_dir and
               args == "config --get remote.origin.url"
           end)

    File.write!(ctx.log, "")

    {nested_refusal, 1} =
      run_cli(ctx, ctx.satellite, "live", "satellite-fixture", ["github-auth-check"],
        input: tool_call("sh -c \"git clone #{@remote}\"")
      )

    assert nested_refusal =~ "from host satellite-fixture for github.com"

    bypasses = [
      {"git fetch https://alice@github.com/example/project.git",
       "https://alice@github.com/example/project.git"},
      {"git fetch https://x-access-token:#{@secret}@github.com/example/project.git",
       "https://[redacted]@github.com/example/project.git"},
      {"git clone https://GitHub.com/example/project.git",
       "https://GitHub.com/example/project.git"},
      {"git push -o foo origin", @remote},
      {"> /tmp/clone.log git clone #{@remote}", @remote},
      {"git submodule update --init", @remote}
    ]

    for {command, repaired_remote} <- bypasses do
      File.write!(ctx.log, "")

      {bypass_refusal, 1} =
        run_cli(ctx, ctx.satellite, "live", "satellite-fixture", ["github-auth-check"],
          input: tool_call(command)
        )

      assert bypass_refusal =~ "from host satellite-fixture for github.com"
      assert bypass_refusal =~ "--remote #{repaired_remote}"
      refute bypass_refusal =~ @secret

      calls = fixture_calls(ctx)

      refute Enum.any?(calls, fn {program, _dir, args} ->
               program == "git" and String.starts_with?(args, "ls-remote ")
             end)

      refute File.read!(ctx.log) =~ @secret
    end

    File.write!(ctx.log, "")

    heredoc = "cat <<'EOF' > /tmp/github-note\ngit clone #{@remote}\nEOF\n"

    assert {"", 0} =
             run_cli(
               ctx,
               ctx.satellite,
               "explode",
               "satellite-fixture",
               [
                 "github-auth-check"
               ],
               input: tool_call(heredoc)
             )

    assert File.read!(ctx.log) == ""
  end

  test "real Rust and Elixir probes agree, redact, and feed secret-free doctor output", ctx do
    {_stdout, 0} =
      run_cli(ctx, ctx.local, "live", "local-fixture", ["onboard", "github"],
        stderr_to_stdout: false
      )

    {git_refusal, 1} =
      run_cli(ctx, ctx.local, "git_fail", "local-fixture", ["github-auth-check"],
        input: tool_call("git fetch #{@remote}")
      )

    assert git_refusal =~ "from host local-fixture for github.com"
    assert git_refusal =~ "failed phase git ls-remote"
    assert git_refusal =~ "git_unready"
    refute git_refusal =~ @secret

    {provider_failure, 1} =
      run_cli(ctx, ctx.local, "api_auth", "local-fixture", ["onboard", "github"], [])

    assert provider_failure =~ "provider_error=[redacted]" or
             provider_failure =~ "invalid oauth token [redacted]"

    refute provider_failure =~ @secret

    credentialed_remote =
      "https://user:#{@secret}@github.com/example/project.git"

    {remote_failure, 1} =
      run_cli(
        ctx,
        ctx.local,
        "git_fail",
        "local-fixture",
        ["onboard", "github", "--remote", credentialed_remote],
        []
      )

    assert remote_failure =~ "https://[redacted]@github.com/example/project.git"
    assert remote_failure =~ "provider_error=[redacted]"
    refute remote_failure =~ @secret

    for {mode, detail, expected} <- [
          {"api_auth", "invalid oauth token", :needs_onboarding},
          {"api_scope", "missing required scope", :insufficient_scope},
          {"api_unknown", "connection reset by peer", :unknown}
        ] do
      {rust_refusal, 1} =
        run_cli(ctx, ctx.local, mode, "local-fixture", ["github-auth-check"],
          input: tool_call("gh issue list --repo example/project")
        )

      assert rust_refusal =~ "failed phase gh api"
      assert rust_refusal =~ "#{expected}:"
      refute rust_refusal =~ @secret
      assert GithubAuth.classify_api_failure(detail) == expected

      assert {:error, ^expected, elixir_detail} =
               with_fixture_env(ctx, ctx.local, mode, "local-fixture", fn ->
                 GithubAuth.probe(ctx.local, "github.com", @remote)
               end)

      refute elixir_detail =~ @secret
    end

    {1, report} =
      with_fixture_env(ctx, ctx.local, "git_fail", "local-fixture", fn ->
        Doctor.evaluate(doctor_catalog(),
          base_dir: ctx.local,
          default_model: Model.new("claude-live", effort: "medium"),
          default_harness: :claude,
          advertised_url: "https://tightbeam.example",
          hosts: %{"local-fixture" => %{ssh: nil, base_dir: ctx.local, cli_bin: nil}},
          local_host_name: "local-fixture",
          cli_bin: Path.join(ctx.local, "bin"),
          credential_state: fn _provider -> :live end,
          harness_binary_probe: fn harness, _cli_bin ->
            {:ok, %{bin: "/fixture/#{harness}", version: "#{harness} 1.0"}}
          end,
          github_remote_url: credentialed_remote
        )
      end)

    github_check = Enum.find(report.checks, &(&1.name == "github_auth:github.com"))
    refute github_check.ok
    assert github_check.detail =~ "git_unready"
    assert github_check.detail =~ "host local-fixture"
    assert github_check.detail =~ "gh #{Path.join(ctx.bin, "gh")}"
    assert github_check.detail =~ "storage file"
    assert report.github.host == "local-fixture"
    assert report.github.gh_path == Path.join(ctx.bin, "gh")
    assert report.github.state == "git_unready"
    assert report.github.storage == "file"

    for rendered <- [Doctor.format(report, :human), Doctor.format(report, :json)] do
      refute rendered =~ @secret
      refute rendered =~ GithubAuth.config_dir(ctx.local)
      assert rendered =~ "[redacted]"
    end

    metadata =
      ctx.local
      |> Path.join("auth/github/github.com/.tightbeam/capability.json")
      |> File.read!()

    refute metadata =~ @secret
    refute metadata =~ GithubAuth.config_dir(ctx.local)
  end

  test "placement projects the host-local bank into local and satellite agents", ctx do
    config = %{
      base_dir: ctx.local,
      db: ctx.db,
      cwd: ctx.root,
      cli_bin: Path.join(ctx.local, "bin"),
      default_model: Model.new("fable"),
      sh: fn command ->
        if Enum.any?(command, &String.contains?(&1, "credential-harvest")) and
             Enum.any?(command, &String.contains?(&1, "cat")),
           do: {"", 42},
           else: {"", 0}
      end
    }

    local_opts = Placement.adapter_opts(config, {:codex, "default", "testhost"})
    assert {"GH_CONFIG_DIR", GithubAuth.config_dir(ctx.local)} in local_opts[:env]
    assert {"TIGHTBEAM_MACHINE", "testhost"} in local_opts[:env]

    assert {:ok, _} =
             Placement.register_host(ctx.db, "worker", %{
               ssh: "fixture@worker",
               base_dir: ctx.satellite,
               cli_bin: Path.join(ctx.satellite, "bin")
             })

    remote_opts = Placement.adapter_opts(config, {:codex, "default", "worker"})

    assert "TIGHTBEAM_MACHINE=worker" in remote_opts[:cmd]
    assert "GH_CONFIG_DIR='#{GithubAuth.config_dir(ctx.satellite)}'" in remote_opts[:cmd]

    projected = inspect([local_opts[:env], remote_opts[:cmd]])
    refute projected =~ @secret
    refute projected =~ ctx.ambient
  end

  @tag timeout: 90_000
  test "timeout is unknown in both probes and never authorizes work", ctx do
    {_stdout, 0} =
      run_cli(ctx, ctx.local, "live", "local-fixture", ["onboard", "github"],
        stderr_to_stdout: false
      )

    File.write!(ctx.log, "")

    {rust_refusal, 1} =
      run_cli(ctx, ctx.local, "timeout", "local-fixture", ["github-auth-check"],
        input: tool_call("gh pr list --repo example/project")
      )

    assert rust_refusal =~ "failed phase gh auth status"
    assert rust_refusal =~ "unknown"
    assert rust_refusal =~ "timed out after 15s"
    refute rust_refusal =~ @secret
    refute Enum.any?(fixture_calls(ctx), fn {program, _dir, _args} -> program == "git" end)

    assert {:error, :unknown, detail} =
             with_fixture_env(ctx, ctx.local, "timeout", "local-fixture", fn ->
               GithubAuth.probe(ctx.local, "github.com", @remote)
             end)

    assert detail =~ "timed out"
    refute detail =~ @secret

    # Task shutdown closes the port at 15s; let the 16s fixture child exit
    # before the suite-wide process leak audit runs.
    Process.sleep(1_500)
  end

  defp run_cli(ctx, base_dir, mode, machine, args, opts) do
    env = fixture_env(ctx, base_dir, mode, machine)
    stderr_to_stdout = Keyword.get(opts, :stderr_to_stdout, true)

    case Keyword.fetch(opts, :input) do
      {:ok, input} ->
        input_path =
          Path.join(ctx.root, "tool-call-#{System.unique_integer([:positive])}.json")

        File.write!(input_path, input)

        try do
          System.cmd(
            "/bin/sh",
            [
              "-c",
              ~S(exec "$@" < "$TB_GITHUB_E2E_INPUT"),
              "tightbeam-github-e2e",
              ctx.cli | args
            ],
            env: [{"TB_GITHUB_E2E_INPUT", input_path} | env],
            stderr_to_stdout: stderr_to_stdout
          )
        after
          File.rm!(input_path)
        end

      :error ->
        System.cmd(ctx.cli, args, env: env, stderr_to_stdout: stderr_to_stdout)
    end
  end

  defp with_fixture_env(ctx, base_dir, mode, machine, fun) do
    env = fixture_env(ctx, base_dir, mode, machine)
    previous = Map.new(env, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(env, fn {name, value} -> System.put_env(name, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp fixture_env(ctx, base_dir, mode, machine) do
    [
      {"PATH", "#{ctx.bin}:/usr/bin:/bin"},
      {"HOME", ctx.home},
      {"TIGHTBEAM_BASE_DIR", base_dir},
      {"TIGHTBEAM_MACHINE", machine},
      {"GH_CONFIG_DIR", ctx.ambient},
      {"GH_FIXTURE_MODE", mode},
      {"GH_FIXTURE_LOG", ctx.log},
      {"GH_FIXTURE_SECRET", @secret}
    ]
  end

  defp fixture_calls(ctx) do
    ctx.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [program, config_dir, args] = String.split(line, "|", parts: 3)
      {program, config_dir, args}
    end)
  end

  defp tool_call(command, description \\ nil) do
    tool_input = %{"command" => command}

    tool_input =
      if description, do: Map.put(tool_input, "description", description), else: tool_input

    JSON.encode!(%{"tool_name" => "Bash", "tool_input" => tool_input})
  end

  defp assert_mode(path, expected) do
    assert Bitwise.band(File.stat!(path).mode, 0o777) == expected,
           "expected #{path} mode #{Integer.to_string(expected, 8)}"
  end

  defp ensure_identity!(base_dir) do
    git_dir = Path.join([base_dir, "identity", ".git"])
    File.mkdir_p!(git_dir)
    File.write!(Path.join(git_dir, "HEAD"), "ref: refs/heads/main\n")
    File.write!(Path.join([base_dir, "identity", "README.md"]), "fixture identity\n")
  end

  defp doctor_catalog do
    {:ok,
     %{
       "claude" => [catalog_entry("claude-live", ["medium"])],
       "codex" => [catalog_entry("codex-live", ["high"])],
       "fixture" => [catalog_entry("fixture-model", [])]
     }}
  end

  defp catalog_entry(family, efforts) do
    %{
      family: family,
      context: nil,
      display_name: family,
      name: family,
      efforts: efforts,
      max_input_tokens: nil,
      capabilities: %{},
      provider: :anthropic
    }
  end

  defp write_executable!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp gh_fixture do
    ~S"""
    #!/bin/sh
    set -eu
    : "${GH_FIXTURE_LOG:?}"
    : "${GH_CONFIG_DIR:?}"
    mode="${GH_FIXTURE_MODE:-live}"
    secret="${GH_FIXTURE_SECRET:-ghp_fixture_secret}"
    printf 'gh|%s|%s\n' "$GH_CONFIG_DIR" "$*" >> "$GH_FIXTURE_LOG"

    if [ "$mode" = "explode" ]; then
      printf 'fixture gh must not have been called\n' >&2
      exit 99
    fi

    case "$1:$2" in
      auth:status)
        if [ "$mode" = "timeout" ]; then
          sleep 16
        fi
        if [ -f "$GH_CONFIG_DIR/hosts.yml" ]; then
          exit 0
        fi
        printf 'not logged into any accounts: %s\n' "$secret" >&2
        exit 1
        ;;
      auth:login)
        case " $* " in
          *" --with-token "*)
            printf 'token-stdin login is forbidden\n' >&2
            exit 97
            ;;
        esac
        mkdir -p "$GH_CONFIG_DIR"
        # Deliberately simulate a permissive provider-created file. Tightbeam,
        # not this fixture, must repair it before reporting success.
        umask 022
        printf 'github.com:\n  oauth_token: %s\n  user: fixture-user\n' "$secret" > "$GH_CONFIG_DIR/hosts.yml"
        chmod 644 "$GH_CONFIG_DIR/hosts.yml"
        exit 0
        ;;
      api:--hostname)
        case "$mode" in
          api_auth)
            printf 'invalid oauth token %s\n' "$secret" >&2
            exit 1
            ;;
          api_scope)
            printf 'missing required scope %s\n' "$secret" >&2
            exit 1
            ;;
          api_unknown)
            printf 'connection reset by peer %s\n' "$secret" >&2
            exit 1
            ;;
        esac
        printf 'fixture-user\n'
        exit 0
        ;;
      config:get)
        printf 'https\n'
        exit 0
        ;;
      *)
        printf 'unexpected gh fixture invocation: %s\n' "$*" >&2
        exit 98
        ;;
    esac
    """
  end

  defp git_fixture do
    ~S"""
    #!/bin/sh
    set -eu
    : "${GH_FIXTURE_LOG:?}"
    : "${GH_CONFIG_DIR:?}"
    mode="${GH_FIXTURE_MODE:-live}"
    secret="${GH_FIXTURE_SECRET:-ghp_fixture_secret}"
    printf 'git|%s|%s\n' "$GH_CONFIG_DIR" "$*" >> "$GH_FIXTURE_LOG"

    if [ "$*" = "config --get remote.origin.url" ]; then
      printf 'https://github.com/example/project.git\n'
      exit 0
    fi

    case "$*" in
      "config --get-regexp "*|"config --file .gitmodules --get-regexp "*)
        exit 1
        ;;
    esac

    if [ "$mode" = "git_fail" ]; then
      printf 'provider_error=%s refused for %s\n' "$secret" "$2" >&2
      exit 128
    fi

    printf '0123456789abcdef\tHEAD\n'
    """
  end
end
