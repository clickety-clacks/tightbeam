defmodule Tightbeam.StateResourceEquivalenceTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Firehose.{Publisher, Registry}

  alias Tightbeam.{
    Artifacts,
    CausalEvents,
    ConditionFacts,
    CriticalLeases,
    DB,
    Devices,
    Escalation,
    Gateway,
    Ledger,
    Model,
    Org,
    Projection,
    ReadMarkers,
    Roles,
    StateResources,
    StateVisibility,
    Wakes
  }

  @held_admin_classes ~w(
    config.updated host_env.updated identity.updated host.registered kungfu.updated user.promoted
  )
  @secret_keys MapSet.new(~w(cliToken token identityToken))

  setup do
    db = :"state_resource_equivalence_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:paired, device} =
      Devices.pair(db, %{
        device_id: "projection-device",
        claimed_name: "Flynn",
        platform: "test",
        model: "fixture"
      })

    Devices.add_user(db, "other", false)
    worker = session(db, "agent:projection:worker", "flynn")
    target = session(db, "agent:projection:target", "flynn")
    fixtures = fixtures(db, worker, target, device)

    %{db: db, fixtures: fixtures, device: device, worker: worker}
  end

  test "every implemented state class shares query, serializer, id, visibility, and secret seams",
       ctx do
    rows = Registry.rows()
    resources = rows |> Map.values() |> MapSet.new(& &1.resource)

    assert resources == MapSet.new(Map.keys(ctx.fixtures))
    assert MapSet.disjoint?(MapSet.new(Map.keys(rows)), MapSet.new(@held_admin_classes))

    Enum.each(@held_admin_classes, fn class ->
      refute Map.has_key?(rows, class)
    end)

    Enum.each(rows, fn {class, row} ->
      fixture = Map.fetch!(ctx.fixtures, row.resource)

      queried =
        apply(StateResources, row.query, [ctx.db, row.resource, fixture.id, fixture.context])

      refute is_nil(queried), class

      detail = apply(StateResources, row.serializer, [queried])
      notice = Publisher.committed_notice(class, queried, fixture.refs)

      assert notice["resource"] == row.resource, class
      assert notice["op"] == row.op, class
      assert JSON.encode!(detail) == JSON.encode!(notice["payload"]), class

      expected_primary_id = Map.fetch!(detail, row.projection_primary_key)
      refute is_nil(expected_primary_id), class
      assert notice["refs"][row.primary_ref] == expected_primary_id, class
      assert is_integer(detail["rowVersion"]), class

      refute contains_secret_key?(detail), class
      refute contains_secret_key?(notice), class
      refute contains_value?(detail, ctx.worker.cli_token), class
      refute contains_value?(notice, ctx.worker.cli_token), class
      refute contains_value?(detail, ctx.device.token), class
      refute contains_value?(notice, ctx.device.token), class

      detail_candidate = %{
        "class" => class,
        "refs" => notice["refs"],
        "payload" => detail
      }

      for {user_id, admin?} <- [{"flynn", false}, {"other", false}, {"flynn", true}] do
        detail_visible =
          apply(StateVisibility, row.visibility, [ctx.db, detail_candidate, user_id, admin?])

        notice_visible =
          apply(StateVisibility, row.visibility, [ctx.db, notice, user_id, admin?])

        assert detail_visible == notice_visible, class
      end

      if class == "critical_lease.updated" do
        refute StateVisibility.visible?(ctx.db, notice, "flynn", false), class
        assert StateVisibility.visible?(ctx.db, notice, "flynn", true), class
      else
        assert StateVisibility.visible?(ctx.db, notice, "flynn", false), class
        refute StateVisibility.visible?(ctx.db, notice, "other", false), class
      end
    end)

    assert map_size(rows) == 33
  end

  test "all notice paths enforce declared projection primary ids" do
    wake_call = %{
      verb: "wake",
      origin: "agent:projection:worker",
      principal: {:session, "agent:projection:worker"},
      session_key: "agent:projection:worker",
      params: %{}
    }

    accepted_notice = Publisher.state_notice(wake_call, %{wake_id: "w_good"})
    assert accepted_notice["refs"]["wakeId"] == "w_good"

    assert_raise ArgumentError, ~r/wake\.scheduled.*wakeId/, fn ->
      Publisher.state_notice(wake_call, %{id: "generic-id"})
    end

    assert_raise ArgumentError, ~r/wake\.scheduled.*wakeId/, fn ->
      Publisher.state_notice(wake_call, %{})
    end

    conflicting_ref_notice =
      Publisher.committed_notice(
        "wake.scheduled",
        %{wake_id: "w_good"},
        %{"wakeId" => "w_bad"}
      )

    assert conflicting_ref_notice["refs"]["wakeId"] == "w_good"

    nil_ref_notice =
      Publisher.committed_notice("wake.scheduled", %{wake_id: "w_good"}, %{"wakeId" => nil})

    assert nil_ref_notice["refs"]["wakeId"] == "w_good"

    assert_raise ArgumentError, ~r/wake\.scheduled.*wakeId/, fn ->
      Publisher.committed_notice("wake.scheduled", %{id: "generic-id"}, %{})
    end

    assert_raise ArgumentError, ~r/wake\.scheduled.*wakeId/, fn ->
      Publisher.committed_notice("wake.scheduled", %{}, %{})
    end
  end

  test "storage credentials exist in query rows but are structurally absent after serialization",
       ctx do
    session_row = StateResources.query(ctx.db, "sessions", ctx.worker.session_key)
    device_row = StateResources.query(ctx.db, "devices", ctx.device.device_id)

    assert session_row.cli_token == ctx.worker.cli_token
    assert device_row.token == ctx.device.token
    refute Map.has_key?(StateResources.session(session_row), "cliToken")
    refute Map.has_key?(StateResources.device(device_row), "token")
  end

  defp fixtures(db, worker, target, device) do
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 60_000})
    user_call = call("work-item-get", {:user, "flynn"}, nil, %{})

    work_item =
      handlers["work-item-create"].(
        call("work-item-create", {:user, "flynn"}, nil, %{title: "Projection fixture"})
      )

    assignment =
      handlers["assign"].(
        call("assign", {:user, "flynn"}, worker.session_key, %{
          subject: "Projection assignment",
          work_item_id: work_item.id
        })
        |> Map.merge(%{target_role: nil, role_fallback: false})
      )

    %{attest: attest} =
      handlers["attest"].(
        call("attest", {:session, worker.session_key}, worker.session_key, %{
          assignment_id: assignment.id,
          kind: "progress",
          note: "projection fixture"
        })
      )

    wake =
      Wakes.schedule(db, %{
        session_key: worker.session_key,
        target_role: nil,
        origin: "user:flynn",
        prompt: "projection fixture",
        due_at: System.system_time(:millisecond) + 60_000
      })

    production_seq = production(db, assignment.id, worker.session_key)

    {:appended, message} =
      Projection.append(db, %{
        session_key: worker.session_key,
        role: "user",
        content: "projection fixture",
        sender: "user:flynn",
        device_id: device.device_id,
        client_message_id: "projection-fixture"
      })

    {:ok, turn_seq} =
      Ledger.enqueue(db, %{
        session_key: worker.session_key,
        message_id: message.id,
        origin: "user:flynn",
        prompt: message.content,
        assignment_id: assignment.id
      })

    request =
      Escalation.ask(db, %{
        verb: "ask",
        origin: "agent:projection:worker",
        principal: {:session, worker.session_key},
        session_key: target.session_key,
        target_role: nil,
        role_fallback: false,
        params: %{question: "Is the projection identical?", assignment_id: assignment.id}
      })

    role = Roles.create!(db, "projection-reader", "flynn", worker.session_key)

    artifact =
      Artifacts.record(db, %{
        principal: {:session, worker.session_key},
        session_key: worker.session_key,
        params: %{
          work_item_id: work_item.id,
          kind: "report",
          title: "Projection fixture",
          origin_path: "gibson:/projection-fixture",
          content_sha256: String.duplicate("a", 64)
        }
      })

    {:ok, true, read_marker} = ReadMarkers.set(db, "flynn", "projection", "seen")

    {:ok, condition_fact} =
      DB.transaction(db, fn txn ->
        ConditionFacts.file_in_txn(txn, %{
          kind: "projection-ready",
          scope: work_item.id,
          origin: "user:flynn"
        })
      end)

    critical =
      CriticalLeases.declare(db, worker.session_key, 60_000, "projection fixture", 120_000)

    decision_call = %{
      verb: "decision-request-get",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{}
    }

    owner_refs = %{"ownerUserId" => "flynn"}

    %{
      "work-items" => fixture(work_item.id, %{call: user_call}, owner_refs),
      "assignments" => fixture(assignment.id, %{call: user_call}, owner_refs),
      "attests" => fixture(attest.id, %{}, owner_refs),
      "wakes" => fixture(wake.wake_id, %{}, owner_refs),
      "productions" => fixture(production_seq, %{}, owner_refs),
      "turns" => fixture(turn_seq, %{}, owner_refs),
      "decision-requests" =>
        fixture(request.id, %{call: decision_call, owner_user_id: "flynn"}, owner_refs),
      "sessions" => fixture(worker.session_key, %{}, owner_refs),
      "roles" => fixture(role.name, %{}, owner_refs),
      "users" => fixture("flynn", %{}, owner_refs),
      "devices" => fixture(device.device_id, %{}, owner_refs),
      "artifacts" => fixture(artifact.artifact_id, %{}, owner_refs),
      "read-markers" => fixture(read_marker.scope_key, %{user_id: "flynn"}, owner_refs),
      "messages" => fixture(message.id, %{}, owner_refs),
      "condition-facts" => fixture(condition_fact.fact_id, %{}, owner_refs),
      "critical-state" => fixture(critical.session_key, %{}, %{})
    }
  end

  defp production(db, assignment_id, session_key) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        CausalEvents.append_in_txn(txn, %{
          kind: "prod_fired",
          assignment_id: assignment_id,
          session_key: session_key,
          detail: %{reason: "projection fixture"}
        })
      end)

    {:ok, [[seq]]} = DB.query(db, "SELECT MAX(seq) FROM causal_events")
    seq
  end

  defp fixture(id, context, refs), do: %{id: id, context: context, refs: refs}

  defp call(verb, principal, session_key, params) do
    %{
      verb: verb,
      origin: principal_origin(principal),
      principal: principal,
      session_key: session_key,
      params: params
    }
  end

  defp principal_origin({:user, user_id}), do: "user:#{user_id}"
  defp principal_origin({:session, session_key}), do: "agent:#{session_key}"

  defp session(db, session_key, owner_user_id) do
    Org.create(db, %{
      session_key: session_key,
      display_name: session_key,
      owner_user_id: owner_user_id,
      origin: "user:#{owner_user_id}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp contains_secret_key?(value) when is_map(value) do
    Enum.any?(value, fn {key, child} ->
      MapSet.member?(@secret_keys, to_string(key)) or contains_secret_key?(child)
    end)
  end

  defp contains_secret_key?(value) when is_list(value),
    do: Enum.any?(value, &contains_secret_key?/1)

  defp contains_secret_key?(_value), do: false

  defp contains_value?(value, secret) when is_map(value),
    do: Enum.any?(value, fn {_key, child} -> contains_value?(child, secret) end)

  defp contains_value?(value, secret) when is_list(value),
    do: Enum.any?(value, &contains_value?(&1, secret))

  defp contains_value?(value, secret), do: value == secret
end
