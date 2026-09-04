defmodule Tightbeam.BreathingTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Breathing, DB, Schema}

  setup do
    db = :"breathing_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    seed!(db)
    %{db: db}
  end

  test "A1 and A5: missing and retired session gates beat physical paths", %{db: db} do
    assert %{breathing: false, reason: "session_missing", evidence: %{}} =
             Breathing.query(db, "session", "missing")

    assert %{breathing: false, reason: "assignment_missing", evidence: %{}} =
             Breathing.query(db, "assignment", "missing")

    assert %{breathing: false, reason: "work_item_missing", evidence: %{}} =
             Breathing.query(db, "work-item", "missing")

    insert_turn!(db, 10, "retired", "running", assignment_id: "asg_retired")
    insert_wake!(db, "w_retired", "retired", assignment_id: "asg_retired")

    assert %{
             breathing: false,
             reason: "session_retired",
             evidence: %{session: %{sessionKey: "retired", state: "retired"}}
           } = Breathing.query(db, "session", "retired")
  end

  test "A2-A4: running, queued, and pending paths use exact deterministic precedence", %{db: db} do
    insert_wake!(db, "w_late", "active", due_at: 200)
    insert_wake!(db, "w_early_b", "active", due_at: 100)
    insert_wake!(db, "w_early_a", "active", due_at: 100)
    insert_turn!(db, 20, "active", "queued")
    insert_turn!(db, 21, "active", "queued")
    insert_turn!(db, 22, "active", "running")
    insert_turn!(db, 23, "active", "running")

    assert %{breathing: true, reason: "running_turn", evidence: %{turn: %{seq: 23}}} =
             Breathing.query(db, "session", "active")

    :ok = DB.execute(db, "UPDATE turns SET status='delivered', endedAt=30 WHERE status='running'")

    assert %{breathing: true, reason: "queued_turn", evidence: %{turn: %{seq: 21}}} =
             Breathing.query(db, "session", "active")

    :ok = DB.execute(db, "UPDATE turns SET status='delivered', endedAt=31 WHERE status='queued'")

    assert %{
             breathing: true,
             reason: "pending_wake",
             evidence: %{wake: %{wakeId: "w_early_a", dueAt: 100}}
           } = Breathing.query(db, "session", "active")
  end

  test "A6-A9: assignment gates and terminal reasons are exact", %{db: db} do
    insert_turn!(db, 30, "active", "running", assignment_id: "asg_closed")
    insert_turn!(db, 31, "retired", "running", assignment_id: "asg_retired")

    assert %{breathing: false, reason: "assignment_closed"} =
             Breathing.query(db, "assignment", "asg_closed")

    assert %{breathing: false, reason: "holder_retired"} =
             Breathing.query(db, "assignment", "asg_retired")

    insert_turn!(db, 32, "active", "failed",
      assignment_id: "asg_active",
      error: "usageLimitExceeded"
    )

    assert %{
             breathing: false,
             reason: "latest_terminal_failed",
             evidence: %{turn: %{seq: 32, error: "usageLimitExceeded"}}
           } = Breathing.query(db, "assignment", "asg_active")

    :ok = DB.execute(db, "UPDATE turns SET status='canceled' WHERE seq=32")

    assert %{breathing: false, reason: "latest_terminal_canceled"} =
             Breathing.query(db, "assignment", "asg_active")

    :ok = DB.execute(db, "UPDATE turns SET status='delivered' WHERE seq=32")

    assert %{breathing: false, reason: "no_current_path"} =
             Breathing.query(db, "assignment", "asg_active")
  end

  test "A10-A12 and A20: work-item composition is ordered and deterministic", %{db: db} do
    insert_wake!(db, "w_linked", "active", assignment_id: "asg_pending")

    insert_turn!(db, 40, "active2", "queued",
      assignment_id: "asg_queued",
      job_ref: "wi_linked"
    )

    insert_turn!(db, 41, "active", "running",
      assignment_id: "asg_running",
      job_ref: "wi_linked"
    )

    assert %{
             breathing: true,
             reason: "running_turn",
             evidence: %{turn: %{seq: 41}}
           } = Breathing.query(db, "work-item", "wi_linked")

    :ok = DB.execute(db, "UPDATE turns SET jobRef=NULL WHERE jobRef='wi_linked'")

    assert %{
             breathing: true,
             reason: "open_assignment_lively",
             evidence: %{assignment: %{id: "asg_running", reason: "running_turn"}}
           } = Breathing.query(db, "work-item", "wi_linked")

    :ok = DB.execute(db, "UPDATE turns SET status='delivered', endedAt=50")
    :ok = DB.execute(db, "DELETE FROM wakes WHERE wakeId='w_linked'")

    assert %{
             breathing: false,
             reason: "all_open_assignments_not_lively",
             evidence: %{
               openAssignments: [
                 %{id: "asg_pending", openedAt: 5},
                 %{id: "asg_queued", openedAt: 6},
                 %{id: "asg_running", openedAt: 7}
               ]
             }
           } = Breathing.query(db, "work-item", "wi_linked")

    assert %{breathing: false, reason: "no_open_assignment"} =
             Breathing.query(db, "work-item", "wi_empty")
  end

  test "A11 and A19: direct wake is breathing but a terminal work-item gate wins", %{db: db} do
    insert_wake!(db, "w_direct", "active", work_item_id: "wi_empty")
    insert_wake!(db, "w_terminal", "active", work_item_id: "wi_terminal")

    assert %{breathing: true, reason: "pending_wake"} =
             Breathing.query(db, "work-item", "wi_empty")

    assert %{
             breathing: false,
             reason: "work_item_terminal",
             evidence: %{workItem: %{state: "closed"}}
           } = Breathing.query(db, "work-item", "wi_terminal")
  end

  test "A13: each result observes one side of an atomic close/path race", %{db: db} do
    for iteration <- 1..40 do
      :ok =
        DB.execute(
          db,
          "UPDATE assignments SET state='open', outcome=NULL, closedAt=NULL, closedByUser=NULL, closingAttestId=NULL WHERE id='asg_active'; DELETE FROM wakes WHERE assignmentId='asg_active'"
        )

      parent = self()

      reader =
        Task.async(fn ->
          send(parent, {:reader_started, iteration})
          Breathing.query(db, "assignment", "asg_active")
        end)

      assert_receive {:reader_started, ^iteration}

      writer =
        Task.async(fn ->
          DB.transaction(db, fn txn ->
            Tightbeam.DB.Txn.q(
              txn,
              "INSERT INTO wakes (wakeId,sessionKey,origin,prompt,dueAt,state,createdAt,assignmentId) VALUES (?1,'active','user:owner','resume',100,'pending',1,'asg_active')",
              ["w_race_#{iteration}"]
            )

            Tightbeam.DB.Txn.q(
              txn,
              "UPDATE assignments SET state='closed', outcome='completed', closedAt=2, closedByUser='owner', closingAttestId='att_race_close' WHERE id='asg_active'"
            )
          end)
        end)

      result = Task.await(reader)
      assert {:ok, _} = Task.await(writer)

      assert {result.breathing, result.reason} in [
               {false, "no_current_path"},
               {false, "assignment_closed"}
             ]
    end
  end

  test "A14 and A17: restart is byte-stable and evidence omits secret siblings" do
    path =
      Path.join(System.tmp_dir!(), "breathing-restart-#{System.unique_integer([:positive])}.db")

    on_exit(fn -> File.rm(path) end)

    first = :"breathing_restart_a_#{System.unique_integer([:positive])}"
    {:ok, first_pid} = DB.start_link(path: path, name: first)
    :ok = Schema.ensure_all(first)
    seed!(first)
    insert_turn!(first, 60, "active", "running", assignment_id: "asg_active")
    before = Breathing.query(first, "assignment", "asg_active")
    GenServer.stop(first_pid)

    second = :"breathing_restart_b_#{System.unique_integer([:positive])}"
    {:ok, second_pid} = DB.start_link(path: path, name: second)
    after_restart = Breathing.query(second, "assignment", "asg_active")
    GenServer.stop(second_pid)

    assert after_restart == before
    refute inspect(after_restart) =~ "cliToken"
    refute inspect(after_restart) =~ "identityToken"
  end

  test "A18 and I1-I2: agent-authored facts neither prove breathing nor receive a stored answer",
       %{
         db: db
       } do
    :ok =
      DB.execute(
        db,
        "INSERT INTO attests (id,assignmentId,kind,note,bySession,ts) VALUES ('att_only','asg_active','progress','breathing','active',1)"
      )

    {:ok, [[before_events]]} = DB.query(db, "SELECT count(*) FROM events")

    assert %{breathing: false, reason: "no_current_path"} =
             result =
             Breathing.query(db, "assignment", "asg_active")

    {:ok, [[after_events]]} = DB.query(db, "SELECT count(*) FROM events")
    assert before_events == after_events
    refute inspect(result) =~ "att_only"
  end

  test "the handler accepts user and session principals and refuses process principals", %{db: db} do
    call = %{principal: {:user, "owner"}, params: %{target_kind: "session", target_id: "active"}}
    assert %{schema: "breathing-v1"} = Breathing.handle(db, call)

    assert %{code: "process_denied"} =
             Breathing.handle(db, %{call | principal: {:process, "tightbeam"}})
  end

  defp seed!(db) do
    :ok =
      DB.execute(db, """
      INSERT INTO users (userId,isAdmin,creationKind,createdAt)
      VALUES ('owner',0,'admin_add',1);

      INSERT INTO sessions
        (sessionKey,displayName,kind,isBuiltIn,ownerUserId,origin,operationalParent,
         archetype,identityName,harness,provider,model,thinkingLevel,createdAt,updatedAt,state)
      VALUES
        ('active','Active','custom',0,'owner','user:owner','active','default','default',
         'codex','openai','model','medium',1,1,'active'),
        ('active2','Active 2','custom',0,'owner','user:owner','active2','default','default',
         'codex','openai','model','medium',1,1,'active'),
        ('retired','Retired','custom',0,'owner','user:owner','retired','default','default',
         'codex','openai','model','medium',1,1,'retired');

      INSERT INTO work_items (id,title,ownerUserId,state,createdByUser,createdAt)
      VALUES
        ('wi_open','Open','owner','open','owner',1),
        ('wi_linked','Linked','owner','open','owner',2),
        ('wi_empty','Empty','owner','open','owner',3),
        ('wi_terminal','Terminal','owner','closed','owner',4);

      INSERT INTO assignments
        (id,subject,holderKey,openedByUser,openedAt,state,outcome,closedAt,closedByUser,workItemId)
      VALUES
        ('asg_active','Active','active','owner',1,'open',NULL,NULL,NULL,'wi_open'),
        ('asg_closed','Closed','active','owner',2,'open',NULL,NULL,NULL,'wi_open'),
        ('asg_retired','Retired','retired','owner',3,'open',NULL,NULL,NULL,'wi_open'),
        ('asg_pending','Pending','active','owner',5,'open',NULL,NULL,NULL,'wi_linked'),
        ('asg_queued','Queued','active2','owner',6,'open',NULL,NULL,NULL,'wi_linked'),
        ('asg_running','Running','active','owner',7,'open',NULL,NULL,NULL,'wi_linked');

      INSERT INTO attests (id,assignmentId,kind,note,bySession,ts)
      VALUES
        ('att_closed','asg_closed','completion','closed fixture','active',3),
        ('att_race_close','asg_active','completion','race fixture','active',2);

      UPDATE assignments
      SET state='closed',outcome='completed',closedAt=3,closedByUser='owner',closingAttestId='att_closed'
      WHERE id='asg_closed';
      """)
  end

  defp insert_turn!(db, seq, session_key, status, opts \\ []) do
    :ok =
      DB.execute(
        db,
        "INSERT INTO turns (seq,sessionKey,messageId,origin,prompt,assignmentId,jobRef,status,adapterGen,error,createdAt,startedAt,endedAt) VALUES (#{seq},'#{session_key}','m_#{seq}','user:owner','work',#{sql(Keyword.get(opts, :assignment_id))},#{sql(Keyword.get(opts, :job_ref))},'#{status}',7,#{sql(Keyword.get(opts, :error))},#{seq},#{seq},#{if status in ~w(queued running), do: "NULL", else: seq})"
      )
  end

  defp insert_wake!(db, wake_id, session_key, opts) do
    due_at = Keyword.get(opts, :due_at, 100)

    :ok =
      DB.execute(
        db,
        "INSERT INTO wakes (wakeId,sessionKey,origin,prompt,dueAt,state,createdAt,assignmentId,work_item_id) VALUES ('#{wake_id}','#{session_key}','user:owner','resume',#{due_at},'pending',1,#{sql(Keyword.get(opts, :assignment_id))},#{sql(Keyword.get(opts, :work_item_id))})"
      )
  end

  defp sql(nil), do: "NULL"
  defp sql(value), do: "'#{value}'"
end
