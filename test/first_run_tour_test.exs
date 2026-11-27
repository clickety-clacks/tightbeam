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
    File.mkdir_p!(base)

    default = Archetypes.builtin_default()
    tour = Archetypes.parse_manifest!("name = \"tour-guide\"", "tour-guide.toml")
    :persistent_term.put(Archetypes, {%{"default" => default, "tour-guide" => tour}, %{}})

    on_exit(fn ->
      if flag, do: System.put_env(@flag, flag), else: System.delete_env(@flag)
      if archetypes, do: :persistent_term.put(Archetypes, archetypes), else: :persistent_term.erase(Archetypes)
      File.rm_rf!(base)
    end)

    %{path: Path.join(base, "state.db")}
  end

  test "fresh bootstrap records eligibility and recovery keeps the exact seeded session", %{path: path} do
    System.put_env(@flag, "true")
    db = open!(path)
    assert :ok = Schema.ensure_all(db)
    assert Org.get_setting(db, @setting) == "pending"
    assert :ok = FirstRunTour.ensure(db, @defaults)
    GenServer.stop(db)

    db = open!(path)
    assert :ok = Schema.ensure_all(db)
    assert Org.get_setting(db, @setting) == "pending"
    main = create_main!(db)
    assert :ok = FirstRunTour.ensure(db, @defaults)
    tour = Org.get_setting(db, @setting)
    assert tour != main.session_key
    assert %{archetype: "tour-guide", spawned_by: parent} = Org.get(db, tour)
    assert parent == main.session_key
    assert {:ok, ^tour, false} = Roles.resolve(db, "tour-guide")
    assert %{kind: "main", archetype: "default"} = Org.get(db, main.session_key)
    GenServer.stop(db)

    db = open!(path)
    assert :ok = Schema.ensure_all(db)
    assert :ok = FirstRunTour.ensure(db, @defaults)
    assert Org.get_setting(db, @setting) == tour
    assert [%{session_key: ^tour}] = Org.active_all_by_identity_name(db, "tour-guide")
  end

  test "enabling after fresh bootstrap does not retrofit an installation", %{path: path} do
    System.delete_env(@flag)
    db = open!(path)
    assert :ok = Schema.ensure_all(db)
    main = create_main!(db)
    GenServer.stop(db)

    System.put_env(@flag, "true")
    db = open!(path)
    assert :ok = Schema.ensure_all(db)
    assert :ok = FirstRunTour.ensure(db, @defaults)
    refute Org.get_setting(db, @setting)
    assert [] = Org.active_all_by_identity_name(db, "tour-guide")
    assert %{kind: "main", archetype: "default"} = Org.get(db, main.session_key)
  end

  test "upgrading a predecessor does not make it eligible", %{path: path} do
    System.put_env(@flag, "true")
    db = open!(path)
    sql = File.read!(Path.join(__DIR__, "fixtures/artifact_durability_reparent_9082cb14.sql"))
    assert :ok = DB.execute(db, sql)
    assert :ok = Schema.ensure_all(db)
    assert :ok = FirstRunTour.ensure(db, @defaults)
    refute Org.get_setting(db, @setting)
    assert [] = Org.active_all_by_identity_name(db, "tour-guide")
  end

  defp open!(path) do
    {:ok, db} = DB.start_link(path: path, name: nil, guard_inputs: [])
    db
  end

  defp create_main!(db) do
    Devices.add_user(db, @owner, true)

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
