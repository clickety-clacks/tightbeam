defmodule Tightbeam.IdPrefixTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.IdPrefix

  setup do
    db = :id_prefix_unit_db
    start_supervised!({DB, path: ":memory:", name: db})

    :ok =
      DB.execute(
        db,
        """
        CREATE TABLE assignments (id TEXT PRIMARY KEY, marker TEXT);
        CREATE TABLE work_items (id TEXT PRIMARY KEY, marker TEXT);
        CREATE TABLE wakes (wakeId TEXT PRIMARY KEY, marker TEXT);
        """
      )

    :ok =
      DB.execute(
        db,
        """
        INSERT INTO assignments VALUES ('asg_alpha_1', NULL), ('asg_alpha_2', NULL), ('asg_bravo', NULL);
        INSERT INTO work_items VALUES ('wi_alpha_1', NULL), ('wi_bravo', NULL);
        INSERT INTO wakes VALUES ('w_alpha_1', NULL), ('w_bravo', NULL);
        """
      )

    %{db: db}
  end

  test "exact ids and one visible typed prefix resolve for all three record types", %{db: db} do
    assert {:ok, "asg_alpha_1"} = IdPrefix.resolve(db, :assignment, "asg_alpha_1")
    assert {:ok, "asg_bravo"} = IdPrefix.resolve(db, :assignment, "asg_b")
    assert {:ok, "wi_alpha_1"} = IdPrefix.resolve(db, :work_item, "wi_a")
    assert {:ok, "w_alpha_1"} = IdPrefix.resolve(db, :wake, "w_a")
  end

  test "ambiguity is deterministic and names only visible candidates", %{db: db} do
    assert {:ambiguous, error} = IdPrefix.resolve(db, :assignment, "asg_alpha")
    assert error.code == "ambiguous_id"
    assert error.candidates == ["asg_alpha_1", "asg_alpha_2"]
    assert error.message =~ "asg_alpha_1, asg_alpha_2"

    visible? = &(&1 == "asg_alpha_2")
    assert {:ok, "asg_alpha_2"} = IdPrefix.resolve(db, :assignment, "asg_alpha", visible?)

    hidden? = fn _id -> false end
    assert :unknown = IdPrefix.resolve(db, :assignment, "asg_alpha", hidden?)
    assert {:ok, "asg_alpha_1"} = IdPrefix.resolve(db, :assignment, "asg_alpha_1", hidden?)
  end

  test "no match and a prefix of the wrong type retain unknown", %{db: db} do
    assert :unknown = IdPrefix.resolve(db, :assignment, "asg_missing")
    assert :unknown = IdPrefix.resolve(db, :assignment, "wi_alpha")
    assert :unknown = IdPrefix.resolve(db, :work_item, "asg_alpha")
    assert :unknown = IdPrefix.resolve(db, :wake, "wi_alpha")
  end

  test "percent and underscore are literal prefix bytes, not LIKE wildcards", %{db: db} do
    :ok =
      DB.execute(
        db,
        """
        INSERT INTO assignments VALUES ('asg_literal%match', NULL), ('asg_literalXmatch', NULL);
        INSERT INTO work_items VALUES ('wi_literal_match', NULL), ('wi_literalXmatch', NULL);
        """
      )

    assert {:ok, "asg_literal%match"} =
             IdPrefix.resolve(db, :assignment, "asg_literal%")

    assert {:ok, "wi_literal_match"} =
             IdPrefix.resolve(db, :work_item, "wi_literal_")
  end

  test "a mutation keeps the id selected inside its transaction", %{db: db} do
    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               assert {:ok, "wi_alpha_1"} = IdPrefix.resolve_in_txn(txn, :work_item, "wi_a")
               Txn.q(txn, "INSERT INTO work_items VALUES ('wi_alpha_2', NULL)")
               Txn.q(txn, "UPDATE work_items SET marker = 'acted' WHERE id = ?1", ["wi_alpha_1"])
               :ok
             end)

    assert {:ok, [["wi_alpha_1", "acted"], ["wi_alpha_2", nil]]} =
             DB.query(
               db,
               "SELECT id, marker FROM work_items WHERE id LIKE 'wi_alpha_%' ORDER BY id"
             )
  end
end

