defmodule Tightbeam.DispatchTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Dispatch, Escalation, EventLog, Rules}

  defmodule DenialHandoffCapture do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_cast({:denied, call, error}, owner) do
      send(owner, {:denial_handoff, call, error})
      {:noreply, owner}
    end
  end

  setup do
    :persistent_term.erase(Rules)
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = ensure_all_schemas(name)

    on_exit(fn -> :persistent_term.erase(Rules) end)

    %{db: name}
  end

  test "publication commits before response and audit failure preserves success", %{db: db} do
    call = %{verb: "transcript", origin: "user:flynn", session_key: "s1", params: %{}}
    parent = self()

    handlers = %{
      "transcript" => fn _ ->
        :sys.suspend(db)
        send(parent, :handler_completed)
        %{entries: ["large result"]}
      end
    }

    task = Task.async(fn -> Dispatch.dispatch(db, handlers, call) end)

    try do
      assert_receive :handler_completed
      assert Task.yield(task, 30) == nil
    after
      :sys.resume(db)
    end

    assert {:ok, %{entries: ["large result"]}} = Task.await(task)
    wait_for_audit(db, "SELECT payload FROM events", [["null"]])

    :ok =
      DB.execute(
        db,
        "CREATE TRIGGER refuse_audit BEFORE INSERT ON events BEGIN SELECT RAISE(FAIL, 'audit unavailable'); END"
      )

    assert {:ok, %{entries: ["large result"]}} =
             Dispatch.dispatch(
               db,
               %{"transcript" => fn _ -> %{entries: ["large result"]} end},
               call
             )

    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM events")
  end

  test "publication survives audit overload and precedes the response", %{db: db} do
    parent = self()

    handler = fn _ ->
      :sys.suspend(db)

      for _ <- 1..128,
          do: send(db, {:"$gen_call", {self(), make_ref()}, {:query, "SELECT 1", []}})

      send(parent, :overloaded)
      %{entries: []}
    end

    call = %{
      verb: "transcript",
      origin: "user:flynn",
      session_key: nil,
      params: %{},
      firehose_hub: self()
    }

    task = Task.async(fn -> Dispatch.dispatch(db, %{"transcript" => handler}, call) end)

    try do
      assert_receive :overloaded
      assert Task.yield(task, 30) == nil
    after
      :sys.resume(db)
    end

    assert {:ok, %{entries: []}} = Task.await(task)
    assert_receive {:"$gen_cast", {:accepted, nil, ^call, %{entries: []}}}
  end

  test "write then denial or crash retains the outcome audit", %{db: db} do
    :ok = DB.execute(db, "CREATE TABLE written_before_outcome(id INTEGER)")

    for outcome <- [:denial, :crash] do
      handler = fn _ ->
        {:ok, _} =
          DB.transaction(db, &DB.Txn.q(&1, "INSERT INTO written_before_outcome VALUES(1)"))

        case outcome do
          :denial -> %{code: "forbidden"}
          :crash -> raise "handler failed"
        end
      end

      verb = if outcome == :denial, do: "post", else: "transcript"
      call = %{verb: verb, origin: "user:flynn", session_key: nil, params: %{}}
      assert {:error, _} = Dispatch.dispatch(db, %{verb => handler}, call)
    end

    :sys.get_state(db)
    events = EventLog.events_after(db, 0, 10)
    assert Enum.count(events, &(&1.kind == "denied")) == 1

    assert {:ok, [[payload]]} =
             DB.query(
               db,
               "SELECT payload FROM events WHERE verb='transcript' AND payload<>'null'"
             )

    assert {%{crash: true, code: "server_error"}, _} = Code.eval_string(payload)
  end

  test "a write and its audit commit together and are not appended twice", %{db: db} do
    :ok = DB.execute(db, "CREATE TABLE primary_result(id INTEGER)")

    handlers = %{
      "post" => fn _ ->
        {:ok, result} =
          DB.transaction(db, fn txn ->
            DB.Txn.q(txn, "INSERT INTO primary_result VALUES(1)")
            %{saved: true}
          end)

        assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM events WHERE verb='post'")
        result
      end
    }

    call = %{verb: "post", origin: "user:flynn", session_key: nil, params: %{}}
    assert {:ok, %{saved: true}} = Dispatch.dispatch(db, handlers, call)
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM primary_result")
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM events WHERE verb='post'")
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

  test "a Cursor launch refusal remains a structured code across Dispatch", %{db: db} do
    refusal = %{
      code: "DIV-CURSOR-API-KEY-ONLY",
      message: "Cursor requires a banked API key"
    }

    call = %{verb: "cursor-checkout", origin: "system", session_key: "cursor", params: %{}}

    assert {:error, ^refusal} =
             Dispatch.dispatch(db, %{"cursor-checkout" => fn _ -> refusal end}, call)

    assert [%{kind: "denied"}] = EventLog.events_after(db, 0, 10)
    assert {:ok, [[payload]]} = DB.query(db, "SELECT payload FROM events")
    assert payload =~ "DIV-CURSOR-API-KEY-ONLY"
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

  test "body reads and body updates elide raised denial messages", %{db: db} do
    hub = start_supervised!({DenialHandoffCapture, self()})
    sentinel = "dispatch-body-secret-#{System.unique_integer([:positive])}"

    for {verb, params} <- [
          {"work-item-get", %{work_item_id: "wi_1"}},
          {"work-item-update", %{work_item_id: "wi_1", body: sentinel}}
        ] do
      call = %{
        verb: verb,
        origin: "user:flynn",
        session_key: nil,
        params: params,
        firehose_hub: hub
      }

      assert {:error, %{code: "server_error", message: ^sentinel}} =
               Dispatch.dispatch(db, %{verb => fn _ -> raise sentinel end}, call)

      assert_receive {:denial_handoff, handed_call, denial_error}
      assert handed_call.verb == verb
      assert denial_error == %{code: "server_error", bodyElided: true}
      notices = Tightbeam.Firehose.Publisher.denied_notices(handed_call, denial_error)
      refute inspect(notices) =~ sentinel

      assert [%{kind: "verb", verb: ^verb}] = EventLog.events_after(db, 0, 10) |> Enum.take(-1)
      {:ok, [[payload]]} = DB.query(db, "SELECT payload FROM events ORDER BY id DESC LIMIT 1")
      refute payload =~ sentinel

      assert {%{code: "server_error", crash: true, bodyElided: true}, _} =
               Code.eval_string(payload)
    end
  end

  test "metadata update crashes preserve their existing denial message", %{db: db} do
    call = %{
      verb: "work-item-update",
      origin: "user:flynn",
      session_key: nil,
      params: %{work_item_id: "wi_1", title: "metadata"}
    }

    assert {:error, %{code: "server_error", message: "metadata boom"}} =
             Dispatch.dispatch(
               db,
               %{"work-item-update" => fn _ -> raise "metadata boom" end},
               call
             )

    {:ok, [[payload]]} = DB.query(db, "SELECT payload FROM events ORDER BY id DESC LIMIT 1")
    assert payload =~ "metadata boom"
  end

  test "accepted body update audit stores only the descriptor", %{db: db} do
    sentinel = "accepted-body-secret-#{System.unique_integer([:positive])}"

    call = %{
      verb: "work-item-update",
      origin: "user:flynn",
      session_key: nil,
      params: %{body: sentinel}
    }

    result = %{body: sentinel, bodyUpdate: %{state: "present", byteLength: byte_size(sentinel)}}

    assert {:ok, ^result} =
             Dispatch.dispatch(db, %{"work-item-update" => fn _ -> result end}, call)

    {:ok, [[payload]]} = DB.query(db, "SELECT payload FROM events ORDER BY id DESC LIMIT 1")
    refute payload =~ sentinel
    assert payload =~ "bodyUpdate"
  end

  test "successful body get returns detail but audits only identity and verb", %{db: db} do
    sentinel = "accepted-body-read-secret-#{System.unique_integer([:positive])}"

    detail = %{
      id: "wi_1",
      body: sentinel,
      bodyUpdatedByUser: "flynn",
      bodyUpdatedBySession: nil,
      bodyUpdatedAt: 123
    }

    result = %{workItem: detail, assignments: []}

    call = %{
      verb: "work-item-get",
      origin: "user:flynn",
      session_key: nil,
      params: %{work_item_id: "wi_1"}
    }

    assert {:ok, ^result} = Dispatch.dispatch(db, %{"work-item-get" => fn _ -> result end}, call)

    {:ok, [[payload]]} = DB.query(db, "SELECT payload FROM events ORDER BY id DESC LIMIT 1")
    refute payload =~ sentinel
    refute payload =~ "bodyUpdatedByUser"
    refute payload =~ "bodyUpdatedBySession"
    refute payload =~ "bodyUpdatedAt"
    assert payload == "null"
    assert [%{verb: "work-item-get", origin: "user:flynn"}] = EventLog.events_after(db, 0, 10)
  end

  test "a raised message keeps its text but not its secrets in the reply and audit row",
       %{db: db} do
    echoed = fn _call ->
      raise "login failed: password=fixtureSENTINEL (echo password=fixtureSENTINEL) " <>
              "via https://svc:fixtureSENTINEL@db.test/x"
    end

    nested = fn _call ->
      raise MatchError, term: %{creds: %{"password" => "fixtureSENTINEL"}, status: 401}
    end

    update = fn _call -> raise "update failed password=fixtureSENTINEL" end

    for {verb, handler} <- [
          {"post", echoed},
          {"work-item-create", nested},
          {"work-item-update", update}
        ] do
      call = %{verb: verb, origin: "system", session_key: nil, params: %{}}

      assert {:error, %{code: "server_error", message: message} = error} =
               Dispatch.dispatch(db, %{verb => handler}, call)

      refute JSON.encode!(error) =~ "SENTINEL"
      assert message =~ "[REDACTED:secret_field]"

      if verb == "post" do
        # An unquoted value is masked to the next delimiter, so the `)` goes with it
        # rather than risk leaving the tail of a secret that contains one.
        assert message ==
                 "login failed: password=[REDACTED:secret_field] " <>
                   "(echo password=[REDACTED:secret_field] via https://[REDACTED:userinfo]@db.test/x"
      else
        if verb == "work-item-create" do
          assert message =~ "no match of right hand side value"
          assert message =~ ~s("password" => "[REDACTED:secret_field]")
          assert message =~ "status: 401"
        else
          assert message == "update failed password=[REDACTED:secret_field]"
        end
      end
    end

    {:ok, payloads} = DB.query(db, "SELECT payload FROM events ORDER BY id")
    assert length(payloads) == 3

    for [payload] <- payloads do
      assert payload =~ "server_error"
      assert payload =~ "[REDACTED:secret_field]"
      refute payload =~ "SENTINEL"
    end
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
      verbs: ["post"],
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

  defp wait_for_audit(db, sql, expected, attempts \\ 100)
  defp wait_for_audit(db, sql, expected, 0), do: assert(DB.query(db, sql) == {:ok, expected})

  defp wait_for_audit(db, sql, expected, attempts) do
    case DB.query(db, sql) do
      {:ok, ^expected} ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_audit(db, sql, expected, attempts - 1)
    end
  end
end
