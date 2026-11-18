defmodule Tightbeam.DBOverloadRefusalTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.{DB, Diagnostics, Dispatch, RequestContext, Rules}
  alias Tightbeam.Wire.Router

  setup do
    :persistent_term.erase(Rules)
    db = :"refusal_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)

    # A regression here must fail the test, not wait out the default 30s call.
    previous = Application.fetch_env(:tightbeam, :db_call_timeout_ms)
    Application.put_env(:tightbeam, :db_call_timeout_ms, 500)

    on_exit(fn ->
      :persistent_term.erase(Rules)

      case previous do
        {:ok, value} -> Application.put_env(:tightbeam, :db_call_timeout_ms, value)
        :error -> Application.delete_env(:tightbeam, :db_call_timeout_ms)
      end

      case Process.whereis(db) do
        pid when is_pid(pid) -> :sys.resume(pid)
        _ -> :ok
      end
    end)

    %{db: db}
  end

  # Hold the owner still with its queue at the fixed limit: every new call is
  # refused exactly as it is when the owner is busy behind a slow transaction.
  defp overload!(db) do
    owner = Process.whereis(db)
    :sys.suspend(owner)

    for _ <- 1..128,
        do: send(owner, {:"$gen_call", {self(), make_ref()}, {:query, "SELECT 1", []}})

    assert DB.overloaded?(db)
    :ok
  end

  defp queued(db) do
    {:message_queue_len, length} = Process.info(Process.whereis(db), :message_queue_len)
    length
  end

  test "an unsent refusal carries its class and caller into diagnostics", %{db: db} do
    start_supervised!({Diagnostics, notify: self()})
    overload!(db)

    RequestContext.bind(
      %{
        request_id: "req_retained",
        principal_kind: "internal",
        principal_ref: "internal:test",
        caller: "POST /agent/dispatch"
      },
      fn ->
        assert {:error, %DB.Overloaded{}} = DB.transaction(db, fn _ -> flunk("not sent") end)
      end
    )

    assert_receive {:diagnostic,
                    %{
                      event: "db_caller_completed",
                      result_class: "db_overloaded",
                      caller: "POST /agent/dispatch",
                      request_id: "req_retained"
                    }}

    assert queued(db) == 128
  end

  describe "a dispatched verb" do
    for {shape, label} <- [
          {:match, "a strict match on the refused call"},
          {:raise, "the refusal raised"},
          {:case, "a case with no clause for the refusal"}
        ] do
      test "is refused retryably when its handler meets the overload as #{label}", %{db: db} do
        shape = unquote(shape)
        call = %{verb: "wake", origin: "user:flynn", session_key: "s1", params: %{}}

        handler = fn _call ->
          overload!(db)
          refused = DB.transaction(db, fn _txn -> flunk("the owner must not run this") end)

          case shape do
            :match ->
              {:ok, _} = refused
              %{ok: true}

            :raise ->
              {:error, error} = refused
              raise error

            :case ->
              case refused do
                {:ok, _} -> %{ok: true}
              end
          end
        end

        log =
          capture_log(fn ->
            assert {:error, %{code: "db_overloaded", message: "database overloaded; retry later"}} =
                     Dispatch.dispatch(db, %{"wake" => handler}, call)
          end)

        assert log =~ ~s("wake" refused: database overloaded)
        # Told at once, and nothing was left behind on the owner that is refusing work.
        assert queued(db) == 128

        :sys.resume(Process.whereis(db))
        assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM events WHERE verb = 'wake'")
      end
    end

    test "still reports an unrelated handler crash as a server error", %{db: db} do
      call = %{verb: "wake", origin: "user:flynn", session_key: "s1", params: %{}}

      capture_log(fn ->
        assert {:error, %{code: "server_error"}} =
                 Dispatch.dispatch(db, %{"wake" => fn _ -> {:ok, _} = {:error, :other} end}, call)
      end)
    end
  end

  test "a reader deadline retains its distinct retryable timeout response", %{db: db} do
    start_supervised!({Diagnostics, notify: self()})

    response =
      Tightbeam.Wire.RequestObservation.call(Plug.Test.conn(:get, "/reader-deadline"), fn _ ->
        DB.read_transaction!(db, fn _ -> raise DB.DeadlineExceeded end)
      end)

    assert response.status == 503
    assert %{"error" => error} = JSON.decode!(response.resp_body)
    assert error["code"] == "db_timeout"
    assert error["timeoutSource"] == "reader_deadline"
    assert error["operation"] == "db.read_transaction"
    assert error["effectState"] == "none"
    assert error["action"] == "retry_safe"
  end

  describe "an HTTP request" do
    test "that meets the overload gets a 503 it can retry, not a bare 500", %{db: db} do
      start_supervised!({Diagnostics, notify: self()})
      opts = Router.init(db: db, cli_token: "private_org_token", handlers: %{})

      bandit =
        start_supervised!(
          {Bandit, plug: {Router, opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(bandit)
      id = RequestContext.id("req_")
      overload!(db)

      capture_log(fn ->
        {:ok, {{_, status, _}, headers, body}} =
          :httpc.request(
            :get,
            {String.to_charlist("http://127.0.0.1:#{port}/api/work-items"),
             [
               {~c"authorization", ~c"Bearer private_http_token"},
               {~c"x-tightbeam-request-id", String.to_charlist(id)}
             ]},
            [timeout: 5_000],
            body_format: :binary
          )

        assert status == 503
        assert {~c"retry-after", ~c"1"} in headers
        assert {~c"x-tightbeam-request-id", String.to_charlist(id)} in headers

        assert %{
                 "error" => %{
                   "code" => "db_overloaded",
                   "message" => "database overloaded; retry later",
                   "requestId" => ^id
                 }
               } = JSON.decode!(body)

        refute body =~ "private_http_token"
      end)

      assert queued(db) == 128
    end
  end
end
