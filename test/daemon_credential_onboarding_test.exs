defmodule Tightbeam.DaemonCredentialOnboardingTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Archetypes, Credentials, DB, Gateway, Placement, Rules}
  alias Tightbeam.Wire.Router

  @release_binary Path.expand("../cli/target/release/tightbeam", __DIR__)
  @cli_token "tbc_daemon_credential_fixture"

  setup do
    base =
      Path.join(System.tmp_dir!(), "tb-daemon-credential-#{System.unique_integer([:positive])}")

    credentials_directory = Path.join(base, "daemon-credentials")
    File.mkdir_p!(credentials_directory)
    File.chmod!(credentials_directory, 0o700)
    source = Path.join(credentials_directory, "opencode-go-api-key")
    File.write!(source, "fake-daemon-key\n")
    File.chmod!(source, 0o600)

    db = :"daemon_credential_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    ensure_all_schemas(db)

    host = Placement.local_host_name()
    register_hosts(db, %{host => %{ssh: nil, base_dir: base, cli_bin: nil}})

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES (?1, 1, ?2)",
        ["daemon-admin", System.system_time(:second)]
      )

    start_supervised!(
      {Credentials,
       name: Credentials,
       base_dir: base,
       credentials_directory: credentials_directory,
       machine: host}
    )

    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, db: db, host: host}
  end

  test "gateway keeps credential bytes and staging path off the wire", ctx do
    onboard =
      Gateway.handlers(%{
        base_dir: ctx.base,
        db: ctx.db,
        onboarding_lease_ms: 1_800_000
      })["onboard"]

    begin_call = %{
      origin: "user:daemon-admin",
      params: %{
        provider: "opencode-go",
        phase: "begin",
        kind: "apiKey",
        source: "daemonCredential"
      }
    }

    assert %{
             provider: :opencode_go,
             kind: "apiKey",
             status: "ready",
             lease_id: lease_id
           } = ready = onboard.(begin_call)

    refute Map.has_key?(ready, :staging_path)
    refute inspect(begin_call) =~ "fake-daemon-key"
    refute inspect(ready) =~ "fake-daemon-key"

    assert %{provider: :opencode_go, credential_kind: "apiKey", status: "onboarded"} =
             onboard.(%{
               origin: "user:daemon-admin",
               params: %{
                 provider: "opencode-go",
                 phase: "finish",
                 kind: "apiKey",
                 lease_id: lease_id
               }
             })

    assert JSON.decode!(File.read!(Path.join([ctx.base, "auth", "pi", "auth.json"]))) == %{
             "opencode-go" => %{"type" => "api_key", "key" => "fake-daemon-key"}
           }
  end

  test "release CLI delivers a fake daemon credential without leaking it", ctx do
    unless File.regular?(@release_binary) do
      flunk("release CLI missing at #{@release_binary}; run cargo build --release in cli/")
    end

    Archetypes.load!(ctx.base)

    handlers =
      Gateway.handlers(%{
        base_dir: ctx.base,
        db: ctx.db,
        onboarding_lease_ms: 1_800_000
      })

    Rules.load!(ctx.base, Map.keys(handlers))

    router_opts =
      Router.init(
        db: ctx.db,
        base_dir: ctx.base,
        handlers: handlers,
        cli_token: @cli_token,
        session_status: fn _ -> nil end
      )

    bandit =
      start_supervised!(
        {Bandit, plug: {Router, router_opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    workdir = Path.join(ctx.base, "work/cli")
    File.mkdir_p!(workdir)

    {output, exit} =
      System.cmd(
        @release_binary,
        [
          "onboard",
          "opencode-go",
          "--daemon-credential",
          "--as-user",
          "daemon-admin"
        ],
        cd: workdir,
        env: [
          {"TIGHTBEAM_BASE_DIR", ctx.base},
          {"TIGHTBEAM_URL", "http://127.0.0.1:#{port}"},
          {"TIGHTBEAM_TOKEN", @cli_token},
          {"TIGHTBEAM_MACHINE", ctx.host}
        ],
        stderr_to_stdout: true
      )

    assert exit == 0, "release CLI daemon onboarding failed (exit #{exit}):\n#{output}"
    assert JSON.decode!(output)["status"] == "onboarded"
    refute output =~ "fake-daemon-key"

    {:ok, rows} = DB.query(ctx.db, "SELECT payload FROM events")
    refute inspect(rows) =~ "fake-daemon-key"

    assert JSON.decode!(File.read!(Path.join([ctx.base, "auth", "pi", "auth.json"]))) == %{
             "opencode-go" => %{"type" => "api_key", "key" => "fake-daemon-key"}
           }
  end
end
