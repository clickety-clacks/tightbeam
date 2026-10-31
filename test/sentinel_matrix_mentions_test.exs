defmodule Tightbeam.SentinelMatrixMentionsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, Identity, Model, Org, Schema}

  @message "sentinels/matrix/message"
  @mention "sentinels/matrix/mention"
  @room "!sentinels-output:example.org"
  @sender "@author:example.org"
  @d "@d:example.org"
  @m "@m:example.org"

  test "reported mentions take precedence, body tokens are exact, and each distinct target gets one post" do
    # Content shapes reproduce recorded intentional mentions, replies, empty
    # mentions and plain-ID messages; identifiers and message text are examples.
    cases =
      [
        {%{
           "body" => "D: ready",
           "m.mentions" => %{"user_ids" => [@d, @m]},
           "formatted_body" => ~s(<a href="https://matrix.to/#/#{@d}">D</a>)
         }, [@d, @m]},
        {%{
           "body" => "it does. thanks",
           "m.mentions" => %{"user_ids" => [@d]},
           "m.relates_to" => %{"m.in_reply_to" => %{"event_id" => "$prior"}}
         }, [@d]},
        {%{"body" => "see #{@d}", "m.mentions" => %{}}, []},
        {%{"body" => "repeat", "m.mentions" => %{"user_ids" => [@d, @d, 7, nil, @sender]}}, [@d]},
        {%{"body" => "#{@d} #{@m} — ruled X\na=b\nsecond line"}, [@d, @m]},
        {%{"body" => "I am #{@sender}, cc #{@m}."}, [@m]},
        {%{"body" => "mail bob@example.org; @shortname please look; @Alice:example.org"}, []},
        {%{"body" => "https://matrix.to/#/#{@d} x#{@m} /#{@d} +#{@d} :#{@d}"}, []},
        {%{"body" => "ping @a.b:example.org. x @a:example.org:8448, y"},
         ["@a.b:example.org", "@a:example.org:8448"]},
        {%{"body" => "(#{@d}), [#{@m}]; #{@d}!"}, [@d, @m]},
        {%{
           "body" => "@room D",
           "formatted_body" => ~s(<a href="https://matrix.to/#/#{@d}">D</a>)
         }, []},
        {%{"body" => "@room #{@d}", "m.mentions" => %{"room" => true}}, []},
        {%{
           "body" => "reply without an ID",
           "m.relates_to" => %{"m.in_reply_to" => %{"event_id" => "$prior"}}
         }, []},
        {%{
           "body" => "edit",
           "m.new_content" => %{"body" => @d, "m.mentions" => %{"user_ids" => [@d]}}
         }, []},
        {%{"body" => "case preserved", "m.mentions" => %{"user_ids" => ["@D:example.org"]}},
         ["@D:example.org"]},
        {%{"body" => String.duplicate("line=λ\n", 8_000), "m.mentions" => %{"user_ids" => [@d]}},
         [@d]}
      ] ++
        Enum.map([nil, "x", 7, [], %{"user_ids" => "x"}, %{"user_ids" => nil}], fn malformed ->
          {%{"body" => @d, "m.mentions" => malformed}, []}
        end)

    messages =
      cases
      |> Enum.with_index()
      |> Enum.map(fn {{content, _}, index} -> message("$case-#{index}", content) end)

    posts = watcher_posts(messages ++ messages)
    {first, repeated} = Enum.split(posts, div(length(posts), 2))
    assert first == repeated

    {[], keys} =
      Enum.reduce(Enum.zip(messages, cases), {first, []}, fn {message, {content, expected}},
                                                             {remaining, keys} ->
        {actual, rest} = Enum.split(remaining, 1 + length(expected))
        [message_post | mentions] = actual
        details = %{"room" => @room, "sender" => @sender, "text" => content["body"]}

        assert message_post == %{
                 event: @message,
                 key: message["source"]["event_id"],
                 details: details
               }

        assert Enum.map(mentions, & &1.details["mentioned"]) == Enum.sort(expected)

        for mention <- mentions do
          assert mention.event == @mention
          assert Map.delete(mention.details, "mentioned") == details
        end

        {rest, keys ++ Enum.map(mentions, & &1.key)}
      end)

    assert length(keys) == length(Enum.uniq(keys))
  end

  test "watcher posts use declared events and exact subscriptions, keeping room and mention wakes separate" do
    root = temporary_root()
    bundles = Path.join(root, "bundles")
    base = Path.join(root, "runtime")
    File.mkdir_p!(bundles)
    File.cp_r!(Path.expand("../priv/kungfu/sentinels", __DIR__), Path.join(bundles, "sentinels"))
    previous = Application.get_env(:tightbeam, :kungfu_bundle_root_dir)
    Application.put_env(:tightbeam, :kungfu_bundle_root_dir, bundles)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :kungfu_bundle_root_dir),
        else: Application.put_env(:tightbeam, :kungfu_bundle_root_dir, previous)
    end)

    db = start_supervised!({DB, path: ":memory:", name: :matrix_mentions_test})
    :ok = Schema.ensure_all(db)
    :ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1)")
    Identity.init!(base)
    {:ok, candidate} = Identity.learn!(base, "sentinels", "test")
    {:ok, _} = Identity.publish_live!(base, candidate)

    for key <- ~w(mentioned either case-only direct both) do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })
    end

    handlers =
      Gateway.handlers(%{db: db, base_dir: base, wake_scheduler: :no_matrix_test_scheduler})

    listed = handlers["sentinel-events"].(%{origin: "process:fixture", params: %{}}).events
    assert Enum.sort(Enum.map(listed, & &1.qualified)) == [@mention, @message]
    mention = Enum.find(listed, &(&1.qualified == @mention))
    assert Enum.map(mention.details, & &1.name) == ["room", "sender", "mentioned", "text"]
    assert Enum.all?(mention.details, &(String.length(&1.description) > 0))

    for {session, event, where} <- [
          {"mentioned", @mention, ["mentioned=" <> @d]},
          {"either", @mention, ["mentioned=" <> @d, "mentioned=" <> @m]},
          {"case-only", @mention, ["mentioned=@D:example.org"]},
          {"direct", @message, ["room=" <> @room]},
          {"both", @message, ["room=" <> @room]},
          {"both", @mention, ["mentioned=" <> @d]},
          {"both", @mention, ["mentioned=" <> @d, "room=" <> @room]}
        ] do
      assert %{id: _} =
               handlers["sentinel-subscribe"].(%{
                 origin: "session:" <> session,
                 principal: {:session, session},
                 session_key: session,
                 params: %{event: event, where: where}
               })
    end

    messages = [
      message("$addressed", %{"body" => "hello", "m.mentions" => %{"user_ids" => [@d, @m, @d]}}),
      message("$direct-chatter", %{"body" => "not addressed"}),
      put_in(
        message("$elsewhere", %{"body" => @d}),
        ["room", "room_id"],
        "!elsewhere:example.org"
      )
    ]

    for post <- watcher_posts(messages ++ messages) do
      assert %{event: %{fact_id: _}} =
               handlers["sentinel-post"].(%{
                 origin: "process:sentinel:sentinels/matrix",
                 principal: {:process, "sentinel:sentinels/matrix"},
                 params: %{
                   event: post.event,
                   key: post.key,
                   detail: Enum.map(post.details, fn {key, value} -> key <> "=" <> value end)
                 }
               })
    end

    assert {:ok, [[6]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind LIKE 'sentinel-event:%'"
             )

    assert {:ok, rows} =
             DB.query(
               db,
               "SELECT sessionKey, conditionKind, prompt FROM wakes ORDER BY sessionKey"
             )

    assert Enum.frequencies_by(rows, &hd/1) == %{
             "mentioned" => 2,
             "either" => 3,
             "direct" => 2,
             "both" => 4
           }

    refute Enum.any?(rows, fn [session, _, _] -> session == "case-only" end)

    assert Enum.count(rows, fn [s, kind, _] ->
             s == "both" and kind == "sentinel-event:" <> @mention
           end) == 2

    assert Enum.count(rows, fn [s, kind, _] ->
             s == "both" and kind == "sentinel-event:" <> @message
           end) == 2

    assert Enum.all?(rows, fn [_, _, prompt] -> prompt =~ "tightbeam sentinel unsubscribe" end)

    assert Enum.any?(rows, fn [s, _, prompt] ->
             s == "mentioned" and prompt =~ "mentioned:\n#{@d}" and prompt =~ "text:\nhello"
           end)

    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  defp message(id, content) do
    sample =
      Path.expand("fixtures/matrix-commander-message.jsonl", __DIR__)
      |> File.read!()
      |> JSON.decode!()

    sample |> put_in(["source", "event_id"], id) |> put_in(["source", "content"], content)
  end

  defp watcher_posts(messages) do
    root = temporary_root()
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    sample = Path.join(root, "messages.jsonl")
    captured = Path.join(root, "posts.jsonl")
    File.write!(sample, Enum.map_join(messages, "\n", &JSON.encode!/1) <> "\n")
    executable(Path.join(bin, "matrix-commander"), "#!/bin/sh\ncat \"$MATRIX_SAMPLE\"\n")

    executable(Path.join(bin, "tightbeam"), """
    #!/usr/bin/env python3
    import json, os, sys
    with open(os.environ["POST_CAPTURE"], "a", encoding="utf-8") as output:
        output.write(json.dumps(sys.argv[1:], ensure_ascii=False) + chr(10))
    """)

    watcher = Path.expand("../priv/kungfu/sentinels/sentinels/matrix", __DIR__)

    {output, status} =
      System.cmd(System.find_executable("python3"), [watcher],
        stderr_to_stdout: true,
        env: [
          {"PATH", bin <> ":" <> System.get_env("PATH", "")},
          {"MATRIX_SAMPLE", sample},
          {"MATRIX_COMMANDER_CREDENTIALS", Path.join(root, "absent-credentials")},
          {"MATRIX_COMMANDER_STORE", Path.join(root, "absent-store")},
          {"POST_CAPTURE", captured}
        ]
      )

    assert status != 0
    assert output =~ "matrix-commander exited"
    refute File.exists?(Path.join(root, "absent-credentials"))
    refute File.exists?(Path.join(root, "absent-store"))

    captured
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      ["sentinel", "post", "--event", event, "--key", key | fields] = JSON.decode!(line)

      details =
        fields
        |> Enum.chunk_every(2)
        |> Map.new(fn ["--detail", pair] ->
          [name, value] = String.split(pair, "=", parts: 2)
          {name, value}
        end)

      %{event: event, key: key, details: details}
    end)
  end

  defp temporary_root do
    root = Path.join(System.tmp_dir!(), "matrix-mentions-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp executable(path, text) do
    File.write!(path, text)
    File.chmod!(path, 0o755)
  end
end
