defmodule Tightbeam.D1ReadTest do
  use Tightbeam.TestCase, async: true

  alias Tightbeam.{D1Read, DB, Devices, Harness, Org, Placement, Schema}

  setup do
    db = :"d1_read_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    %{db: db}
  end

  test "the seam serializes config and host environment with values redacted", %{db: db} do
    :ok = Org.put_setting(db, "default-archetype", "default")
    :ok = Org.put_setting(db, "private-priority", "secret")

    assert [default, private] = D1Read.collection(db, "/unused", :config, %{})
    assert default["value"] == "default"
    assert private["value"] == nil

    assert D1Read.encode(:config, private) ==
             ~s({"key":"private-priority","value":null,"updatedAt":#{private["updatedAt"]},"rowVersion":#{private["rowVersion"]}})

    assert {:ok, _host} =
             Placement.register_host(db, "alpha", %{
               ssh: "operator@alpha",
               base_dir: "/private/alpha",
               cli_bin: "/private/tightbeam",
               adapter_bin_dir: "/private/adapters"
             })

    harness = hd(Harness.all()).wire_name()

    assert {:ok, _overlay} =
             Placement.set_env_overlay(
               db,
               "alpha",
               harness,
               "PRIVATE_TOKEN",
               "secret",
               "user:admin"
             )

    assert [environment] = D1Read.collection(db, "/unused", :host_environment, %{})
    assert environment["value"] == nil
    assert environment["valuePresent"] == true
    refute D1Read.encode(:host_environment, environment) =~ "secret"
  end

  test "the seam reads current users in stable public tuple order", %{db: db} do
    Devices.add_user(db, "zeta", false)
    Devices.add_user(db, "alpha", true)

    users = D1Read.collection(db, "/unused", :users, %{})

    assert Enum.map(users, & &1["userId"]) == ["alpha", "zeta"]
    assert Enum.all?(users, &(is_boolean(&1["isAdmin"]) and is_integer(&1["rowVersion"])))
  end
end
