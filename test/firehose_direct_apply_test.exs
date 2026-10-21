defmodule Tightbeam.Firehose.DirectApplyTest do
  use ExUnit.Case, async: true

  @required_resources ~w(work-items assignments attests artifacts turns wakes sessions)

  test "the generic client model follows version, walk, restart, and visibility rules" do
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

defmodule Tightbeam.Firehose.DirectApplyConvergenceTest do
  use Tightbeam.TestCase, async: false
  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{
    Artifacts,
    Assignments,
    DB,
    Devices,
    Ledger,
    Model,
    Org,
    Schema,
    Wakes,
    WorkItems
  }

  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  setup do
    db = :"firehose_direct_apply_convergence_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)

    {:paired, device} =
      Devices.pair(db, %{
        device_id: "firehose-direct-apply-device",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    work_root =
      Path.join(System.tmp_dir!(), "firehose-direct-apply-#{System.unique_integer([:positive])}")

    File.mkdir_p!(work_root)
    File.write!(Path.join(work_root, "sample.md"), "server-backed artifact")

    on_exit(fn -> File.rm_rf!(work_root) end)

    register_hosts(db, %{
      "testhost" => %{ssh: nil, base_dir: work_root, cli_bin: nil}
    })

    session =
      Org.create(db, %{
        session_key: "direct-apply-owner",
        display_name: "Direct apply owner",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    work_item =
      WorkItems.__handle__(db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        params: %{title: "Server-backed convergence item"}
      })

    start_supervised!({Hub, name: Hub})
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: false})

    router_opts = [
      db: db,
      base_dir: work_root,
      handlers: %{},
      cli_token: "unused-direct-apply-token",
      firehose_hub: Hub,
      model_catalog: %{},
      session_status: fn _ -> nil end
    ]

    %{
      db: db,
      device: device,
      session: session,
      work_item: work_item,
      work_root: work_root,
      router_opts: router_opts
    }
  end

  test "committed notices for each required resource match its REST row", ctx do
    item =
      WorkItems.__handle__(ctx.db, "work-item-update", %{
        verb: "work-item-update",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        firehose_in_txn: true,
        firehose_hub: Hub,
        supervision_interval_ms: 1_000,
        params: %{work_item_id: ctx.work_item.id, title: "Updated by the server"}
      })

    assert_converges(
      ctx,
      "work_item.updated",
      "work-items",
      "id",
      item.id,
      "/api/work-items?limit=500&tail=true"
    )

    assignment =
      Assignments.__handle__(ctx.db, "assign", %{
        verb: "assign",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: ctx.session.session_key,
        target_role: nil,
        role_fallback: false,
        firehose_in_txn: true,
        firehose_hub: Hub,
        supervision_interval_ms: 60_000,
        params: %{subject: "Server-backed assignment", work_item_id: item.id}
      })

    assert_converges(
      ctx,
      "assignment.opened",
      "assignments",
      "id",
      assignment.id,
      "/api/assignments/#{assignment.id}"
    )

    attest_result =
      Assignments.__handle__(ctx.db, "attest", %{
        verb: "attest",
        origin: "agent:direct-apply-owner",
        principal: {:session, ctx.session.session_key},
        session_key: nil,
        firehose_in_txn: true,
        firehose_hub: Hub,
        params: %{
          assignment_id: assignment.id,
          kind: "progress",
          note: "Server-backed attest"
        }
      })

    attest_id = attest_result.attest.id

    assert_converges(
      ctx,
      "attest.filed",
      "attests",
      "id",
      attest_id,
      "/api/assignments/#{assignment.id}/attests?limit=500&tail=true"
    )

    artifact =
      Artifacts.record(ctx.db, %{
        principal: {:session, ctx.session.session_key},
        session_key: ctx.session.session_key,
        params: %{
          kind: "report",
          title: "Server-backed artifact",
          origin_path: "sample.md",
          work_item_id: item.id
        }
      })

    assert_converges(
      ctx,
      "artifact.recorded",
      "artifacts",
      "artifactId",
      artifact.artifact_id,
      "/api/artifacts?workItemId=#{item.id}&limit=500&tail=true"
    )

    assert {:ok, turn_seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: ctx.session.session_key,
               message_id: "direct-apply-server-turn",
               origin: "user:flynn",
               prompt: "Server-backed queued turn",
               assignment_id: assignment.id,
               job_ref: item.id
             })

    assert_converges(
      ctx,
      "turn.queued",
      "turns",
      "seq",
      turn_seq,
      "/api/sessions/#{ctx.session.session_key}/turns?limit=500&tail=true"
    )

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.session.session_key,
        origin: "user:flynn",
        prompt: "Server-backed wake",
        due_at: System.system_time(:millisecond) + 60_000,
        work_item_id: item.id,
        assignment_id: assignment.id
      })

    assert_converges(
      ctx,
      "wake.scheduled",
      "wakes",
      "wakeId",
      wake.wake_id,
      "/api/sessions/#{ctx.session.session_key}/wakes?limit=500&tail=true"
    )

    renamed = Org.rename(ctx.db, ctx.session.session_key, "Server-backed renamed session")

    assert_converges(
      ctx,
      "session.updated",
      "sessions",
      "sessionKey",
      renamed.session_key,
      "/api/sessions?limit=500&tail=true"
    )
  end

  defp assert_converges(ctx, class, resource, key_field, key, rest_path) do
    notice = receive_notice(class)
    payload = notice["payload"]

    assert notice["resource"] == resource
    assert payload[key_field] == key
    assert is_integer(payload["rowVersion"])

    client = apply_upsert(%{}, {resource, key}, payload)
    assert apply_upsert(client, {resource, key}, payload) == client

    response =
      rest_get(ctx, rest_path)

    assert response.status == 200, response.resp_body
    body = JSON.decode!(response.resp_body)

    row =
      case body do
        %{"item" => item} -> item
        %{"items" => items} -> Enum.find(items, &(&1[key_field] == key))
      end

    assert row
    assert row == payload
    assert client[{resource, key}] == %{row_version: row["rowVersion"], value: row}
  end

  defp apply_upsert(client, key, row) do
    version = row["rowVersion"]

    case client[key] do
      %{row_version: held} when held >= version -> client
      _ -> Map.put(client, key, %{row_version: version, value: row})
    end
  end

  defp receive_notice(class) do
    assert_receive {:firehose_notice, notice}
    Hub.delivered(Hub, self())

    if notice["class"] == class do
      notice
    else
      receive_notice(class)
    end
  end

  defp rest_get(ctx, path) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{ctx.device.token}")
    |> Router.call(Router.init(ctx.router_opts))
  end
end
