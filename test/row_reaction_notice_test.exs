defmodule Tightbeam.RowReactionNoticeTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Model, Org, RowReactions, Schema, Wakes}
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.Plan

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    Tightbeam.Archetypes.load!(System.tmp_dir!())
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',1,1)")

    for key <- ["target", "other"] do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "owner",
        origin: "user:owner",
        kind: "custom",
        archetype: "default",
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture"),
        host: "synthetic-host"
      })
    end

    %{db: db}
  end

  defp event(id \\ "one"), do: %{"id" => id, "org" => "example", "kind" => "example", "at" => 10}

  defp rails(target \\ "target", opts \\ []) do
    value =
      %{
        "session_key" => target,
        "owner_user_id" => "owner",
        "origin" => "example",
        "prompt" => Keyword.get(opts, :prompt, "original"),
        "due_at" => Keyword.get(opts, :due_at, 10),
        "target_gate" => 1,
        "on_unavailable" => Keyword.get(opts, :unavailable, "pending")
      }
      |> Map.merge(Keyword.get(opts, :value, %{}))

    [
      Plan.compile!(
        %{
          "name" => "example",
          "family" => "example",
          "events" => ["example"],
          "when" => true,
          "effects" => [
            %{"kind" => "notice", "slot" => "notice", "when" => true, "value" => value}
          ]
        },
        %{"revision" => "one"}
      )
    ]
  end

  defp admit(db, event, rails),
    do: DB.transaction(db, &RowReactions.admit_in_txn(&1, event, %{}, rails, 10))

  defp reconcile(db, event, rails),
    do:
      DB.transaction(
        db,
        &RowReactions.reconcile_in_txn(&1, event["org"], event["id"], %{}, rails, 20)
      )

  test "withdrawal elects current cancellation evidence without admitting an absent action", %{
    db: db
  } do
    assert {:ok, [action]} = admit(db, event(), rails())
    id = action["result"]["wake_id"]
    [rail] = rails()
    [effect] = rail.effects

    effect =
      Map.put(effect, "withdraw", %{
        "requester_id" => "tightbeam:wake-scheduler",
        "reason_kind" => "target_unresolvable",
        "source_kind" => "scheduler_delivery",
        "source_id" => %{"ref" => "facts.output"}
      })

    changed = [%{rail | condition: false, effects: [effect]}]

    assert {:ok, [canceled]} =
             DB.transaction(db, fn txn ->
               RowReactions.reconcile_in_txn(
                 txn,
                 "example",
                 "one",
                 %{"output" => id},
                 changed,
                 20
               )
             end)

    assert canceled["status"] == "canceled"

    assert {:ok, [["tightbeam:wake-scheduler", "target_unresolvable", "scheduler_delivery", ^id]]} =
             DB.query(
               db,
               "SELECT requesterId,reasonKind,causalSourceKind,causalSourceId FROM wake_cancellations WHERE wakeId=?1",
               [id]
             )

    assert {:ok, []} = admit(db, event("absent"), changed)
    assert {:ok, [^canceled]} = reconcile(db, event(), rails())
  end

  test "notice cancellation schema and its stamp commit together", %{db: db} do
    Tightbeam.SchemaShapeRuntimeFixture.downgrade_row_reaction_notices!(db)

    assert {:ok, [[old_sql]]} =
             DB.query(db, "SELECT sql FROM sqlite_master WHERE name='wake_cancellations'")

    :ok =
      DB.execute(db, """
      CREATE TRIGGER reject_reaction_notice_stamp BEFORE UPDATE ON schema_stamp
      WHEN NEW.shape='row-reaction-notice-v1'
      BEGIN SELECT RAISE(ABORT, 'fixture reaction stamp refusal'); END;
      """)

    assert_raise DB.Error, ~r/fixture reaction stamp refusal/, fn ->
      Schema.ensure_all(db)
    end

    assert {:ok, [[^old_sql]]} =
             DB.query(db, "SELECT sql FROM sqlite_master WHERE name='wake_cancellations'")

    assert {:ok, [["decision-request-row-schema-v2-019"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    :ok = DB.execute(db, "DROP TRIGGER reject_reaction_notice_stamp")
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [["row-reaction-notice-v1"]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  test "notice execution and replay schedule one real wake", %{db: db} do
    assert {:ok, [action]} = admit(db, event(), rails())
    id = action["result"]["wake_id"]
    assert %{prompt: "original", session_key: "target", state: "pending"} = Wakes.get(db, id)
    assert {:ok, [same]} = admit(db, event(), rails())
    assert same["id"] == action["id"]
    assert same["result"]["wake_id"] == id
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes WHERE origin='example'")
  end

  test "a changed rail updates recipient text and timing on the same pending wake", %{db: db} do
    {:ok, [initial]} = admit(db, event(), rails())

    assert {:ok, [updated]} =
             reconcile(db, event(), rails("other", prompt: "changed", due_at: 50))

    assert updated["id"] == initial["id"]
    id = initial["result"]["wake_id"]
    assert updated["result"]["wake_id"] == id
    assert %{prompt: "changed", session_key: "other", due_at: 50} = Wakes.get(db, id)

    assert {:ok, [["session:other"]]} =
             DB.query(db, "SELECT sourceAddress FROM wakes WHERE wakeId=?1", [id])

    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes WHERE origin='example'")
  end

  test "absence cancels through the ordinary cancellation seam and rollback stays canceled", %{
    db: db
  } do
    {:ok, [initial]} = admit(db, event(), rails())
    assert {:ok, [canceled]} = reconcile(db, event(), [])
    assert canceled["status"] == "canceled"
    assert %{state: "canceled"} = Wakes.get(db, initial["result"]["wake_id"])
    assert {:ok, [^canceled]} = reconcile(db, event(), rails())
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wake_cancellations")
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wake_cancellations")
  end

  test "elected no-target dispositions skip retain or roll back", %{db: db} do
    assert {:ok, []} = admit(db, event("skip"), rails(nil, unavailable: "skip"))
    assert {:ok, [pending]} = admit(db, event("pending"), rails(nil))
    assert pending["status"] == "pending"
    assert pending["result"] == nil
    assert {:ok, [resumed]} = reconcile(db, event("pending"), rails())
    assert resumed["id"] == pending["id"]
    assert %{state: "pending"} = Wakes.get(db, resumed["result"]["wake_id"])

    assert {:error, %ArgumentError{}} =
             admit(db, event("refuse"), rails(nil, unavailable: "refuse"))

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT COUNT(*) FROM row_reaction_events WHERE eventId='refuse'")
  end

  defp undelivered_rails do
    rails(nil,
      unavailable: "undelivered",
      value: %{
        "unavailable" => %{
          "session_key" => "target",
          "purpose" => "example-purpose",
          "reason" => "example-unavailable"
        }
      }
    )
  end

  test "elected undelivered outcome persists one canceled intent and typed evidence", %{db: db} do
    assert {:ok, [action]} = admit(db, event(), undelivered_rails())
    assert action["status"] == "canceled"
    id = action["result"]["wake_id"]

    assert %{state: "canceled", session_key: "target", fired_at: nil} =
             Wakes.get(db, id)

    assert {:ok, [[nil]]} =
             DB.query(db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [id])

    assert {:ok, [[detail]]} =
             DB.query(
               db,
               "SELECT detail FROM lifecycle_events WHERE kind='wake_undeliverable' AND subject=?1",
               [id]
             )

    assert JSON.decode!(detail) == %{
             "wake_id" => id,
             "assignment_id" => nil,
             "purpose" => "example-purpose",
             "reason" => "example-unavailable",
             "outcome" => "undelivered"
           }

    assert {:ok, [["target_unresolvable", "no_replacement"]]} =
             DB.query(
               db,
               "SELECT reasonKind,outcomeKind FROM wake_cancellations WHERE wakeId=?1",
               [id]
             )

    assert {:ok, [^action]} = admit(db, event(), undelivered_rails())
    assert {:ok, [^action]} = reconcile(db, event(), rails())

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM lifecycle_events WHERE kind='wake_undeliverable'")

    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM turns")
  end

  test "required undeliverable evidence failure rolls back source and intent", %{db: db} do
    DB.execute(
      db,
      "CREATE TRIGGER reject_undeliverable BEFORE INSERT ON lifecycle_events WHEN NEW.kind='wake_undeliverable' BEGIN SELECT RAISE(ABORT, 'fixture evidence failure'); END;"
    )

    assert {:error, _} =
             DB.transaction(db, fn txn ->
               Txn.q(
                 txn,
                 "UPDATE sessions SET displayName='changed source' WHERE sessionKey='target'"
               )

               RowReactions.admit_in_txn(txn, event(), %{}, undelivered_rails(), 10)
             end)

    assert {:ok, [["target"]]} =
             DB.query(db, "SELECT displayName FROM sessions WHERE sessionKey='target'")

    for table <- ~w(wakes wake_cancellations row_reaction_events row_reaction_actions) do
      assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM " <> table)
    end
  end

  test "unavailable changed target disposes same pending intent without a new notice", %{db: db} do
    assert {:ok, [original]} = admit(db, event(), rails())
    assert {:ok, [changed]} = reconcile(db, event(), undelivered_rails())
    assert changed["id"] == original["id"]
    assert changed["result"]["wake_id"] == original["result"]["wake_id"]
    assert changed["status"] == "canceled"
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
  end

  test "an unavailable changed recipient cannot receive the obsolete pending notice", %{db: db} do
    {:ok, [initial]} = admit(db, event(), rails())
    assert {:ok, [waiting]} = reconcile(db, event(), rails(nil))
    assert %{state: "canceled"} = Wakes.get(db, initial["result"]["wake_id"])
    assert waiting["status"] == "pending"
    assert waiting["result"]["wake_id"] == nil
    assert {:ok, [resumed]} = reconcile(db, event(), rails("other"))
    assert resumed["id"] == initial["id"]
    refute resumed["result"]["wake_id"] == initial["result"]["wake_id"]
    assert resumed["result"]["previous_wake_ids"] == [initial["result"]["wake_id"]]
    assert %{session_key: "other", state: "pending"} = Wakes.get(db, resumed["result"]["wake_id"])
  end

  test "an existing global wake identity suppresses duplicate scheduling in any state", %{db: db} do
    elected = rails("target", value: %{"wake_id" => "w_global"})
    assert {:ok, [_]} = admit(db, event("first"), elected)
    assert {:ok, [second]} = admit(db, event("second"), elected)
    assert second["status"] == "accepted"
    assert second["result"]["existing"]
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes WHERE wakeId='w_global'")
  end

  test "a changed global identity withdraws the old pending output under the same action", %{
    db: db
  } do
    {:ok, [initial]} = admit(db, event(), rails("target", value: %{"wake_id" => "w_old"}))

    assert {:ok, [changed]} =
             reconcile(db, event(), rails("other", value: %{"wake_id" => "w_new"}))

    assert changed["id"] == initial["id"]
    assert changed["status"] == "pending"
    assert changed["result"]["wake_id"] == "w_new"
    assert changed["result"]["previous_wake_ids"] == ["w_old"]
    assert %{state: "canceled", session_key: "target"} = Wakes.get(db, "w_old")
    assert %{state: "pending", session_key: "other"} = Wakes.get(db, "w_new")

    assert {:ok, [same]} =
             reconcile(db, event(), rails("other", value: %{"wake_id" => "w_new"}))

    assert same["result"] == changed["result"]
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes WHERE state='pending'")

    # Rolling the rail back cannot revive its already-canceled global output.
    assert {:ok, [rolled_back]} =
             reconcile(db, event(), rails("target", value: %{"wake_id" => "w_old"}))

    assert rolled_back["id"] == initial["id"]
    assert rolled_back["status"] == "accepted"
    assert rolled_back["result"]["existing"]
    assert rolled_back["result"]["previous_wake_ids"] == ["w_old", "w_new"]
    assert %{state: "canceled"} = Wakes.get(db, "w_old")
    assert %{state: "canceled"} = Wakes.get(db, "w_new")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM wakes WHERE state='pending'")
  end

  test "a changed global identity links an existing output without altering its recipient", %{
    db: db
  } do
    {:ok, [initial]} = admit(db, event(), rails("target", value: %{"wake_id" => "w_old"}))
    {:ok, [_]} = admit(db, event("other"), rails("target", value: %{"wake_id" => "w_shared"}))
    shared = Wakes.get(db, "w_shared")

    assert {:ok, [changed]} =
             reconcile(db, event(), rails("other", value: %{"wake_id" => "w_shared"}))

    assert changed["id"] == initial["id"]
    assert changed["status"] == "accepted"
    assert changed["result"]["wake_id"] == "w_shared"
    assert changed["result"]["previous_wake_ids"] == ["w_old"]
    assert changed["result"]["existing"]
    assert %{state: "canceled"} = Wakes.get(db, "w_old")
    assert Wakes.get(db, "w_shared") == shared
  end

  test "actual admitted turn freezes notice text and action before reconciliation", %{db: db} do
    {:ok, [initial]} = admit(db, event(), rails())
    id = initial["result"]["wake_id"]
    # The ledger row is the durable acceptance boundary read by the executor.
    {:ok, _} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,wakeId) VALUES('target','message','example','original','queued',10,?1)",
          [id]
        )
      end)

    assert {:ok, [accepted]} = reconcile(db, event(), rails("other", prompt: "changed"))
    assert accepted["status"] == "accepted"
    assert %{session_key: "target", prompt: "original"} = Wakes.get(db, id)
    assert {:ok, [^accepted]} = reconcile(db, event(), [])
  end

  test "elected obligation relation follows pending changes and freezes on acceptance", %{db: db} do
    {:ok, [initial]} = admit(db, event(), rails("target", value: %{"obligation_ref" => "first"}))
    id = initial["result"]["wake_id"]
    assert %{obligation_ref: "first"} = Wakes.get(db, id)

    assert {:ok, [updated]} =
             reconcile(db, event(), rails("target", value: %{"obligation_ref" => "second"}))

    assert updated["result"]["wake_id"] == id
    assert %{obligation_ref: "second"} = Wakes.get(db, id)
    assert {:ok, [_]} = reconcile(db, event(), rails())
    assert %{obligation_ref: nil} = Wakes.get(db, id)

    assert {:ok, [_]} =
             reconcile(db, event(), rails("target", value: %{"obligation_ref" => "accepted"}))

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,wakeId) VALUES('target','message','example','original','queued',10,?1)",
        [id]
      )

    assert {:ok, [accepted]} =
             reconcile(db, event(), rails("target", value: %{"obligation_ref" => "later"}))

    assert accepted["status"] == "accepted"
    assert %{obligation_ref: "accepted"} = Wakes.get(db, id)
  end
end
