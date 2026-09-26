defmodule Tightbeam.ResponseObservationAdapterTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Diagnostics, ListenerLifecycle, RequestContext}

  defmodule ClosingAdapter do
    # A test-only gate at the real adapter call. It closes the actual bound TCP
    # socket, then lets Bandit's real send observe the error; no idealized reply
    # or transport exception is manufactured by this fixture.
    def send_resp({adapter, payload, parent}, status, headers, body) do
      send(parent, {:before_send, self()})

      receive do
        :close_socket -> ThousandIsland.Socket.close(payload.transport.socket)
      end

      adapter.send_resp(payload, status, headers, body)
    end
  end

  defmodule FixturePlug do
    import Plug.Conn
    alias Tightbeam.Wire.RequestObservation
    def init(opts), do: opts

    def call(conn, opts) do
      conn =
        if conn.request_path == "/close" do
          {adapter, payload} = conn.adapter
          %{conn | adapter: {ClosingAdapter, {adapter, payload, opts[:parent]}}}
        else
          conn
        end

      conn = put_private(conn, :plug_route, {"/api/work-items", nil})

      RequestObservation.call(conn, fn conn ->
        sent = send_resp(conn, 200, "ok")

        if conn.request_path == "/late" do
          DB.transaction(opts[:db], fn txn ->
            DB.Txn.exec(txn, "INSERT INTO effects(value) VALUES (1)")
          end)
        end

        sent
      end)
    end
  end

  setup do
    start_supervised!({Diagnostics, notify: self()})
    owner = start_supervised!({ListenerLifecycle, name: nil})
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = DB.execute(db, "CREATE TABLE effects(value INTEGER)")

    bandit =
      start_supervised!(
        ListenerLifecycle.listener_spec(
          [
            plug: {FixturePlug, [parent: self(), db: db]},
            port: 0,
            ip: {127, 0, 0, 1},
            startup_log: false
          ],
          owner
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(bandit)
    %{db: db, port: port}
  end

  test "real send failure records started with no HTTP status exactly once", %{port: port} do
    id = RequestContext.id("req_")
    task = Task.async(fn -> request(port, "/close", id) end)
    assert_receive {:before_send, sender}, 2_000
    send(sender, :close_socket)

    assert_receive {:diagnostic,
                    %{
                      event: "http_response_terminal",
                      request_id: ^id,
                      response_state: "started",
                      http_status: nil,
                      cause: "connection_reset",
                      listener_generation: generation
                    }},
                   2_000

    assert generation =~ ~r/\Algen_[A-Za-z0-9_-]{22}\z/
    assert {:error, _} = Task.await(task, 5_000)

    assert length(
             Enum.filter(
               Diagnostics.records(),
               &(&1.event == "http_response_terminal" and &1.request_id == id)
             )
           ) == 1
  end

  test "a real DB timeout after successful send preserves complete and one late effect", %{
    port: port,
    db: db
  } do
    previous = Application.fetch_env(:tightbeam, :db_call_timeout_ms)
    Application.put_env(:tightbeam, :db_call_timeout_ms, 50)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tightbeam, :db_call_timeout_ms, value)
        :error -> Application.delete_env(:tightbeam, :db_call_timeout_ms)
      end
    end)

    :sys.suspend(db)
    id = RequestContext.id("req_")

    try do
      assert {:ok, {{_, 200, _}, _, "ok"}} = request(port, "/late", id)

      assert_receive {:diagnostic,
                      %{event: "db_call_abandoned", request_id: ^id, db_call_id: call_id}},
                     2_000

      assert_receive {:diagnostic,
                      %{
                        event: "http_response_terminal",
                        request_id: ^id,
                        db_call_id: ^call_id,
                        response_state: "complete",
                        http_status: 200,
                        cause: "db_caller_timeout"
                      }},
                     2_000

      :sys.resume(db)
      assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM effects")

      assert_receive {:diagnostic,
                      %{
                        event: "db_server_completed",
                        request_id: ^id,
                        db_call_id: ^call_id,
                        result_class: "ok"
                      }},
                     2_000

      assert length(
               Enum.filter(
                 Diagnostics.records(),
                 &(&1.event == "http_response_terminal" and &1.request_id == id)
               )
             ) == 1
    after
      :sys.resume(db)
    end
  end

  defp request(port, path, id) do
    :httpc.request(
      :get,
      {String.to_charlist("http://127.0.0.1:#{port}#{path}"),
       [{~c"x-tightbeam-request-id", String.to_charlist(id)}]},
      [timeout: 2_000], body_format: :binary)
  end
end
