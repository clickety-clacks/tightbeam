defmodule Tightbeam.Firehose.RegistryProofTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Firehose.{Hub, Publisher, Registry}

  alias Tightbeam.{
    DB,
    Gateway,
    Model,
    Org,
    Roles,
    StateResources,
    StateVisibility,
    SubagentMarkers,
    Toplines
  }

  @r8_groups [
    {~w(work_item.created work_item.updated work_item.iceboxed work_item.reopened work_item.closed work_item.failed),
     "work-items", "upsert", ["workItemId"], :work_item},
    {~w(assignment.opened assignment.reopened assignment.closed), "assignments", "upsert",
     ["assignmentId"], :assignment},
    {~w(attest.filed), "attests", "upsert", ["attestId"], :attest},
    {~w(wake.scheduled wake.fired wake.canceled), "wakes", "upsert", ["wakeId"], :wake},
    {~w(turn.queued turn.started turn.ended), "turns", "upsert", ["turnSeq"], :turn},
    {~w(decision_request.opened decision_request.updated decision_request.answered decision_request.returned decision_request.ruled decision_request.consumed decision_request.withdrawn decision_request.superseded),
     "decision requests", "upsert", ["decisionRequestId"], :decision_request},
    {~w(session.spawned session.updated session.harness_changed session.retired), "sessions",
     "upsert", ["sessionKey"], :session},
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

    committed_decision_classes =
      ~w(decision_request.opened decision_request.updated decision_request.answered
         decision_request.returned decision_request.ruled decision_request.consumed
         decision_request.withdrawn decision_request.superseded)
      |> Map.new(&{&1, &1})

    production_classes = Map.merge(gateway_classes, committed_decision_classes)
    registry_classes = Map.new(Map.keys(Registry.rows()), &{&1, &1})
    assert :ok = assert_closed_map!("R8 production classes", registry_classes, production_classes)

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

  test "DA7.5 each published class has exact row references, including role-targeted wakes",
       ctx do
    fixtures = row_reference_fixtures(ctx)

    Enum.each(Registry.rows(), fn {class, row} ->
      fixture = Map.fetch!(fixtures, row.serializer)

      supplied_refs =
        if class == "kungfu.updated" do
          %{"name" => "capability-row"}
        else
          %{
            "origin" => "agent:writer",
            "principal" => "session:writer",
            "sessionKey" => "caller-session",
            "workItemId" => "request-work-item",
            "assignmentId" => "request-assignment",
            "ownerUserId" => "test-user"
          }
          |> Map.drop(row.primary_refs)
          |> then(fn refs ->
            if fixture[:parent_work_item_id],
              do: Map.put(refs, :firehose_parent_work_item_id, fixture.parent_work_item_id),
              else: refs
          end)
        end

      notice = Publisher.committed_notice(class, fixture.payload, supplied_refs)

      expected_refs =
        fixture.primary_refs
        |> Map.merge(fixture.secondary_refs)
        |> Map.merge(Map.take(supplied_refs, ~w(origin principal)))
        |> Map.merge(if(class == "message.created", do: %{"ownerUserId" => "test-user"}, else: %{}))

      assert notice["refs"] == expected_refs, "unexpected references for #{class}"

      if row.serializer == :decision_request do
        assert notice["schemaVersion"] == 2
      end
    end)
  end

  test "row-reference filters are literal and relationship membership comes from the payload" do
    row = %{
      id: "assignment-row",
      holderKey: "current-holder",
      workItemId: "linked-work-item",
      openedAt: 1,
      state: "open"
    }

    notice =
      Publisher.committed_notice("assignment.closed", row, %{
        "assignmentId" => "assignment-row",
        "sessionKey" => "writer-session",
        "workItemId" => "request-work-item",
        "origin" => "agent:writer",
        "principal" => "session:writer"
      })

    assert notice["refs"] == %{
             "assignmentId" => "assignment-row",
             "sessionKey" => "current-holder",
             "workItemId" => "linked-work-item",
             "origin" => "agent:writer",
             "principal" => "session:writer"
           }

    assert Hub.matches?(notice, %{"classes" => ["assignment."], "sessionKey" => "current-holder"})
    assert Hub.matches?(notice, %{"workItemId" => "linked-work-item"})
    assert Hub.matches?(notice, %{"principal" => "session:writer"})
    refute Hub.matches?(notice, %{"sessionKey" => "prior-holder"})
    refute Hub.matches?(notice, %{"sessionKey" => "writer-session"})

    assert Hub.matches?(notice, %{"classes" => ["assignment."]})
  end

  test "parent refs filter attest notices without changing class-only eligibility", ctx do
    assert :ok =
             DB.execute(
               ctx.db,
               "INSERT INTO users (userId, isAdmin, createdAt) VALUES " <>
                 "('holder-user', 0, 1), ('opener-user', 0, 1), ('sibling-user', 0, 1)"
             )

    session!(ctx.db, "holder-row", "holder-user")
    session!(ctx.db, "sibling-holder", "sibling-user")
    work_item!(ctx.db, "wi_parent-row", "opener-user")

    assignment!(
      ctx.db,
      "asg_parent-row",
      "holder-row",
      "wi_parent-row",
      "opener-user"
    )

    assignment!(ctx.db, "asg_sibling-row", "sibling-holder", "wi_parent-row")

    listeners = [
      {:holder_attest,
       class_listener(ctx, :holder_attest, "attest.filed", %{
         user_id: "holder-user",
         principal_kind: :session,
         principal_id: "holder-row"
       })},
      {:opener_attest,
       class_listener(ctx, :opener_attest, "attest.filed", %{user_id: "opener-user"})},
      {:holder_decision,
       class_listener(ctx, :holder_decision, "decision_request.", %{
         user_id: "holder-user",
         principal_kind: :session,
         principal_id: "holder-row"
       })},
      {:opener_decision,
       class_listener(ctx, :opener_decision, "decision_request.", %{user_id: "opener-user"})},
      {:sibling_attest,
       class_listener(ctx, :sibling_attest, "attest.filed", %{
         user_id: "sibling-user",
         principal_kind: :session,
         principal_id: "sibling-holder"
       })},
      {:sibling_decision,
       class_listener(ctx, :sibling_decision, "decision_request.", %{
         user_id: "sibling-user",
         principal_kind: :session,
         principal_id: "sibling-holder"
       })},
      {:opener_filter,
       filtered_listener(
         ctx,
         :opener_filter,
         %{"classes" => ["attest.filed"], "workItemId" => "wi_parent-row"},
         %{user_id: "opener-user"}
       )},
      {:sibling_filter,
       filtered_listener(
         ctx,
         :sibling_filter,
         %{
           "classes" => ["attest.filed", "decision_request."],
           "workItemId" => "wi_parent-row"
         },
         %{
           user_id: "sibling-user",
           principal_kind: :session,
           principal_id: "sibling-holder"
         }
       )}
    ]

    on_exit(fn -> Enum.each(listeners, fn {_tag, pid} -> Process.exit(pid, :kill) end) end)

    :ok =
      Hub.register(ctx.hub, self(), %{
        mode: :all,
        db: ctx.db,
        user_id: "test-user",
        is_admin: true
      })

    attest = %{
      id: "attest-row",
      assignment_id: "asg_parent-row",
      kind: "progress",
      verdict_kind: nil,
      note: nil,
      by_session: "holder-row",
      by_user: nil,
      producer: nil,
      producer_command: nil,
      by_harness: nil,
      by_provider: nil,
      commit_refs: nil,
      artifact_id: nil,
      content_sha256: nil,
      wait_id: nil,
      ts: 10
    }

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               DB.Txn.q(
                 txn,
                 "INSERT INTO attests(id,assignmentId,kind,note,bySession,ts) VALUES(?1,?2,?3,?4,?5,?6)",
                 [
                   attest.id,
                   attest.assignment_id,
                   attest.kind,
                   attest.note,
                   attest.by_session,
                   attest.ts
                 ]
               )

               Publisher.accepted_in_txn(
                 txn,
                 %{
                   verb: "attest",
                   origin: "agent:holder-row",
                   principal: {:session, "holder-row"},
                   session_key: "holder-row",
                   firehose_hub: ctx.hub,
                   params: %{
                     assignment_id: "asg_parent-row",
                     session_key: "holder-row",
                     work_item_id: "wi_parent-row"
                   }
                 },
                 %{attest: attest}
               )

               Publisher.committed_in_txn(
                 txn,
                 "decision_request.opened",
                 %{
                   id: "request-row",
                   kind: "operator",
                   status: "open",
                   raiser_session_key: "holder-row",
                   assignment_id: "asg_parent-row",
                   row_schema_revision: 2,
                   row_version: 10
                 },
                 %{
                   "decisionRequestId" => "request-row",
                   "sessionKey" => "holder-row",
                   "workItemId" => "wi_parent-row",
                   "assignmentId" => "asg_parent-row"
                 },
                 ctx.hub
               )

               :ok
             end)

    Enum.each(listeners, fn {tag, pid} -> sync_listener(ctx.hub, pid, tag) end)

    assert_received {:class_notice, :holder_attest, %{"class" => "attest.filed"}}
    assert_received {:class_notice, :opener_attest, %{"class" => "attest.filed"}}
    assert_received {:class_notice, :holder_decision, %{"class" => "decision_request.opened"}}
    assert_received {:class_notice, :opener_decision, %{"class" => "decision_request.opened"}}
    assert_received {:class_notice, :opener_filter, %{"class" => "attest.filed"}}

    for tag <- [:sibling_attest, :sibling_decision, :sibling_filter] do
      refute_received {:class_notice, ^tag, _notice}
    end

    assert %{"class" => "verb.accepted"} = take_notice(ctx.hub)

    attest_notice = take_notice(ctx.hub)

    assert %{
             "class" => "attest.filed",
             "refs" => %{
               "attestId" => "attest-row",
               "sessionKey" => "holder-row",
               "workItemId" => "wi_parent-row",
               "assignmentId" => "asg_parent-row",
               "origin" => "agent:holder-row",
               "principal" => "session:holder-row"
             }
           } = attest_notice

    decision_notice = take_notice(ctx.hub)

    assert %{
             "class" => "decision_request.opened",
             "schemaVersion" => 2,
             "refs" => %{
               "decisionRequestId" => "request-row",
               "sessionKey" => "holder-row",
               "workItemId" => "wi_parent-row",
               "assignmentId" => "asg_parent-row"
             }
           } = decision_notice

    assert Hub.matches?(attest_notice, %{
             "classes" => ["attest.filed"],
             "workItemId" => "wi_parent-row"
           })

    assert Hub.matches?(decision_notice, %{
             "classes" => ["decision_request."],
             "workItemId" => "wi_parent-row"
           })

    rest_page =
      StateResources.query_attests(ctx.db, %{
        collection: %{
          filters: %{},
          principal: %{kind: "session", id: "sibling-holder"},
          boundary: :latest,
          limit: 20
        }
      })

    assert rest_page.rows == []

    holder_rest_page =
      StateResources.query_attests(ctx.db, %{
        collection: %{
          filters: %{},
          principal: %{kind: "session", id: "holder-row"},
          boundary: :latest,
          limit: 20
        }
      })

    assert Enum.any?(holder_rest_page.rows, &(&1.id == "attest-row"))

    opener_rest_page =
      StateResources.query_attests(ctx.db, %{
        collection: %{
          filters: %{},
          principal: %{kind: "user", id: "opener-user", is_admin: false},
          boundary: :latest,
          limit: 20
        }
      })

    assert Enum.any?(opener_rest_page.rows, &(&1.id == "attest-row"))
  end

  test "attest-driven assignment notices preserve their pre-ref recipients", ctx do
    assert :ok =
             DB.execute(
               ctx.db,
               "INSERT INTO users (userId, isAdmin, createdAt) VALUES " <>
                 "('fixture-work-owner', 0, 1), ('fixture-holder-owner', 0, 1), " <>
                 "('fixture-session-opener-owner', 0, 1), ('fixture-user-opener', 0, 1)"
             )

    session!(ctx.db, "fixture-assignment-holder", "fixture-holder-owner")
    session!(ctx.db, "fixture-session-opener", "fixture-session-opener-owner")
    work_item!(ctx.db, "wi_fixture-recipient-check", "fixture-work-owner")

    assignments = [
      {"fixture-session-opened-assignment", "session", "fixture-session-opener",
       "fixture-session-completion"},
      {"fixture-user-opened-assignment", "user", "fixture-user-opener", "fixture-user-completion"}
    ]

    for {assignment_id, opener_kind, opener_id, completion_id} <- assignments do
      opener_column = if opener_kind == "session", do: "openedBySession", else: "openedByUser"

      assert {:ok, []} =
               DB.query(
                 ctx.db,
                 "INSERT INTO assignments " <>
                   "(id,subject,holderKey,#{opener_column},openedAt,workItemId) " <>
                   "VALUES (?1,'Recipient check','fixture-assignment-holder',?2,1," <>
                   "'wi_fixture-recipient-check')",
                 [assignment_id, opener_id]
               )

      assert {:ok, []} =
               DB.query(
                 ctx.db,
                 "INSERT INTO attests(id,assignmentId,kind,bySession,ts) " <>
                   "VALUES (?1,?2,'completion','fixture-assignment-holder',1)",
                 [completion_id, assignment_id]
               )

      assert {:ok, []} =
               DB.query(
                 ctx.db,
                 "UPDATE assignments SET state='closed',outcome='completed',closedAt=2," <>
                   "closedBySession='fixture-assignment-holder',closingAttestId=?1 " <>
                   "WHERE id=?2",
                 [completion_id, assignment_id]
               )
    end

    listeners = [
      {:assignment_holder,
       class_listener(ctx, :assignment_holder, "assignment.closed", %{
         user_id: "fixture-holder-owner",
         principal_kind: :session,
         principal_id: "fixture-assignment-holder"
       })},
      {:work_item_owner,
       class_listener(ctx, :work_item_owner, "assignment.closed", %{
         user_id: "fixture-work-owner"
       })},
      {:session_opener,
       class_listener(ctx, :session_opener, "assignment.closed", %{
         user_id: "fixture-session-opener-owner",
         principal_kind: :session,
         principal_id: "fixture-session-opener"
       })},
      {:user_opener,
       class_listener(ctx, :user_opener, "assignment.closed", %{
         user_id: "fixture-user-opener"
       })}
    ]

    on_exit(fn -> Enum.each(listeners, fn {_tag, pid} -> Process.exit(pid, :kill) end) end)

    :ok =
      Hub.register(ctx.hub, self(), %{
        mode: :all,
        db: ctx.db,
        user_id: "fixture-holder-owner",
        is_admin: false
      })

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               for {assignment_id, opener_kind, opener_id, _completion_id} <- assignments do
                 opener_principal =
                   if opener_kind == "session",
                     do: {:session, opener_id},
                     else: {:user, opener_id}

                 origin =
                   if opener_kind == "session",
                     do: "agent:fixture-opener",
                     else: "user:" <> opener_id

                 call = %{principal: opener_principal}

                 before = StateResources.query_assignment(txn, assignment_id, call)
                 assert before.derived_status == "claims-done"

                 by_session = if opener_kind == "session", do: opener_id, else: nil
                 by_user = if opener_kind == "user", do: opener_id, else: nil

                 assert [] ==
                          DB.Txn.q(
                            txn,
                            "INSERT INTO attests " <>
                              "(id,assignmentId,kind,verdictKind,note,bySession,byUser,ts) " <>
                              "VALUES (?1,?2,'verdict','verified','Verified completion',?3,?4,3)",
                            [
                              "fixture-verified-#{assignment_id}",
                              assignment_id,
                              by_session,
                              by_user
                            ]
                          )

                 assert [] ==
                          DB.Txn.q(
                            txn,
                            "UPDATE assignments SET rowVersion=rowVersion+1 WHERE id=?1",
                            [assignment_id]
                          )

                 payload =
                   StateResources.query_assignment(txn, assignment_id, call)

                 assert payload.derived_status == "verified"

                 actor_refs = Publisher.actor_refs(%{origin: origin, principal: opener_principal})

                 Publisher.committed_attest_assignment_change_in_txn(
                   txn,
                   "assignment.closed",
                   payload,
                   Map.put(actor_refs, "assignmentId", assignment_id),
                   ctx.hub
                 )
               end

               :ok
             end)

    Enum.each(listeners, fn {tag, pid} -> sync_listener(ctx.hub, pid, tag) end)

    for _ <- 1..2 do
      assert_received {:class_notice, :assignment_holder, %{"class" => "assignment.closed"}}
    end

    for _ <- 1..2 do
      assert_received {:class_notice, :work_item_owner, %{"class" => "assignment.closed"}}
    end

    for tag <- [:session_opener, :user_opener] do
      refute_received {:class_notice, ^tag, _notice}
    end

    first_notice = take_notice(ctx.hub)
    second_notice = take_notice(ctx.hub)
    notices = [first_notice, second_notice]

    assert Enum.map(notices, & &1["class"]) == ["assignment.closed", "assignment.closed"]

    assert Enum.map(notices, & &1["refs"]["origin"]) == [
             "agent:fixture-opener",
             "user:fixture-user-opener"
           ]

    assert Enum.map(notices, & &1["refs"]["principal"]) == [
             "session:fixture-session-opener",
             "user:fixture-user-opener"
           ]

    for notice <- notices do
      assert notice["refs"]["sessionKey"] == "fixture-assignment-holder"
      assert notice["refs"]["workItemId"] == "wi_fixture-recipient-check"
      refute Map.has_key?(notice, "eligibilityRefs")
    end
  end

  test "row-reference repairs preserve spawn and role create/remove recipients", ctx do
    assert :ok =
             DB.execute(
               ctx.db,
               "INSERT INTO users (userId, isAdmin, createdAt) VALUES " <>
                 "('spawn-owner', 0, 1), ('spawn-holder', 0, 1)"
             )

    session!(ctx.db, "spawn-actor", "test-user")
    session!(ctx.db, "spawn-target", "kay")
    session!(ctx.db, "spawn-work-holder", "spawn-holder")
    work_item!(ctx.db, "wi_spawn-work-item", "spawn-owner")
    assignment!(ctx.db, "assignment-spawn-work-item", "spawn-work-holder", "wi_spawn-work-item")

    spawn_listeners = [
      {:spawn_creator,
       class_listener(ctx, :spawn_creator, "session.spawned", %{
         user_id: "test-user",
         principal_kind: :session,
         principal_id: "spawn-actor"
       })},
      {:spawn_work_owner,
       class_listener(ctx, :spawn_work_owner, "session.spawned", %{user_id: "spawn-owner"})},
      {:spawn_work_holder,
       class_listener(ctx, :spawn_work_holder, "session.spawned", %{
         user_id: "spawn-holder",
         principal_kind: :session,
         principal_id: "spawn-work-holder"
       })},
      {:spawn_target,
       class_listener(ctx, :spawn_target, "session.spawned", %{
         user_id: "kay",
         principal_kind: :session,
         principal_id: "spawn-target"
       })},
      {:spawn_target_owner,
       class_listener(ctx, :spawn_target_owner, "session.spawned", %{user_id: "kay"})}
    ]

    on_exit(fn -> Enum.each(spawn_listeners, fn {_tag, pid} -> Process.exit(pid, :kill) end) end)

    session_call = %{
      verb: "spawn",
      origin: "agent:spawn-actor",
      principal: {:session, "spawn-actor"},
      session_key: "spawn-actor",
      firehose_hub: ctx.hub,
      params: %{work_item_id: "wi_spawn-work-item"}
    }

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               session = StateResources.query_session(txn, "spawn-target")
               Publisher.accepted_in_txn(txn, session_call, %{session: session})
               :ok
             end)

    Enum.each(spawn_listeners, fn {tag, pid} -> sync_listener(ctx.hub, pid, tag) end)

    assert_received {:class_notice, :spawn_creator,
                     %{"class" => "session.spawned", "refs" => refs} = spawn_notice}

    assert refs["sessionKey"] == "spawn-target"
    assert refs["origin"] == "agent:spawn-actor"
    assert refs["principal"] == "session:spawn-actor"
    refute Map.has_key?(refs, "workItemId")
    refute Map.has_key?(spawn_notice, "eligibilityRefs")
    assert_received {:class_notice, :spawn_work_owner, %{"class" => "session.spawned"}}
    assert_received {:class_notice, :spawn_work_holder, %{"class" => "session.spawned"}}
    assert_received {:class_notice, :spawn_target, %{"class" => "session.spawned"}}
    assert_received {:class_notice, :spawn_target_owner, %{"class" => "session.spawned"}}

    Enum.each(spawn_listeners, fn {_tag, pid} -> Process.exit(pid, :kill) end)

    session!(ctx.db, "role-creator", "test-user")
    session!(ctx.db, "role-bound-target", "kay")

    role_listeners = [
      {:role_owner, class_listener(ctx, :role_owner, "role.created", %{user_id: "test-user"})},
      {:role_creator,
       class_listener(ctx, :role_creator, "role.created", %{
         user_id: "test-user",
         principal_kind: :session,
         principal_id: "role-creator"
       })},
      {:role_bound_target,
       class_listener(ctx, :role_bound_target, "role.created", %{
         user_id: "kay",
         principal_kind: :session,
         principal_id: "role-bound-target"
       })},
      {:role_bound_owner,
       class_listener(ctx, :role_bound_owner, "role.created", %{user_id: "kay"})}
    ]

    on_exit(fn -> Enum.each(role_listeners, fn {_tag, pid} -> Process.exit(pid, :kill) end) end)

    role_call = %{
      verb: "role-create",
      origin: "agent:role-creator",
      principal: {:session, "role-creator"},
      session_key: "role-creator",
      firehose_hub: ctx.hub,
      firehose_in_txn: true,
      params: %{name: "project:row-ref-test", bind: "role-bound-target"}
    }

    assert %{name: "project:row-ref-test"} =
             Roles.create_with_firehose!(
               ctx.db,
               "project:row-ref-test",
               "test-user",
               "role-bound-target",
               role_call
             )

    Enum.each(role_listeners, fn {tag, pid} -> sync_listener(ctx.hub, pid, tag) end)

    assert_received {:class_notice, :role_owner, %{"class" => "role.created"}}

    assert_received {:class_notice, :role_creator,
                     %{"class" => "role.created", "refs" => role_refs}}

    assert role_refs["role"] == "project:row-ref-test"
    assert role_refs["sessionKey"] == "role-bound-target"
    assert role_refs["origin"] == "agent:role-creator"
    assert role_refs["principal"] == "session:role-creator"
    refute_received {:class_notice, :role_bound_target, _notice}
    refute_received {:class_notice, :role_bound_owner, _notice}

    Enum.each(role_listeners, fn {_tag, pid} -> Process.exit(pid, :kill) end)

    removed_role_name = "project:row-ref-remove-test"

    assert %{name: ^removed_role_name} =
             Roles.create!(ctx.db, removed_role_name, "test-user", "role-bound-target")

    remove_listeners = [
      {:role_remover,
       class_listener(ctx, :role_remover, "role.removed", %{
         user_id: "test-user",
         principal_kind: :session,
         principal_id: "role-creator"
       })},
      {:removed_bound_target,
       class_listener(ctx, :removed_bound_target, "role.removed", %{
         user_id: "kay",
         principal_kind: :session,
         principal_id: "role-bound-target"
       })},
      {:removed_bound_owner,
       class_listener(ctx, :removed_bound_owner, "role.removed", %{user_id: "kay"})}
    ]

    on_exit(fn -> Enum.each(remove_listeners, fn {_tag, pid} -> Process.exit(pid, :kill) end) end)

    remove_call = %{
      verb: "role-rm",
      origin: "agent:role-creator",
      principal: {:session, "role-creator"},
      session_key: "role-creator",
      firehose_hub: ctx.hub,
      firehose_in_txn: true,
      params: %{name: removed_role_name}
    }

    captured_remove_call = Publisher.capture_before(ctx.db, remove_call)
    assert :ok = Roles.rm_with_firehose(ctx.db, removed_role_name, captured_remove_call)

    Enum.each(remove_listeners, fn {tag, pid} -> sync_listener(ctx.hub, pid, tag) end)

    assert_received {:class_notice, :role_remover,
                     %{"class" => "role.removed", "refs" => removed_refs}}

    assert removed_refs["role"] == removed_role_name
    assert removed_refs["sessionKey"] == "role-bound-target"
    refute_received {:class_notice, :removed_bound_target, _notice}
    refute_received {:class_notice, :removed_bound_owner, _notice}
  end

  # Subscription matching runs first and visibility is checked only for a
  # matching row, so a hidden row may be matched but never emits a frame.
  test "A3 hidden rows are matched but emit no frame; visible rows emit one", ctx do
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

      assert_received {:trace, ^hub_pid, :call,
                       {Hub, :matches?, [^notice, %{"classes" => ^classes}]}}

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
    assert_received {:trace, ^hub_pid, :call, {Hub, :matches?, [^unresolved_marker, _]}}
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

  defp row_reference_fixtures(ctx) do
    %{
      work_item:
        row_reference_fixture(
          %{id: "work-row", row_version: 10},
          %{"workItemId" => "work-row"},
          %{}
        ),
      assignment:
        row_reference_fixture(
          %{id: "assignment-row", holderKey: "holder-row", workItemId: "work-row", openedAt: 10},
          %{"assignmentId" => "assignment-row"},
          %{"sessionKey" => "holder-row", "workItemId" => "work-row"}
        ),
      attest:
        row_reference_fixture(
          %{
            id: "attest-row",
            assignment_id: "assignment-row",
            kind: "progress",
            verdict_kind: nil,
            note: nil,
            by_session: "filing-session",
            by_user: nil,
            producer: nil,
            producer_command: nil,
            by_harness: nil,
            by_provider: nil,
            commit_refs: nil,
            artifact_id: nil,
            content_sha256: nil,
            wait_id: nil,
            ts: 10
          },
          %{"attestId" => "attest-row"},
          %{
            "sessionKey" => "filing-session",
            "workItemId" => "parent-work-row",
            "assignmentId" => "assignment-row"
          },
          "parent-work-row"
        ),
      wake:
        row_reference_fixture(
          %{
            wake_id: "wake-row",
            session_key: "stale-role-resolution",
            target_role: "example",
            origin: "agent:writer",
            prompt: "pending work",
            consumer: "wake",
            due_at: 10,
            state: "pending",
            created_at: 10,
            fired_at: nil,
            reresolve: nil,
            reresolve_seed: nil,
            reresolve_rung: nil,
            condition_kind: nil,
            condition_scope: nil,
            condition_after_id: nil,
            fired_by: nil,
            creator_session_key: nil,
            rumination: false,
            work_item_id: "work-row",
            assignment_id: "assignment-row",
            canceled_at: nil,
            target_gate: nil,
            class: nil,
            class_election: nil,
            delivery_rule: nil,
            digest: false,
            summon: false,
            delivery_status: nil,
            row_version: 10
          },
          %{"wakeId" => "wake-row"},
          %{
            "workItemId" => "work-row",
            "assignmentId" => "assignment-row"
          }
        ),
      turn:
        row_reference_fixture(
          %{
            seq: 44,
            session_key: "turn-session",
            message_id: nil,
            wake_id: nil,
            origin: "agent:writer",
            prompt: "queued work",
            role_ref: nil,
            role_fallback: 0,
            assignment_id: "assignment-row",
            job_ref: "work-row",
            model: nil,
            thinking_level: nil,
            model_context: nil,
            harness: nil,
            reply_attention: 0,
            status: "queued",
            owner: nil,
            adapter_gen: nil,
            request_ref: nil,
            error: nil,
            created_at: 10,
            started_at: nil,
            ended_at: nil,
            published_at: nil,
            row_version: 10
          },
          %{"turnSeq" => 44},
          %{
            "sessionKey" => "turn-session",
            "workItemId" => "work-row",
            "assignmentId" => "assignment-row"
          }
        ),
      decision_request:
        row_reference_fixture(
          %{
            id: "request-row",
            kind: "operator",
            status: "open",
            raiser_session_key: "raising-session",
            assignment_id: "assignment-row",
            row_schema_revision: 2,
            row_version: 10
          },
          %{"decisionRequestId" => "request-row"},
          %{
            "sessionKey" => "raising-session",
            "workItemId" => "parent-work-row",
            "assignmentId" => "assignment-row"
          },
          "parent-work-row"
        ),
      session:
        row_reference_fixture(
          session_row_fixture(ctx.db),
          %{"sessionKey" => "session-row"},
          %{}
        ),
      role:
        row_reference_fixture(
          %{
            name: "role-row",
            bound_session_key: "bound-session",
            owner_user_id: "test-user",
            created_at: 10,
            updated_at: 11,
            row_version: 11
          },
          %{"role" => "role-row"},
          %{"sessionKey" => "bound-session"}
        ),
      user:
        row_reference_fixture(
          %{user_id: "test-user", is_admin: false, created_at: 1, row_version: 1},
          %{"userId" => "test-user"},
          %{}
        ),
      device:
        row_reference_fixture(
          %{
            device_id: "device-row",
            user_id: "test-user",
            claimed_name: nil,
            status: "allowlisted",
            platform: nil,
            model: nil,
            created_at: 10,
            row_version: 10
          },
          %{"deviceId" => "device-row"},
          %{}
        ),
      artifact:
        row_reference_fixture(
          %{
            artifact_id: "artifact-row",
            kind: "spec",
            title: "Projection fixture",
            description: nil,
            created_by_session: "artifact-creator",
            work_item_id: "work-row",
            parent_session: nil,
            origin_path: "projection-fixture.md",
            content_sha256: nil,
            recorded_message_id: nil,
            recorded_turn_evidence: "none",
            state: "in-workspace",
            home: nil,
            created_at: 10,
            updated_at: 10,
            row_version: 10
          },
          %{"artifactId" => "artifact-row"},
          %{"sessionKey" => "artifact-creator", "workItemId" => "work-row"}
        ),
      read_marker:
        row_reference_fixture(
          %{user_id: "test-user", scope_key: "scope-row", marker: "message-row", updated_at: 10},
          %{"userId" => "test-user", "scopeKey" => "scope-row"},
          %{}
        ),
      message:
        row_reference_fixture(
          %{
            id: "message-row",
            seq: 22,
            session_key: "message-session",
            role: "user",
            message_type: nil,
            content: "hello",
            timestamp: 22,
            sender: nil,
            device_id: nil,
            client_message_id: nil,
            reply_to_message_id: nil,
            reply_to_client_message_id: nil,
            llm_visible_message_id: "message-row",
            attachments: [],
            attention_tier: 1,
            turn_seq: nil,
            assignment_id: nil,
            job_ref: nil,
            harness: nil,
            provider: nil,
            model: nil,
            effort: nil,
            context: nil,
            row_version: 22
          },
          %{"messageId" => "message-row", "sessionKey" => "message-session"},
          %{}
        ),
      condition_fact:
        row_reference_fixture(
          %{id: 7, ts: 10, kind: "type", scope: nil, origin: "agent:writer"},
          %{"factId" => 7},
          %{}
        ),
      critical_state:
        row_reference_fixture(
          %{
            session_key: "critical-session",
            reason: "active",
            started_at: 10,
            expires_at: 20,
            hard_deadline: 30,
            updated_at: 10,
            row_version: 10
          },
          %{"sessionKey" => "critical-session"},
          %{}
        ),
      config:
        row_reference_fixture(
          %{key: "config-row", value: "enabled", updated_at: 10, row_version: 10},
          %{"key" => "config-row"},
          %{}
        ),
      host_environment:
        row_reference_fixture(
          %{
            host: "sample-host",
            harness: "claude",
            name: "setting",
            value_present: false,
            updated_at: 10,
            row_version: 10
          },
          %{"host" => "sample-host", "harness" => "claude", "name" => "setting"},
          %{}
        ),
      host:
        row_reference_fixture(
          %{host: "sample-host", row_version: 10},
          %{"host" => "sample-host"},
          %{}
        ),
      identity:
        row_reference_fixture(
          %{
            name: "identity-row",
            live_revision: "revision-one",
            state: "ready",
            session_revisions: %{},
            staleness: [],
            conflicts: [],
            row_version: 10
          },
          %{"name" => "identity-row"},
          %{}
        ),
      kungfu:
        row_reference_fixture(
          %{
            name: "capability-row",
            purpose: "Projection fixture",
            phrases: [],
            root_archetype: "default",
            installed_revision: nil,
            status: "available",
            documents: [],
            row_version: 10
          },
          %{"name" => "capability-row"},
          %{}
        )
    }
  end

  defp row_reference_fixture(payload, primary_refs, secondary_refs, parent_work_item_id \\ nil) do
    %{
      payload: payload,
      primary_refs: primary_refs,
      secondary_refs: secondary_refs,
      parent_work_item_id: parent_work_item_id
    }
  end

  defp session_row_fixture(db) do
    session!(db, "session-row", "test-user")
    StateResources.query_session(db, "session-row")
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

  defp class_listener(ctx, tag, class, principal) do
    filtered_listener(ctx, tag, %{"classes" => [class]}, principal)
  end

  defp filtered_listener(ctx, tag, filters, principal) do
    parent = self()

    pid =
      spawn(fn ->
        registration =
          Map.merge(%{mode: :filtered, db: ctx.db, is_admin: false}, principal)

        :ok = Hub.register(ctx.hub, self(), registration)
        :ok = Hub.subscribe(ctx.hub, self(), Atom.to_string(tag), filters)
        send(parent, {:class_listener_ready, tag})
        class_listener_loop(ctx.hub, parent, tag)
      end)

    assert_receive {:class_listener_ready, ^tag}
    pid
  end

  defp class_listener_loop(hub, parent, tag) do
    receive do
      {:firehose_notice, notice} ->
        Hub.delivered(hub, self())
        send(parent, {:class_notice, tag, notice})
        class_listener_loop(hub, parent, tag)

      {:barrier, ref} ->
        send(parent, {:class_listener_barrier, tag, ref})
        class_listener_loop(hub, parent, tag)

      :stop ->
        Hub.unregister(hub, self())
    end
  end

  defp sync_listener(hub, pid, tag) do
    _sequence = Hub.sequence(hub, pid)
    barrier = make_ref()
    send(pid, {:barrier, barrier})
    assert_receive {:class_listener_barrier, ^tag, ^barrier}
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

  defp assignment!(db, id, holder, work_item_id, opened_by_user \\ "test-user") do
    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO assignments
                 (id, subject, holderKey, openedByUser, openedAt, workItemId)
               VALUES (?1, 'Firehose proof', ?2, ?3, 1, ?4)
               """,
               [id, holder, opened_by_user, work_item_id]
             )
  end
end