defmodule Tightbeam.IdPrefixOperationsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assignments, DB, Gateway, Model, Org, WorkItems}
  alias Tightbeam.DB.Txn

  setup do
    db = :id_prefix_operations_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('flynn', 0, 'admin_add', 1)"
      )

    ensure_main_session(db, "flynn")

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

    %{db: db, handlers: Gateway.handlers(%{db: db})}
  end

  test "assignment and work-item operations accept unique prefixes", ctx do
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO assignments (id, subject, holderKey, holderFallback, openedByUser, openedAt) VALUES ('asg_unique_alpha', 'work', 'holder', 0, 'flynn', 1)"
      )

    attests_call = %{
      verb: "attests",
      origin: "agent:holder",
      session_key: nil,
      principal: {:session, "holder"},
      params: %{assignment_id: "asg_unique"}
    }

    assert %{attests: []} = Assignments.__handle__(ctx.db, "attests", attests_call)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES ('wi_unique_alpha', 'work', 'flynn', 'flynn', 1)"
      )

    get_call = %{
      verb: "work-item-get",
      origin: "user:flynn",
      session_key: nil,
      principal: {:user, "flynn"},
      params: %{work_item_id: "wi_unique"}
    }

    assert %{workItem: %{id: "wi_unique_alpha"}} =
             WorkItems.__handle__(ctx.db, "work-item-get", get_call)

    trace_call = %{get_call | verb: "work-item-trace"}

    assert %{workItem: %{id: "wi_unique_alpha"}} =
             WorkItems.__handle__(ctx.db, "work-item-trace", trace_call)
  end

  test "a work-item disposition cannot change prefix meaning after resolution", ctx do
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES ('wi_race_alpha', 'alpha', 'flynn', 'flynn', 1)"
      )

    completion_attest_id = completion_fixture!(ctx.db, "wi_race_alpha", "alpha")

    call = %{
      verb: "work-item-close",
      origin: "user:flynn",
      session_key: nil,
      principal: {:user, "flynn"},
      params: %{
        work_item_id: "wi_race",
        completion_attest_id: completion_attest_id
      },
      on_id_resolved_in_txn: fn txn, :work_item, "wi_race_alpha" ->
        Txn.q(
          txn,
          "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES ('wi_race_beta', 'beta', 'flynn', 'flynn', 2)"
        )
      end
    }

    assert %{ok: true, workItem: %{id: "wi_race_alpha", state: "closed"}} =
             WorkItems.__handle__(ctx.db, "work-item-close", call)

    assert {:ok, [["wi_race_alpha", "closed"], ["wi_race_beta", "open"]]} =
             DB.query(
               ctx.db,
               "SELECT id, state FROM work_items WHERE id LIKE 'wi_race_%' ORDER BY id"
             )
  end

  test "all public work-item lifecycle verbs resolve and return canonical ids", ctx do
    for id <- ~w(wi_life_icebox wi_life_close wi_life_fail) do
      {:ok, _} =
        DB.query(
          ctx.db,
          "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES (?1, ?1, 'flynn', 'flynn', 1)",
          [id]
        )
    end

    close_attest_id = completion_fixture!(ctx.db, "wi_life_close", "wi_life_close")

    call = fn verb, prefix, params ->
      WorkItems.__handle__(ctx.db, verb, %{
        verb: verb,
        origin: "user:flynn",
        session_key: nil,
        principal: {:user, "flynn"},
        params: Map.merge(%{work_item_id: prefix}, params)
      })
    end

    assert %{workItem: %{id: "wi_life_icebox", state: "iceboxed"}} =
             call.("work-item-icebox", "wi_life_i", %{})

    assert %{workItem: %{id: "wi_life_icebox", state: "open"}} =
             call.("work-item-reopen", "wi_life_i", %{})

    assert %{workItem: %{id: "wi_life_close", state: "closed"}} =
             call.("work-item-close", "wi_life_c", %{
               completion_attest_id: close_attest_id
             })

    assert %{workItem: %{id: "wi_life_fail", state: "failed", failReason: "broken"}} =
             call.("work-item-fail", "wi_life_f", %{reason: "broken"})
  end

  test "ambiguous and missing lifecycle mutations emit no writes or callbacks", ctx do
    for id <- ~w(wi_refuse_alpha wi_refuse_atom) do
      {:ok, _} =
        DB.query(
          ctx.db,
          "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES (?1, ?1, 'flynn', 'flynn', 1)",
          [id]
        )
    end

    snapshot = fn ->
      {:ok, states} =
        DB.query(
          ctx.db,
          "SELECT id, state FROM work_items WHERE id LIKE 'wi_refuse_%' ORDER BY id"
        )

      {:ok, [[events]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM causal_events")
      {:ok, [[wakes]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")
      {states, events, wakes}
    end

    call = fn id ->
      WorkItems.__handle__(ctx.db, "work-item-close", %{
        verb: "work-item-close",
        origin: "user:flynn",
        session_key: nil,
        principal: {:user, "flynn"},
        params: %{work_item_id: id},
        on_work_item_change: fn _, _ -> send(self(), :unexpected_callback) end
      })
    end

    before = snapshot.()

    assert %{code: "ambiguous_id", candidates: ["wi_refuse_alpha", "wi_refuse_atom"]} =
             call.("wi_refuse_a")

    assert %{code: "unknown_work_item"} = call.("wi_missing")
    assert snapshot.() == before
    refute_received :unexpected_callback
  end

  defp completion_fixture!(db, work_item_id, title) do
    {:ok, attest_id} =
      DB.transaction(db, fn txn ->
        Tightbeam.DeliverableContract.create_work_item_in_txn(txn, work_item_id, title, 1)
        suffix = Tightbeam.Id.uuid4()
        assignment_id = "asg_" <> suffix
        attest_id = "att_" <> suffix

        Txn.q(
          txn,
          "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state,workItemId) VALUES (?1,'close fixture','holder','flynn',1,'open',?2)",
          [assignment_id, work_item_id]
        )

        :ok =
          Tightbeam.DeliverableContract.bind_assignment_in_txn(
            txn,
            %{
              id: assignment_id,
              subject: "close fixture",
              holderKey: "holder",
              openedAt: 1,
              workItemId: work_item_id
            },
            true
          )

        Txn.q(
          txn,
          "INSERT INTO attests (id,assignmentId,kind,bySession,ts) VALUES (?1,?2,'completion','holder',2)",
          [attest_id, assignment_id]
        )

        Txn.q(
          txn,
          "UPDATE assignments SET state='closed',outcome='completed',closedAt=2,closedBySession='holder',closingAttestId=?2 WHERE id=?1",
          [assignment_id, attest_id]
        )

        :ok =
          Tightbeam.DeliverableContract.record_completion_claim_in_txn(
            txn,
            assignment_id,
            %{id: attest_id, ts: 2}
          )

        attest_id
      end)

    attest_id
  end

  test "public wake cancellation resolves only the caller's visible prefix", ctx do
    own =
      Tightbeam.Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "agent:holder",
        prompt: "own",
        due_at: 1
      })

    _hidden =
      Tightbeam.Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "agent:other",
        prompt: "hidden",
        due_at: 2
      })

    prefix = String.slice(own.wake_id, 0, 12)

    call = %{
      verb: "wake",
      origin: "agent:holder",
      session_key: nil,
      principal: {:session, "holder"},
      params: %{cancel_wake_id: prefix}
    }

    assert {:accepted_in_txn, _event_id, %{canceled: true}} = ctx.handlers["wake"].(call)
    assert Tightbeam.Wakes.get(ctx.db, own.wake_id).state == "canceled"
  end

  test "ambiguous and missing wake cancellation leave every wake untouched", ctx do
    first =
      Tightbeam.Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "agent:holder",
        prompt: "first",
        due_at: 1
      })

    second =
      Tightbeam.Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "agent:holder",
        prompt: "second",
        due_at: 2
      })

    call = fn supplied ->
      ctx.handlers["wake"].(%{
        verb: "wake",
        origin: "agent:holder",
        session_key: nil,
        principal: {:session, "holder"},
        params: %{cancel_wake_id: supplied}
      })
    end

    assert %{code: "ambiguous_id", candidates: candidates} = call.("w_")
    assert candidates == Enum.sort([first.wake_id, second.wake_id])
    assert %{canceled: false} = call.("w_missing")
    assert Tightbeam.Wakes.get(ctx.db, first.wake_id).state == "pending"
    assert Tightbeam.Wakes.get(ctx.db, second.wake_id).state == "pending"
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wake_cancellations")
  end
end
