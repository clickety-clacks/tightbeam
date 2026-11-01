defmodule Tightbeam.Wire.OperatorHistoryTest do
  use Tightbeam.TestCase, async: false
  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{
    Archetypes,
    DB,
    Devices,
    Ledger,
    Model,
    Org,
    Projection,
    Schema,
    StateResources,
    Wakes
  }

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
    read_resource(ctx, session, "messages", query, token)
  end

  defp read_resource(ctx, session, resource, query, token \\ "operator-fixture") do
    request_path = String.replace_suffix(path(session), "messages", resource)

    conn(:get, request_path <> "?" <> query)
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
    assert hd(all["items"])["rowVersion"] == max(first.seq, first.timestamp)
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

  test "organization reads accept no user selection and validate explicit user filters", ctx do
    selected_message = append(ctx, ctx.selected, "private selected content")
    organization_read = read(ctx, ctx.selected, "")
    assert organization_read.status == 200
    assert Enum.map(body(organization_read)["items"], & &1["id"]) == [selected_message.id]

    # REST state API v1 AU1a treats unusable selection as absent and uses the observer principal.
    organization_identity =
      body(organization_read)["page"]["oldestCursor"]
      |> Base.url_decode64!(padding: false)
      |> JSON.decode!()

    assert organization_identity["principalKind"] == "observer"
    assert organization_identity["principalId"] == "observer"

    empty_selection = read(ctx, ctx.selected, "asUser=") |> body()
    assert empty_selection["items"] == body(organization_read)["items"]

    empty_selection_identity =
      empty_selection["page"]["oldestCursor"]
      |> Base.url_decode64!(padding: false)
      |> JSON.decode!()

    assert empty_selection_identity["principalKind"] == "observer"
    assert empty_selection_identity["principalId"] == "observer"

    repeated_owner = read(ctx, ctx.selected, "asUser=owner&asUser=owner") |> body()
    assert Enum.map(repeated_owner["items"], & &1["id"]) == [selected_message.id]

    repeated_other = read(ctx, ctx.selected, "asUser=owner&asUser=other")
    assert_error(repeated_other, 404, "not_found")
    refute repeated_other.resp_body =~ "private selected content"

    for {selection, user} <- [
          {ctx.selected, "unknown"},
          {ctx.hidden, "owner"},
          {%{session_key: "missing"}, "owner"}
        ] do
      response = read(ctx, selection, "asUser=" <> user)
      assert_error(response, 404, "not_found")
      refute response.resp_body =~ "private selected content"
    end

    invalid_bearer_read = read(ctx, ctx.selected, "asUser=owner", "invalid-token")
    assert invalid_bearer_read.status == 200
    assert Enum.map(body(invalid_bearer_read)["items"], & &1["id"]) == [selected_message.id]

    invalid_bearer_identity =
      body(invalid_bearer_read)["page"]["oldestCursor"]
      |> Base.url_decode64!(padding: false)
      |> JSON.decode!()

    assert invalid_bearer_identity["principalKind"] == "user"
    assert invalid_bearer_identity["principalId"] == "owner"

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
    assert read(ctx, ctx.selected, "asUser=owner&before=" <> cursor).status == 200
    assert_error(read(ctx, ctx.sibling, "asUser=owner&before=" <> cursor), 400, "invalid_cursor")

    other_principal =
      read(ctx, ctx.selected, "asUser=owner&before=" <> cursor, ctx.admin.token) |> body()

    admin_default = read(ctx, ctx.selected, "", ctx.admin.token) |> body()
    assert other_principal["items"] == admin_default["items"]
    assert Enum.map(other_principal["items"], & &1["content"]) == ["one", "two"]
  end

  test "org reads expose session collections with unchanged owner and admin visibility", ctx do
    append(ctx, ctx.selected, "ordinary reads")

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.selected.session_key,
        origin: "user:owner",
        prompt: "operator-visible wake",
        due_at: System.system_time(:millisecond) + 60_000
      })

    {:ok, _turn_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.selected.session_key,
        message_id: "operator-history-turn",
        origin: "user:owner",
        prompt: "operator-visible turn",
        wake_id: wake.wake_id
      })

    assert read(ctx, ctx.selected, "", ctx.selected.cli_token).status == 200
    assert read(ctx, ctx.selected, "", ctx.owner.token).status == 200

    for token <- [ctx.selected.cli_token, ctx.owner.token] do
      response = read(ctx, ctx.selected, "asUser=owner", token)
      assert response.status == 200, response.resp_body
      assert Enum.any?(body(response)["items"], &(&1["content"] == "ordinary reads"))

      identity =
        body(response)["page"]["oldestCursor"]
        |> Base.url_decode64!(padding: false)
        |> JSON.decode!()

      assert identity["principalKind"] == "user"
      assert identity["principalId"] == "owner"
    end

    assert_error(read(ctx, ctx.hidden, "", ctx.owner.token), 404, "not_found")

    for resource <- ["messages", "wakes", "turns"] do
      response = read_resource(ctx, ctx.selected, resource, "asUser=owner")
      assert response.status == 200, response.resp_body

      items = JSON.decode!(response.resp_body)["items"]

      expected =
        if resource == "messages",
          do: "ordinary reads",
          else: "operator-visible #{String.trim_trailing(resource, "s")}"

      assert Enum.any?(
               items,
               &(Map.get(&1, "content") == expected or Map.get(&1, "prompt") == expected)
             )

      assert_error(read_resource(ctx, ctx.hidden, resource, "asUser=owner"), 404, "not_found")
      assert read_resource(ctx, ctx.hidden, resource, "asUser=#{ctx.admin.user_id}").status == 200

      for token <- [ctx.selected.cli_token, ctx.owner.token] do
        assert read_resource(ctx, ctx.selected, resource, "", token).status == 200
      end
    end
  end
end
