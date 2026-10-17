defmodule Tightbeam.Wire.OperatorHistoryTest do
  use Tightbeam.TestCase, async: false
  import Plug.Conn
  import Plug.Test
  alias Tightbeam.{Archetypes, DB, Devices, Model, Org, Projection, Schema, StateResources}
  alias Tightbeam.Wire.Router

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    Archetypes.load!(System.tmp_dir!())

    {:paired, admin} =
      Devices.pair(db, %{
        device_id: "admin-device",
        claimed_name: "Admin",
        platform: nil,
        model: nil
      })

    {:pending, owner} =
      Devices.pair(db, %{
        device_id: "owner-device",
        claimed_name: "Owner",
        platform: nil,
        model: nil
      })

    owner = Devices.approve(db, owner.device_id, "owner")

    {:pending, other} =
      Devices.pair(db, %{
        device_id: "other-device",
        claimed_name: "Other",
        platform: nil,
        model: nil
      })

    other = Devices.approve(db, other.device_id, "other")

    selected = session(db, "agent:selected / exact", owner.user_id)
    sibling = session(db, "agent:sibling", owner.user_id)
    hidden = session(db, "agent:hidden", other.user_id)
    opts = Router.init(db: db, cli_token: "operator-fixture", handlers: %{})

    %{
      db: db,
      opts: opts,
      owner: owner,
      admin: admin,
      other: other,
      selected: selected,
      sibling: sibling,
      hidden: hidden
    }
  end

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:" <> owner,
      archetype: "default",
      host: "fixture-host",
      harness: "fixture",
      provider: "fixture_provider",
      model: Model.new("fixture")
    })
  end

  defp path(session),
    do:
      "/api/sessions/" <> URI.encode(session.session_key, &URI.char_unreserved?/1) <> "/messages"

  defp read(ctx, session, query, token \\ "operator-fixture") do
    conn(:get, path(session) <> "?" <> query)
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(ctx.opts)
  end

  defp body(response) do
    assert response.status == 200, response.resp_body
    JSON.decode!(response.resp_body)
  end

  defp assert_error(response, status, code) do
    assert response.status == status, response.resp_body
    assert JSON.decode!(response.resp_body)["error"]["code"] == code
  end

  defp append(ctx, session, text, extra \\ %{}) do
    {:appended, row} =
      Projection.append(
        ctx.db,
        Map.merge(
          %{
            session_key: session.session_key,
            role: "user",
            content: text,
            timestamp: System.system_time(:millisecond),
            attachments: []
          },
          extra
        )
      )

    row
  end

  test "operator history preserves canonical retained rows, markers and both paging directions",
       ctx do
    first =
      append(ctx, ctx.selected, "before reset", %{
        sender: "user:owner",
        device_id: "owner-device",
        client_message_id: "c_original"
      })

    {:appended, marker} =
      Projection.append_marker(ctx.db, ctx.selected.session_key, %{
        kind: "session-restart",
        from: "before",
        to: "after"
      })

    last = append(ctx, ctx.selected, "after reset", %{reply_to_message_id: first.id})
    append(ctx, ctx.sibling, "unselected")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET clearedThroughSeq=?2 WHERE sessionKey=?1", [
        ctx.selected.session_key,
        marker.seq
      ])

    expected =
      StateResources.query_messages_for_session_page(
        ctx.db,
        ctx.selected.session_key,
        :earliest,
        500
      )
      |> Map.fetch!(:rows)
      |> Enum.map(&StateResources.message/1)

    all = read(ctx, ctx.selected, "asUser=owner&tail=false") |> body()
    assert all["items"] == expected
    assert Enum.map(all["items"], & &1["id"]) == [first.id, marker.id, last.id]
    assert hd(all["items"])["clientMessageId"] == "c_original"
    assert hd(all["items"])["deviceId"] == "owner-device"
    assert hd(all["items"])["seq"] == first.seq
    assert hd(all["items"])["rowVersion"] == first.seq
    assert hd(all["items"])["sessionKey"] == ctx.selected.session_key

    assert Enum.at(all["items"], 1)["marker"] == %{
             "kind" => "session-restart",
             "from" => "before",
             "to" => "after"
           }

    assert List.last(all["items"])["replyToMessageId"] == first.id

    tail = read(ctx, ctx.selected, "asUser=owner&limit=1") |> body()
    assert Enum.map(tail["items"], & &1["id"]) == [last.id]
    assert tail["page"]["hasMoreBefore"]
    refute tail["page"]["hasMoreAfter"]

    older =
      read(ctx, ctx.selected, "asUser=owner&limit=2&before=" <> tail["page"]["oldestCursor"])
      |> body()

    assert Enum.map(older["items"], & &1["id"]) == [first.id, marker.id]
    refute older["page"]["hasMoreBefore"]
    assert older["page"]["hasMoreAfter"]

    forward =
      read(ctx, ctx.selected, "asUser=owner&after=" <> older["page"]["newestCursor"]) |> body()

    assert forward["items"] == tail["items"]

    empty =
      read(ctx, ctx.selected, "asUser=owner&after=" <> forward["page"]["newestCursor"]) |> body()

    assert empty["items"] == []
    assert empty["page"]["hasMoreBefore"]
    refute empty["page"]["hasMoreAfter"]

    # The unchanged device path returns the same canonical envelope and cursors.
    assert read(ctx, ctx.selected, "tail=false", ctx.owner.token) |> body() == all
  end

  test "operator reads require a valid explicit user and exact authorized selection", ctx do
    append(ctx, ctx.selected, "private selected content")
    assert_error(read(ctx, ctx.selected, ""), 403, "org_token_read_forbidden")

    for query <- ["asUser=", "asUser=owner&asUser=owner", "asUser=owner&asUser=other"] do
      assert_error(read(ctx, ctx.selected, query), 400, "invalid_as_user")
    end

    for {selection, user} <- [
          {ctx.selected, "unknown"},
          {ctx.hidden, "owner"},
          {%{session_key: "missing"}, "owner"}
        ] do
      response = read(ctx, selection, "asUser=" <> user)
      assert_error(response, 404, "not_found")
      refute response.resp_body =~ "private selected content"
    end

    assert_error(read(ctx, ctx.selected, "asUser=owner", "invalid-token"), 401, "auth_failed")

    for query <- [
          "asUser=owner&sessionKey=another",
          "asUser=owner&sessionKey=a&sessionKey=b",
          "asUser=owner&unexpected=1"
        ] do
      assert_error(read(ctx, ctx.selected, query), 400, "invalid_filter")
    end

    assert read(
             ctx,
             ctx.selected,
             "asUser=owner&sessionKey=" <> URI.encode_www_form(ctx.selected.session_key)
           ).status == 200

    assert read(ctx, ctx.hidden, "asUser=" <> ctx.admin.user_id).status == 200
    assert_error(read(ctx, ctx.hidden, "asUser=owner"), 404, "not_found")

    {:ok, _} = DB.query(ctx.db, "UPDATE users SET isAdmin=0 WHERE userId=?1", [ctx.admin.user_id])
    assert_error(read(ctx, ctx.hidden, "asUser=" <> ctx.admin.user_id), 404, "not_found")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET ownerUserId='other' WHERE sessionKey=?1", [
        ctx.selected.session_key
      ])

    assert_error(read(ctx, ctx.selected, "asUser=owner"), 404, "not_found")
  end

  test "cursors remain bound to selected session and current user principal", ctx do
    append(ctx, ctx.selected, "one")
    append(ctx, ctx.selected, "two")
    page = read(ctx, ctx.selected, "asUser=owner&limit=1") |> body()
    cursor = page["page"]["oldestCursor"]
    identity = cursor |> Base.url_decode64!(padding: false) |> JSON.decode!()
    assert identity["principalKind"] == "user"
    assert identity["principalId"] == "owner"
    assert_error(read(ctx, ctx.sibling, "asUser=owner&before=" <> cursor), 400, "invalid_cursor")

    assert_error(
      read(ctx, ctx.selected, "asUser=" <> ctx.admin.user_id <> "&before=" <> cursor),
      400,
      "invalid_cursor"
    )
  end

  test "session and device reads retain their identity and other collections stay closed to operator",
       ctx do
    append(ctx, ctx.selected, "ordinary reads")
    assert read(ctx, ctx.selected, "", ctx.selected.cli_token).status == 200
    assert read(ctx, ctx.selected, "", ctx.owner.token).status == 200

    for token <- [ctx.selected.cli_token, ctx.owner.token] do
      assert_error(read(ctx, ctx.selected, "asUser=owner", token), 400, "invalid_as_user")
    end

    assert_error(read(ctx, ctx.hidden, "", ctx.owner.token), 404, "not_found")

    for resource <- ["wakes", "turns"] do
      response =
        conn(
          :get,
          String.replace_suffix(path(ctx.selected), "messages", resource) <> "?asUser=owner"
        )
        |> put_req_header("authorization", "Bearer operator-fixture")
        |> Router.call(ctx.opts)

      assert_error(response, 403, "org_token_read_forbidden")
    end
  end
end
