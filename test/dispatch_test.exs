defmodule Tightbeam.DispatchTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Dispatch, Escalation, EventLog, Rules}

  setup do
    :persistent_term.erase(Rules)
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = EventLog.ensure_schema(name)
    :ok = Escalation.ensure_schema(name)

    on_exit(fn -> :persistent_term.erase(Rules) end)

    %{db: name}
  end

  test "success returns result and appends one verb event", %{db: db} do
    handlers = %{"post" => fn call -> %{echoed: call.params} end}
    call = %{verb: "post", origin: "user:flynn", session_key: "s1", params: %{content: "hi"}}

    assert {:ok, %{echoed: %{content: "hi"}}} = Dispatch.dispatch(db, handlers, call)

    assert [%{kind: "verb", verb: "post", origin: "user:flynn", session_key: "s1"}] =
             EventLog.events_after(db, 0, 10)
  end

  test "transactional accepted result reuses its committed event without a second append", %{
    db: db
  } do
    call = %{
      verb: "cancel-wake",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: "s1",
      params: %{wake_id: "wake-1"}
    }

    handlers = %{
      "cancel-wake" => fn _call ->
        {:ok, envelope} =
          DB.transaction(db, fn txn ->
            event_id =
              EventLog.append_event_in_txn(
                txn,
                "verb",
                "cancel-wake",
                "user:flynn",
                "s1",
                %{canceled: true},
                {:user, "flynn"},
                1
              )

            {:accepted_in_txn, event_id, %{canceled: true}}
          end)

        envelope
      end
    }

    assert {:ok, %{canceled: true}} = Dispatch.dispatch(db, handlers, call)

    assert [%{id: event_id, kind: "verb", verb: "cancel-wake"}] =
             EventLog.events_after(db, 0, 10)

    assert event_id > 0
  end

  test "only the exact transactional accepted result bypasses the ordinary append", %{db: db} do
    call = %{
      verb: "cancel-wake",
      origin: "user:flynn",
      session_key: "s1",
      params: %{wake_id: "wake-1"}
    }

    malformed = {:accepted_in_txn, 1, %{canceled: true, extra: true}}
    handlers = %{"cancel-wake" => fn _call -> malformed end}

    assert {:ok, ^malformed} = Dispatch.dispatch(db, handlers, call)

    assert [%{kind: "verb", verb: "cancel-wake"}] = EventLog.events_after(db, 0, 10)
  end

  test "onboarding lease identities are returned but not written to the event log", %{db: db} do
    result = %{status: "ready", staging_path: "/tmp/onboard", lease_id: "lease-secret"}
    call = %{verb: "onboard", origin: "user:flynn", session_key: nil, params: %{}}

    assert {:ok, ^result} = Dispatch.dispatch(db, %{"onboard" => fn _call -> result end}, call)

    {:ok, [[payload]]} = DB.query(db, "SELECT payload FROM events")
    assert payload =~ "/tmp/onboard"
    refute payload =~ "lease-secret"
  end

  test "unknown and handler denials append denied events", %{db: db} do
    unknown = %{verb: "nope", origin: "system", session_key: nil, params: %{}}
    assert {:error, %{code: "unknown_verb"}} = Dispatch.dispatch(db, %{}, unknown)

    handlers = %{"spawn" => fn _call -> %{code: "headcount_cap", message: "cap reached"} end}
    denied = %{verb: "spawn", origin: "agent:orchestrator", session_key: nil, params: %{}}
    assert {:error, %{code: "headcount_cap"}} = Dispatch.dispatch(db, handlers, denied)

    assert Enum.map(EventLog.events_after(db, 0, 10), &{&1.kind, &1.verb}) == [
             {"denied", "nope"},
             {"denied", "spawn"}
           ]
  end

  test "raising handler returns server_error and appends a verb event with the error", %{db: db} do
    handlers = %{"post" => fn _call -> raise "boom" end}
    call = %{verb: "post", origin: "system", session_key: nil, params: %{}}

    assert {:error, %{code: "server_error", message: "boom"}} =
             Dispatch.dispatch(db, handlers, call)

    assert [%{kind: "verb", verb: "post"}] = EventLog.events_after(db, 0, 10)

    {:ok, [[payload]]} = DB.query(db, "SELECT payload FROM events")
    assert payload =~ "server_error"
    assert payload =~ "boom"
  end

  test "ruling CAS loss emits a queryable E1 denial", %{db: db} do
    call = %{
      verb: "post",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{assignment_id: "a-cas"}
    }

    rule = %{
      name: "cas-rule",
      verb: "post",
      text: "owner approval required",
      conditions: [],
      edges: ["verb"],
      effect: "escalate",
      check: nil,
      identity_manifest_sha: "identity-sha"
    }

    :persistent_term.put(Rules, [rule, rule])
    action_key = Escalation.digest(call)

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO decision_requests
          (id, raiserId, ownerUserId, raisedAt, deadlineAt, statuteName, actionKey,
           question, context, status, decision)
        VALUES ('dr_cas', 'user:flynn', 'flynn', 1, 2, 'cas-rule', ?1,
                'owner approval required', '{}', 'ruled', 'allow')
        """,
        [action_key]
      )

    assert {:error,
            %{
              code: "rule_denied",
              rule: "cas-rule",
              edge: "verb",
              reason: "rule_denied",
              script_exit_class: nil,
              ref: "a-cas",
              producer: nil,
              identity_manifest_sha: "identity-sha"
            }} = Dispatch.dispatch(db, %{"post" => fn _ -> flunk("CAS loss must deny") end}, call)

    assert [
             %{
               rule: "cas-rule",
               edge: "verb",
               reason: "rule_denied",
               ref: "a-cas",
               identity_manifest_sha: "identity-sha"
             }
           ] =
             EventLog.rail_denials(db, 0, 10)
  end
end
