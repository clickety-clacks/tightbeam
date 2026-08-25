defmodule Tightbeam.LocalOpenAiOnboardingTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Archetypes,
    Credentials,
    DB,
    Devices,
    Gateway,
    Placement,
    Rules
  }

  alias Tightbeam.Wire.Router

  @spark_endpoint "https://spark.tailf064dc.ts.net/v1"
  @release_binary Path.expand("../cli/target/release/tightbeam", __DIR__)
  @cli_token "tbc_local_openai_live"

  setup do
    base = Path.join(System.tmp_dir!(), "tb-local-openai-#{System.unique_integer([:positive])}")
    db = :"local_openai_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Devices.ensure_schema(db)
    :ok = Placement.ensure_schema(db)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, db: db}
  end

  defp onboard_handlers(base, db) do
    Gateway.handlers(%{base_dir: base, db: db, onboarding_lease_ms: 1_800_000})["onboard"]
  end

  defp seed_admin(db, user_id \\ "local-admin") do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES (?1, 1, ?2)",
        [user_id, System.system_time(:second)]
      )
  end

  defp local_openai_bytes(endpoint, api_key \\ nil) do
    record =
      case api_key do
        nil -> %{"local-openai" => %{"endpoint" => endpoint}}
        key -> %{"local-openai" => %{"endpoint" => endpoint, "apiKey" => key}}
      end

    JSON.encode!(record)
  end

  describe "host-scoped local-openai persistence" do
    test "banks endpoint-only credentials under auth/pi-local", ctx do
      seed_admin(ctx.db)
      start_supervised!({Credentials, name: Credentials, base_dir: ctx.base, machine: "testhost"})

      onboard = onboard_handlers(ctx.base, ctx.db)

      call = %{
        origin: "user:local-admin",
        params: %{provider: "local-openai", phase: "begin", kind: "apiKey"}
      }

      assert %{
               provider: :local_openai,
               kind: "apiKey",
               status: "ready",
               staging_path: staging_path,
               lease_id: lease_id
             } = onboard.(call)

      File.write!(
        Path.join(staging_path, "local-openai.json"),
        local_openai_bytes(@spark_endpoint)
      )

      assert %{provider: :local_openai, credential_kind: "apiKey", status: "onboarded"} =
               onboard.(
                 call
                 |> put_in([:params, :phase], "finish")
                 |> put_in([:params, :lease_id], lease_id)
               )

      store = Path.join([ctx.base, "auth", "pi-local", "local-openai.json"])
      metadata_path = Path.join([ctx.base, "auth", "pi-local", ".tightbeam", "credential.json"])

      assert JSON.decode!(File.read!(store)) == %{
               "local-openai" => %{"endpoint" => @spark_endpoint}
             }

      assert File.stat!(store).mode |> Bitwise.band(0o777) == 0o600
      assert File.stat!(metadata_path).mode |> Bitwise.band(0o777) == 0o600

      metadata = metadata_path |> File.read!() |> JSON.decode!()
      assert metadata["provider"] == "local_openai"
      assert metadata["kind"] == "api_key"
      assert metadata["onboarded"] == true
      assert Credentials.status(:local_openai, Credentials) == :onboarded
      assert Credentials.kind(:local_openai, Credentials) == :api_key
    end

    test "banks endpoint plus optional apiKey", ctx do
      seed_admin(ctx.db)
      start_supervised!({Credentials, name: Credentials, base_dir: ctx.base, machine: "testhost"})

      onboard = onboard_handlers(ctx.base, ctx.db)

      call = %{
        origin: "user:local-admin",
        params: %{provider: "local-openai", phase: "begin", kind: "apiKey"}
      }

      assert %{staging_path: staging_path, lease_id: lease_id} = onboard.(call)

      File.write!(
        Path.join(staging_path, "local-openai.json"),
        local_openai_bytes(@spark_endpoint, "spark-local")
      )

      assert :ok =
               onboard.(
                 call
                 |> put_in([:params, :phase], "finish")
                 |> put_in([:params, :lease_id], lease_id)
               )
               |> then(fn
                 %{status: "onboarded"} -> :ok
                 other -> flunk("expected onboarded, got #{inspect(other)}")
               end)

      assert JSON.decode!(
               File.read!(Path.join([ctx.base, "auth", "pi-local", "local-openai.json"]))
             ) == %{
               "local-openai" => %{
                 "endpoint" => @spark_endpoint,
                 "apiKey" => "spark-local"
               }
             }
    end

    test "refuses hollow endpoint records before they reach the store", ctx do
      seed_admin(ctx.db)
      start_supervised!({Credentials, name: Credentials, base_dir: ctx.base, machine: "testhost"})

      onboard = onboard_handlers(ctx.base, ctx.db)

      call = %{
        origin: "user:local-admin",
        params: %{provider: "local-openai", phase: "begin", kind: "apiKey"}
      }

      assert %{staging_path: staging_path, lease_id: lease_id} = onboard.(call)

      File.write!(
        Path.join(staging_path, "local-openai.json"),
        ~s({"local-openai":{"endpoint":""}})
      )

      assert {:error, {:hollow_credential, %{found: found, sentence: sentence}}} =
               Credentials.finish_onboard(:local_openai, :api_key, lease_id, Credentials)

      assert found =~ "endpoint is empty"
      assert sentence =~ "tightbeam onboard local-openai"
      refute File.exists?(Path.join([ctx.base, "auth", "pi-local", "local-openai.json"]))
    end

    test "local-openai refuses subscription kind before opening a lease", ctx do
      seed_admin(ctx.db)
      start_supervised!({Credentials, name: Credentials, base_dir: ctx.base, machine: "testhost"})

      onboard = onboard_handlers(ctx.base, ctx.db)

      call = %{
        origin: "user:local-admin",
        params: %{provider: "local-openai", phase: "begin", kind: "subscription"}
      }

      assert %{
               code: "invalid_message",
               message:
                 "local-openai requires credential kind apiKey; subscription is unsupported"
             } = onboard.(call)
    end
  end

  @tag :spark_live
  test "release CLI live onboard local-openai product capture", _ctx do
    if System.get_env("TIGHTBEAM_SPARK_LIVE") != "1" do
      :ok
    else
      run_release_cli_live_onboard!()
    end
  end

  defp run_release_cli_live_onboard! do
    unless File.regular?(@release_binary) do
      flunk("release CLI missing at #{@release_binary}; run cargo build --release in cli/")
    end

    isolated =
      Path.join(
        System.tmp_dir!(),
        "tb-local-openai-cli-live-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(isolated)
    db_path = Path.join(isolated, "state.db")
    db = :"local_openai_live_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: db_path, name: db})
    ensure_all_schemas(db)

    admin = "local-openai-live-admin"
    seed_admin(db, admin)

    host = Placement.local_host_name()
    register_hosts(db, %{host => %{ssh: nil, base_dir: isolated, cli_bin: nil}})

    start_supervised!(
      {Credentials, name: Credentials.server(host), base_dir: isolated, machine: host}
    )

    Archetypes.load!(isolated)

    gateway_config = %{
      db: db,
      base_dir: isolated,
      cwd: isolated,
      onboarding_lease_ms: 1_800_000
    }

    handlers = Gateway.handlers(gateway_config)
    Rules.load!(isolated, Map.keys(handlers))

    router_opts =
      Router.init(
        db: db,
        base_dir: isolated,
        handlers: handlers,
        cli_token: @cli_token,
        session_status: fn _ -> nil end
      )

    bandit =
      start_supervised!(
        {Bandit, plug: {Router, router_opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    File.write!(
      Path.join(isolated, "gateway.json"),
      JSON.encode!(%{port: port, cliToken: @cli_token})
    )

    workdir = Path.join(isolated, "work/cli")
    File.mkdir_p!(workdir)

    prod_store = Path.join([Path.expand("~/.tightbeam"), "auth", "pi-local", "local-openai.json"])
    prod_before = if File.exists?(prod_store), do: File.read!(prod_store), else: nil

    env = [
      {"TIGHTBEAM_BASE_DIR", isolated},
      {"TIGHTBEAM_URL", "http://127.0.0.1:#{port}"},
      {"TIGHTBEAM_TOKEN", @cli_token}
    ]

    {output, exit} =
      System.cmd(
        @release_binary,
        [
          "onboard",
          "local-openai",
          "--endpoint",
          @spark_endpoint,
          "--as-user",
          admin
        ],
        cd: workdir,
        env: env,
        stderr_to_stdout: true
      )

    assert exit == 0, "release CLI onboard failed (exit #{exit}):\n#{output}"

    result = JSON.decode!(output)
    assert result["status"] == "onboarded"
    assert result["provider"] == "local_openai"
    assert result["credentialKind"] == "apiKey"

    store = Path.join([isolated, "auth", "pi-local", "local-openai.json"])
    metadata_path = Path.join([isolated, "auth", "pi-local", ".tightbeam", "credential.json"])

    assert File.regular?(store)

    assert JSON.decode!(File.read!(store)) == %{
             "local-openai" => %{"endpoint" => @spark_endpoint}
           }

    assert File.stat!(store).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(metadata_path).mode |> Bitwise.band(0o777) == 0o600

    assert Credentials.status(:local_openai, Credentials.server(host)) == :onboarded

    if prod_before do
      assert File.read!(prod_store) == prod_before
    else
      refute File.exists?(prod_store)
    end

    refute output =~ "apiKey"
    refute output =~ "Bearer"

    File.rm_rf!(isolated)
  end
end
