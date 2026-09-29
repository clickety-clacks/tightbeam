defmodule Tightbeam.HarnessHealthRedeliveryRestart do
  import ExUnit.Assertions

  alias Tightbeam.{DB, HarnessHealth, Ledger, Model, Org, Schema, Wakes}

  def run(payload, base) do
    payload = Path.expand(payload)
    app_dir = Application.app_dir(:tightbeam) |> Path.expand()
    assert payload == app_dir
    refute File.exists?(base)

    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, _} = Application.ensure_all_started(:crypto)
    Application.put_env(:tightbeam, :fixture_harness, true)

    path = Path.join(base, "state.db")
    {:ok, db} = DB.start_link(path: path, name: nil, guard_inputs: [])

    try do
      ensure_all_schemas(db)
      :ok = DB.assert_base_admitted!(db, base)
      owner = "health-redelivery-restart"
      ensure_main_session(db, owner)

      sessions =
        for index <- 1..3 do
          session_key = "agent:health-redelivery:#{index}"

          Org.create(db, %{
            session_key: session_key,
            display_name: "Health redelivery #{index}",
            owner_user_id: owner,
            origin: "user:#{owner}",
            archetype: "coder",
            host: "testhost",
            harness: "claude",
            provider: "anthropic",
            model: Model.new("claude-fable-5")
          })

          session_key
        end

      [first, second, healthy] = sessions
      auth_error = %{"status" => 401, "error" => "unauthorized"}
      interrupted_error = :interrupted_outcome_unknown

      source_turns =
        Enum.map(
          [{first, "restart-source-1"}, {second, "restart-source-2"}],
          fn {key, message_id} ->
            fail_health_turn!(db, key, message_id, "original prompt", auth_error)
          end
        )

      Enum.each(source_turns, fn turn ->
        session = Org.get(db, turn.session_key)

        assert {:ok, post_commit} =
                 DB.transaction(db, fn txn ->
                   HarnessHealth.observe_turn_failure_in_txn(
                     txn,
                     session,
                     turn,
                     :prompt,
                     auth_error
                   )
                 end)

        if is_function(post_commit, 0), do: post_commit.()
      end)

      assert [first_incident] = HarnessHealth.active(db)
      assert first_incident.failureClass == "auth-dead"

      _first_restore = restore_health_turn!(db, healthy, "restore-first")
      assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM health_redelivery_attempts")

      # A failed redelivery can open another typed incident, but its source
      # message guard must prevent a second retry row for either message.
      Enum.each([first, second], fn key ->
        {:ok, retry_turn} = Ledger.claim_next(db, key, "health-redelivery-test")
        session = Org.get(db, key)
        retry_turn = Map.put(retry_turn, :session_key, key)

        assert {:ok, post_commit} =
                 DB.transaction(db, fn txn ->
                   assert Ledger.finish_in_txn(txn, retry_turn.seq, "failed", "HTTP 401",
                            owner_lease: retry_turn.owner_lease
                          )

                   HarnessHealth.observe_turn_failure_in_txn(
                     txn,
                     session,
                     retry_turn,
                     :prompt,
                     auth_error
                   )
                 end)

        if is_function(post_commit, 0), do: post_commit.()
      end)

      assert [second_incident] = HarnessHealth.active(db)
      assert second_incident.failureClass == "auth-dead"

      second_restore = restore_health_turn!(db, healthy, "restore-second")
      second_restore_seq = second_restore.seq
      assert HarnessHealth.active(db) == []

      assert {:ok, [[0]]} =
               DB.query(
                 db,
                 "SELECT COUNT(*) FROM turns WHERE status='queued' AND sessionKey IN (?1,?2)",
                 [first, second]
               )

      assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM health_redelivery_attempts")

      assert {:ok, [["restart-source-1", 2], ["restart-source-2", 2]]} =
               DB.query(
                 db,
                 """
                 SELECT messageId,COUNT(*) FROM turns
                 WHERE messageId IN ('restart-source-1','restart-source-2')
                 GROUP BY messageId ORDER BY messageId
                 """
               )

      # A parentless interrupted outcome uses the same once-only success
      # fallback, and its persisted attempt must survive reopening this store.
      interrupted_source =
        fail_health_turn!(
          db,
          first,
          "restart-interrupted-source",
          "original interrupted prompt",
          interrupted_error,
          terminal: "failed_unknown"
        )

      _third_restore = restore_health_turn!(db, healthy, "restore-third")

      assert {:ok, [[3]]} = DB.query(db, "SELECT COUNT(*) FROM health_redelivery_attempts")

      assert {:ok, [[2]]} =
               DB.query(
                 db,
                 "SELECT COUNT(*) FROM turns WHERE messageId='restart-interrupted-source'"
               )

      GenServer.stop(db)
      {:ok, reopened} = DB.start_link(path: path, name: nil, guard_inputs: [])

      try do
        ensure_all_schemas(reopened)
        :ok = DB.assert_base_admitted!(reopened, base)

        assert {:ok, 0} =
                 DB.transaction(reopened, fn txn ->
                   Wakes.redeliver_failed_intent_in_txn(
                     txn,
                     second_incident.id,
                     "auth-dead",
                     second_restore
                   )
                 end)

        assert {:ok, [[3]]} =
                 DB.query(reopened, "SELECT COUNT(*) FROM health_redelivery_attempts")

        assert {:ok, [[2]]} =
                 DB.query(
                   reopened,
                   "SELECT COUNT(*) FROM health_redelivery_attempts " <>
                     "WHERE failureClass='auth-dead' " <>
                     "AND redeliveryTurnSeq IS NOT NULL"
                 )

        assert {:ok, [[1]]} =
                 DB.query(
                   reopened,
                   "SELECT COUNT(*) FROM health_redelivery_attempts " <>
                     "WHERE sessionKey=?1 AND sourceTurnSeq=?2 " <>
                     "AND failureClass='interrupted-outcome-unknown' " <>
                     "AND redeliveryTurnSeq IS NOT NULL",
                   [first, interrupted_source.seq]
                 )

        assert {:ok, :ok} =
                 DB.transaction(reopened, fn txn ->
                   Wakes.record_health_redelivery_source_in_txn(
                     txn,
                     interrupted_source.seq,
                     "interrupted-outcome-unknown"
                   )
                 end)

        _fourth_restore = restore_health_turn!(reopened, healthy, "restore-fourth")

        assert {:ok, [[2]]} =
                 DB.query(
                   reopened,
                   "SELECT COUNT(*) FROM turns WHERE messageId='restart-interrupted-source'"
                 )

        assert {:ok, [[1]]} =
                 DB.query(
                   reopened,
                   "SELECT COUNT(*) FROM turns WHERE messageId='restart-interrupted-source' " <>
                     "AND status='queued'"
                 )

        assert {:ok, [[second_restore_seq]]} =
                 DB.query(
                   reopened,
                   "SELECT seq FROM turns WHERE messageId='restore-second' AND status='delivered'"
                 )
      after
        if Process.alive?(reopened), do: GenServer.stop(reopened)
      end
    after
      if Process.alive?(db), do: GenServer.stop(db)
    end
  end

  defp ensure_all_schemas(db) do
    :ok = Schema.ensure_all(db)
    {:ok, columns} = DB.query(db, "PRAGMA table_info(users)")

    if Enum.any?(columns, fn [_cid, name | _rest] -> name == "creationKind" end) do
      :ok
    else
      DB.execute(db, "ALTER TABLE users ADD COLUMN creationKind TEXT NOT NULL DEFAULT 'legacy'")
    end
  end

  defp ensure_main_session(db, owner) do
    key = Org.personal_session_key(owner)

    case Org.get(db, key) do
      nil ->
        Org.create(db, %{
          session_key: key,
          display_name: "Main",
          kind: "main",
          is_built_in: true,
          owner_user_id: owner,
          origin: "user:#{owner}",
          archetype: "default",
          harness: "claude",
          provider: "anthropic",
          model: Model.new("fable"),
          host: "testhost"
        })

      %{kind: "main"} = session ->
        session

      session ->
        raise "invalid Main fixture for #{owner}: #{inspect(session)}"
    end
  end

  defp fail_health_turn!(db, session_key, message_id, prompt, reason, opts \\ []) do
    terminal = Keyword.get(opts, :terminal, "failed")

    {:ok, source_seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: message_id,
        origin: "agent:health-redelivery",
        prompt: prompt
      })

    {:ok, turn} = Ledger.claim_next(db, session_key, "health-redelivery-test")
    turn = Map.put(turn, :session_key, session_key)
    session = Org.get(db, session_key)

    assert {:ok, post_commit} =
             DB.transaction(db, fn txn ->
               assert Ledger.finish_in_txn(
                        txn,
                        source_seq,
                        terminal,
                        if(terminal == "failed_unknown",
                          do: "interrupted: outcome unknown",
                          else: "HTTP 401"
                        ),
                        owner_lease: turn.owner_lease
                      )

               if terminal == "failed_unknown" do
                 HarnessHealth.observe_terminal_in_txn(
                   txn,
                   source_seq,
                   "interrupted-outcome-unknown",
                   "test terminal was interrupted; outcome unknown",
                   "process:test"
                 )
               else
                 HarnessHealth.observe_turn_failure_in_txn(
                   txn,
                   session,
                   turn,
                   :prompt,
                   reason
                 )
               end
             end)

    if is_function(post_commit, 0), do: post_commit.()
    turn
  end

  defp restore_health_turn!(db, session_key, message_id) do
    {:ok, _seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: message_id,
        origin: "agent:health-redelivery",
        prompt: "restored provider turn"
      })

    {:ok, turn} = Ledger.claim_next(db, session_key, "health-redelivery-test")
    turn = Map.put(turn, :session_key, session_key)
    session = Org.get(db, session_key)

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "delivered", nil,
                        owner_lease: turn.owner_lease
                      )

               HarnessHealth.resolve_normal_turn_in_txn(txn, session, turn)
             end)

    turn
  end
end

[payload, base] = System.argv()
Tightbeam.HarnessHealthRedeliveryRestart.run(payload, base)
IO.puts("health-redelivery-restart: ok")
