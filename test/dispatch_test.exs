defmodule Tightbeam.DispatchTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Dispatch, Escalation, EventLog, Model, Org, Rules}

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

  test "supervision policy denial commits its event and successor together", %{db: db} do
    prepare_claimed_liveness!(db)
    :persistent_term.put(Rules, [denial_rule()])

    call = %{
      verb: "wake",
      origin: "process:tightbeam",
      principal: {:process, "tightbeam"},
      session_key: "holder",
      params: %{assignment_id: "asg_1"}
    }

    transition = %{
      kind: "policy_denied",
      evaluation_clock: 5_000
    }

    assert {:error, %{code: "rule_denied"}} =
             Dispatch.dispatch_with_policy_denial_transition(
               db,
               %{"wake" => fn _ -> flunk("policy denial must not reach the handler") end},
               call,
               transition
             )

    assert [%{id: event_id, kind: "denied", principal: "process:tightbeam"}] =
             EventLog.events_after(db, 0, 10)

    assert {:ok, [[4, 6_000, "armed", "policy_denied", basis_id, "policy_denied"]]} =
             DB.query(
               db,
               """
               SELECT generation, dueAt, state, basisKind, basisId, cause
               FROM supervision_entitlements
               WHERE assignmentId='asg_1'
               """
             )

    assert basis_id == to_string(event_id)
    assert {:ok, [[1]]} = DB.query(db, "SELECT deniedStreak FROM assignment_prods")

    assert {:ok, [[nil, nil]]} =
             DB.query(
               db,
               "SELECT pendingBranch, pendingAssignment FROM supervision_watermarks"
             )
  end

  test "supervision policy denial cannot name a different transition assignment", %{db: db} do
    prepare_claimed_liveness!(db)
    :persistent_term.put(Rules, [denial_rule()])

    call = %{
      verb: "wake",
      origin: "process:tightbeam",
      principal: {:process, "tightbeam"},
      session_key: "holder",
      params: %{assignment_id: "asg_other"}
    }

    assert_raise FunctionClauseError, fn ->
      Dispatch.dispatch_with_policy_denial_transition(db, %{}, call, %{
        kind: "policy_denied",
        assignment_id: "asg_1",
        evaluation_clock: 5_000
      })
    end

    assert [] = EventLog.events_after(db, 0, 10)

    assert {:ok, [[3, "claimed", 5_000]]} =
             DB.query(
               db,
               "SELECT generation, state, claimClock FROM supervision_entitlements"
             )

    assert {:ok, [["prod", "asg_1"]]} =
             DB.query(
               db,
               "SELECT pendingBranch, pendingAssignment FROM supervision_watermarks"
             )
  end

  test "supervision policy denial rollback preserves the claimed branch", %{db: db} do
    prepare_claimed_liveness!(db, counters: false)
    :persistent_term.put(Rules, [denial_rule()])

    call = %{
      verb: "wake",
      origin: "process:tightbeam",
      principal: {:process, "tightbeam"},
      session_key: "holder",
      params: %{assignment_id: "asg_1"}
    }

    assert_raise RuntimeError,
                 "incompatible_supervision_liveness_v1: missing policy denial counters",
                 fn ->
                   Dispatch.dispatch_with_policy_denial_transition(db, %{}, call, %{
                     kind: "policy_denied",
                     evaluation_clock: 5_000
                   })
                 end

    assert [] = EventLog.events_after(db, 0, 10)

    assert {:ok, [[3, "claimed", 5_000]]} =
             DB.query(
               db,
               "SELECT generation, state, claimClock FROM supervision_entitlements"
             )

    assert {:ok, [["prod", "asg_1"]]} =
             DB.query(
               db,
               "SELECT pendingBranch, pendingAssignment FROM supervision_watermarks"
             )
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

  defp prepare_claimed_liveness!(db, opts \\ []) do
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(
        db,
        """
        CREATE TABLE supervision_entitlements (
          assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
          generation INTEGER NOT NULL,
          dueAt INTEGER,
          state TEXT NOT NULL,
          lastAttemptGeneration INTEGER,
          claimClock INTEGER,
          basisKind TEXT NOT NULL,
          basisId TEXT NOT NULL,
          terminusAt INTEGER,
          cause TEXT NOT NULL,
          principal TEXT NOT NULL,
          supervisionIntervalMs INTEGER
        );
        """
      )

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    Org.create(db, %{
      session_key: "holder",
      display_name: "holder",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "eezo"
    })

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt) VALUES ('asg_1', 'ship it', 'holder', 'flynn', 1)"
      )

    :ok =
      DB.execute(
        db,
        """
        INSERT INTO supervision_entitlements
          (assignmentId, generation, dueAt, state, lastAttemptGeneration, claimClock,
           basisKind, basisId, terminusAt, cause, principal, supervisionIntervalMs)
        VALUES
          ('asg_1', 3, 5000, 'claimed', 3, 5000, 'assignment_open', 'asg_1', NULL,
           'deadline', 'process:tightbeam', 1000);
        INSERT INTO supervision_watermarks
          (sessionKey, lastEvaluatedTerminal, pendingBranch, pendingAssignment, pendingK, pendingN)
        VALUES ('holder', 7, 'prod', 'asg_1', 1, 2);
        """
      )

    if Keyword.get(opts, :counters, true) do
      {:ok, _} =
        DB.query(
          db,
          "INSERT INTO assignment_prods (assignmentId, attemptCount, prodCount, deniedStreak) VALUES ('asg_1', 1, 0, 0)"
        )
    end

    :ok
  end

  defp denial_rule do
    %{
      name: "deny-wake",
      verb: "wake",
      text: "deny this wake",
      conditions: [],
      edges: ["verb"],
      effect: "deny",
      check: nil,
      identity_manifest_sha: "identity-sha"
    }
  end
end
