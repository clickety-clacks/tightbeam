defmodule Tightbeam.FirstRunTourTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Archetypes, DB, Devices, FirstRunTour, Model, Org, Roles, Schema}

  @flag "TIGHTBEAM_FIRST_RUN_ONBOARDING"
  @setting "first-run-tour"
  @owner "sample-owner"
  @defaults %{harness: :codex, provider: "openai", model: Model.new("fixture")}

  setup do
    flag = System.get_env(@flag)
    archetypes = :persistent_term.get(Archetypes, nil)
    base = Path.join(System.tmp_dir!(), "first-run-tour-#{System.unique_integer([:positive])}")
    payload = Path.join(base, "fixture/release/lib/tightbeam-0.1.17")
    File.mkdir_p!(Path.join(payload, "ebin"))
    File.mkdir_p!(Path.join(payload, "priv"))
    File.write!(Path.join(payload, "ebin/fixture.beam"), "fixture beam")
    File.write!(Path.join(payload, "priv/fixture"), "fixture content")
    package = Path.join(base, "fixture")
    File.mkdir_p!(Path.join(package, "bin"))
    File.write!(Path.join(package, "package.json"), ~s({"name":"tightbeam"}))
    File.write!(Path.join(package, "bin/tightbeam"), "fixture cli")
    File.write!(Path.join(package, "bin/tightbeam-gateway"), "fixture gateway")
    state = Path.join(base, "install")
    File.mkdir_p!(state)

    default = Archetypes.builtin_default()
    tour = Archetypes.parse_manifest!("name = \"tour-guide\"", "tour-guide.toml")
    :persistent_term.put(Archetypes, {%{"default" => default, "tour-guide" => tour}, %{}})

    on_exit(fn ->
      if flag, do: System.put_env(@flag, flag), else: System.delete_env(@flag)

      if archetypes,
        do: :persistent_term.put(Archetypes, archetypes),
        else: :persistent_term.erase(Archetypes)

      File.rm_rf!(base)
    end)

    %{path: Path.join(state, "state.db"), payload: payload}
  end

  test "fresh bootstrap records eligibility and recovery keeps the exact seeded session", %{
    path: path,
    payload: payload
  } do
    System.put_env(@flag, "true")
    db = open!(path, payload)
    assert :ok = Schema.prepare_tour_birth(db, Path.dirname(path))
    assert FirstRunTour.eligible?(db)
    assert {:ok, [["fresh"]]} = DB.query(db, "SELECT origin FROM schema_bootstrap_origin")
    assert :ok = Schema.ensure_all(db)
    GenServer.stop(db)

    db = open!(path, payload)
    assert :ok = Schema.prepare_tour_birth(db, Path.dirname(path))
    assert :ok = Schema.ensure_all(db)
    assert Org.get_setting(db, @setting) == "pending"
    Devices.add_user(db, @owner, true)
    assert :ok = FirstRunTour.ensure(db, @defaults)
    assert Org.get_setting(db, @setting) == "pending"
    GenServer.stop(db)

    db = open!(path, payload)
    assert :ok = Schema.ensure_all(db)
    main = create_main!(db)
    GenServer.stop(db)

    db = open!(path, payload)
    assert :ok = Schema.ensure_all(db)
    assert :ok = FirstRunTour.ensure(db, @defaults)
    tour = Org.get_setting(db, @setting)
    assert tour != main.session_key
    assert %{archetype: "tour-guide", spawned_by: parent} = Org.get(db, tour)
    assert parent == main.session_key
    assert {:ok, ^tour, false} = Roles.resolve(db, "tour-guide")
    assert %{kind: "main", archetype: "default"} = Org.get(db, main.session_key)
    GenServer.stop(db)

    db = open!(path, payload)
    assert :ok = Schema.ensure_all(db)
    assert :ok = FirstRunTour.ensure(db, @defaults)
    assert Org.get_setting(db, @setting) == tour
    assert [%{session_key: ^tour}] = Org.active_all_by_identity_name(db, "tour-guide")
  end

  test "enabling after fresh bootstrap does not retrofit an installation", %{
    path: path,
    payload: payload
  } do
    System.delete_env(@flag)
    db = open!(path, payload)
    assert :ok = Schema.prepare_tour_birth(db, Path.dirname(path))
    assert :ok = Schema.ensure_all(db)
    main = create_main!(db)
    GenServer.stop(db)

    System.put_env(@flag, "true")
    db = open!(path, payload)
    assert :ok = Schema.prepare_tour_birth(db, Path.dirname(path))
    assert :ok = Schema.ensure_all(db)
    assert :ok = FirstRunTour.ensure(db, @defaults)
    refute Org.get_setting(db, @setting)
    assert [] = Org.active_all_by_identity_name(db, "tour-guide")
    assert %{kind: "main", archetype: "default"} = Org.get(db, main.session_key)
  end

  test "an older interrupted bootstrap cannot acquire tour eligibility", %{
    path: path,
    payload: payload
  } do
    System.delete_env(@flag)
    base = Path.dirname(path)
    %{identity: identity} = Tightbeam.LiveBaseAdmission.prepare!(base, payload_root: payload)
    db = open!(path, payload)
    assert :ok = DB.prepare_schema(db)

    assert :ok =
             DB.execute(db, """
             INSERT INTO schema_stamp(shape,stampedAt) VALUES('row-driven-admission-pre-liveness-v1-019',1);
             CREATE TABLE schema_bootstrap_origin (
               id INTEGER PRIMARY KEY CHECK(id=1),
               origin TEXT NOT NULL CHECK(origin='fresh'),
               createdAt INTEGER NOT NULL
             );
             INSERT INTO schema_bootstrap_origin VALUES(1,'fresh',1);
             """)

    GenServer.stop(db)

    File.write!(
      Path.join(base, "build-owner.json"),
      JSON.encode!(%{"format" => "tightbeam-build-owner/v1", "buildIdentity" => identity})
    )

    System.put_env(@flag, "true")
    db = open!(path, payload)
    assert :ok = Schema.prepare_tour_birth(db, Path.dirname(path))
    assert :ok = Schema.ensure_all(db)
    create_main!(db)
    assert :ok = FirstRunTour.ensure(db, @defaults)
    refute FirstRunTour.eligible?(db)
    assert [] = Org.active_all_by_identity_name(db, "tour-guide")
  end

  test "a new database beside an existing identity cannot acquire tour eligibility", %{
    path: path,
    payload: payload
  } do
    System.put_env(@flag, "true")
    File.mkdir!(Path.join(Path.dirname(path), "identity"))
    db = open!(path, payload)
    assert :ok = Schema.prepare_tour_birth(db, Path.dirname(path))
    assert :ok = Schema.ensure_all(db)
    refute FirstRunTour.eligible?(db)
  end

  test "upgrading a predecessor does not make it eligible" do
    System.put_env(@flag, "true")
    db = open!(":memory:", nil)
    sql = File.read!(Path.join(__DIR__, "fixtures/artifact_durability_reparent_9082cb14.sql"))
    assert :ok = DB.execute(db, sql)
    assert :ok = Schema.ensure_all(db)
    assert :ok = FirstRunTour.ensure(db, @defaults)
    refute Org.get_setting(db, @setting)
    assert [] = Org.active_all_by_identity_name(db, "tour-guide")
  end

  defp open!(path, payload) do
    {:ok, db} = DB.start_link(path: path, name: nil, guard_inputs: [], payload_root: payload)
    db
  end

  defp create_main!(db) do
    if is_nil(Devices.user(db, @owner)), do: Devices.add_user(db, @owner, true)

    Org.create(db, %{
      session_key: Org.personal_session_key(@owner),
      display_name: "Main",
      kind: "main",
      is_built_in: true,
      owner_user_id: @owner,
      origin: "user:#{@owner}",
      archetype: "default",
      host: Tightbeam.Placement.local_host_name(),
      harness: "codex",
      provider: "openai",
      model: @defaults.model
    })
  end
end
