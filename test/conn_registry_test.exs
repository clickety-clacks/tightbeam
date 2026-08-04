defmodule Tightbeam.ConnRegistryTest do
  use ExUnit.Case, async: true

  alias Tightbeam.ConnRegistry

  setup do
    reg = start_supervised!({ConnRegistry, name: :"cr_#{System.unique_integer([:positive])}"})
    test_pid = self()
    # deliver reports (pid, payload) back to the TEST process (not the GenServer)
    deliver = fn pid, payload -> send(test_pid, {:sent, pid, payload}) end
    %{reg: reg, deliver: deliver, test_pid: test_pid}
  end

  test "owner-scoped broadcast: owner only — admin is powers, not a merged feed", %{
    reg: reg,
    deliver: d
  } do
    {:ok, _, _} =
      ConnRegistry.register(reg, %{
        pid: :flynn,
        user_id: "flynn",
        device_id: "d1",
        is_admin: true,
        subscriptions: MapSet.new(["chat"])
      })

    {:ok, _, _} =
      ConnRegistry.register(reg, %{
        pid: :mike,
        user_id: "mike",
        device_id: "d2",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    :ok = ConnRegistry.broadcast(reg, "mike", %{t: "typing"}, d)
    # mike (owner) gets it; flynn (admin) gets NOTHING — not one byte of
    # another user's content reaches an admin device.
    assert_received {:sent, :mike, %{t: "typing"}}
    refute_received {:sent, :flynn, _}

    :ok = ConnRegistry.publish_message(reg, "k1", "mike", 1, %{t: "message"}, d)
    assert_received {:sent, :mike, %{t: "message"}}
    refute_received {:sent, :flynn, _}
  end

  test "publish_message delivers unconditionally — no filter, no watermark", %{
    reg: reg,
    deliver: d
  } do
    {:ok, _ref, _} =
      ConnRegistry.register(reg, %{
        pid: :c,
        user_id: "u",
        device_id: "d",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    # The registry filters NOTHING. Delivery is a hint; the store is truth; a
    # duplicate is the client's to reconcile by seq/id (it already must, to
    # survive reconnect replay). The registry used to keep a watermark here and
    # drop frames at or below it — which permanently deleted a live frame
    # whenever a HIGHER one arrived first. Any seq, any order, always delivered:
    for seq <- [10, 15, 13, 15, 9] do
      :ok = ConnRegistry.publish_message(reg, "k1", "u", seq, %{seq: seq}, d)
      assert_received {:sent, :c, %{seq: ^seq}}
    end
  end

  test "a live frame is never suppressed by a HIGHER live frame that arrived first", %{
    reg: reg,
    deliver: d
  } do
    {:ok, _ref, _} =
      ConnRegistry.register(reg, %{
        pid: :c,
        user_id: "u",
        device_id: "d",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    # Two writers to one session commit 20 then 21, and publish in the other order:
    # publication happens after each transaction returns, from each caller's own
    # process, so nothing orders them against each other.
    :ok = ConnRegistry.publish_message(reg, "k1", "u", 21, %{seq: 21}, d)
    assert_received {:sent, :c, %{seq: 21}}

    # 20 is NOT a duplicate and was never replayed. It must arrive. Suppressing it
    # loses it permanently: replay serves rows after the CLIENT's cursor, which has
    # already advanced past 20, so no reconnect ever restores it.
    :ok = ConnRegistry.publish_message(reg, "k1", "u", 20, %{seq: 20}, d)
    assert_received {:sent, :c, %{seq: 20}}
  end

  test "generation-tagged takeover: new registration owns the slot; slow old unregister cannot evict it",
       %{reg: reg, test_pid: test_pid} do
    {:ok, _old_ref, nil} =
      ConnRegistry.register(reg, %{
        pid: :old,
        user_id: "u",
        device_id: "dev",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    # takeover: same device, new socket
    {:ok, new_ref, replaced} =
      ConnRegistry.register(reg, %{
        pid: :new,
        user_id: "u",
        device_id: "dev",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    assert replaced != nil

    # the OLD connection now closes and unregisters LATE — must NOT evict :new
    ConnRegistry.unregister(reg, replaced)

    # :new still owns the device slot and is the only live conn
    assert map_size(:sys.get_state(reg).conns) == 1
    d = fn pid, p -> send(test_pid, {:sent, pid, p}) end
    :ok = ConnRegistry.broadcast(reg, "u", %{x: 1}, d)
    assert_received {:sent, :new, %{x: 1}}
    refute_received {:sent, :old, _}
    _ = new_ref
  end

  test "unregister is generation-guarded and idempotent", %{reg: reg} do
    {:ok, ref, _} =
      ConnRegistry.register(reg, %{
        pid: :a,
        user_id: "u",
        device_id: "d",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    ConnRegistry.unregister(reg, ref)
    ConnRegistry.unregister(reg, ref)
    assert map_size(:sys.get_state(reg).conns) == 0
  end

  test "chat and both work grains fan out only to their subscribed owner sets", %{
    reg: reg,
    deliver: d
  } do
    for {pid, user, subscriptions} <- [
          {:chat, "u", ["chat"]},
          {:work, "u", ["work_state"]},
          {:both, "v", ["chat", "work_state"]},
          {:admin, "admin", ["work_state"]}
        ] do
      {:ok, _, _} =
        ConnRegistry.register(reg, %{
          pid: pid,
          user_id: user,
          device_id: to_string(pid),
          is_admin: pid == :admin,
          subscriptions: MapSet.new(subscriptions)
        })
    end

    :ok = ConnRegistry.broadcast(reg, "u", %{type: :chat}, d)
    assert_received {:sent, :chat, %{type: :chat}}
    refute_received {:sent, :work, _}

    :ok = ConnRegistry.publish_work_state(reg, "u", %{type: :assignment}, d)
    assert_received {:sent, :work, %{type: :assignment}}
    refute_received {:sent, :chat, _}
    refute_received {:sent, :admin, _}

    :ok = ConnRegistry.publish_work_item(reg, MapSet.new(["u", "v"]), %{type: :item}, d)
    assert_received {:sent, :work, %{type: :item}}
    assert_received {:sent, :both, %{type: :item}}
    refute_received {:sent, :admin, _}
  end
end
