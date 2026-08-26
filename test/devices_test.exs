defmodule Tightbeam.DevicesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Devices}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = Tightbeam.Schema.ensure_all(name)
    %{db: name}
  end

  defp pair(db, device_id, claimed_name) do
    Devices.pair(db, %{
      device_id: device_id,
      claimed_name: claimed_name,
      platform: nil,
      model: nil
    })
  end

  test "pairing refuses a zero-user database without writing", %{db: db} do
    assert :first_user_required = pair(db, "dev-1", "Flynn iPhone")
    assert Devices.user(db, "flynn-iphone") == nil
    assert Devices.by_id(db, "dev-1") == nil
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM devices WHERE token IS NOT NULL")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM events")
  end

  test "an approved device re-pairs by rotating its token", %{db: db} do
    first = allowlisted_device(db, "dev-1", "flynn-iphone", true)
    assert first.user_id == "flynn-iphone"
    assert first.is_admin
    assert first.status == "allowlisted"
    assert first.token =~ ~r/^tbt_[A-Za-z0-9_-]{32}$/

    assert {:paired, second} = pair(db, "dev-1", "Flynn iPhone")
    refute second.token == first.token
    assert Devices.by_token(db, first.token) == nil
    assert Devices.by_token(db, second.token).device_id == "dev-1"
  end

  test "the shared cold-start rule makes a directly added first user admin", %{db: db} do
    assert %{user_id: "installer", is_admin: true} =
             Devices.add_user(db, "installer", false)

    assert %{user_id: "guest", is_admin: false} = Devices.add_user(db, "guest", false)
  end

  test "pending and denied flows preserve the approval queue", %{db: db} do
    _ = allowlisted_device(db, "admin", "admin", true)
    assert {:pending, pending} = pair(db, "dev-2", "Guest")
    assert pending.token == nil
    assert Enum.map(Devices.list_pending(db), & &1.device_id) == ["dev-2"]

    assert :ok = Devices.deny(db, "dev-2")
    assert :denied = pair(db, "dev-2", "Guest")
    assert Devices.by_id(db, "dev-2").status == "denied"
    assert Devices.list_pending(db) == []
  end

  test "approve can override the claimed user and derives admin through the join", %{db: db} do
    _ = allowlisted_device(db, "dev-1", "admin", true)
    assert {:pending, _} = pair(db, "dev-2", "Typo Name")

    approved = Devices.approve(db, "dev-2", "admin")
    assert approved.user_id == "admin"
    assert approved.is_admin
    assert approved.status == "allowlisted"
    assert Devices.by_token(db, approved.token).is_admin
    assert Devices.user_count(db) == 1
  end

  test "revoke clears token while by_id remains allowlisted", %{db: db} do
    device = allowlisted_device(db, "dev-1", "admin", true)
    assert :ok = Devices.revoke(db, "dev-1")
    assert Devices.by_token(db, device.token) == nil
    assert %{status: "allowlisted", token: nil} = Devices.by_id(db, "dev-1")
  end

  test "admin follows the user and unknown mutations raise", %{db: db} do
    _ = allowlisted_device(db, "phone-1", "flynn", true)
    assert {:pending, _} = pair(db, "phone-2", "Flynn")
    assert Devices.approve(db, "phone-2").is_admin

    refute Devices.set_user_admin(db, "flynn", false).is_admin
    refute Devices.by_id(db, "phone-1").is_admin

    assert_raise ArgumentError, "unknown device: missing", fn -> Devices.revoke(db, "missing") end

    assert_raise ArgumentError, "unknown user: missing", fn ->
      Devices.set_user_admin(db, "missing", true)
    end
  end
end
