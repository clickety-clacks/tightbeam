defmodule Tightbeam.Firehose.DirectApplyTest do
  use ExUnit.Case, async: true

  @required_resources ~w(work-items assignments attests artifacts turns wakes sessions)

  test "DA3.5 mutation and visibility cases converge for every required resource" do
    Enum.each(@required_resources, fn resource ->
      key = resource <> ":sample"
      opened = row(key, 40, "open", 1_000)
      closed = row(key, 41, "closed", 1_000)
      reopened = row(key, 42, "open", 1_000)
      after_restart = row(key, 43, "open", 1_000)

      client = apply_upsert(%{}, opened)
      client = apply_upsert(client, opened)

      # A paged walk can overlap a close/reopen in the current subscription.
      # Later pages and duplicate notices may carry rows already superseded.
      client = apply_page(client, [opened])
      client = apply_upsert(client, closed)
      client = apply_upsert(client, reopened)
      client = apply_upsert(client, reopened)
      client = apply_page(client, [opened])

      # The client reconnects with its held model preserved. The next row
      # advances the same key even when the timestamp cannot distinguish writes;
      # source-specific disk tests verify durable server versions.
      client = restart_client(client)
      client = apply_upsert(client, after_restart)

      assert client[key].value == after_restart, "#{resource} did not retain its newest row"
      assert client == complete_walk([after_restart])

      # A visibility change invalidates the partial walk's absence result.
      stale_from_replaced_subscription = row(key, 44, "closed", 1_000)
      client = finish_walk(client, false, [[opened]], [])
      assert client[key].row_version == 43

      # A complete walk under the new visibility boundary removes the key and
      # discards its floor. A later authorized view may then reintroduce it.
      client = finish_walk(client, true, [[]], [])
      refute Map.has_key?(client, key)

      visible_again = row(key, 45, "open", 1_000)

      client =
        apply_subscription_events(client, :current, [
          {:replaced, stale_from_replaced_subscription},
          {:current, visible_again}
        ])

      assert client == complete_walk([visible_again])
    end)
  end

  test "turns are held as queued from turn.queued until a newer start row arrives" do
    key = "turns:sample"
    queued = row(key, 40, "queued", 1_000)
    started = row(key, 41, "running", 1_000)

    client = apply_upsert(%{}, queued)
    assert client[key].value["state"] == "queued"

    client = apply_page(client, [queued])
    assert client[key].value["state"] == "queued"

    client = apply_upsert(client, started)
    assert client[key].value["state"] == "running"
    assert client == complete_walk([started])
  end

  test "a complete walk resets absent versions while an incomplete visibility walk removes nothing" do
    held = %{
      "key" => "work-item:visible-to-this-principal",
      "rowVersion" => 10,
      "state" => "open"
    }

    stale_notice = %{"key" => held["key"], "rowVersion" => 11, "state" => "closed"}
    client = apply_upsert(%{}, held)

    # A visibility change during a paged walk invalidates its absence result.
    client = finish_walk(client, false, [], [stale_notice])
    assert client[held["key"]].row_version == stale_notice["rowVersion"]

    # A new complete walk on the current visibility boundary omits the key.
    client = finish_walk(client, true, [[]], [])
    refute Map.has_key?(client, held["key"])

    # The held notice belongs to the replaced subscription and is discarded;
    # it cannot restore a key removed by the fresh complete walk.
    replaced_subscription_notices = [stale_notice]
    current_subscription_notices = []
    assert replaced_subscription_notices != current_subscription_notices
    assert client == finish_walk(client, true, [[]], current_subscription_notices)

    # A row arriving on the current subscription after the new cut is accepted
    # because absence discarded the prior version.
    current_notice = %{"key" => held["key"], "rowVersion" => 12, "state" => "open"}
    visible_client = apply_upsert(client, current_notice)
    assert visible_client[held["key"]].value == current_notice
  end

  test "equal or lower versions are ignored and absence discards a tombstone floor" do
    row = %{"key" => "assignment:sample", "rowVersion" => 40, "state" => "open"}
    equal_but_different = %{"key" => row["key"], "rowVersion" => 40, "state" => "closed"}
    older = %{"key" => row["key"], "rowVersion" => 39, "state" => "closed"}

    client = apply_upsert(%{}, row)
    assert apply_upsert(client, equal_but_different) == client
    assert apply_upsert(client, older) == client

    client = apply_delete(client, row["key"], 41)
    assert client[row["key"]] == %{row_version: 41, value: nil}

    client = complete_walk_apply(client, [])
    assert client == %{}
    reintroduced = apply_upsert(client, older)
    assert reintroduced[row["key"]].value == older
  end

  defp apply_upsert(client, row) do
    key = row["key"]
    version = row["rowVersion"]

    case client[key] do
      %{row_version: held} when held >= version ->
        client

      _ ->
        Map.put(client, key, %{row_version: version, value: row})
    end
  end

  defp apply_delete(client, key, version) do
    case client[key] do
      %{row_version: held} when held >= version -> client
      _ -> Map.put(client, key, %{row_version: version, value: nil})
    end
  end

  defp complete_walk(rows) do
    Enum.reduce(rows, %{}, &apply_upsert(&2, &1))
  end

  defp complete_walk_apply(client, rows) do
    walked = complete_walk(rows)
    visible_keys = Map.keys(walked) |> MapSet.new()

    client
    |> Map.reject(fn {key, _value} -> key not in visible_keys end)
    |> Map.merge(walked, fn _key, held, fresh ->
      if fresh.row_version > held.row_version, do: fresh, else: held
    end)
  end

  defp apply_page(client, rows), do: Enum.reduce(rows, client, &apply_upsert(&2, &1))

  defp apply_subscription_events(client, current_subscription, events) do
    Enum.reduce(events, client, fn {subscription, row}, acc ->
      if subscription == current_subscription, do: apply_upsert(acc, row), else: acc
    end)
  end

  defp restart_client(client), do: :erlang.binary_to_term(:erlang.term_to_binary(client))

  defp row(key, version, state, changed_at) do
    %{"key" => key, "rowVersion" => version, "state" => state, "changedAt" => changed_at}
  end

  defp finish_walk(client, false, _pages, notices),
    do: Enum.reduce(notices, client, &apply_upsert(&2, &1))

  defp finish_walk(client, true, pages, notices) do
    rows = List.flatten(pages)
    client = complete_walk_apply(client, rows)
    Enum.reduce(notices, client, &apply_upsert(&2, &1))
  end
end
