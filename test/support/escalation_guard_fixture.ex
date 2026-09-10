defmodule Tightbeam.EscalationGuardFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias Tightbeam.{DB, Devices, Escalation, LiveBaseLock, Model, Org, Schema}
  alias Exqlite.Sqlite3

  def run(mode, base, locks) do
    Tightbeam.Rules.load!(Path.join(System.tmp_dir!(), "guarded-escalation-empty-rules"), [])
    path = Path.join(base, "state.db")
    {:ok, db} = DB.start_link(path: path, name: nil, guard_inputs: [lock_dir: locks])

    try do
      :ok = Schema.ensure_all(db)
      :ok = DB.assert_base_admitted!(db, base)
      Devices.add_user(db, "flynn", true)
      marker = File.read!(Path.join(base, "build-owner.json"))

      case mode do
        :visibility -> visibility(db, path)
        :integrity -> integrity(db, path, base, locks)
      end

      assert File.read!(Path.join(base, "build-owner.json")) == marker
    after
      if Process.alive?(db), do: GenServer.stop(db)
    end

    await_release(base, locks)
  end

  defp visibility(db, path) do
    raiser = session(db, "transaction-raiser", "flynn")
    {:ok, reader} = Sqlite3.open(path, mode: :readonly)

    try do
      request =
        Escalation.operator_ask(db, operator_call(raiser, %{question: "transaction barrier?"}))

      assert {:ok, _} =
               DB.query(
                 db,
                 "INSERT INTO condition_facts (ts,kind,scope,origin) VALUES (?1,'unrelated','fixture','process:test')",
                 [System.system_time(:millisecond)]
               )

      parent = self()

      task =
        Task.async(fn ->
          hook =
            {:block, :after_schedule, parent, :scheduled_uncommitted, :commit_terminal_ruling}

          Escalation.operator_rule(
            db,
            owner_operator_rule(request.id, %{decision: "accept"}),
            transaction_step_hook: hook
          )
        end)

      assert_receive {:scheduled_uncommitted, db_pid}, 2_000

      try do
        assert {:ok, [[0, 0]]} =
                 readonly_query(
                   reader,
                   "SELECT (SELECT COUNT(*) FROM wakes WHERE conditionScope=?1), (SELECT COUNT(*) FROM condition_facts WHERE scope=?1)",
                   [request.id]
                 )
      after
        send(db_pid, :commit_terminal_ruling)
      end

      ruled = Task.await(task)

      assert {:ok, [[cursor, "fired", "condition"]]} =
               DB.query(
                 db,
                 "SELECT conditionAfterId,state,firedBy FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope=?1",
                 [request.id]
               )

      assert cursor < ruled.ruling_fact_id

      rollback =
        Escalation.operator_ask(db, operator_call(raiser, %{question: "transaction rollback?"}))

      assert_raise RuntimeError, "fixture after schedule", fn ->
        Escalation.operator_rule(
          db,
          owner_operator_rule(rollback.id, %{decision: "accept"}),
          transaction_step_hook: {:raise, :after_schedule, "fixture after schedule"}
        )
      end

      assert {:ok, [[0, 0]]} =
               DB.query(
                 db,
                 "SELECT (SELECT COUNT(*) FROM wakes WHERE conditionScope=?1), (SELECT COUNT(*) FROM condition_facts WHERE scope=?1)",
                 [rollback.id]
               )
    after
      :ok = Sqlite3.close(reader)
    end
  end

  defp integrity(first, path, base, locks) do
    first_pid = first
    raiser = session(first, "evidence-restart", "flynn")

    request =
      Escalation.operator_ask(first, operator_call(raiser, %{question: "evidence restart?"}))

    Escalation.operator_rule(
      first,
      owner_operator_rule(request.id, %{decision: "accept"})
    )

    assert {:ok, _} =
             DB.query(
               first,
               "DELETE FROM lifecycle_events WHERE kind='decision_request_ruled' AND subject=?1",
               [request.id]
             )

    owner_call = %{origin: "user:flynn", principal: {:user, "flynn"}, params: %{}}

    assert %{code: "decision_request_integrity_invalid"} =
             Escalation.list(first, owner_call, "ruled")

    assert %{code: "decision_request_integrity_invalid"} =
             Escalation.get(first, owner_call, request.id)

    refute Escalation.consume(first, request.id)

    assert %{code: "decision_request_integrity_invalid"} =
             Escalation.operator_rule(
               first,
               owner_operator_rule(request.id, %{decision: "accept"})
             )

    assert :ok = GenServer.stop(first_pid)

    await_release(base, locks)
    {:ok, second_pid} = DB.start_link(path: path, name: nil, guard_inputs: [lock_dir: locks])
    second = second_pid

    try do
      assert :ok = Schema.ensure_all(second)

      assert %{code: "decision_request_integrity_invalid"} =
               Escalation.get(second, owner_call, request.id)

      assert %{code: "decision_request_integrity_invalid"} =
               Escalation.list(second, owner_call, "ruled")

      refute Escalation.consume(second, request.id)

      assert %{code: "decision_request_integrity_invalid"} =
               Escalation.operator_rule(
                 second,
                 owner_operator_rule(request.id, %{decision: "accept"})
               )

      assert {:ok, [[1, "list", ~s(["rulingLifecycleEvent"])]]} =
               DB.query(
                 second,
                 "SELECT COUNT(*),MIN(firstSurface),MIN(failingFields) FROM decision_request_integrity_evidence WHERE requestId=?1",
                 [request.id]
               )
    after
      if Process.alive?(second_pid), do: GenServer.stop(second_pid)
    end

    await_release(base, locks)
  end

  defp readonly_query(reader, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(reader, sql)

    try do
      :ok = Sqlite3.bind(stmt, params)
      Sqlite3.fetch_all(reader, stmt)
    after
      :ok = Sqlite3.release(reader, stmt)
    end
  end

  defp await_release(base, locks) do
    path = Path.join(locks, Base.encode16(:crypto.hash(:sha256, base), case: :lower) <> ".lock")

    await = fn recur, left ->
      case LiveBaseLock.acquire(path) do
        {:ok, lock} ->
          :ok = LiveBaseLock.release(lock)

        {:error, :lock_busy} when left > 0 ->
          Process.sleep(10)
          recur.(recur, left - 1)

        other ->
          raise "guard lock did not release: #{inspect(other)}"
      end
    end

    await.(await, 100)
  end

  defp session(db, name, owner) do
    Org.create(db, %{
      session_key: "agent:#{name}:app",
      display_name: name,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp operator_call(session, params) do
    %{
      verb: "operator-ask",
      origin: "agent:raiser",
      principal: {:session, session.session_key},
      transport_session_key: session.session_key,
      params: params
    }
  end

  defp owner_operator_rule(id, params) do
    %{
      verb: "operator-rule",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      transport_session_key: nil,
      params: Map.put(params, :request, id)
    }
  end
end
