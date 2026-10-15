defmodule Tightbeam.ResponseObservationAdapterTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Diagnostics, ListenerLifecycle, RequestContext}

  @max_diagnostic_elapsed_us 60_000_000
  @max_diagnostic_queue 1_000_000
  @max_diagnostic_schedulers 4_096

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
        if conn.request_path in ["/close", "/timeout-close"] do
          {adapter, payload} = conn.adapter
          %{conn | adapter: {ClosingAdapter, {adapter, payload, opts[:parent]}}}
        else
          conn
        end

      conn = put_private(conn, :plug_route, {"/api/work-items", nil})

      RequestObservation.call(conn, fn conn ->
        if conn.request_path in ["/timeout", "/timeout-close"] do
          DB.transaction(opts[:db], fn txn ->
            DB.Txn.exec(txn, "INSERT INTO effects(value) VALUES (1)")
          end)
        end

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

  defmodule SegmentedPostPlug do
    import Plug.Conn
    alias Tightbeam.{DB, Wire.RequestObservation}

    def init(opts), do: opts

    def call(conn, opts) do
      route = if conn.method == "POST", do: "/agent/dispatch", else: "/api/work-items"
      conn = put_private(conn, :plug_route, {route, nil})

      RequestObservation.call(conn, fn conn ->
        case conn.request_path do
          "/segmented-timeout" ->
            send(opts[:parent], {:post_headers_received, self()})

            {:more, first, conn} = read_body(conn, length: 8, read_length: 8)
            send(opts[:parent], {:post_first_segment_read, self(), first})

            receive do
              :release_final_segment -> :ok
            after
              2_000 -> raise "timed out waiting for the final POST segment"
            end

            {:ok, final, conn} = read_body(conn, length: 1_024, read_length: 1_024)
            send(opts[:parent], {:post_body_consumed, byte_size(first) + byte_size(final)})

            DB.query(opts[:db], "SELECT 1")
            send_resp(conn, 200, "unexpected")

          "/api/work-items" ->
            send_resp(conn, 200, "next-ok")
        end
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

  test "a timeout response completes once before the queued mutation finishes", %{
    port: port,
    db: db
  } do
    with_suspended_db(db, fn ->
      id = RequestContext.id("req_")
      assert {:ok, {{_, 503, _}, headers, body}} = request(port, "/timeout", id)
      assert {~c"x-tightbeam-request-id", String.to_charlist(id)} in headers
      assert %{"error" => %{"code" => "db_timeout", "requestId" => ^id}} = JSON.decode!(body)

      assert_receive {:diagnostic,
                      %{event: "db_call_abandoned", request_id: ^id, db_call_id: call_id}},
                     2_000

      assert_receive {:diagnostic,
                      %{
                        event: "http_response_terminal",
                        request_id: ^id,
                        db_call_id: ^call_id,
                        response_state: "complete",
                        http_status: 503,
                        cause: "db_caller_timeout"
                      }},
                     2_000

      :sys.resume(db)
      assert_late_effect(db, id, call_id)
      assert_one_terminal(id)
    end)
  end

  test "response reader retains headers across gated body fragments" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    parent = self()

    header =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Length: 10\r\n" <>
        "X-Test: fragment\r\n\r\n"

    server =
      Task.async(fn ->
        {:ok, server_socket} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.send(server_socket, header)
        send(parent, {:response_headers_sent, self()})

        receive do
          :send_first_body_fragment -> :ok
          :stop -> :ok
        after
          2_000 -> raise "timed out waiting to send first response body fragment"
        end

        :ok = :gen_tcp.send(server_socket, "hello")
        send(parent, {:response_first_fragment_sent, self()})

        receive do
          :send_final_body_fragment -> :ok
          :stop -> :ok
        after
          2_000 -> raise "timed out waiting to send final response body fragment"
        end

        :ok = :gen_tcp.send(server_socket, "world")
        :gen_tcp.close(server_socket)
      end)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    on_exit(fn ->
      send(server.pid, :stop)
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    reader =
      Task.async(fn ->
        recv_http_response(socket, <<>>, fn buffer ->
          send(parent, {:response_buffered, buffer})
        end)
      end)

    assert_receive {:response_headers_sent, server_pid}, 2_000
    assert_receive {:response_buffered, ^header}, 2_000

    send(server_pid, :send_first_body_fragment)
    assert_receive {:response_first_fragment_sent, ^server_pid}, 2_000
    first_fragment = header <> "hello"
    assert_receive {:response_buffered, ^first_fragment}, 2_000

    send(server_pid, :send_final_body_fragment)
    complete_response = header <> "helloworld"
    assert_receive {:response_buffered, ^complete_response}, 2_000

    assert Task.await(reader, 2_000) ==
             {200, [{"content-length", "10"}, {"x-test", "fragment"}], "helloworld"}

    assert Task.await(server, 2_000) == :ok
  end

  test "segmented POST timeout leaves the same keep-alive socket ready for its next request", %{
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

    bandit =
      start_supervised!(
        {Bandit,
         plug: {SegmentedPostPlug, [parent: self(), db: db]},
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(bandit)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    on_exit(fn -> :gen_tcp.close(socket) end)

    body = "0123456789abcdefghijklmnopqrstuv"
    first = binary_part(body, 0, 8)
    final = binary_part(body, 8, byte_size(body) - 8)
    post_id = RequestContext.id("req_")
    next_id = RequestContext.id("req_")

    :sys.suspend(db)

    try do
      :ok =
        :gen_tcp.send(
          socket,
          "POST /segmented-timeout HTTP/1.1\r\n" <>
            "Host: localhost\r\n" <>
            "Connection: keep-alive\r\n" <>
            "Content-Type: application/octet-stream\r\n" <>
            "Content-Length: #{byte_size(body)}\r\n" <>
            "X-Tightbeam-Request-ID: #{post_id}\r\n\r\n"
        )

      assert_receive {:post_headers_received, _server}, 2_000
      :ok = :gen_tcp.send(socket, first)
      assert_receive {:post_first_segment_read, server, ^first}, 2_000
      send(server, :release_final_segment)
      :ok = :gen_tcp.send(socket, final)
      assert_receive {:post_body_consumed, body_size}, 2_000
      assert body_size == byte_size(body)

      {post_status, post_headers, post_body} = recv_http_response(socket)
      assert post_status == 503
      assert {"x-tightbeam-request-id", post_id} in post_headers

      assert %{"error" => %{"code" => "db_timeout", "requestId" => ^post_id}} =
               JSON.decode!(post_body)

      assert_receive {:diagnostic,
                      %{
                        event: "http_response_terminal",
                        request_id: ^post_id,
                        response_state: "complete",
                        http_status: 503
                      }},
                     2_000

      :ok =
        :gen_tcp.send(
          socket,
          "GET /api/work-items HTTP/1.1\r\n" <>
            "Host: localhost\r\n" <>
            "Connection: keep-alive\r\n" <>
            "X-Tightbeam-Request-ID: #{next_id}\r\n\r\n"
        )

      {next_status, next_headers, next_body} = recv_http_response(socket)
      assert next_status == 200
      assert {"x-tightbeam-request-id", next_id} in next_headers
      assert next_body == "next-ok"

      assert_receive {:diagnostic,
                      %{
                        event: "http_response_terminal",
                        request_id: ^next_id,
                        response_state: "complete",
                        http_status: 200
                      }},
                     2_000

      assert_one_terminal(post_id)
      assert_one_terminal(next_id)
    after
      :sys.resume(db)
    end
  end

  for order <- [:send_failure_first, :late_completion_first] do
    @order order
    test "timeout response failure and late completion retain independent facts: #{@order}", %{
      port: port,
      db: db
    } do
      with_suspended_db(db, fn ->
        id = RequestContext.id("req_")
        task = Task.async(fn -> request(port, "/timeout-close", id) end)

        assert_receive {:diagnostic,
                        %{event: "db_call_abandoned", request_id: ^id, db_call_id: call_id}},
                       2_000

        assert_receive {:before_send, sender}, 2_000

        if @order == :late_completion_first do
          :sys.resume(db)
          assert_late_effect(db, id, call_id)
        end

        send(sender, :close_socket)

        assert_receive {:diagnostic,
                        %{
                          event: "http_response_terminal",
                          request_id: ^id,
                          db_call_id: ^call_id,
                          response_state: "started",
                          http_status: nil,
                          cause: "connection_reset",
                          timeout_source: "otp_db_call"
                        }},
                       2_000

        assert {:error, _} = Task.await(task, 5_000)

        if @order == :send_failure_first do
          :sys.resume(db)
          assert_late_effect(db, id, call_id)
        end

        assert_one_terminal(id)
      end)
    end
  end

  defp with_suspended_db(db, fun) do
    previous = Application.fetch_env(:tightbeam, :db_call_timeout_ms)
    Application.put_env(:tightbeam, :db_call_timeout_ms, 50)
    :sys.suspend(db)

    try do
      fun.()
    after
      :sys.resume(db)

      case previous do
        {:ok, value} -> Application.put_env(:tightbeam, :db_call_timeout_ms, value)
        :error -> Application.delete_env(:tightbeam, :db_call_timeout_ms)
      end
    end
  end

  defp assert_late_effect(db, id, call_id) do
    assert {:ok, [[1]]} = confirmation_query(db, "SELECT count(*) FROM effects")

    assert_receive {:diagnostic,
                    %{
                      event: "db_server_completed",
                      request_id: ^id,
                      db_call_id: ^call_id,
                      result_class: "ok"
                    }},
                   2_000
  end

  test "a timed-out confirmation query emits bounded scheduler context and still fails", %{
    db: db
  } do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        with_suspended_db(db, fn ->
          assert_raise DB.Timeout, fn ->
            confirmation_query(db, "SELECT count(*) FROM effects")
          end
        end)
      end)

    assert [line] = String.split(output, "\n", trim: true)
    assert String.starts_with?(line, "response_observation_confirmation_db_timeout ")

    fields =
      line
      |> String.split()
      |> Enum.drop(1)
      |> Map.new(fn field ->
        [name, value] = String.split(field, "=", parts: 2)
        {name, value}
      end)

    assert Map.keys(fields) |> Enum.sort() ==
             [
               "db_mailbox",
               "db_mailbox_capped",
               "elapsed_capped",
               "elapsed_us",
               "run_queue",
               "run_queue_capped",
               "schedulers_capped",
               "schedulers_online"
             ]

    assert fields["elapsed_capped"] in ["true", "false"]
    assert fields["run_queue_capped"] in ["true", "false"]
    assert fields["db_mailbox_capped"] in ["true", "false"]
    assert fields["schedulers_capped"] in ["true", "false"]

    for {name, maximum} <- [
          {"elapsed_us", @max_diagnostic_elapsed_us},
          {"schedulers_online", @max_diagnostic_schedulers},
          {"run_queue", @max_diagnostic_queue},
          {"db_mailbox", @max_diagnostic_queue}
        ] do
      {value, ""} = Integer.parse(fields[name])
      assert value <= maximum
    end

    refute output =~ "SELECT"
    refute output =~ "req_"
  end

  defp confirmation_query(db, sql) do
    started_at = System.monotonic_time(:microsecond)

    try do
      DB.query(db, sql)
    rescue
      error in DB.Timeout ->
        emit_confirmation_query_timeout(db, started_at)
        reraise error, __STACKTRACE__
    end
  end

  defp emit_confirmation_query_timeout(db, started_at) do
    elapsed_us = max(System.monotonic_time(:microsecond) - started_at, 0)
    {elapsed_us, elapsed_capped} = bounded_metric(elapsed_us, @max_diagnostic_elapsed_us)

    {schedulers_online, schedulers_capped} =
      safe_bounded_metric(
        fn -> :erlang.system_info(:schedulers_online) end,
        @max_diagnostic_schedulers
      )

    {run_queue, run_queue_capped} =
      safe_bounded_metric(fn -> :erlang.statistics(:run_queue) end, @max_diagnostic_queue)

    {db_mailbox, db_mailbox_capped} =
      safe_bounded_metric(
        fn -> Process.info(db, :message_queue_len) |> elem(1) end,
        @max_diagnostic_queue
      )

    IO.puts(
      :stderr,
      "response_observation_confirmation_db_timeout elapsed_us=#{elapsed_us} elapsed_capped=#{elapsed_capped} " <>
        "schedulers_online=#{schedulers_online} schedulers_capped=#{schedulers_capped} " <>
        "run_queue=#{run_queue} run_queue_capped=#{run_queue_capped} " <>
        "db_mailbox=#{db_mailbox} db_mailbox_capped=#{db_mailbox_capped}"
    )
  end

  defp safe_bounded_metric(read, maximum) do
    read.() |> bounded_metric(maximum)
  rescue
    _error -> {0, false}
  catch
    _kind, _reason -> {0, false}
  end

  defp bounded_metric(value, maximum) when is_integer(value) and value >= 0 do
    {min(value, maximum), value > maximum}
  end

  defp bounded_metric(_value, _maximum), do: {0, false}

  defp assert_one_terminal(id) do
    assert length(
             Enum.filter(
               Diagnostics.records(),
               &(&1.event == "http_response_terminal" and &1.request_id == id)
             )
           ) == 1
  end

  defp request(port, path, id) do
    :httpc.request(
      :get,
      {String.to_charlist("http://127.0.0.1:#{port}#{path}"),
       [{~c"x-tightbeam-request-id", String.to_charlist(id)}]},
      [timeout: 2_000],
      body_format: :binary
    )
  end

  defp recv_http_response(socket, buffered \\ <<>>, observe_buffer \\ fn _buffer -> :ok end) do
    case :binary.match(buffered, "\r\n\r\n") do
      {header_end, 4} ->
        header = binary_part(buffered, 0, header_end)
        rest = binary_part(buffered, header_end + 4, byte_size(buffered) - header_end - 4)
        [status_line | header_lines] = String.split(header, "\r\n")
        [_, status] = Regex.run(~r/^HTTP\/1\.1 ([0-9]{3})\b/, status_line)

        headers =
          Enum.map(header_lines, fn line ->
            [name, value] = String.split(line, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        body_length =
          case List.keyfind(headers, "content-length", 0) do
            {"content-length", value} -> String.to_integer(value)
            nil -> 0
          end

        if byte_size(rest) >= body_length do
          body = binary_part(rest, 0, body_length)
          {String.to_integer(status), headers, body}
        else
          recv_http_response(socket, read_more(socket, buffered, observe_buffer), observe_buffer)
        end

      :nomatch ->
        recv_http_response(socket, read_more(socket, buffered, observe_buffer), observe_buffer)
    end
  end

  defp read_more(socket, buffered, observe_buffer) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, bytes} ->
        next_buffer = buffered <> bytes
        observe_buffer.(next_buffer)
        next_buffer

      other ->
        flunk("expected an HTTP response on the persistent socket, got #{inspect(other)}")
    end
  end
end
