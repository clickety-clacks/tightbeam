defmodule Tightbeam.TurnLifecycleTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, Ledger, TurnLifecycle}
  alias Tightbeam.DB.Txn

  setup do
    db = :"turn_lifecycle_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO users (userId, isAdmin, creationKind, createdAt)
      VALUES ('flynn', 0, 'admin_add', 1), ('kay', 0, 'admin_add', 1), ('root', 1, 'admin_add', 1);

      INSERT INTO sessions
        (sessionKey, displayName, kind, isBuiltIn, ownerUserId, origin, operationalParent,
         archetype, identityName, harness, provider, model, thinkingLevel, modelContext,
         createdAt, updatedAt)
      VALUES
        ('k1', 'Flynn session', 'main', 1, 'flynn', 'user:flynn', 'k1',
         'default', 'default', 'claude', 'anthropic', 'claude-sonnet-5', 'medium', NULL,
         1, 1),
        ('k2', 'Kay session', 'main', 1, 'kay', 'user:kay', 'k2',
         'default', 'default', 'claude', 'anthropic', 'claude-sonnet-5', 'medium', NULL,
         1, 1);
      """)

    %{db: db}
  end

  test "successful turn boundaries form one ordered, privacy-safe trace", %{db: db} do
    seq = enqueue!(db, "tell me the secret prompt")
    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(db, "k1", "lane:fixture")

    event!(db, seq, "checkout:started", "stage_started", stage: "checkout")
    lease = owner_lease(db, seq)
    assert :ok = Ledger.stamp_adapter(db, seq, 7, lease)
    event!(db, seq, "session:started", "stage_started", stage: "session")

    event!(db, seq, "session:succeeded", "stage_succeeded",
      stage: "session",
      detail: %{v: 1, mode: "new"}
    )

    event!(db, seq, "prompt:started", "stage_started", stage: "prompt")

    event!(db, seq, "prompt:dispatched", "prompt_dispatched",
      stage: "prompt",
      acp_request_id: 42
    )

    event!(db, seq, "progress:1", "progress_observed",
      stage: "prompt",
      detail: %{v: 1, class: "tool_call", label: "Tool activity"}
    )

    event!(db, seq, "prompt:resolved", "prompt_resolved",
      stage: "prompt",
      outcome: "delivered",
      detail: %{v: 1, result: "delivered"}
    )

    event!(db, seq, "prompt:succeeded", "stage_succeeded", stage: "prompt")

    {:ok, :appended} =
      DB.transaction(db, fn txn ->
        TurnLifecycle.append_in_txn(txn, seq, %{
          event_key: "assistant:committed",
          producer_event_id: "projection:assistant:committed",
          kind: "assistant_committed",
          outcome: "committed",
          cause: "projection:append",
          principal: "process:tightbeam",
          owner_lease: lease,
          detail: %{v: 1, messageCount: 1}
        })
      end)

    assert :ok = Ledger.finish(db, seq, "delivered", nil, owner_lease: lease)
    assert :ok = Ledger.mark_published(db, seq)

    trace = read(db, "k1", seq, {:user, "flynn"})

    assert Enum.map(trace.events, & &1.event_key) == [
             "accepted",
             "claimed",
             "checkout:started",
             "checkout:succeeded",
             "session:started",
             "session:succeeded",
             "prompt:started",
             "prompt:dispatched",
             "progress:1",
             "prompt:resolved",
             "prompt:succeeded",
             "assistant:committed",
             "terminal:committed",
             "terminal:published"
           ]

    assert Enum.map(trace.events, & &1.ordinal) == Enum.to_list(1..14)
    assert Enum.at(trace.events, 3).adapter_gen == 7
    assert Enum.at(trace.events, 7).acp_request_id == 42

    assert Enum.at(trace.events, 8).detail == %{
             "class" => "tool_call",
             "label" => "Tool activity",
             "v" => 1
           }

    encoded = JSON.encode!(trace)
    refute encoded =~ "secret prompt"
    refute encoded =~ "tool arguments"

    {:ok, [[stored_trace]]} =
      DB.query(
        db,
        """
        SELECT group_concat(eventKey || cause || principal || producerEventId || detail, '\n')
        FROM turn_lifecycle_events WHERE turnSeq=?1
        """,
        [seq]
      )

    refute stored_trace =~ "secret prompt"
    refute stored_trace =~ "assistant secret text"
    refute stored_trace =~ "tool arguments"
    refute stored_trace =~ "credential material"
    refute stored_trace =~ "jsonrpc"
  end

  test "exact replay is idempotent and conflicting replay is a named diagnostic", %{db: db} do
    seq = enqueue!(db, "replay")
    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(db, "k1", "lane:fixture")

    attrs =
      event("checkout:started", "stage_started", stage: "checkout")
      |> Map.put(:owner_lease, owner_lease(db, seq))

    assert :ok = TurnLifecycle.append(db, seq, attrs)
    assert :duplicate = TurnLifecycle.append(db, seq, Map.put(attrs, :at, 999))

    conflicting = Map.put(attrs, :cause, "different-cause")

    assert {:error, {:turn_lifecycle_conflict, "checkout:started"}} =
             TurnLifecycle.append(db, seq, conflicting)

    producer_conflict =
      attrs
      |> Map.put(:event_key, "checkout:another-key")
      |> Map.put(:cause, "fixture:boundary")

    assert {:error, {:turn_lifecycle_conflict, "checkout:another-key"}} =
             TurnLifecycle.append(db, seq, producer_conflict)

    progress =
      event("progress:1", "progress_observed",
        stage: "prompt",
        producer_event_id: "adapter:lease:progress:1",
        detail: %{v: 1, class: "thought", label: "Thinking"}
      )
      |> Map.put(:owner_lease, owner_lease(db, seq))

    assert :ok = TurnLifecycle.append(db, seq, progress)
    assert :duplicate = TurnLifecycle.append(db, seq, Map.put(progress, :at, 1_234))

    assert Enum.count(read(db, "k1", seq, {:user, "flynn"}).events) == 4
  end

  test "owner leases fence stale callbacks and terminal commit is absorbing", %{db: db} do
    seq = enqueue!(db, "lease fence")
    assert {:ok, %{seq: ^seq, owner_lease: lease}} = Ledger.claim_next(db, "k1", "lane:one")

    valid =
      event("prompt:started", "stage_started", stage: "prompt")
      |> Map.put(:owner_lease, lease)

    assert :ok = TurnLifecycle.append(db, seq, valid)

    stale =
      event("prompt:dispatched", "prompt_dispatched",
        stage: "prompt",
        acp_request_id: 99
      )
      |> Map.put(:owner_lease, "ol_prior_owner")

    assert {:error, {:turn_lifecycle_write_rejected, :stale_owner_lease}} =
             TurnLifecycle.append(db, seq, stale)

    assert {:error, {:turn_lifecycle_write_rejected, :invalid_terminal_authority}} =
             Ledger.finish(db, seq, "failed")

    assert {:ok, [["running"]]} = DB.query(db, "SELECT status FROM turns WHERE seq=?1", [seq])

    assert :ok = TurnLifecycle.append(db, seq, Map.put(stale, :owner_lease, lease))

    assert :ok =
             Ledger.finish(db, seq, "canceled", nil,
               owner_lease: lease,
               cause: "cancel-request",
               principal: "user:flynn"
             )

    late =
      event("prompt:late", "progress_observed",
        stage: "prompt",
        detail: %{v: 1, class: "thought", label: "Thinking"}
      )
      |> Map.put(:owner_lease, lease)

    assert {:error, {:turn_lifecycle_write_rejected, :terminal_absorbing}} =
             TurnLifecycle.append(db, seq, late)

    terminal =
      Enum.filter(
        read(db, "k1", seq, {:user, "flynn"}).events,
        &(&1.kind == "terminal_committed")
      )

    assert [%{outcome: "canceled", owner_lease: ^lease}] = terminal

    assert :duplicate = TurnLifecycle.append(db, seq, valid)
  end

  test "turns that reuse one ACP session cannot accept each other's callback lease", %{db: db} do
    first = enqueue!(db, "first shared-session turn")
    assert {:ok, %{owner_lease: first_lease}} = Ledger.claim_next(db, "k1", "lane:first")
    assert :ok = Ledger.finish(db, first, "delivered", nil, owner_lease: first_lease)

    second = enqueue!(db, "second shared-session turn")
    assert {:ok, %{owner_lease: second_lease}} = Ledger.claim_next(db, "k1", "lane:second")

    callback =
      event("prompt:started", "stage_started", stage: "prompt")
      |> Map.put(:owner_lease, first_lease)

    assert {:error, {:turn_lifecycle_write_rejected, :stale_owner_lease}} =
             TurnLifecycle.append(db, second, callback)

    assert :ok =
             TurnLifecycle.append(db, second, Map.put(callback, :owner_lease, second_lease))
  end

  test "owner and admin can read; foreign, mismatched, and unknown look identical", %{db: db} do
    seq = enqueue!(db, "authorization")

    assert %{turn: %{seq: ^seq}} = read(db, "k1", seq, {:user, "flynn"})
    assert %{turn: %{seq: ^seq}} = read(db, "k1", seq, {:user, "root"})
    assert %{turn: %{seq: ^seq}} = read(db, "k1", seq, {:session, "k1"})

    hidden = read(db, "k1", seq, {:user, "kay"})
    foreign_role_token = read(db, "k1", seq, {:session, "k2"})
    mismatch = read(db, "k2", seq, {:user, "root"})
    unknown = read(db, "k1", seq + 100, {:user, "root"})

    assert hidden == %{code: "not_found", message: "turn not found"}
    assert foreign_role_token == hidden
    assert mismatch == hidden
    assert unknown == hidden
  end

  test "the Gateway exposes the same owner-scoped turn-trace read", %{db: db} do
    seq = enqueue!(db, "gateway read")
    call = %{params: %{session_key: "k1", turn_seq: seq}, principal: {:user, "flynn"}}

    assert Gateway.handlers(%{db: db})["turn-trace"].(call) == TurnLifecycle.read(db, call)
  end

  test "historical turns remain readable as legacy without invented events", %{db: db} do
    :ok = DB.execute(db, "DROP TABLE turn_lifecycle_events; DROP TABLE turn_lifecycle_epoch;")

    {:ok, seq} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          """
          INSERT INTO turns (sessionKey, messageId, origin, prompt, status, createdAt)
          VALUES ('k1', 'legacy-message', 'user:flynn', 'old prompt', 'delivered', 1)
          """
        )

        [[seq]] = Txn.q(txn, "SELECT last_insert_rowid()")
        seq
      end)

    assert :ok = TurnLifecycle.ensure_schema(db)
    trace = read(db, "k1", seq, {:user, "flynn"})
    assert trace.turn.legacy
    assert trace.events == []
    assert :legacy = TurnLifecycle.append(db, seq, event("late", "claimed"))
  end

  test "trace rows and producer identities survive a DB owner restart" do
    unique = System.unique_integer([:positive])
    db = :"turn_lifecycle_restart_db_#{unique}"
    path = Path.join(System.tmp_dir!(), "turn-lifecycle-restart-#{unique}.sqlite3")
    on_exit(fn -> File.rm(path) end)

    {:ok, first_owner} = DB.start_link(path: path, name: db)
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('flynn', 0, 'admin_add', 1);
      INSERT INTO sessions
        (sessionKey, displayName, kind, isBuiltIn, ownerUserId, origin, operationalParent,
         archetype, identityName, harness, provider, model, thinkingLevel, modelContext,
         createdAt, updatedAt)
      VALUES ('restart', 'Restart', 'main', 1, 'flynn', 'user:flynn', 'restart',
              'default', 'default', 'claude', 'anthropic', 'claude-sonnet-5', 'medium',
              NULL, 1, 1);
      """)

    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: "restart",
        message_id: "restart-message",
        origin: "user:flynn",
        prompt: "not retained"
      })

    assert {:ok, %{owner_lease: lease}} = Ledger.claim_next(db, "restart", "lane:restart")

    assert :ok =
             TurnLifecycle.append(
               db,
               seq,
               event("prompt:started", "stage_started", stage: "prompt")
               |> Map.put(:owner_lease, lease)
             )

    assert :ok =
             TurnLifecycle.append(
               db,
               seq,
               event("prompt:dispatched", "prompt_dispatched",
                 stage: "prompt",
                 acp_request_id: 81
               )
               |> Map.put(:owner_lease, lease)
             )

    GenServer.stop(first_owner)

    {:ok, second_owner} = DB.start_link(path: path, name: db)
    trace = read(db, "restart", seq, {:user, "flynn"})

    assert Enum.map(trace.events, & &1.producer_event_id) == [
             "ledger:accepted",
             "ledger:claimed",
             "fixture:prompt:started",
             "fixture:prompt:dispatched"
           ]

    assert Enum.at(trace.events, 1).owner_lease == lease
    assert Enum.at(trace.events, 3).acp_request_id == 81
    refute JSON.encode!(trace) =~ "not retained"
    GenServer.stop(second_owner)
  end

  test "durable progress and failure detail are bounded labels, not raw inputs" do
    assert TurnLifecycle.progress_observation(%{
             "sessionUpdate" => "tool_call",
             "title" => "deploy --token super-secret"
           }) == %{class: "tool_call", label: "Tool activity"}

    assert TurnLifecycle.progress_observation(%{
             "sessionUpdate" => "agent_thought_chunk",
             "content" => "private reasoning"
           }) == %{class: "thought", label: "Thinking"}

    detail = TurnLifecycle.failure_detail({:provider, "credential super-secret"})
    assert detail.failureClass == "error"
    assert byte_size(detail.failureDigest) == 64
    refute JSON.encode!(detail) =~ "super-secret"
  end

  test "detail schemas reject accidental raw payload fields", %{db: db} do
    seq = enqueue!(db, "privacy")
    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(db, "k1", "lane:fixture")

    assert {:error, %ArgumentError{message: message}} =
             TurnLifecycle.append(
               db,
               seq,
               event("prompt:dispatched", "prompt_dispatched",
                 stage: "prompt",
                 acp_request_id: 7,
                 detail: %{v: 1, prompt: "must not persist"}
               )
               |> Map.put(:owner_lease, owner_lease(db, seq))
             )

    assert message =~ "unknown keys"
  end

  test "enqueue rollback leaves neither an accepted turn nor an orphan event", %{db: db} do
    assert {:error, %RuntimeError{message: "rollback specimen"}} =
             DB.transaction(db, fn txn ->
               assert {:ok, _seq} =
                        Ledger.enqueue_in_txn(txn, %{
                          session_key: "k1",
                          message_id: "rollback-message",
                          origin: "user:flynn",
                          principal: "user:flynn",
                          prompt: "must roll back"
                        })

               raise "rollback specimen"
             end)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM turns WHERE messageId='rollback-message'")

    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM turn_lifecycle_events")
  end

  test "accepted banks the normalized authenticated caller", %{db: db} do
    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "authenticated-caller",
        origin: "agent:product-owner",
        principal: {:session, "k1"},
        prompt: "not traced"
      })

    [accepted] = read(db, "k1", seq, {:user, "flynn"}).events
    assert accepted.principal == "session:k1"
    assert accepted.detail["authenticatedCaller"] == "session:k1"
    assert accepted.detail["origin"] == "agent:product-owner"
  end

  defp enqueue!(db, prompt) do
    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "m_#{System.unique_integer([:positive])}",
        client_message_id: "client-safe-id",
        origin: "user:flynn",
        prompt: prompt
      })

    seq
  end

  defp event!(db, seq, key, kind, opts) do
    attrs = event(key, kind, opts) |> Map.put(:owner_lease, owner_lease(db, seq))
    assert :ok = TurnLifecycle.append(db, seq, attrs)
  end

  defp event(key, kind, opts \\ []) do
    %{
      event_key: key,
      producer_event_id: Keyword.get(opts, :producer_event_id, "fixture:#{key}"),
      kind: kind,
      stage: Keyword.get(opts, :stage),
      outcome: Keyword.get(opts, :outcome, default_outcome(kind)),
      cause: Keyword.get(opts, :cause, "fixture:boundary"),
      principal: Keyword.get(opts, :principal, "process:tightbeam"),
      adapter_gen: Keyword.get(opts, :adapter_gen),
      acp_request_id: Keyword.get(opts, :acp_request_id),
      detail: Keyword.get(opts, :detail, %{v: 1})
    }
  end

  defp default_outcome("stage_started"), do: "started"
  defp default_outcome("stage_succeeded"), do: "succeeded"
  defp default_outcome("stage_failed"), do: "failed"
  defp default_outcome("prompt_dispatched"), do: "dispatched"
  defp default_outcome("progress_observed"), do: "observed"
  defp default_outcome("prompt_resolved"), do: "resolved"
  defp default_outcome(_kind), do: nil

  defp owner_lease(db, seq) do
    {:ok, [[lease]]} =
      DB.query(
        db,
        "SELECT ownerLease FROM turn_lifecycle_events WHERE turnSeq=?1 AND kind='claimed'",
        [seq]
      )

    lease
  end

  defp read(db, session_key, seq, principal) do
    TurnLifecycle.read(db, %{
      params: %{session_key: session_key, turn_seq: seq},
      principal: principal
    })
  end
end
