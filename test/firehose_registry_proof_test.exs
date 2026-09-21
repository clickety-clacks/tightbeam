defmodule Tightbeam.Firehose.RegistryProofTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Firehose.{Hub, Publisher, Registry}
  alias Tightbeam.{DB, Gateway, Model, Org, StateVisibility, SubagentMarkers, Toplines}

  @r8_groups [
    {~w(work_item.created work_item.updated work_item.iceboxed work_item.reopened work_item.closed work_item.failed),
     "work-items", "upsert", ["workItemId"], :work_item},
    {~w(assignment.opened assignment.reopened assignment.closed), "assignments", "upsert",
     ["assignmentId"], :assignment},
    {~w(attest.filed), "attests", "upsert", ["attestId"], :attest},
    {~w(wake.scheduled wake.fired wake.canceled), "wakes", "upsert", ["wakeId"], :wake},
    {~w(turn.started turn.ended), "turns", "upsert", ["turnSeq"], :turn},
    {~w(decision_request.opened decision_request.ruled decision_request.returned decision_request.withdrawn),
     "decision-requests", "upsert", ["decisionRequestId"], :decision_request},
    {~w(session.spawned session.updated session.retired), "sessions", "upsert", ["sessionKey"],
     :session},
    {~w(role.created role.bound), "roles", "upsert", ["role"], :role},
    {~w(role.removed), "roles", "delete", ["role"], :role},
    {~w(user.added), "users", "upsert", ["userId"], :user},
    {~w(device.approved device.denied device.revoked), "devices", "upsert", ["deviceId"],
     :device},
    {~w(artifact.recorded artifact.archived artifact.released), "artifacts", "upsert",
     ["artifactId"], :artifact},
    {~w(read_marker.updated), "read-markers", "upsert", ["userId", "scopeKey"], :read_marker},
    {~w(message.created), "messages", "upsert", ["messageId", "sessionKey"], :message},
    {~w(condition_fact.filed), "condition-facts", "upsert", ["factId"], :condition_fact},
    {~w(critical_lease.updated), "critical-state", "upsert", ["sessionKey"], :critical_state},
    {~w(config.updated), "config", "upsert", ["key"], :config},
    {~w(host_env.updated), "host environment", "upsert", ["host", "harness", "name"],
     :host_environment},
    {~w(host.registered), "hosts", "upsert", ["host"], :host},
    {~w(user.promoted user.demoted), "users", "upsert", ["userId"], :user},
    {~w(identity.updated), "identity", "upsert", ["name"], :identity},
    {~w(kungfu.updated), "kungfu", "upsert", ["name"], :kungfu}
  ]

  @r8b_inventory %{
    "topline.created" => %{
      class: "topline.created",
      op: "observe",
      ref_sets: [["toplineId"]],
      source: {Toplines, "topline_created"},
      version_source: "topline_events.seq",
      occurred_at_source: "topline_events.eventAt",
      visibility: :topline_visible?
    },
    "topline_work_membership.linked" => %{
      class: "topline_work_membership.linked",
      op: "observe",
      ref_sets: [["membershipId", "toplineId", "workItemId"]],
      source: {Toplines, "work_linked"},
      version_source: "topline_events.seq",
      occurred_at_source: "topline_events.eventAt",
      visibility: :topline_visible?
    },
    "topline_work_membership.unlinked" => %{
      class: "topline_work_membership.unlinked",
      op: "observe",
      ref_sets: [["membershipId", "toplineId", "workItemId"]],
      source: {Toplines, "work_unlinked"},
      version_source: "topline_events.seq",
      occurred_at_source: "topline_events.eventAt",
      visibility: :topline_visible?
    },
    "subagent_marker.appended" => %{
      class: "subagent_marker.appended",
      op: "observe",
      ref_sets: [
        ["markerId", "sessionKey"],
        ["assignmentId", "markerId", "sessionKey", "workItemId"]
      ],
      source: {SubagentMarkers, :insert},
      version_source: "subagent_markers.id",
      occurred_at_source: "subagent_markers.at",
      visibility: :subagent_marker_visible?
    }
  }

  @filter_refs %{
    "sessionKey" => "s_flynn",
    "workItemId" => "wi_firehose",
    "origin" => "user:flynn",
    "principal" => "user:flynn"
  }

  setup do
    suffix = System.unique_integer([:positive])
    db = :"firehose_registry_proof_db_#{suffix}"
    hub = :"firehose_registry_proof_hub_#{suffix}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Hub, name: hub})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Toplines.ensure_schema(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES " <>
          "('flynn', 0, 1), ('kay', 0, 1), ('root', 1, 1)"
      )

    session!(db, "s_flynn", "flynn")
    work_item!(db, "wi_firehose", "flynn")
    assignment!(db, "asg_firehose", "s_flynn", "wi_firehose")
    %{db: db, hub: hub}
  end

  test "A1 closed R8 and R8b tables reject removed, added, drifted, and unmapped sources", ctx do
    expected_r8 = expected_r8_inventory()
    actual_r8 = Map.new(Registry.rows(), fn {class, row} -> {class, r8_shape(row)} end)
    assert :ok = assert_closed_map!("R8 registry", expected_r8, actual_r8)

    assert_raise ArgumentError, ~r/R8 registry.*removed=\["work_item.created"\]/, fn ->
      assert_closed_map!("R8 registry", expected_r8, Map.delete(actual_r8, "work_item.created"))
    end

    assert_raise ArgumentError, ~r/R8 registry.*added=\["invented.extra"\]/, fn ->
      assert_closed_map!(
        "R8 registry",
        expected_r8,
        Map.put(actual_r8, "invented.extra", Map.fetch!(actual_r8, "work_item.created"))
      )
    end

    assert_raise ArgumentError, ~r/R8 registry.*drifted=\["work_item.created"\]/, fn ->
      drifted = put_in(actual_r8, ["work_item.created", :resource], "wrong-resource")
      assert_closed_map!("R8 registry", expected_r8, drifted)
    end

    actual_r8b =
      Map.new(Registry.invalidation_rows(), fn {class, row} ->
        {class, Map.take(row, Map.keys(Map.fetch!(@r8b_inventory, class)))}
      end)

    assert :ok = assert_closed_map!("R8b registry", @r8b_inventory, actual_r8b)

    gateway_classes =
      ctx.db
      |> then(&Gateway.handler_effects(%{db: &1}))
      |> Gateway.emitted_state_classes()
      |> Map.new(&{&1, &1})

    registry_classes = Map.new(Map.keys(Registry.rows()), &{&1, &1})
    assert :ok = assert_closed_map!("R8 production classes", registry_classes, gateway_classes)

    production_sources =
      Enum.concat([
        Enum.map(Toplines.firehose_sources(), fn {source, class} ->
          {{Toplines, source}, class}
        end),
        Enum.map(SubagentMarkers.firehose_sources(), fn {source, class} ->
          {{SubagentMarkers, source}, class}
        end)
      ])
      |> Map.new()

    registry_sources =
      Registry.invalidation_rows()
      |> Map.values()
      |> Map.new(&{&1.source, &1.class})

    assert :ok =
             assert_closed_map!("R8b production sources", registry_sources, production_sources)

    assert Code.ensure_loaded?(StateVisibility)

    assert Enum.all?(Registry.invalidation_rows(), fn {class, row} ->
             class == row.class and row.op == "observe" and
               function_exported?(StateVisibility, row.visibility, 4) and
               match?(:error, Registry.fetch(class))
           end)
  end

  test "A1 source commits emit one exact invalidation and replay, refusal, or duplicate emits none",
       ctx do
    :ok =
      Hub.register(ctx.hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: false})

    create_call = topline_call(ctx, %{title: "Firehose", idempotency_key: "create"})
    created = Toplines.create(ctx.db, create_call)
    topline_id = created.topline.id

    assert_source_notice(
      take_notice(ctx.hub),
      "topline.created",
      %{"toplineId" => topline_id},
      1,
      event_at(ctx.db, topline_id, 1)
    )

    assert created == Toplines.create(ctx.db, create_call)
    assert_quiet(ctx.hub)

    assert %{code: "idempotency_conflict"} =
             Toplines.create(ctx.db, put_in(create_call, [:params, :title], "Changed"))

    assert_quiet(ctx.hub)

    link_call =
      topline_call(ctx, %{
        topline_id: topline_id,
        work_item_id: "wi_firehose",
        reason: "belongs here",
        idempotency_key: "link"
      })

    linked = Toplines.link_work(ctx.db, link_call)
    membership_id = linked.membership.id

    link_refs = %{
      "toplineId" => topline_id,
      "membershipId" => membership_id,
      "workItemId" => "wi_firehose"
    }

    assert_source_notice(
      take_notice(ctx.hub),
      "topline_work_membership.linked",
      link_refs,
      2,
      event_at(ctx.db, topline_id, 2)
    )

    assert linked == Toplines.link_work(ctx.db, link_call)
    assert_quiet(ctx.hub)

    assert %{code: "membership_exists"} =
             Toplines.link_work(
               ctx.db,
               put_in(link_call, [:params, :idempotency_key], "link-refusal")
             )

    assert_quiet(ctx.hub)

    unlink_call =
      topline_call(ctx, %{
        membership_id: membership_id,
        reason: "done",
        idempotency_key: "unlink"
      })

    unlinked = Toplines.unlink_work(ctx.db, unlink_call)

    assert_source_notice(
      take_notice(ctx.hub),
      "topline_work_membership.unlinked",
      link_refs,
      3,
      event_at(ctx.db, topline_id, 3)
    )

    assert unlinked == Toplines.unlink_work(ctx.db, unlink_call)
    assert_quiet(ctx.hub)

    marker_input = marker_input(ctx, "event-resolved", "asg_firehose", 700)
    assert {:ok, %{appended: true}} = append_marker(ctx.db, marker_input)
    marker_id = marker_id(ctx.db, "event-resolved")

    assert_source_notice(
      take_notice(ctx.hub),
      "subagent_marker.appended",
      %{
        "markerId" => Integer.to_string(marker_id),
        "sessionKey" => "s_flynn",
        "assignmentId" => "asg_firehose",
        "workItemId" => "wi_firehose"
      },
      marker_id,
      700
    )

    assert {:ok, %{appended: false}} = append_marker(ctx.db, marker_input)
    assert_quiet(ctx.hub)

    unresolved = marker_input(ctx, "event-unresolved", "asg_missing", 701)
    assert {:ok, %{appended: true}} = append_marker(ctx.db, unresolved)
    unresolved_id = marker_id(ctx.db, "event-unresolved")

    assert unresolved_id > marker_id

    unresolved_notice =
      Publisher.source_invalidation_notice("subagent_marker.appended", unresolved_id, 701, %{
        "markerId" => Integer.to_string(unresolved_id),
        "sessionKey" => "s_flynn"
      })

    refute StateVisibility.visible?(ctx.db, unresolved_notice, "flynn", false)
    refute StateVisibility.visible?(ctx.db, unresolved_notice, "root", true)

    assert_quiet(ctx.hub)
  end

  test "maintenance rename close and reopen retain events without inventing invalidations", ctx do
    :ok =
      Hub.register(ctx.hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: false})

    created =
      Toplines.create(
        ctx.db,
        topline_call(ctx, %{title: "Before", idempotency_key: "create-maintenance"})
      )

    id = created.topline.id

    assert_source_notice(
      take_notice(ctx.hub),
      "topline.created",
      %{"toplineId" => id},
      1,
      event_at(ctx.db, id, 1)
    )

    updated =
      Toplines.update(
        ctx.db,
        topline_call(ctx, %{
          topline_id: id,
          title: "After",
          reason: "rename",
          idempotency_key: "rename"
        })
      )

    assert updated.topline.title == "After"
    assert_quiet(ctx.hub)
    close_call = topline_call(ctx, %{topline_id: id, reason: "close", idempotency_key: "close"})
    closed = Toplines.close(ctx.db, close_call)
    assert closed.topline.state == "closed"
    assert closed == Toplines.close(ctx.db, close_call)
    assert_quiet(ctx.hub)

    reopened =
      Toplines.reopen(
        ctx.db,
        topline_call(ctx, %{topline_id: id, reason: "reopen", idempotency_key: "reopen"})
      )

    assert reopened.topline.state == "open"
    assert_quiet(ctx.hub)

    assert {:ok,
            [
              ["topline_created", 1],
              ["topline_renamed", 2],
              ["topline_closed", 3],
              ["topline_reopened", 4]
            ]} =
             DB.query(
               ctx.db,
               "SELECT kind, seq FROM topline_events WHERE toplineId = ?1 ORDER BY seq",
               [id]
             )
  end

  test "rolled-back marker source has neither durable row nor postcommit notice", ctx do
    :ok =
      Hub.register(ctx.hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: false})

    assert {:error, %RuntimeError{message: "abort marker"}} =
             DB.transaction(ctx.db, fn txn ->
               assert %{appended: true} =
                        SubagentMarkers.append_in_txn(
                          txn,
                          marker_input(ctx, "rollback-marker", "asg_firehose", 900)
                        )

               raise "abort marker"
             end)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM subagent_markers WHERE sourceEventRef = 'rollback-marker'"
             )

    assert_quiet(ctx.hub)
  end

  test "A1 mapping drift refuses unknown, missing, extra, partial, and invalid versions" do
    assert %{
             "class" => "topline.created",
             "op" => "observe",
             "refs" => %{"toplineId" => "tl_one"},
             "payload" => %{"sourceVersion" => 1}
           } =
             Publisher.source_invalidation_notice("topline.created", 1, 2, %{
               "toplineId" => "tl_one"
             })

    assert_raise ArgumentError, ~r/unregistered firehose source invalidation/, fn ->
      Publisher.source_invalidation_notice("unknown.source", 1, 2, %{"id" => "one"})
    end

    assert_raise ArgumentError, ~r/refs do not match the registry/, fn ->
      Publisher.source_invalidation_notice("topline.created", 1, 2, %{})
    end

    assert_raise ArgumentError, ~r/refs do not match the registry/, fn ->
      Publisher.source_invalidation_notice("topline.created", 1, 2, %{
        "toplineId" => "tl_one",
        "origin" => "user:flynn"
      })
    end

    assert_raise ArgumentError, ~r/refs do not match the registry/, fn ->
      Publisher.source_invalidation_notice("subagent_marker.appended", 1, 2, %{
        "markerId" => "1",
        "sessionKey" => "s_flynn",
        "assignmentId" => "asg_firehose"
      })
    end

    assert_raise ArgumentError, ~r/invalid firehose source invalidation/, fn ->
      Publisher.source_invalidation_notice("topline.created", 0, 2, %{"toplineId" => "tl_one"})
    end
  end

  test "increment independently closes exactly four real R8b source mappings" do
    assert Registry.invalidation_rows() == @r8b_inventory

    production =
      Enum.concat(
        Enum.map(Toplines.firehose_sources(), fn {source, class} ->
          {{Toplines, source}, class}
        end),
        Enum.map(SubagentMarkers.firehose_sources(), fn {source, class} ->
          {{SubagentMarkers, source}, class}
        end)
      )
      |> Map.new()

    assert production == Map.new(@r8b_inventory, fn {class, row} -> {row.source, class} end)
  end

  test "A3 every R8 and R8b row obeys class and present, absent, different, and conjunctive refs" do
    Enum.each(Registry.rows(), fn {class, row} ->
      refs =
        Enum.reduce(row.primary_refs, @filter_refs, fn key, refs ->
          Map.put_new(refs, key, ref_value(key))
        end)

      assert_filter_matrix!(class, refs)
    end)

    Enum.each(Registry.invalidation_rows(), fn {class, row} ->
      Enum.each(row.ref_sets, fn ref_set ->
        refs = Map.new(ref_set, &{&1, ref_value(&1)})
        assert_filter_matrix!(class, refs)
      end)
    end)
  end

  test "A3 source visibility runs before matching and hidden rows emit no frame", ctx do
    %{valid: notices, unresolved_marker: unresolved_marker} = visibility_notices(ctx)

    Enum.each(notices, fn notice ->
      assert StateVisibility.visible?(ctx.db, notice, "flynn", false)
      refute StateVisibility.visible?(ctx.db, notice, "kay", false)
      assert StateVisibility.visible?(ctx.db, notice, "root", true)
    end)

    refute StateVisibility.visible?(ctx.db, unresolved_marker, "flynn", false)
    refute StateVisibility.visible?(ctx.db, unresolved_marker, "root", true)

    missing_topline =
      Publisher.source_invalidation_notice("topline.created", 1, 1, %{
        "toplineId" => "tl_missing"
      })

    refute StateVisibility.visible?(ctx.db, missing_topline, "root", true)

    hub_pid = GenServer.whereis(ctx.hub)
    :erlang.trace_pattern({Hub, :matches?, 2}, true, [:local])
    :erlang.trace(hub_pid, true, [:call, {:tracer, self()}])
    on_exit(fn -> :erlang.trace_pattern({Hub, :matches?, 2}, false, [:local]) end)

    Enum.each(notices, fn notice ->
      class = notice["class"]

      classes = [class]
      invalid_classes = Stream.map(classes, & &1)
      refute Hub.matches?(notice, %{"classes" => invalid_classes})

      :ok =
        Hub.register(ctx.hub, self(), %{
          mode: :filtered,
          db: ctx.db,
          user_id: "kay",
          is_admin: false
        })

      :ok = Hub.subscribe(ctx.hub, self(), class, %{"classes" => classes})
      Hub.publish(ctx.hub, notice)
      _sequence = Hub.sequence(ctx.hub, self())
      trace_barrier(hub_pid)
      refute_received {:trace, ^hub_pid, :call, {Hub, :matches?, _}}
      refute_received {:firehose_notice, _frame}

      :ok =
        Hub.register(ctx.hub, self(), %{
          mode: :filtered,
          db: ctx.db,
          user_id: "flynn",
          is_admin: false
        })

      Hub.publish(ctx.hub, notice)
      _sequence = Hub.sequence(ctx.hub, self())
      trace_barrier(hub_pid)

      assert_received {:trace, ^hub_pid, :call,
                       {Hub, :matches?, [^notice, %{"classes" => ^classes}]}}

      assert_received {:firehose_notice, %{"class" => ^class, "type" => "change"}}
      Hub.delivered(ctx.hub, self())
      _sequence = Hub.sequence(ctx.hub, self())
      :ok = Hub.unsubscribe(ctx.hub, self(), class)
    end)

    hidden_class = unresolved_marker["class"]

    hidden_classes = [hidden_class]

    :ok =
      Hub.register(ctx.hub, self(), %{
        mode: :filtered,
        db: ctx.db,
        user_id: "root",
        is_admin: true
      })

    :ok = Hub.subscribe(ctx.hub, self(), "unresolved", %{"classes" => hidden_classes})
    Hub.publish(ctx.hub, unresolved_marker)
    _sequence = Hub.sequence(ctx.hub, self())
    trace_barrier(hub_pid)
    refute_received {:trace, ^hub_pid, :call, {Hub, :matches?, _}}
    refute_received {:firehose_notice, _frame}
  end

  defp trace_barrier(pid) do
    barrier = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^barrier}
  end

  defp expected_r8_inventory do
    Enum.flat_map(@r8_groups, fn {classes, resource, op, primary_refs, serializer} ->
      Enum.map(classes, fn class ->
        {class,
         %{
           class: class,
           resource: resource,
           op: op,
           primary_refs: primary_refs,
           serializer: serializer
         }}
      end)
    end)
    |> Map.new()
  end

  defp r8_shape(row),
    do: Map.take(row, [:class, :resource, :op, :primary_refs, :serializer])

  defp assert_closed_map!(label, expected, actual) do
    expected_keys = Map.keys(expected)
    actual_keys = Map.keys(actual)
    removed = Enum.sort(expected_keys -- actual_keys)
    added = Enum.sort(actual_keys -- expected_keys)

    drifted =
      expected_keys
      |> Enum.filter(&(Map.has_key?(actual, &1) and expected[&1] != actual[&1]))
      |> Enum.sort()

    if removed != [] or added != [] or drifted != [] do
      raise ArgumentError,
            "#{label} closed-table mismatch: removed=#{inspect(removed)} " <>
              "added=#{inspect(added)} drifted=#{inspect(drifted)}"
    end

    :ok
  end

  defp assert_filter_matrix!(class, refs) do
    notice = %{"class" => class, "refs" => refs}
    [namespace | _rest] = String.split(class, ".", parts: 2)
    prefix = namespace <> "."

    assert Hub.matches?(notice, %{})
    assert Hub.matches?(notice, %{"classes" => [prefix]})
    assert Hub.matches?(notice, %{"classes" => [class]})
    refute Hub.matches?(notice, %{"classes" => ["different."]})

    Enum.each(@filter_refs, fn {key, value} ->
      if refs[key] do
        assert Hub.matches?(notice, %{key => refs[key]})
        refute Hub.matches?(notice, %{key => value <> "-different"})
      else
        refute Hub.matches?(notice, %{key => value})
      end

      refute Hub.matches?(%{notice | "refs" => Map.delete(refs, key)}, %{key => value})
    end)

    exact_filters =
      refs
      |> Map.take(Map.keys(@filter_refs))
      |> Map.put("classes", [prefix])

    assert Hub.matches?(notice, exact_filters)
  end

  defp assert_source_notice(notice, class, refs, source_version, occurred_at) do
    assert notice == %{
             "class" => class,
             "op" => "observe",
             "occurredAt" => occurred_at,
             "refs" => refs,
             "payload" => %{"sourceVersion" => source_version}
           }
  end

  defp take_notice(hub) do
    _sequence = Hub.sequence(hub, self())
    assert_received {:firehose_notice, notice}
    Hub.delivered(hub, self())
    _sequence = Hub.sequence(hub, self())
    notice
  end

  defp assert_quiet(hub) do
    _sequence = Hub.sequence(hub, self())
    refute_received {:firehose_notice, _notice}
  end

  defp visibility_notices(ctx) do
    created =
      Toplines.create(
        ctx.db,
        topline_call(ctx, %{title: "Visible", idempotency_key: "visibility-create"})
      )

    topline_id = created.topline.id

    linked =
      Toplines.link_work(
        ctx.db,
        topline_call(ctx, %{
          topline_id: topline_id,
          work_item_id: "wi_firehose",
          reason: "visible work",
          idempotency_key: "visibility-link"
        })
      )

    membership_id = linked.membership.id

    _unlinked =
      Toplines.unlink_work(
        ctx.db,
        topline_call(ctx, %{
          membership_id: membership_id,
          reason: "visibility complete",
          idempotency_key: "visibility-unlink"
        })
      )

    assert {:ok, %{appended: true}} =
             append_marker(ctx.db, marker_input(ctx, "visibility-marker", "asg_firehose", 800))

    resolved_marker_id = marker_id(ctx.db, "visibility-marker")

    assert {:ok, %{appended: true}} =
             append_marker(ctx.db, marker_input(ctx, "visibility-unresolved", nil, 801))

    unresolved_marker_id = marker_id(ctx.db, "visibility-unresolved")
    _barrier = Hub.sequence(ctx.hub, self())

    membership_refs = %{
      "toplineId" => topline_id,
      "membershipId" => membership_id,
      "workItemId" => "wi_firehose"
    }

    valid = [
      Publisher.source_invalidation_notice(
        "topline.created",
        1,
        event_at(ctx.db, topline_id, 1),
        %{"toplineId" => topline_id}
      ),
      Publisher.source_invalidation_notice(
        "topline_work_membership.linked",
        2,
        event_at(ctx.db, topline_id, 2),
        membership_refs
      ),
      Publisher.source_invalidation_notice(
        "topline_work_membership.unlinked",
        3,
        event_at(ctx.db, topline_id, 3),
        membership_refs
      ),
      Publisher.source_invalidation_notice(
        "subagent_marker.appended",
        resolved_marker_id,
        800,
        %{
          "markerId" => Integer.to_string(resolved_marker_id),
          "sessionKey" => "s_flynn",
          "assignmentId" => "asg_firehose",
          "workItemId" => "wi_firehose"
        }
      )
    ]

    unresolved_marker =
      Publisher.source_invalidation_notice(
        "subagent_marker.appended",
        unresolved_marker_id,
        801,
        %{
          "markerId" => Integer.to_string(unresolved_marker_id),
          "sessionKey" => "s_flynn"
        }
      )

    %{valid: valid, unresolved_marker: unresolved_marker}
  end

  defp topline_call(ctx, params) do
    %{
      verb: "test",
      principal: {:user, "flynn"},
      origin: "test",
      session_key: nil,
      params: params,
      firehose_hub: ctx.hub
    }
  end

  defp marker_input(ctx, source_event_ref, assignment_id, at) do
    %{
      kind: "subagent_start",
      principal: "s_flynn",
      subagent_ref: "subagent:#{source_event_ref}",
      source_event_ref: source_event_ref,
      harness: :codex,
      at: at,
      assignment_id: assignment_id,
      firehose_hub: ctx.hub
    }
  end

  defp append_marker(db, input),
    do: DB.transaction(db, &SubagentMarkers.append_in_txn(&1, input))

  defp event_at(db, topline_id, seq) do
    assert {:ok, [[at]]} =
             DB.query(
               db,
               "SELECT eventAt FROM topline_events WHERE toplineId = ?1 AND seq = ?2",
               [topline_id, seq]
             )

    at
  end

  defp marker_id(db, source_event_ref) do
    assert {:ok, [[id]]} =
             DB.query(db, "SELECT id FROM subagent_markers WHERE sourceEventRef = ?1", [
               source_event_ref
             ])

    id
  end

  defp ref_value("markerId"), do: "1"
  defp ref_value("toplineId"), do: "tl_firehose"
  defp ref_value("membershipId"), do: "tlm_firehose"
  defp ref_value("assignmentId"), do: "asg_firehose"
  defp ref_value("sessionKey"), do: "s_flynn"
  defp ref_value("workItemId"), do: "wi_firehose"
  defp ref_value("origin"), do: "user:flynn"
  defp ref_value("principal"), do: "user:flynn"
  defp ref_value(key), do: "#{key}-value"

  defp session!(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })
  end

  defp work_item!(db, id, owner) do
    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO work_items
                 (id, title, ownerUserId, state, createdByUser, createdContextKnown, createdAt)
               VALUES (?1, ?2, ?3, 'open', ?3, 1, 1)
               """,
               [id, "Work #{id}", owner]
             )
  end

  defp assignment!(db, id, holder, work_item_id) do
    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO assignments
                 (id, subject, holderKey, openedByUser, openedAt, workItemId)
               VALUES (?1, 'Firehose proof', ?2, 'flynn', 1, ?3)
               """,
               [id, holder, work_item_id]
             )
  end
end
