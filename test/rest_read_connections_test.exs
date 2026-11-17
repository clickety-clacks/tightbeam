defmodule Tightbeam.RestReadConnectionsTest do
  # wi_0b608f33: REST reads of a session (its history, its detail, its tool
  # calls) only read. They must run on the database's read connections, so a
  # slow history load cannot hold the single writer, and a busy writer cannot
  # hold the reads. These run on a file-backed database, the only kind with
  # read connections.
  use Tightbeam.TestCase, async: false
  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{DB, Devices, Model, Org, Projection}
  alias Tightbeam.Wire.Router

  setup do
    base_dir =
      System.tmp_dir!()
      |> Path.join("tightbeam-rest-read-connections-#{System.unique_integer([:positive])}")
      |> Tightbeam.LiveBaseAdmission.canonical!()

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    payload_root = Path.join(base_dir, "payload")
    File.mkdir_p!(Path.join(payload_root, "ebin"))
    File.mkdir_p!(Path.join(payload_root, "priv"))
    File.write!(Path.join(payload_root, "priv/rest-read-connections"), "test payload")

    {:ok, manifest} =
      Tightbeam.LiveBaseGuard.generate_manifest(Tightbeam.LiveBasePayload.files!(payload_root))

    File.write!(Path.join(payload_root, "build-manifest.json"), JSON.encode!(manifest))

    db =
      start_supervised!(
        Supervisor.child_spec(
          {DB,
           path: Path.join(base_dir, "state.db"),
           name: nil,
           guard_inputs: [],
           payload_root: payload_root},
          id: {:rest_read_connections, System.unique_integer([:positive])}
        )
      )

    :ok = ensure_all_schemas(db)

    {:paired, device} =
      Devices.pair(db, %{device_id: "d1", claimed_name: "Flynn", platform: nil, model: nil})

    session =
      Org.create(db, %{
        session_key: "history-reader",
        display_name: "history-reader",
        owner_user_id: device.user_id,
        origin: "user:#{device.user_id}",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    for n <- 1..3 do
      {:appended, _} =
        Projection.append(db, %{
          session_key: session.session_key,
          role: "user",
          content: "message #{n}"
        })
    end

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tbc_test",
      session_status: fn _ -> nil end
    ]

    %{db: db, device: device, session: session, opts: opts}
  end

  test "session history, detail and tool calls answer while the database writer is busy",
       ctx do
    parent = self()

    writer =
      Task.async(fn ->
        DB.transaction(ctx.db, fn _txn ->
          send(parent, {:writer_held, self()})

          receive do
            :release -> :released
          after
            15_000 -> raise "writer was not released"
          end
        end)
      end)

    assert_receive {:writer_held, owner}, 5_000
    key = ctx.session.session_key

    reads =
      Task.async(fn ->
        %{
          observer_history: get(ctx, "/api/sessions/#{key}/messages", "tbc_test"),
          user_history: get(ctx, "/api/sessions/#{key}/messages", ctx.device.token),
          detail: get(ctx, "/api/sessions/#{key}", ctx.device.token),
          tool_calls: get(ctx, "/api/sessions/#{key}/tool-calls", ctx.device.token)
        }
      end)

    answered = Task.yield(reads, 5_000)
    send(owner, :release)
    assert {:ok, :released} = Task.await(writer, 5_000)
    assert {:ok, responses} = answered || {:after_writer, Task.await(reads, 30_000)}

    for name <- [:observer_history, :user_history] do
      response = responses[name]
      assert response.status == 200, "#{name}: #{response.resp_body}"

      assert Enum.map(JSON.decode!(response.resp_body)["items"], & &1["content"]) ==
               ["message 1", "message 2", "message 3"]
    end

    assert responses.detail.status == 200, responses.detail.resp_body
    assert JSON.decode!(responses.detail.resp_body)["item"]["sessionKey"] == key
    assert responses.tool_calls.status == 200, responses.tool_calls.resp_body
    assert JSON.decode!(responses.tool_calls.resp_body)["items"] == []
  end

  test "the other REST read resources answer while the database writer is busy", ctx do
    key = ctx.session.session_key

    {:ok, [[message_id]]} =
      DB.query(ctx.db, "SELECT id FROM messages WHERE sessionKey=?1 ORDER BY seq LIMIT 1", [key])

    paths = [
      "/api/sessions",
      "/api/sessions/#{key}/messages/#{message_id}",
      "/api/sessions/#{key}/tool-calls/tc_missing",
      "/api/wakes/w_missing",
      "/api/turns/1",
      "/api/artifacts",
      "/api/artifacts/art_missing",
      "/api/attests",
      "/api/attests/att_missing",
      "/api/assignments/asg_missing/attests",
      "/api/read-markers",
      "/api/read-markers/scope_missing",
      "/api/roles/role-missing",
      "/api/facts/1",
      "/api/critical-state/#{key}",
      "/api/devices/d1",
      "/api/decision-requests/dr_missing"
    ]

    parent = self()

    writer =
      Task.async(fn ->
        DB.transaction(ctx.db, fn _txn ->
          send(parent, {:writer_held, self()})

          receive do
            :release -> :released
          after
            30_000 -> raise "writer was not released"
          end
        end)
      end)

    assert_receive {:writer_held, owner}, 5_000

    reads =
      Task.async(fn ->
        Map.new(paths, fn path -> {path, get(ctx, path, ctx.device.token)} end)
      end)

    answered = Task.yield(reads, 10_000)
    send(owner, :release)
    assert {:ok, :released} = Task.await(writer, 5_000)
    assert {:ok, responses} = answered || {:after_writer, Task.await(reads, 60_000)}

    for path <- paths do
      response = responses[path]
      assert response.status in [200, 404], "#{path}: #{response.status} #{response.resp_body}"
    end

    assert responses["/api/sessions/#{key}/messages/#{message_id}"].status == 200
    assert responses["/api/sessions"].status == 200
  end

  test "a read right after a committed write sees the write", ctx do
    key = ctx.session.session_key

    for n <- 4..8 do
      {:appended, _} =
        Projection.append(ctx.db, %{session_key: key, role: "user", content: "message #{n}"})

      response = get(ctx, "/api/sessions/#{key}/messages?limit=1", ctx.device.token)
      assert response.status == 200, response.resp_body
      assert [%{"content" => content}] = JSON.decode!(response.resp_body)["items"]
      assert content == "message #{n}"
    end
  end

  defp get(ctx, path, bearer) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> Router.call(Router.init(ctx.opts))
  end
end
