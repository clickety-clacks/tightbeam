defmodule Tightbeam.ProviderAdditivityTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{Credentials, DB, Devices, Gateway, Harness, Homes}

  test "provider literal scan is closed and detects an unreported consumer" do
    scan = Path.expand("scripts/check_provider_literals.sh")
    assert {"", 0} = System.cmd(scan, [], stderr_to_stdout: true)

    probe = "lib/tightbeam/provider_literal_probe.ex"
    File.write!(probe, ~s(defmodule Tightbeam.ProviderLiteralProbe, do: @provider :openai\n))
    on_exit(fn -> File.rm(probe) end)

    assert {_output, 1} = System.cmd(scan, [], stderr_to_stdout: true)
    File.rm!(probe)
  end

  test "fixture provider onboards through the lifecycle using only scan-reported sites" do
    base =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-fixture-provider-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(base) end)

    db = :"provider_additivity_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Devices.ensure_schema(db)

    {:ok, _rows} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES (?1, 1, ?2)",
        ["fixture-admin", System.system_time(:second)]
      )

    start_supervised!({Credentials, name: Credentials, base_dir: base, machine: "testhost"})

    assert Harness.Fixture.credential_provider() == :fixture_provider

    onboard = Gateway.handlers(%{base_dir: base, db: db})["onboard"]
    call = %{origin: "user:fixture-admin", params: %{provider: "fixture-provider"}}

    assert %{provider: :fixture_provider, status: "ready", staging_path: staging_path} =
             onboard.(put_in(call.params[:phase], "begin"))

    File.write!(Path.join(staging_path, "fixture.json"), "fixture-provider-credential")

    assert %{provider: :fixture_provider, status: "onboarded"} =
             onboard.(put_in(call.params[:phase], "finish"))

    assert Credentials.status(:fixture_provider) == :onboarded

    store = Path.join([base, "auth", "fixture", "fixture.json"])
    home = Homes.home_path(base, "testhost", :fixture)

    assert File.read!(store) == "fixture-provider-credential"
    assert File.read_link!(Path.join(home, "fixture.json")) == store

    {reported, 0} =
      System.cmd(Path.expand("scripts/check_provider_literals.sh"), ["--print"])

    reported = MapSet.new(String.split(reported, "\n", trim: true))

    fixture_sites =
      ((["lib", "config", "cli/src"]
        |> Enum.flat_map(fn root ->
          Path.wildcard("#{root}/**/*.{ex,exs,rs}")
        end)) ++ ["scripts/feature_smoke.exs", "docs/SMOKE.md"])
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(&(File.read!(&1) =~ ~r/fixture_provider|fixture-provider/))
      |> Enum.reject(&String.starts_with?(&1, "lib/tightbeam/harness/"))
      |> MapSet.new()

    assert MapSet.subset?(fixture_sites, reported)
  end
end
