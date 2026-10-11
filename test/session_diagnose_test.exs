defmodule Tightbeam.SessionDiagnoseTest do
  use Tightbeam.TestCase, async: false
  import Plug.Test
  alias Tightbeam.{SessionDiagnose, SessionLane}
  alias Tightbeam.Wire.Router

  @key "agent:main:clawline:mike:main s_8d73770a"
  @secret "CANARY_AUTH_SQL_MAILBOX_229693e2"

  setup do
    start_supervised!({Registry, keys: :unique, name: SessionDiagnoseTest.Registry})

    {:ok,
     %{
       deps: %{
         cli_token: @secret,
         diagnostic_scope: %{@key => "mike"},
         lane_registry: SessionDiagnoseTest.Registry,
         db: :no_diagnostic_db
       }
     }}
  end

  defp request(deps, body, token \\ @secret) do
    conn(:post, "/agent/session-diagnose", JSON.encode!(body))
    |> Plug.Conn.put_req_header(
      "x-tightbeam-cli-version",
      Tightbeam.CliCompatibility.required_version()
    )
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Router.call(Map.to_list(deps))
  end

  defp body, do: %{"sessionKey" => @key, "asUser" => "mike"}

  defp lane(state) do
    parent = self()

    pid =
      :proc_lib.spawn_link(fn ->
        Registry.register(SessionDiagnoseTest.Registry, @key, nil)
        send(parent, {:fixture_lane_ready, self()})
        :gen_server.enter_loop(SessionLane, [], state)
      end)

    assert_receive {:fixture_lane_ready, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  test "real router authenticates and refuses unscoped targets without DB", %{deps: deps} do
    assert request(deps, body(), "wrong").status == 401
    assert request(deps, %{body() | "asUser" => "other"}).status == 403
    assert request(deps, %{body() | "sessionKey" => "another-seat"}).status == 403
    assert request(Map.delete(deps, :diagnostic_scope), body()).status == 403
  end

  test "absent lane and unrecorded fields are explicit", %{deps: deps} do
    response = request(deps, body())
    assert response.status == 200
    data = JSON.decode!(response.resp_body)["result"]
    assert data["db"] == %{"exists" => false}
    assert data["lane"]["recorded"]["status"] == "absent"
    assert data["reservationGate"] == "unavailable_without_lane_snapshot"
    assert data["operationPhase"] == "unavailable_not_recorded"
    assert data["ledgerCounts"] == "unavailable_without_db_query"
    refute response.resp_body =~ @secret
    assert byte_size(response.resp_body) <= 4096
  end

  test "actual lane callback reports active and stale tasks without changing state", %{deps: deps} do
    task =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)

    state = %SessionLane{
      current_seq: 195_315,
      task_ref: make_ref(),
      task_pid: task,
      session_key: @key,
      db: :must_not_query,
      runner: fn _ -> flunk("runner called") end
    }

    pid = lane(state)

    data =
      request(deps, body()) |> Map.fetch!(:resp_body) |> JSON.decode!() |> Map.fetch!("result")

    assert data["lane"]["recorded"] == %{
             "status" => "available",
             "currentSeq" => 195_315,
             "taskPresent" => true,
             "taskAlive" => true,
             "reservationPresent" => false,
             "settlementRechecking" => false,
             "deferredDrain" => false
           }

    assert :sys.get_state(pid) == state
    send(task, :done)
    monitor = Process.monitor(task)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}

    data =
      request(deps, body()) |> Map.fetch!(:resp_body) |> JSON.decode!() |> Map.fetch!("result")

    assert data["lane"]["recorded"]["taskAlive"] == false
    assert data["lane"]["recorded"]["taskPresent"] == true
    assert :sys.get_state(pid) == state
  end

  test "busy actual DB and busy lane cannot block diagnostic response or receive DB calls", %{
    deps: deps
  } do
    db = start_supervised!({Tightbeam.DB, path: ":memory:", name: SessionDiagnoseTest.DB})
    :ok = Tightbeam.DB.execute(db, "CREATE TABLE diagnostic_fixture (value INTEGER)")
    assert {:ok, []} = Tightbeam.DB.query(db, "INSERT INTO diagnostic_fixture VALUES (7)")
    parent = self()

    worker =
      Task.async(fn ->
        Tightbeam.DB.transaction(db, fn _ ->
          send(parent, :db_blocked)

          receive do
            :release_fixture_db -> :ok
          end
        end)
      end)

    assert_receive :db_blocked
    state = %SessionLane{session_key: @key, db: db, runner: fn _ -> flunk("runner called") end}
    pid = lane(state)
    :sys.suspend(pid)
    send(db, {:DOWN, make_ref(), :process, self(), {:synthetic_secret_canary, @secret}})
    before_queue = Process.info(db, :message_queue_len)
    started = System.monotonic_time(:millisecond)
    response = request(%{deps | db: db}, body())
    elapsed = System.monotonic_time(:millisecond) - started
    assert response.status == 200
    assert elapsed < 1000
    data = JSON.decode!(response.resp_body)["result"]
    assert data["db"]["exists"]
    assert data["db"]["queueLength"] == elem(before_queue, 1)
    assert data["lane"]["recorded"]["status"] == "unavailable_busy_or_exited"
    refute response.resp_body =~ @secret
    assert Process.info(db, :message_queue_len) == before_queue
    :sys.resume(pid)
    assert :sys.get_state(pid) == state
    # The fixture owner is blocked on its explicit release; no production process is touched.
    send(db, :release_fixture_db)
    assert Task.await(worker) == {:ok, :ok}
    assert Tightbeam.DB.query(db, "SELECT value FROM diagnostic_fixture") == {:ok, [[7]]}
  end

  test "drain is observable and diagnostics do not claim work", %{deps: deps} do
    old = :persistent_term.get({Tightbeam.Application, :draining}, false)
    on_exit(fn -> :persistent_term.put({Tightbeam.Application, :draining}, old) end)
    :persistent_term.put({Tightbeam.Application, :draining}, true)

    state = %SessionLane{
      session_key: @key,
      db: :must_not_query,
      runner: fn _ -> flunk("runner called") end
    }

    pid = lane(state)

    data =
      request(deps, body()) |> Map.fetch!(:resp_body) |> JSON.decode!() |> Map.fetch!("result")

    assert data["applicationDraining"]
    assert data["reservationGate"] == false
    assert data["parkGate"] == "unavailable_without_db_query"
    assert :sys.get_state(pid) == state
  end

  test "reservation and settlement gates are recorded without releasing or claiming", %{
    deps: deps
  } do
    state = %SessionLane{
      session_key: @key,
      db: :must_not_query,
      runner: fn _ -> flunk("runner called") end,
      reservation_token: make_ref(),
      reservation_owner_ref: make_ref(),
      settlement_rechecking: true,
      deferred_drain: true
    }

    pid = lane(state)
    data = request(deps, body()).resp_body |> JSON.decode!() |> Map.fetch!("result")
    assert data["reservationGate"] == true
    assert data["lane"]["recorded"]["settlementRechecking"] == true
    assert data["lane"]["recorded"]["deferredDrain"] == true
    assert data["parkGate"] == "unavailable_without_db_query"
    assert :sys.get_state(pid) == state
  end

  test "request and scope bounds refuse safely", %{deps: deps} do
    assert request(deps, Map.put(body(), "unexpected", @secret)).status == 403
    response = request(deps, %{body() | "sessionKey" => String.duplicate("x", 2048)})
    assert response.status == 400
    refute response.resp_body =~ @secret

    assert_raise ArgumentError, "invalid diagnostic scope", fn ->
      SessionDiagnose.scope(@secret)
    end

    assert_raise ArgumentError, "invalid diagnostic scope", fn ->
      SessionDiagnose.scope(JSON.encode!(Map.new(1..9, &{Integer.to_string(&1), "mike"})))
    end

    assert SessionDiagnose.scope(JSON.encode!(%{@key => "mike"})) == %{@key => "mike"}
  end

  test "compatibility and internal-error outputs omit secret-bearing values", %{deps: deps} do
    response =
      conn(:post, "/agent/session-diagnose", JSON.encode!(body()))
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> @secret)
      |> Router.call(Map.to_list(deps))

    assert response.status == 426
    refute response.resp_body =~ @secret
    response = request(Map.put(deps, :lane_registry, {:invalid_registry, @secret}), body())
    assert response.status == 503
    assert JSON.decode!(response.resp_body) == %{"error" => %{"code" => "diagnostic_unavailable"}}
    refute response.resp_body =~ @secret
    assert request(deps, body(), String.duplicate("x", byte_size(@secret))).status == 401
  end

  test "many unrelated registry entries do not broaden exact-target output", %{deps: deps} do
    for i <- 1..1000,
        do: Registry.register(SessionDiagnoseTest.Registry, "unrelated-#{i}", @secret)

    response = request(deps, body())
    assert response.status == 200
    assert byte_size(response.resp_body) <= 4096
    refute response.resp_body =~ "unrelated-"
    refute response.resp_body =~ @secret
    assert JSON.decode!(response.resp_body)["result"]["lane"]["recorded"]["status"] == "absent"
  end

  test "overall snapshot deadline bounds a held metadata read and cleans up only its helper" do
    parent = self()
    started = System.monotonic_time(:millisecond)

    assert SessionDiagnose.bounded_snapshot(fn ->
             send(parent, {:diagnostic_helper, self()})

             receive do
               :release_fixture -> :ok
             end
           end) == :timeout

    assert System.monotonic_time(:millisecond) - started < 1500
    assert_receive {:diagnostic_helper, helper}
    monitor = Process.monitor(helper)
    assert_receive {:DOWN, ^monitor, :process, ^helper, _}
    assert SessionDiagnose.bounded_snapshot(fn -> raise @secret end) == :unavailable
    assert Process.alive?(self())
  end

  test "caller termination still stops its held metadata helper" do
    parent = self()

    caller =
      spawn(fn ->
        SessionDiagnose.bounded_snapshot(fn ->
          send(parent, {:held_helper, self()})

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive {:held_helper, helper}
    monitor = Process.monitor(helper)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^helper, _}, 1000
    assert Process.alive?(self())
  end

  test "a result deliberately delayed past timeout cannot enter the caller mailbox" do
    parent = self()

    controller =
      spawn(fn ->
        receive do
          {:hold_guardian, helper} ->
            {:monitored_by, [guardian]} = Process.info(helper, :monitored_by)
            :erlang.suspend_process(guardian)
            monitor = Process.monitor(helper)
            send(helper, :finish)

            receive do
              {:DOWN, ^monitor, :process, ^helper, _} ->
                send(parent, {:late_guardian, guardian})

                receive do
                  :resume_guardian -> :erlang.resume_process(guardian)
                end
            end
        end
      end)

    assert SessionDiagnose.bounded_snapshot(fn ->
             send(controller, {:hold_guardian, self()})

             receive do
               :finish -> :late_result
             end
           end) == :timeout

    assert_receive {:late_guardian, guardian}
    monitor = Process.monitor(guardian)
    send(controller, :resume_guardian)
    assert_receive {:DOWN, ^monitor, :process, ^guardian, _}, 1000
    refute_receive {_tag, {:ok, :late_result}}, 50
    assert Process.alive?(self())
  end
end
