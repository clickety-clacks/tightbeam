defmodule Tightbeam.LocalOpenAiOnboardingTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Archetypes,
    Credentials,
    DB,
    Devices,
    Gateway,
    LocalOpenAi.Providers,
    Placement,
    Rules
  }

  alias Tightbeam.Wire.Router

  @provider_name "spark"
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
    record = %{
      "name" => @provider_name,
      "type" => "local-openai",
      "endpoint" => endpoint
    }

    record =
      if api_key do
        Map.put(record, "apiKey", api_key)
      else
        record
      end

    JSON.encode!(record)
  end

  describe "host-scoped local-openai persistence" do
    test "banks endpoint-only credentials under auth/pi-local/providers", ctx do
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
        Path.join(staging_path, "#{@provider_name}.json"),
        local_openai_bytes(@spark_endpoint)
      )

      assert %{provider: :local_openai, credential_kind: "apiKey", status: "onboarded"} =
               onboard.(
                 call
                 |> put_in([:params, :phase], "finish")
                 |> put_in([:params, :lease_id], lease_id)
               )

      store = Providers.provider_path(ctx.base, @provider_name)

      metadata_path =
        Path.join([
          ctx.base,
          "homes",
          "testhost",
          "pi",
          ".tightbeam",
          "local-openai-credential.json"
        ])

      assert JSON.decode!(File.read!(store)) == %{
               "name" => @provider_name,
               "type" => "local-openai",
               "endpoint" => @spark_endpoint
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
        Path.join(staging_path, "#{@provider_name}.json"),
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

      assert JSON.decode!(File.read!(Providers.provider_path(ctx.base, @provider_name))) == %{
               "name" => @provider_name,
               "type" => "local-openai",
               "endpoint" => @spark_endpoint,
               "apiKey" => "spark-local"
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
        Path.join(staging_path, "#{@provider_name}.json"),
        ~s({"name":"spark","type":"local-openai","endpoint":""})
      )

      assert {:error, {:hollow_credential, %{found: found, sentence: sentence}}} =
               Credentials.finish_onboard(:local_openai, :api_key, lease_id, Credentials)

      assert found =~ "endpoint is empty"
      assert sentence =~ "tightbeam onboard local-openai"
      refute File.exists?(Providers.provider_path(ctx.base, @provider_name))
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

    test "remote finish moves the staged provider on the satellite without reading its bytes",
         ctx do
      owner = self()
      secret = "TB_REMOTE_STAGED_LOCAL_OPENAI_SECRET"

      sh = fn command ->
        send(owner, {:remote_finish_command, command})
        joined = Enum.join(command, " ")

        cond do
          String.contains?(joined, "/bin/ls -1") and
              String.contains?(joined, "/staging/credential-onboarding/") ->
            {"spark.json\n", 0}

          String.contains?(joined, "/bin/ls -1") and
              String.contains?(joined, "/auth/pi-local/providers") ->
            {"spark.json\n", 0}

          String.contains?(joined, "__TIGHTBEAM_LOCAL_OPENAI_VALID__") ->
            {"__TIGHTBEAM_LOCAL_OPENAI_VALID__\n", 0}

          String.contains?(joined, "__TIGHTBEAM_API_KEY_PRESENT__") or
              String.contains?(joined, "__TIGHTBEAM_API_KEY_ABSENT__") ->
            {~s({"name":"spark","type":"local-openai","endpoint":"https://spark.example/v1"}) <>
               "\n__TIGHTBEAM_API_KEY_ABSENT__\n", 0}

          String.contains?(joined, "cat") and String.contains?(joined, ".tightbeam/manifest") ->
            {"", 1}

          true ->
            {"", 0}
        end
      end

      server =
        start_supervised!(
          {Credentials,
           name: nil,
           base_dir: ctx.base,
           machine: "worker",
           ssh: "fixture@worker",
           ssh_bin: "/usr/bin/ssh",
           sh: sh}
        )

      assert {:ok, staging, lease_id} = Credentials.begin_onboard(:local_openai, server)
      refute File.exists?(staging)

      assert :ok = Credentials.finish_onboard(:local_openai, :api_key, lease_id, server)

      commands = collect_remote_finish_commands([])
      assert Enum.any?(commands, &(Enum.join(&1, " ") =~ "/bin/ls -1"))
      assert Enum.any?(commands, &(Enum.join(&1, " ") =~ "/bin/mv"))
      refute Enum.any?(commands, &(Enum.join(&1, " ") =~ secret))
    end

    test "remote finish refuses a malformed staged provider and leaves the old descriptor", ctx do
      owner = self()
      secret = "TB_REMOTE_STAGED_MALFORMED_SECRET"

      old_descriptor =
        ~s({"name":"spark","type":"local-openai","endpoint":"https://old.example/v1"})

      ref = :atomics.new(1, [])
      :atomics.put(ref, 1, 1)

      sh = fn command ->
        send(owner, {:remote_malformed_command, command})
        joined = Enum.join(command, " ")

        cond do
          String.contains?(joined, "/bin/ls -1") ->
            {"spark.json\n", 0}

          String.contains?(joined, "__TIGHTBEAM_LOCAL_OPENAI_VALID__") ->
            {"provider descriptor is malformed\n", 65}

          String.contains?(joined, "/bin/mv") ->
            :atomics.put(ref, 1, 0)
            {"", 0}

          true ->
            {"", 0}
        end
      end

      server =
        start_supervised!(
          {Credentials,
           name: nil,
           base_dir: ctx.base,
           machine: "worker",
           ssh: "fixture@worker",
           ssh_bin: "/usr/bin/ssh",
           sh: sh}
        )

      assert {:ok, staging, lease_id} = Credentials.begin_onboard(:local_openai, server)
      refute File.exists?(staging)

      assert {:error,
              {:local_openai_failed, {:staged_local_openai_validation_failed, {:exit, 65}}}} =
               Credentials.finish_onboard(:local_openai, :api_key, lease_id, server)

      assert :atomics.get(ref, 1) == 1
      commands = collect_remote_malformed_commands([])
      refute Enum.any?(commands, &(Enum.join(&1, " ") =~ "/bin/mv"))
      refute Enum.any?(commands, &(Enum.join(&1, " ") =~ secret))
      assert old_descriptor =~ "old.example"
    end

    test "remote finish rejects an ftp endpoint and leaves the old descriptor", ctx do
      owner = self()

      staged_descriptor =
        ~s({"name":"spark","type":"local-openai","endpoint":"ftp://spark.example/v1"})

      old_descriptor =
        ~s({"name":"spark","type":"local-openai","endpoint":"https://old.example/v1"})

      {:ok, store} = Agent.start_link(fn -> old_descriptor end)

      sh = fn command ->
        send(owner, {:remote_ftp_command, command})
        joined = Enum.join(command, " ")

        cond do
          String.contains?(joined, "/bin/ls -1") ->
            {"spark.json\n", 0}

          String.contains?(joined, "__TIGHTBEAM_LOCAL_OPENAI_VALID__") ->
            {"endpoint must be an http(s) URL\n", 65}

          String.contains?(joined, "/bin/mv") ->
            Agent.update(store, fn _ -> staged_descriptor end)
            {"", 0}

          true ->
            {"", 0}
        end
      end

      server =
        start_supervised!(
          {Credentials,
           name: nil,
           base_dir: ctx.base,
           machine: "worker",
           ssh: "fixture@worker",
           ssh_bin: "/usr/bin/ssh",
           sh: sh}
        )

      assert {:ok, staging, lease_id} = Credentials.begin_onboard(:local_openai, server)
      refute File.exists?(staging)

      assert {:error,
              {:local_openai_failed, {:staged_local_openai_validation_failed, {:exit, 65}}}} =
               Credentials.finish_onboard(:local_openai, :api_key, lease_id, server)

      commands = collect_remote_ftp_commands([])

      validation_command =
        Enum.find(commands, &(Enum.join(&1, " ") =~ "__TIGHTBEAM_LOCAL_OPENAI_VALID__"))

      assert validation_command
      assert Enum.join(validation_command, " ") =~ "http://"
      assert Enum.join(validation_command, " ") =~ "https://"
      assert Agent.get(store, & &1) == old_descriptor
      refute Enum.any?(commands, &(Enum.join(&1, " ") =~ "/bin/mv"))
      assert staged_descriptor =~ "ftp://"

      Agent.stop(store)
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

    prod_store =
      Path.join([
        Path.expand("~/.tightbeam"),
        "auth",
        "pi-local",
        "providers",
        "#{@provider_name}.json"
      ])

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
          "--name",
          @provider_name,
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

    store = Providers.provider_path(isolated, @provider_name)
    metadata_path = Path.join([isolated, "auth", "pi-local", ".tightbeam", "credential.json"])

    assert File.regular?(store)

    assert JSON.decode!(File.read!(store)) == %{
             "name" => @provider_name,
             "type" => "local-openai",
             "endpoint" => @spark_endpoint
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

  defp collect_remote_finish_commands(acc) do
    receive do
      {:remote_finish_command, command} -> collect_remote_finish_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_remote_malformed_commands(acc) do
    receive do
      {:remote_malformed_command, command} -> collect_remote_malformed_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_remote_ftp_commands(acc) do
    receive do
      {:remote_ftp_command, command} -> collect_remote_ftp_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
