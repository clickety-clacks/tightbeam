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
    Gateway,
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

    base =
      Path.join(
        System.tmp_dir!(),
        "firehose-direct-apply-db-#{System.unique_integer([:positive])}"
      )

    db_path = Path.join(base, "state.db")
    payload = Path.join(base, "payload")
    File.mkdir_p!(Path.join(payload, "ebin"))
    File.mkdir_p!(Path.join(payload, "priv"))
    File.write!(Path.join(payload, "ebin/fixture.beam"), "fixture")
    File.write!(Path.join(payload, "priv/fixture.rule"), "fixture")

    {:ok, manifest} =
      Tightbeam.LiveBaseGuard.generate_manifest(Tightbeam.LiveBasePayload.files!(payload))

    File.write!(Path.join(payload, "build-manifest.json"), JSON.encode!(manifest))
    on_exit(fn -> File.rm_rf!(base) end)

    start_supervised!(
      {DB, path: db_path, name: db, guard_inputs: [], payload_root: payload},
      id: db
    )

    :ok = Schema.ensure_all(db)

    {:paired, device} =
      Devices.pair(db, %{
        device_id: "firehose-direct-apply-device",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    owner_user_id = device.user_id
    _owner = Devices.set_user_admin(db, owner_user_id, false)
    _other = Devices.add_user(db, "other", false)
    _admin = Devices.add_user(db, "admin", true)

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

    page_session =
      Org.create(db, %{
        session_key: "direct-apply-page-owner",
        display_name: "Direct apply page owner",
        owner_user_id: owner_user_id,
        origin: "user:#{owner_user_id}",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    other_session =
      Org.create(db, %{
        session_key: "direct-apply-other-owner",
        display_name: "Direct apply other owner",
        owner_user_id: "other",
        origin: "user:other",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    work_item =
      WorkItems.__handle__(db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:#{owner_user_id}",
        principal: {:user, owner_user_id},
        session_key: nil,
        params: %{title: "Server-backed convergence item"}
      })

    page_work_item =
      WorkItems.__handle__(db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:#{owner_user_id}",
        principal: {:user, owner_user_id},
        session_key: nil,
        params: %{title: "Server-backed page item"}
      })

    other_work_item =
      WorkItems.__handle__(db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:other",
        principal: {:user, "other"},
        session_key: nil,
        params: %{title: "Server-backed private item"}
      })

    lifecycle_work_item =
      WorkItems.__handle__(db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:#{owner_user_id}",
        principal: {:user, owner_user_id},
        session_key: nil,
        params: %{title: "Server-backed reversible item"}
      })

    assignment =
      create_assignment(
        db,
        owner_user_id,
        session.session_key,
        work_item.id,
        "Direct apply assignment"
      )

    page_assignment =
      create_assignment(
        db,
        owner_user_id,
        page_session.session_key,
        page_work_item.id,
        "Direct apply page assignment"
      )

    other_assignment =
      create_assignment(
        db,
        "other",
        other_session.session_key,
        other_work_item.id,
        "Direct apply private assignment"
      )

    _first_attest = create_progress_attest(db, owner_user_id, session.session_key, assignment.id)
    _page_attest = create_progress_attest(db, owner_user_id, session.session_key, assignment.id)

    other_attest =
      create_progress_attest(db, "other", other_session.session_key, other_assignment.id)

    artifact =
      create_artifact(db, session.session_key, work_item.id, "Direct apply artifact")

    page_artifact =
      create_artifact(db, session.session_key, work_item.id, "Direct apply page artifact")

    other_artifact =
      create_artifact(
        db,
        other_session.session_key,
        other_work_item.id,
        "Direct apply private artifact"
      )

    {:ok, first_turn} =
      enqueue_turn(
        db,
        session.session_key,
        "direct-apply-first-turn",
        work_item.id,
        assignment.id
      )

    {:ok, page_turn} =
      enqueue_turn(db, session.session_key, "direct-apply-page-turn", work_item.id, assignment.id)

    {:ok, other_turn} =
      enqueue_turn(
        db,
        other_session.session_key,
        "direct-apply-other-turn",
        other_work_item.id,
        other_assignment.id
      )

    first_wake =
      schedule_wake(
        db,
        session.session_key,
        "Direct apply first wake",
        work_item.id,
        assignment.id
      )

    page_wake =
      schedule_wake(
        db,
        session.session_key,
        "Direct apply page wake",
        work_item.id,
        assignment.id
      )

    other_wake =
      schedule_wake(
        db,
        other_session.session_key,
        "Direct apply private wake",
        other_work_item.id,
        other_assignment.id
      )

    start_supervised!({Hub, name: Hub}, id: Hub)

    :ok =
      Hub.register(Hub, self(), %{
        mode: :all,
        db: db,
        user_id: owner_user_id,
        is_admin: false
      })

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
      base: base,
      db_path: db_path,
      db: db,
      payload: payload,
      device: device,
      owner_user_id: owner_user_id,
      session: session,
      page_session: page_session,
      other_session: other_session,
      work_item: work_item,
      page_work_item: page_work_item,
      other_work_item: other_work_item,
      lifecycle_work_item: lifecycle_work_item,
      assignment: assignment,
      page_assignment: page_assignment,
      other_assignment: other_assignment,
      other_attest: other_attest,
      artifacts: [artifact, page_artifact],
      other_artifact: other_artifact,
      turns: [first_turn, page_turn],
      other_turn: other_turn,
      wakes: [first_wake, page_wake],
      other_wake: other_wake,
      admin_walk?: false,
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
        origin: "agent:test-session",
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

  test "server rows converge after duplicate notices for every required resource", ctx do
    for resource <- [:work_items, :assignments, :attests, :artifacts, :turns, :wakes, :sessions] do
      client = walk_model(ctx, resource)
      notices = mutate_resource(ctx, resource)
      once = Enum.reduce(notices, client, &apply_notice/2)
      twice = Enum.reduce(notices, once, &apply_notice/2)

      assert twice == once, "#{resource} duplicate notice changed the client model"
      assert_matches_fresh_walk(ctx, resource, twice, "after duplicate notices")
    end
  end

  test "notices during collection and detail walks converge for every required resource", ctx do
    for resource <- [:work_items, :assignments, :attests, :artifacts, :turns, :wakes, :sessions] do
      {client, walk} = begin_walk(ctx, resource)
      notices = mutate_resource(ctx, resource)

      if resource == :turns do
        assert Enum.any?(notices, &(&1["class"] == "turn.queued"))
        assert Enum.all?(notices, &(&1["payload"]["status"] == "queued"))
      end

      client = Enum.reduce(notices, client, &apply_notice/2)
      client = continue_walk(ctx, resource, walk, client)
      assert_matches_fresh_walk(ctx, resource, client, "after a concurrent notice")
    end
  end

  test "server lifecycle reversals converge for mutable work items and assignments", ctx do
    for resource <- [:work_items, :assignments] do
      client = walk_model(ctx, resource)
      [closed, reopened] = reverse_lifecycle(ctx, resource)

      assert reopened["payload"]["rowVersion"] > closed["payload"]["rowVersion"]

      client = Enum.reduce([closed, reopened], client, &apply_notice/2)
      assert_matches_fresh_walk(ctx, resource, client, "after lifecycle reversal")
    end
  end

  test "server wake fired-to-pending reversal converges", ctx do
    wake =
      schedule_wake(
        ctx.db,
        ctx.session.session_key,
        "Server-backed wake lifecycle reversal",
        ctx.work_item.id,
        ctx.assignment.id
      )

    _scheduled = receive_notice_for(Hub, "wake.scheduled", "wakes", "wakeId", wake.wake_id)
    client = walk_model(ctx, :wakes)
    original = client[{"wakes", wake.wake_id}].value

    # Seed a fired source so this exercises the real gateway restoration path
    # in a later transaction, rather than an in-transaction transient state.
    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1 AND state='pending'",
                 [wake.wake_id, System.system_time(:millisecond)]
               )

               assert Tightbeam.DB.Txn.changes(txn) == 1
               Wakes.publish_change_in_txn(txn, "wake.fired", wake.wake_id)
             end)

    fired = receive_notice_for(Hub, "wake.fired", "wakes", "wakeId", wake.wake_id)
    assert fired["payload"]["state"] == "fired"
    assert fired["payload"]["rowVersion"] > original["rowVersion"]

    fired_client = apply_notice(fired, client)
    assert walk_model(ctx, :wakes)[{"wakes", wake.wake_id}].value == fired["payload"]

    assert_matches_fresh_walk(
      ctx,
      :wakes,
      fired_client,
      "after a wake enters the fired lifecycle"
    )

    assert {:ok, {:staged, _source}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 ctx.session.session_key,
                 wake.origin,
                 wake.prompt,
                 wake_id: wake.wake_id,
                 sender: wake.origin,
                 target_gate: wake
               )
             end)

    restored = Wakes.get(ctx.db, wake.wake_id)
    assert restored.state == "pending"
    assert is_integer(restored.fired_at)

    pending = receive_notice_for(Hub, "wake.scheduled", "wakes", "wakeId", wake.wake_id)
    assert pending["payload"]["state"] == "pending"
    assert is_integer(pending["payload"]["firedAt"])
    assert pending["payload"]["firedAt"] == fired["payload"]["firedAt"]
    assert pending["payload"]["rowVersion"] > fired["payload"]["rowVersion"]

    client = apply_notice(pending, client)

    assert walk_model(ctx, :wakes)[{"wakes", wake.wake_id}].value == pending["payload"]
    assert_matches_fresh_walk(ctx, :wakes, client, "after restoring a fired wake to pending")
  end

  test "server rows converge after database and hub owner restart for every required resource",
       ctx do
    for resource <- [:work_items, :assignments, :attests, :artifacts, :turns, :wakes, :sessions] do
      client = walk_model(ctx, resource)
      restart_server(ctx)
      notices = mutate_resource(ctx, resource)
      client = Enum.reduce(notices, client, &apply_notice/2)

      assert_matches_fresh_walk(ctx, resource, client, "after the database and hub owner restart")
    end
  end

  test "same-millisecond server writes converge for every required resource", ctx do
    occurred_at = System.system_time(:millisecond)

    for resource <- [:work_items, :assignments, :attests, :artifacts, :turns, :wakes, :sessions] do
      client = walk_model(ctx, resource)
      expected = same_millisecond_mutations(ctx, resource, occurred_at)

      notices =
        Enum.map(expected, fn {class, resource_name, key_field, key} ->
          notice = receive_notice_for(Hub, class, resource_name, key_field, key)
          assert is_integer(notice["payload"]["rowVersion"])
          notice
        end)

      for [first_notice, second_notice] <- Enum.chunk_every(notices, 2) do
        if notice_key(first_notice) == notice_key(second_notice) do
          first = first_notice["payload"]["rowVersion"]
          second = second_notice["payload"]["rowVersion"]
          assert second > first, "#{resource} did not advance the same key across two writes"
        end
      end

      case resource do
        :work_items ->
          assert Enum.all?(notices, &(&1["payload"]["rowVersion"] >= occurred_at))

        :assignments ->
          assert hd(notices)["payload"]["closedAt"] == occurred_at
          assert List.last(notices)["payload"]["state"] == "open"

        :attests ->
          assert Enum.all?(notices, &(&1["payload"]["ts"] == occurred_at))

        :artifacts ->
          assert Enum.all?(notices, &(&1["payload"]["createdAt"] == occurred_at))

        :turns ->
          assert Enum.all?(notices, &(&1["payload"]["createdAt"] == occurred_at))

        :wakes ->
          assert Enum.all?(notices, &(&1["payload"]["createdAt"] == occurred_at))

        :sessions ->
          [first, second] = Enum.map(notices, & &1["payload"]["updatedAt"])
          assert first >= occurred_at
          assert second > first
      end

      client = Enum.reduce(notices, client, &apply_notice/2)

      assert_matches_fresh_walk(ctx, resource, client, "after two same-millisecond mutations")
    end
  end

  test "server visibility changes invalidate in-progress walks and rebuild between walks", ctx do
    for resource <- [:work_items, :assignments, :attests, :artifacts, :turns, :wakes, :sessions] do
      held = walk_model(ctx, resource)
      {_partial, _walk} = begin_walk(ctx, resource)

      assert %{changed: true, user: %{is_admin: true}} = promote_owner(ctx, true)

      # Authorization changed while the walk was incomplete. Discard its
      # partial absence result, update the principal boundary, and rebuild.
      # User administration notices are intentionally visible only to admins.
      register_visibility(ctx, true)
      visible = walk_model(%{ctx | admin_walk?: true}, resource)
      promoted_model = apply_complete_walk(held, visible)

      assert promoted_model == visible,
             "#{resource} did not converge after a visibility change during its walk"

      assert map_size(visible) > map_size(held),
             "#{resource} fixture must include a row hidden from the non-admin principal"

      # A second visibility change occurs between complete walks. The next
      # walk is fresh under the demoted principal and removes rows no longer
      # visible to it.
      assert %{changed: true, user: %{is_admin: false}} = promote_owner(ctx, false)
      register_visibility(ctx, false)
      restored = walk_model(%{ctx | admin_walk?: false}, resource)
      demoted_model = apply_complete_walk(promoted_model, restored)

      assert demoted_model == restored,
             "#{resource} did not converge after a visibility change between walks"

      assert restored == held,
             "#{resource} did not return to its original complete walk after demotion"
    end
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

  defp create_assignment(db, owner, session_key, work_item_id, subject) do
    Assignments.__handle__(db, "assign", %{
      verb: "assign",
      origin: "user:#{owner}",
      principal: {:user, owner},
      session_key: session_key,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 60_000,
      params: %{subject: subject, work_item_id: work_item_id, effect_kind: "coordination"}
    })
  end

  defp create_progress_attest(
         db,
         owner,
         session_key,
         assignment_id,
         publish? \\ false,
         occurred_at \\ nil,
         note \\ nil
       ) do
    call = %{
      verb: "attest",
      origin: "agent:test-session",
      principal: {:session, session_key},
      session_key: nil,
      firehose_in_txn: publish?,
      firehose_hub: Hub,
      firehose_test_at: occurred_at,
      params: %{
        assignment_id: assignment_id,
        kind: "progress",
        note: note || "Server-backed convergence fixture for #{owner}"
      }
    }

    result = Assignments.__handle__(db, "attest", call)

    result.attest
  end

  defp create_artifact(db, session_key, work_item_id, title) do
    Artifacts.record(db, %{
      principal: {:session, session_key},
      session_key: session_key,
      params: %{
        kind: "report",
        title: title,
        origin_path: "sample.md",
        work_item_id: work_item_id
      }
    })
  end

  defp enqueue_turn(db, session_key, message_id, work_item_id, assignment_id, occurred_at \\ nil) do
    attrs = %{
      session_key: session_key,
      message_id: message_id,
      origin: "user:direct-apply",
      prompt: "Server-backed queued turn #{message_id}",
      assignment_id: assignment_id,
      job_ref: work_item_id
    }

    Ledger.enqueue(
      db,
      if(is_integer(occurred_at),
        do: Map.put(attrs, :firehose_test_at, occurred_at),
        else: attrs
      )
    )
  end

  defp schedule_wake(db, session_key, prompt, work_item_id, assignment_id, occurred_at \\ nil) do
    attrs = %{
      session_key: session_key,
      origin: "user:direct-apply",
      prompt: prompt,
      due_at: System.system_time(:millisecond) + 60_000,
      work_item_id: work_item_id,
      assignment_id: assignment_id
    }

    Wakes.schedule(
      db,
      if(is_integer(occurred_at),
        do: Map.put(attrs, :firehose_test_at, occurred_at),
        else: attrs
      )
    )
  end

  defp begin_walk(ctx, :assignments) do
    row = rest_item!(ctx, "/api/assignments/#{ctx.assignment.id}")
    client = model_from_rows("assignments", [row])
    {client, %{ids: [ctx.assignment.id, ctx.page_assignment.id], detail_walk: true}}
  end

  defp begin_walk(ctx, resource) when resource in [:turns, :wakes] do
    client = walk_model(ctx, resource)
    path = page_path(ctx, resource)
    {rows, page} = fetch_page!(ctx, path, nil)

    assert page_more?(page), "#{resource} fixture must span more than one REST page"
    {apply_rows(client, resource_name(resource), rows), %{path: path, page: page}}
  end

  defp begin_walk(ctx, resource) do
    path = page_path(ctx, resource)
    {rows, page} = fetch_page!(ctx, path, nil)

    assert page_more?(page), "#{resource} fixture must span more than one REST page"
    {model_from_rows(resource_name(resource), rows), %{path: path, page: page}}
  end

  defp continue_walk(ctx, :assignments, %{ids: ids}, client) do
    Enum.reduce(tl(ids), client, fn assignment_id, acc ->
      row = rest_item!(ctx, "/api/assignments/#{assignment_id}")
      apply_upsert(acc, {"assignments", assignment_id}, row)
    end)
  end

  defp continue_walk(ctx, resource, %{path: path, page: page}, client) do
    cursor = page_cursor(page)
    continue_pages(ctx, resource, path, cursor, client)
  end

  defp continue_pages(_ctx, _resource, _path, nil, client), do: client

  defp continue_pages(ctx, resource, path, cursor, client) do
    {rows, page} = fetch_page!(ctx, path, cursor)
    client = apply_rows(client, resource_name(resource), rows)

    if page_more?(page),
      do: continue_pages(ctx, resource, path, page_cursor(page), client),
      else: client
  end

  defp fetch_page!(ctx, path, nil) do
    response = rest_get(ctx, path <> "?limit=1&tail=false")
    assert response.status == 200, response.resp_body
    body = JSON.decode!(response.resp_body)
    {body["items"], body["page"]}
  end

  defp fetch_page!(ctx, path, cursor) do
    response = rest_get(ctx, path <> "?limit=1&after=#{cursor}")
    assert response.status == 200, response.resp_body
    body = JSON.decode!(response.resp_body)
    {body["items"], body["page"]}
  end

  defp walk_model(ctx, :assignments) do
    rows =
      [ctx.assignment.id, ctx.page_assignment.id, ctx.other_assignment.id]
      |> Enum.flat_map(fn assignment_id ->
        response = rest_get(ctx, "/api/assignments/#{assignment_id}")

        case response.status do
          200 -> [JSON.decode!(response.resp_body)["item"]]
          404 -> []
          status -> flunk("assignment detail walk returned #{status}: #{response.resp_body}")
        end
      end)

    model_from_rows("assignments", rows)
  end

  defp walk_model(ctx, resource) do
    rows =
      walk_paths(ctx, resource)
      |> Enum.flat_map(&walk_path(ctx, resource, &1))

    model_from_rows(resource_name(resource), rows)
  end

  defp walk_paths(_ctx, :work_items), do: ["/api/work-items"]
  defp walk_paths(_ctx, :attests), do: ["/api/attests"]
  defp walk_paths(_ctx, :artifacts), do: ["/api/artifacts"]
  defp walk_paths(_ctx, :sessions), do: ["/api/sessions"]

  defp walk_paths(ctx, resource) when resource in [:turns, :wakes] do
    sessions =
      if ctx.admin_walk?,
        do: [ctx.session.session_key, ctx.page_session.session_key, ctx.other_session.session_key],
        else: [ctx.session.session_key, ctx.page_session.session_key]

    Enum.map(sessions, &page_path(ctx, resource, &1))
  end

  defp walk_path(ctx, resource, path) do
    case rest_get(ctx, path <> "?limit=1&tail=false") do
      %{status: 200} ->
        walk_pages(ctx, resource, path, nil)

      %{status: 404} when resource in [:turns, :wakes] ->
        []

      response ->
        flunk("#{resource} REST walk returned #{response.status}: #{response.resp_body}")
    end
  end

  defp walk_pages(ctx, resource, path, cursor) do
    {rows, page} = fetch_page!(ctx, path, cursor)

    if page_more?(page) do
      rows ++ walk_pages(ctx, resource, path, page_cursor(page))
    else
      rows
    end
  end

  defp page_path(_ctx, :work_items), do: "/api/work-items"
  defp page_path(_ctx, :attests), do: "/api/attests"
  defp page_path(_ctx, :artifacts), do: "/api/artifacts"
  defp page_path(_ctx, :sessions), do: "/api/sessions"
  defp page_path(ctx, :turns), do: page_path(ctx, :turns, ctx.session.session_key)
  defp page_path(ctx, :wakes), do: page_path(ctx, :wakes, ctx.session.session_key)
  defp page_path(_ctx, :turns, session_key), do: "/api/sessions/#{session_key}/turns"
  defp page_path(_ctx, :wakes, session_key), do: "/api/sessions/#{session_key}/wakes"

  defp mutate_resource(ctx, :work_items) do
    item =
      WorkItems.__handle__(ctx.db, "work-item-update", %{
        verb: "work-item-update",
        origin: "user:#{ctx.owner_user_id}",
        principal: {:user, ctx.owner_user_id},
        session_key: nil,
        firehose_in_txn: true,
        firehose_hub: Hub,
        supervision_interval_ms: 1_000,
        params: %{
          work_item_id: ctx.work_item.id,
          title: "Updated during server walk #{System.unique_integer([:positive])}"
        }
      })

    updated = receive_notice_for(Hub, "work_item.updated", "work-items", "id", item.id)
    [updated]
  end

  defp mutate_resource(ctx, :assignments) do
    closed_result = complete_assignment(ctx, ctx.assignment.id)

    assert %{attest: %{kind: "completion"}, assignment: %{state: "closed"}} = closed_result

    closed = receive_notice_for(Hub, "assignment.closed", "assignments", "id", ctx.assignment.id)

    [closed]
  end

  defp mutate_resource(ctx, :attests) do
    attest =
      create_progress_attest(
        ctx.db,
        ctx.owner_user_id,
        ctx.page_session.session_key,
        ctx.page_assignment.id,
        true
      )

    [receive_notice_for(Hub, "attest.filed", "attests", "id", attest.id)]
  end

  defp mutate_resource(ctx, :artifacts) do
    artifact =
      create_artifact(ctx.db, ctx.session.session_key, ctx.work_item.id, "Artifact during walk")

    [
      receive_notice_for(
        Hub,
        "artifact.recorded",
        "artifacts",
        "artifactId",
        artifact.artifact_id
      )
    ]
  end

  defp mutate_resource(ctx, :turns) do
    {:ok, seq} =
      enqueue_turn(
        ctx.db,
        ctx.session.session_key,
        "direct-apply-overlap-turn",
        ctx.work_item.id,
        ctx.assignment.id
      )

    notice = receive_notice_for(Hub, "turn.queued", "turns", "seq", seq)
    assert notice["payload"]["status"] == "queued"
    [notice]
  end

  defp mutate_resource(ctx, :wakes) do
    wake =
      schedule_wake(
        ctx.db,
        ctx.session.session_key,
        "Wake created during server walk",
        ctx.work_item.id,
        ctx.assignment.id
      )

    [receive_notice_for(Hub, "wake.scheduled", "wakes", "wakeId", wake.wake_id)]
  end

  defp mutate_resource(ctx, :sessions) do
    session =
      Org.rename(
        ctx.db,
        ctx.session.session_key,
        "Renamed during server walk"
      )

    renamed =
      receive_notice_for(Hub, "session.updated", "sessions", "sessionKey", session.session_key)

    [renamed]
  end

  defp reverse_lifecycle(ctx, :work_items) do
    icebox_call = work_item_disposition_call(ctx, "work-item-icebox")
    assert %{ok: true} = WorkItems.__handle__(ctx.db, "work-item-icebox", icebox_call)

    iceboxed =
      receive_notice_for(
        Hub,
        "work_item.iceboxed",
        "work-items",
        "id",
        ctx.lifecycle_work_item.id
      )

    reopen_call = work_item_disposition_call(ctx, "work-item-reopen")
    assert %{ok: true} = WorkItems.__handle__(ctx.db, "work-item-reopen", reopen_call)

    reopened =
      receive_notice_for(
        Hub,
        "work_item.reopened",
        "work-items",
        "id",
        ctx.lifecycle_work_item.id
      )

    [iceboxed, reopened]
  end

  defp reverse_lifecycle(ctx, :assignments) do
    closed_result = complete_assignment(ctx, ctx.assignment.id)

    assert %{attest: %{kind: "completion"}, assignment: %{state: "closed"}} = closed_result

    closed = receive_notice_for(Hub, "assignment.closed", "assignments", "id", ctx.assignment.id)
    _reopened = reopen_assignment(ctx, ctx.assignment.id)

    reopened =
      receive_notice_for(Hub, "assignment.reopened", "assignments", "id", ctx.assignment.id)

    [closed, reopened]
  end

  defp same_millisecond_mutations(ctx, :work_items, occurred_at) do
    for title <- ["Same-millisecond work item A", "Same-millisecond work item B"] do
      item =
        WorkItems.__handle__(ctx.db, "work-item-update", %{
          verb: "work-item-update",
          origin: "user:#{ctx.owner_user_id}",
          principal: {:user, ctx.owner_user_id},
          session_key: nil,
          firehose_in_txn: true,
          firehose_hub: Hub,
          supervision_interval_ms: 1_000,
          firehose_test_at: occurred_at,
          params: %{work_item_id: ctx.work_item.id, title: title}
        })

      {"work_item.updated", "work-items", "id", item.id}
    end
  end

  defp same_millisecond_mutations(ctx, :assignments, occurred_at) do
    closed = revoke_assignment(ctx, ctx.assignment.id, occurred_at)
    reopened = reopen_assignment(ctx, ctx.assignment.id, occurred_at)
    assert closed.state == "closed"
    assert reopened.state == "open"

    [
      {"assignment.closed", "assignments", "id", ctx.assignment.id},
      {"assignment.reopened", "assignments", "id", ctx.assignment.id}
    ]
  end

  defp same_millisecond_mutations(ctx, :attests, occurred_at) do
    for note <- ["Same-millisecond attest A", "Same-millisecond attest B"] do
      attest =
        create_progress_attest(
          ctx.db,
          ctx.owner_user_id,
          ctx.page_session.session_key,
          ctx.page_assignment.id,
          true,
          occurred_at,
          note
        )

      {"attest.filed", "attests", "id", attest.id}
    end
  end

  defp same_millisecond_mutations(ctx, :artifacts, occurred_at) do
    clock_key = {Artifacts, :test_clock}
    prior_clock = Process.get(clock_key)
    Process.put(clock_key, occurred_at)

    try do
      for suffix <- ["A", "B"] do
        artifact =
          create_artifact(
            ctx.db,
            ctx.session.session_key,
            ctx.work_item.id,
            "Same-millisecond artifact #{suffix}"
          )

        {"artifact.recorded", "artifacts", "artifactId", artifact.artifact_id}
      end
    after
      if is_nil(prior_clock),
        do: Process.delete(clock_key),
        else: Process.put(clock_key, prior_clock)
    end
  end

  defp same_millisecond_mutations(ctx, :turns, occurred_at) do
    for suffix <- ["a", "b"] do
      message_id = "direct-apply-same-ms-turn-#{suffix}-#{System.unique_integer([:positive])}"

      {:ok, seq} =
        enqueue_turn(
          ctx.db,
          ctx.session.session_key,
          message_id,
          ctx.work_item.id,
          ctx.assignment.id,
          occurred_at
        )

      {"turn.queued", "turns", "seq", seq}
    end
  end

  defp same_millisecond_mutations(ctx, :wakes, occurred_at) do
    for suffix <- ["A", "B"] do
      wake =
        schedule_wake(
          ctx.db,
          ctx.session.session_key,
          "Same-millisecond wake #{suffix}",
          ctx.work_item.id,
          ctx.assignment.id,
          occurred_at
        )

      {"wake.scheduled", "wakes", "wakeId", wake.wake_id}
    end
  end

  defp same_millisecond_mutations(ctx, :sessions, occurred_at) do
    session_key = ctx.session.session_key

    for name <- ["Same-millisecond session A", "Same-millisecond session B"] do
      transaction!(ctx.db, fn txn ->
        {:changed, _session, _result} =
          Org.mutate_session_in_txn(
            txn,
            session_key,
            fn ->
              Tightbeam.DB.Txn.q(txn, "UPDATE sessions SET displayName=?2 WHERE sessionKey=?1", [
                session_key,
                name
              ])
            end,
            occurred_at
          )
      end)

      {"session.updated", "sessions", "sessionKey", session_key}
    end
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp notice_key(%{"resource" => "work-items", "payload" => row}), do: {"work-items", row["id"]}

  defp notice_key(%{"resource" => "assignments", "payload" => row}),
    do: {"assignments", row["id"]}

  defp notice_key(%{"resource" => "attests", "payload" => row}), do: {"attests", row["id"]}

  defp notice_key(%{"resource" => "artifacts", "payload" => row}),
    do: {"artifacts", row["artifactId"]}

  defp notice_key(%{"resource" => "turns", "payload" => row}), do: {"turns", row["seq"]}
  defp notice_key(%{"resource" => "wakes", "payload" => row}), do: {"wakes", row["wakeId"]}

  defp notice_key(%{"resource" => "sessions", "payload" => row}),
    do: {"sessions", row["sessionKey"]}

  defp work_item_disposition_call(ctx, verb) do
    %{
      verb: verb,
      origin: "user:#{ctx.owner_user_id}",
      principal: {:user, ctx.owner_user_id},
      session_key: nil,
      firehose_in_txn: true,
      firehose_hub: Hub,
      params: %{work_item_id: ctx.lifecycle_work_item.id}
    }
  end

  defp complete_assignment(ctx, assignment_id) do
    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "agent:test-session",
      principal: {:session, ctx.session.session_key},
      session_key: nil,
      firehose_in_txn: true,
      firehose_hub: Hub,
      params: %{
        assignment_id: assignment_id,
        kind: "completion",
        note: "Complete during server-backed convergence"
      }
    })
  end

  defp reopen_assignment(ctx, assignment_id, occurred_at \\ nil) do
    call = %{
      verb: "reopen-assignment",
      origin: "agent:test-session",
      principal: {:session, ctx.session.session_key},
      session_key: nil,
      firehose_in_txn: true,
      firehose_hub: Hub,
      supervision_interval_ms: 60_000,
      params: %{assignment_id: assignment_id, reason: "Continue server-backed convergence"}
    }

    Assignments.__handle__(
      ctx.db,
      "reopen-assignment",
      if(is_integer(occurred_at), do: Map.put(call, :firehose_test_at, occurred_at), else: call)
    )
  end

  defp revoke_assignment(ctx, assignment_id, occurred_at) do
    Assignments.__handle__(ctx.db, "revoke-assignment", %{
      verb: "revoke-assignment",
      origin: "user:#{ctx.owner_user_id}",
      principal: {:user, ctx.owner_user_id},
      session_key: nil,
      firehose_in_txn: true,
      firehose_hub: Hub,
      firehose_test_at: occurred_at,
      params: %{assignment_id: assignment_id, reason: "Close during same-millisecond convergence"}
    })
  end

  defp assert_matches_fresh_walk(ctx, resource, client, scenario) do
    snapshot = walk_model(ctx, resource)

    assert client == snapshot,
           "#{resource} did not converge #{scenario}: #{inspect(model_diff(client, snapshot))}"

    snapshot
  end

  defp apply_complete_walk(client, snapshot) do
    visible_keys = Map.keys(snapshot) |> MapSet.new()

    client =
      Enum.reduce(snapshot, client, fn {key, %{value: row}}, acc ->
        apply_upsert(acc, key, row)
      end)

    Map.reject(client, fn {key, _row} -> not MapSet.member?(visible_keys, key) end)
  end

  defp promote_owner(ctx, is_admin) do
    Devices.promote_user_with_firehose(ctx.db, ctx.owner_user_id, is_admin, %{
      verb: "promote-user",
      origin: "user:admin",
      principal: {:user, "admin"},
      session_key: nil,
      params: %{user_id: ctx.owner_user_id, is_admin: is_admin},
      firehose_in_txn: true,
      firehose_hub: Hub
    })
  end

  defp register_visibility(ctx, is_admin) do
    :ok =
      Hub.register(Hub, self(), %{
        mode: :all,
        db: ctx.db,
        user_id: ctx.owner_user_id,
        is_admin: is_admin
      })
  end

  defp restart_server(ctx) do
    _ = Hub.unregister(Hub, self())
    :ok = stop_supervised!(Hub)
    :ok = stop_supervised!(ctx.db)

    start_supervised!(
      {DB, path: ctx.db_path, name: ctx.db, guard_inputs: [], payload_root: ctx.payload},
      id: ctx.db
    )

    :ok = Schema.ensure_all(ctx.db)
    start_supervised!({Hub, name: Hub}, id: Hub)
    register_visibility(ctx, false)
  end

  defp receive_notice_for(server, class, resource, key_field, key, skipped \\ []) do
    receive do
      {:firehose_notice, notice} ->
        Hub.delivered(server, self())

        if notice["class"] == class and notice["resource"] == resource and
             notice["payload"][key_field] == key do
          notice
        else
          receive_notice_for(
            server,
            class,
            resource,
            key_field,
            key,
            Enum.take([notice | skipped], 8)
          )
        end
    after
      1_000 ->
        flunk(
          "missing #{class} notice for #{resource} #{key_field}=#{key}; " <>
            "last notices: #{inspect(Enum.reverse(skipped))}"
        )
    end
  end

  defp rest_item!(ctx, path) do
    response = rest_get(ctx, path)
    assert response.status == 200, response.resp_body
    JSON.decode!(response.resp_body)["item"]
  end

  defp model_from_rows(resource, rows) do
    Enum.reduce(rows, %{}, fn row, client ->
      apply_upsert(client, {resource, row_key(resource, row)}, row)
    end)
  end

  defp apply_rows(client, resource, rows) do
    Enum.reduce(rows, client, fn row, acc ->
      apply_upsert(acc, {resource, row_key(resource, row)}, row)
    end)
  end

  defp apply_notice(notice, client) do
    row = notice["payload"]
    resource = notice["resource"]
    apply_upsert(client, {resource, row_key(resource, row)}, row)
  end

  defp model_diff(client, snapshot) do
    (Map.keys(client) ++ Map.keys(snapshot))
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn key, diff ->
      client_row = Map.get(client, key)
      snapshot_row = Map.get(snapshot, key)

      if client_row == snapshot_row,
        do: diff,
        else: Map.put(diff, key, %{client: client_row, rest: snapshot_row})
    end)
  end

  defp row_key("work-items", row), do: row["id"]
  defp row_key("assignments", row), do: row["id"]
  defp row_key("attests", row), do: row["id"]
  defp row_key("artifacts", row), do: row["artifactId"]
  defp row_key("turns", row), do: row["seq"]
  defp row_key("wakes", row), do: row["wakeId"]
  defp row_key("sessions", row), do: row["sessionKey"]

  defp resource_name(:work_items), do: "work-items"
  defp resource_name(:assignments), do: "assignments"
  defp resource_name(:attests), do: "attests"
  defp resource_name(:artifacts), do: "artifacts"
  defp resource_name(:turns), do: "turns"
  defp resource_name(:wakes), do: "wakes"
  defp resource_name(:sessions), do: "sessions"

  defp page_more?(page),
    do: Map.get(page, "after", Map.get(page, "hasMoreAfter", false))

  defp page_cursor(page), do: Map.get(page, "newest") || Map.get(page, "newestCursor")
end
