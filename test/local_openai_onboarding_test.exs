defmodule Tightbeam.LocalOpenAiOnboardingTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Credentials, DB, Devices, Gateway, Placement}

  @spark_endpoint "https://spark.tailf064dc.ts.net/v1"

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

  defp seed_admin(db) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES (?1, 1, ?2)",
        ["local-admin", System.system_time(:second)]
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
  test "live Spark endpoint reconciles through gateway onboarding", ctx do
    if System.get_env("TIGHTBEAM_SPARK_LIVE") != "1" do
      :ok
    else
      do_live_spark_reconciliation(ctx)
    end
  end

  defp do_live_spark_reconciliation(ctx) do
    seed_admin(ctx.db)
    start_supervised!({Credentials, name: Credentials, base_dir: ctx.base, machine: "testhost"})

    onboard = onboard_handlers(ctx.base, ctx.db)

    call = %{
      origin: "user:local-admin",
      params: %{provider: "local-openai", phase: "begin", kind: "apiKey"}
    }

    assert %{staging_path: staging_path, lease_id: lease_id} = onboard.(call)

    case :httpc.request(
           :get,
           {@spark_endpoint <> "/models", []},
           [{:timeout, 15_000}],
           []
         ) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        decoded = JSON.decode!(body)
        assert is_list(decoded["data"]) or is_list(decoded["models"])

        File.write!(
          Path.join(staging_path, "local-openai.json"),
          local_openai_bytes(@spark_endpoint)
        )

        assert %{status: "onboarded"} =
                 onboard.(
                   call
                   |> put_in([:params, :phase], "finish")
                   |> put_in([:params, :lease_id], lease_id)
                 )

        assert Credentials.status(:local_openai, Credentials) == :onboarded

      other ->
        flunk("live Spark probe failed before reconciliation: #{inspect(other)}")
    end
  end
end
