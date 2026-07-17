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

  test "owner-scoped broadcast: owner + admin receive, others don't", %{reg: reg, deliver: d} do
    {:ok, _, _} = ConnRegistry.register(reg, %{pid: :flynn, user_id: "flynn", device_id: "d1", is_admin: true})
    {:ok, _, _} = ConnRegistry.register(reg, %{pid: :mike, user_id: "mike", device_id: "d2", is_admin: false})

    :ok = ConnRegistry.broadcast(reg, "mike", %{t: "typing"}, d)
    # mike (owner) gets it; flynn (admin) gets it; nobody else exists
    assert_received {:sent, :mike, %{t: "typing"}}
    assert_received {:sent, :flynn, %{t: "typing"}}
  end

  test "per-connection seq filter drops already-delivered (late pre-watermark) messages", %{reg: reg, deliver: d} do
    {:ok, ref, _} = ConnRegistry.register(reg, %{pid: :c, user_id: "u", device_id: "d", is_admin: false})

    # replay advanced this connection's watermark to seq 11 for k1
    ConnRegistry.note_replayed(reg, ref, "k1", 11)

    # a LATE publication of seq 10 (committed before the watermark) is dropped
    :ok = ConnRegistry.publish_message(reg, "k1", "u", 10, %{seq: 10}, d)
    refute_received {:sent, :c, _}

    # seq 12 (after the watermark) is delivered, and advances the filter
    :ok = ConnRegistry.publish_message(reg, "k1", "u", 12, %{seq: 12}, d)
    assert_received {:sent, :c, %{seq: 12}}

    # re-publishing 12 (a duplicate) is dropped
    :ok = ConnRegistry.publish_message(reg, "k1", "u", 12, %{seq: 12}, d)
    refute_received {:sent, :c, _}
  end

  test "generation-tagged takeover: new registration owns the slot; slow old unregister cannot evict it",
       %{reg: reg, test_pid: test_pid} do
    {:ok, _old_ref, nil} = ConnRegistry.register(reg, %{pid: :old, user_id: "u", device_id: "dev", is_admin: false})

    # takeover: same device, new socket
    {:ok, new_ref, replaced} = ConnRegistry.register(reg, %{pid: :new, user_id: "u", device_id: "dev", is_admin: false})
    assert replaced != nil

    # the OLD connection now closes and unregisters LATE — must NOT evict :new
    ConnRegistry.unregister(reg, replaced)

    # :new still owns the device slot and is the only live conn
    assert ConnRegistry.count(reg) == 1
    d = fn pid, p -> send(test_pid, {:sent, pid, p}) end
    :ok = ConnRegistry.broadcast(reg, "u", %{x: 1}, d)
    assert_received {:sent, :new, %{x: 1}}
    refute_received {:sent, :old, _}
    _ = new_ref
  end

  test "unregister is generation-guarded and idempotent", %{reg: reg} do
    {:ok, ref, _} = ConnRegistry.register(reg, %{pid: :a, user_id: "u", device_id: "d", is_admin: false})
    ConnRegistry.unregister(reg, ref)
    ConnRegistry.unregister(reg, ref)
    assert ConnRegistry.count(reg) == 0
  end
end
