defmodule Tightbeam.RestHarnessProcessRoutesTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{Archetypes, DB, Devices, Identity}
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  setup do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-rest-harness-processes-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = :"rest_harness_process_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Hub, name: Hub})
    :ok = ensure_all_schemas(db)

    {:paired, admin_device} =
      claim_org(db, %{
        device_id: "harness-process-admin-device",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    Devices.add_user(db, "reader", false)

    {:pending, _pending} =
      Devices.pair(db, %{
        device_id: "harness-process-reader-device",
        claimed_name: "Reader",
        platform: nil,
        model: nil
      })

    reader_device = Devices.approve(db, "harness-process-reader-device", "reader")

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tbc_harness_process_routes",
      firehose_hub: Hub,
      model_catalog: %{},
      session_status: fn _ -> nil end
    ]

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{db: db, opts: opts, admin_device: admin_device, reader_device: reader_device}
  end

  test "admin collection emits the closed item in tuple order and pages by createdAt and id",
       ctx do
    insert_launch(ctx.db, %{
      id: "launch-a",
      host: "alpha",
      harness: "codex",
      state: "launching",
      created_at: 10,
      pid: nil,
      resolved_at: nil
    })

    insert_launch(ctx.db, %{
      id: "launch-b",
      host: "alpha",
      harness: "codex",
      state: "running",
      created_at: 20,
      pid: 101,
      resolved_at: nil
    })

    insert_launch(ctx.db, %{
      id: "launch-c",
      host: "beta",
      harness: "claude",
      state: "kill_failed",
      created_at: 20,
      pid: 202,
      resolved_at: 30
    })

    first = get(ctx, "/api/harness-processes?limit=2")
    assert first.status == 200, first.resp_body

    body = JSON.decode!(first.resp_body)
    assert body["resource"] == "harness processes"
    assert Enum.map(body["items"], & &1["id"]) == ["launch-b", "launch-c"]
    assert body["page"]["hasMoreBefore"]

    assert first.resp_body =~
             ~s({"id":"launch-b","host":"alpha","harness":"codex","pid":101,"state":"running","createdAt":20,"resolvedAt":null})

    refute Enum.any?(
             ["sessionKey", "provider", "model", "rowVersion"],
             &Map.has_key?(hd(body["items"]), &1)
           )

    for marker <- [
          "private-ssh",
          "private-helper-path",
          "private-identity-path",
          "private-boot-id",
          "private-token",
          "private-error"
        ] do
      refute first.resp_body =~ marker
    end

    earlier =
      get(
        ctx,
        "/api/harness-processes?limit=2&before=#{body["page"]["oldestCursor"]}"
      )

    assert earlier.status == 200, earlier.resp_body
    earlier_body = JSON.decode!(earlier.resp_body)
    assert Enum.map(earlier_body["items"], & &1["id"]) == ["launch-a"]
    assert earlier.resp_body =~
             ~s({"id":"launch-a","host":"alpha","harness":"codex","pid":null,"state":"launching","createdAt":10,"resolvedAt":null})

    assert earlier_body["page"]["hasMoreAfter"]

    later =
      get(
        ctx,
        "/api/harness-processes?limit=2&after=#{earlier_body["page"]["newestCursor"]}"
      )

    assert later.status == 200, later.resp_body

    assert Enum.map(JSON.decode!(later.resp_body)["items"], & &1["id"]) == [
             "launch-b",
             "launch-c"
           ]
  end

  test "filters are exact and conjunctive, and non-admins see no launch rows", ctx do
    insert_launch(ctx.db, %{
      id: "matching-launch",
      host: "alpha",
      harness: "codex",
      state: "running",
      created_at: 10,
      pid: 123,
      resolved_at: nil
    })

    insert_launch(ctx.db, %{
      id: "other-harness",
      host: "alpha",
      harness: "claude",
      state: "running",
      created_at: 20,
      pid: 124,
      resolved_at: nil
    })

    insert_launch(ctx.db, %{
      id: "other-state",
      host: "alpha",
      harness: "codex",
      state: "killed",
      created_at: 30,
      pid: 125,
      resolved_at: 40
    })

    insert_launch(ctx.db, %{
      id: "other-host",
      host: "beta",
      harness: "codex",
      state: "running",
      created_at: 40,
      pid: 126,
      resolved_at: nil
    })

    filtered =
      get(ctx, "/api/harness-processes?host=alpha&harness=codex&state=running")

    assert filtered.status == 200, filtered.resp_body
    assert Enum.map(JSON.decode!(filtered.resp_body)["items"], & &1["id"]) == ["matching-launch"]

    non_admin = get(ctx, "/api/harness-processes", ctx.reader_device.token)
    assert non_admin.status == 200, non_admin.resp_body
    assert JSON.decode!(non_admin.resp_body)["items"] == []
  end

  test "unsupported and unknown state filters are rejected without echoing values", ctx do
    for path <- [
          "/api/harness-processes?sessionKey=private-session",
          "/api/harness-processes?provider=private-provider",
          "/api/harness-processes?model=private-model",
          "/api/harness-processes?state=unknown-state"
        ] do
      response = get(ctx, path)
      assert response.status == 400, response.resp_body
      assert JSON.decode!(response.resp_body)["error"]["code"] == "invalid_filter"

      refute response.resp_body =~ "private-session"
      refute response.resp_body =~ "private-provider"
      refute response.resp_body =~ "private-model"
      refute response.resp_body =~ "unknown-state"
    end
  end

  defp insert_launch(db, row) do
    {:ok, _rows} =
      DB.query(
        db,
        """
        INSERT INTO harness_processes
          (launchId, adapterKey, harness, preset, host, ssh, helperPath, identityPath,
           launchSequence, osPid, processGroupId, bootIdentity, identityToken,
           state, createdAt, resolvedAt, lastError)
        VALUES (?1, 'fixture-adapter', ?2, 'shared', ?3, 'private-ssh',
                'private-helper-path', 'private-identity-path', ?4, ?5, 606,
                'private-boot-id', 'private-token', ?6, ?7, ?8, 'private-error')
        """,
        [
          row.id,
          row.harness,
          row.host,
          row.created_at,
          row.pid,
          row.state,
          row.created_at,
          row.resolved_at
        ]
      )
  end

  defp get(ctx, path, bearer \\ nil) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{bearer || ctx.admin_device.token}")
    |> Router.call(Router.init(ctx.opts))
  end
end
