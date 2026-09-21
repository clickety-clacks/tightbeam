defmodule Tightbeam.ReminderDeliveryTest do
  use ExUnit.Case, async: true

  alias Tightbeam.ReminderDelivery

  test "authorized rebind retains intent and snapshot without advancing delivery backoff" do
    old = %{"wake" => "original"}
    claim = %{"consumer" => old, "epoch" => 4, "snapshot" => "old fact", "intent" => "original"}
    state = %{"claimEpoch" => 4, "pending" => claim, "nextEligibleAt" => 123}

    for successor <- [%{"wake" => "replacement"}, %{"turn" => 42}] do
      assert {:ok, rebound} = ReminderDelivery.rebind(state, old, 4, successor)
      assert rebound["claimEpoch"] == 5
      assert rebound["pending"]["snapshot"] == "old fact"
      assert rebound["pending"]["intent"] == "original"
      assert rebound["nextEligibleAt"] == 123
      assert {:error, :stale_claim} = ReminderDelivery.delivered(rebound, old, 4, 200)
      assert {:ok, delivered} = ReminderDelivery.delivered(rebound, successor, 5, 300)
      assert delivered["nextEligibleAt"] == 300_300
    end

    assert {:ok, delivered} = ReminderDelivery.delivered(state, old, 4, 200)
    assert {:error, :stale_claim} = ReminderDelivery.rebind(delivered, old, 4, %{"turn" => 42})
    assert {:error, :invalid_successor} = ReminderDelivery.rebind(state, old, 4, %{"turn" => 0})
  end

  test "successful delivery anchors the selected gaps and preserves newer evidence" do
    initial = %{"claimEpoch" => 0, "currentConsequence" => "newer"}

    Enum.reduce([300_000, 900_000, 1_800_000, 1_800_000], initial, fn gap, state ->
      epoch = state["claimEpoch"] + 1
      consumer = %{"turn" => epoch}
      pending = %{"consumer" => consumer, "epoch" => epoch, "snapshot" => "old", "intent" => 1}
      claimed = state |> Map.put("claimEpoch", epoch) |> Map.put("pending", pending)
      now = epoch * 10_000_000
      assert {:ok, next} = ReminderDelivery.delivered(claimed, consumer, epoch, now)
      assert next["nextEligibleAt"] == now + gap
      assert next["currentConsequence"] == "newer"
      assert next["lastSnapshot"] == "old"
      assert next["claimEpoch"] == epoch
      assert {:error, :stale_claim} = ReminderDelivery.delivered(next, consumer, epoch, now)
      next
    end)
  end

  test "a late predecessor cannot clear a rebound successor claim" do
    state = %{
      "claimEpoch" => 2,
      "pending" => %{
        "consumer" => %{"turn" => 2},
        "epoch" => 2,
        "snapshot" => "fact",
        "intent" => 1
      }
    }

    assert {:error, :stale_claim} = ReminderDelivery.delivered(state, %{"wake" => 1}, 1, 100)
    assert {:ok, next} = ReminderDelivery.delivered(state, %{"turn" => 2}, 2, 200)
    assert next["nextEligibleAt"] == 300_200
  end
end
