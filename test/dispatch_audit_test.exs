defmodule Tightbeam.DispatchAuditTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Dispatch}

  # File-backed: only then do reads have connections of their own.
  setup do
    db = :"dispatch_audit_db_#{System.unique_integer([:positive])}"
    base = Path.join(System.tmp_dir!(), "#{db}")
    prepared = Tightbeam.GuardRuntimeFixture.prepare!(base, "schema_shape_runtime.exs")
    on_exit(fn -> File.rm_rf!(base) end)

    owner =
      start_supervised!(
        {DB,
         path: Path.join(prepared.base, "state.db"),
         name: db,
         guard_inputs: [],
         payload_root: prepared.payload}
      )

    :ok = ensure_all_schemas(db)
    %{db: db, owner: owner}
  end

  defp read!(db, result \\ %{attests: []}, hub \\ nil) do
    call = %{
      verb: "attests",
      origin: "process:reader",
      principal: {:process, "reader"},
      session_key: nil,
      params: %{}
    }

    call = if hub, do: Map.put(call, :firehose_hub, hub), else: call
    assert {:ok, ^result} = Dispatch.dispatch(db, %{"attests" => fn _ -> result end}, call)
  end

  defp audits(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT count(*) FROM events WHERE verb='attests'")
    count
  end

  defp eventually(fun, tries \\ 400) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  test "a burst of reads behind one slow write leaves room for other callers", %{
    db: db,
    owner: owner
  } do
    parent = self()

    slow =
      Task.async(fn ->
        DB.transaction(db, fn _txn ->
          send(parent, :writing)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :writing
    for _ <- 1..400, do: read!(db)

    # One call from the audits' own process; the reads themselves queue nothing.
    assert eventually(fn ->
             Process.info(owner, :message_queue_len) == {:message_queue_len, 1}
           end)

    refute DB.overloaded?(db)
    other = Task.async(fn -> DB.transaction(db, fn _txn -> :written end) end)
    send(owner, :release)

    assert {:ok, :ok} = Task.await(slow)
    assert {:ok, :written} = Task.await(other)
    assert eventually(fn -> audits(db) == 400 end)
  end

  test "audits met by an overloaded owner are kept and written once it recovers", %{
    db: db,
    owner: owner
  } do
    :sys.suspend(owner)

    for _ <- 1..128,
        do: send(owner, {:"$gen_call", {self(), make_ref()}, {:query, "SELECT 1", []}})

    assert DB.overloaded?(db)
    ExUnit.CaptureLog.capture_log(fn -> for _ <- 1..3, do: read!(db) end)
    assert audits(db) == 0

    :sys.resume(owner)
    assert eventually(fn -> audits(db) == 3 end)
  end

  test "an owner that answers late outlives the audits it did not write", %{
    db: db,
    owner: owner
  } do
    previous = Application.fetch_env(:tightbeam, :db_call_timeout_ms)
    Application.put_env(:tightbeam, :db_call_timeout_ms, 50)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tightbeam, :db_call_timeout_ms, value)
        :error -> Application.delete_env(:tightbeam, :db_call_timeout_ms)
      end
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      :sys.suspend(owner)
      read!(db)
      Process.sleep(300)
      assert Process.alive?(owner)
      :sys.resume(owner)

      read!(db)
      assert eventually(fn -> audits(db) >= 1 end)
      assert Process.whereis(db) == owner
    end)
  end

  test "a read's result is not sent to the database owner", %{db: db, owner: owner} do
    result = %{attests: Enum.map(1..5_000, &%{id: &1})}
    :erlang.trace(owner, true, [:receive])

    read!(db, result)
    assert eventually(fn -> audits(db) == 1 end)
    :erlang.trace(owner, false, [:receive])

    assert_received {:trace, ^owner, :receive, {:"$gen_call", _, _} = request}
    assert :erts_debug.flat_size(request) < :erts_debug.flat_size(result)
    refute_received {:trace, ^owner, :receive, {:"$gen_cast", {:dispatch_audit, _, _}}}
  end

  test "each read is published once, after its audit commits", %{db: db} do
    hub = :"dispatch_audit_hub_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.Firehose.Hub, name: hub})

    :ok =
      Tightbeam.Firehose.Hub.register(hub, self(), %{
        mode: :all,
        db: db,
        user_id: "flynn",
        is_admin: true
      })

    read!(db, %{attests: []}, hub)

    assert_receive {:firehose_notice,
                    %{"class" => "verb.accepted", "payload" => %{"verb" => "attests"}}},
                   2_000

    assert audits(db) == 1
    refute_receive {:firehose_notice, _}, 50
  end
end
