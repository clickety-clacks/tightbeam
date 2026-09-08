defmodule Tightbeam.DeployReadinessTest do
  use ExUnit.Case, async: true
  alias Tightbeam.DeployReadiness, as: Ready

  test "production route never invokes the full-smoke callback in readiness mode" do
    assert Ready.route!("readiness", fn -> :bounded end, fn -> flunk("full smoke ran") end) ==
             :bounded

    assert_raise ArgumentError, fn ->
      Ready.route!("typo", fn -> flunk("readiness ran") end, fn -> flunk("full smoke ran") end)
    end
  end

  test "wake refusal still retires the new session" do
    refused = fn
      "wake", _ -> %{"error" => "wake denied"}
      verb, params -> call(verb, params)
    end

    assert_raise RuntimeError, ~r/wake refused/, fn ->
      Ready.run!(refused, fn _, _ -> flunk("observed after refusal") end, nonce: "test")
    end

    assert_received {:called, "retire", %{"sessionKey" => "new-session"}}
  end

  test "spawn refusal does not attempt any unrelated cleanup" do
    refused = fn
      "spawn", _ -> %{"error" => "spawn denied"}
      verb, _ -> flunk("unexpected mutation #{verb}")
    end

    assert_raise RuntimeError, ~r/spawn refused/, fn ->
      Ready.run!(refused, fn _, _ -> flunk("observed after refusal") end)
    end
  end

  defp call(verb, params) do
    send(self(), {:called, verb, params})

    case verb do
      "spawn" -> %{"stream" => %{"sessionKey" => "new-session"}}
      "wake" -> %{"wakeId" => "new-wake"}
      "retire" -> %{"retiredSessionKeys" => [params["sessionKey"]]}
      _ -> flunk("unbounded mutation: #{verb}")
    end
  end

  defp row(status, content \\ "DEPLOY READY test") do
    %{
      "status" => status,
      "content" => content,
      "replyId" => "reply",
      "messageId" => "prompt",
      "turnSeq" => 1
    }
  end

  test "bounded lifecycle uses only new spawn, its wake and checked retirement" do
    proof =
      Ready.run!(
        &call/2,
        fn session, wake ->
          assert session == "new-session"
          assert wake == "new-wake"
          [row("delivered")]
        end,
        nonce: "test",
        timeout_ms: 0
      )

    assert proof["replyId"] == "reply"
    assert proof["wakeId"] == "new-wake"
    assert_received {:called, "spawn", _}
    assert_received {:called, "wake", %{"sessionKey" => "new-session"}}
    assert_received {:called, "retire", %{"sessionKey" => "new-session"}}
    refute_received {:called, _, _}
  end

  test "absent, active and delivered-without-answer turns never pass; cleanup still runs" do
    for rows <- [
          [],
          [row("queued")],
          [row("running")],
          [row("delivered", "wrong")],
          [Map.put(row("delivered"), "replyId", nil)]
        ] do
      assert_raise RuntimeError, ~r/reply timeout/, fn ->
        Ready.run!(&call/2, fn _, _ -> rows end, nonce: "test", timeout_ms: 0)
      end

      assert_received {:called, "retire", %{"sessionKey" => "new-session"}}
    end
  end

  test "failed and canceled turns fail even with matching answer text" do
    for status <- ~w(failed canceled failed_unknown) do
      assert_raise RuntimeError, ~r/turn failed/, fn ->
        Ready.run!(&call/2, fn _, _ -> [row(status)] end, nonce: "test", timeout_ms: 0)
      end

      assert_received {:called, "retire", _}
    end
  end

  test "retire refusal is fatal and does not hide a reply failure" do
    refused = fn
      "retire", _ -> %{"error" => %{"code" => "denied"}}
      verb, params -> call(verb, params)
    end

    assert_raise RuntimeError, ~r/retirement failed.*denied/, fn ->
      Ready.run!(refused, fn _, _ -> [row("delivered")] end, nonce: "test", timeout_ms: 0)
    end

    assert_raise RuntimeError, ~r/reply proof failed:.*timeout.*retirement failed:/, fn ->
      Ready.run!(refused, fn _, _ -> [] end, nonce: "test", timeout_ms: 0)
    end
  end

  test "missing retirement key and unconfirmed retirement refuse" do
    assert_raise RuntimeError, ~r/missing sessionKey/, fn -> Ready.retire!(&call/2, %{}) end

    assert_raise RuntimeError, ~r/did not confirm/, fn ->
      Ready.retire!(fn _, _ -> %{"retiredSessionKeys" => []} end, %{"sessionKey" => "s"})
    end
  end

  test "observer binds wake, session, assistant role and reply-to identity in real SQL" do
    dir = Path.join(System.tmp_dir!(), "readiness-sql-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    db = Path.join(dir, "state.db")

    {_, 0} =
      System.cmd("sqlite3", [
        db,
        """
        CREATE TABLE turns(seq INTEGER, sessionKey TEXT, wakeId TEXT, messageId TEXT, status TEXT);
        CREATE TABLE messages(id TEXT, sessionKey TEXT, replyToMessageId TEXT, role TEXT, content TEXT);
        INSERT INTO turns VALUES(1,'new-session','new-wake','prompt','delivered');
        INSERT INTO messages VALUES('wrong-session','other','prompt','assistant','DEPLOY READY test');
        INSERT INTO messages VALUES('wrong-turn','new-session','old-prompt','assistant','DEPLOY READY test');
        INSERT INTO messages VALUES('echo','new-session','prompt','user','DEPLOY READY test');
        """
      ])

    assert Ready.observe!(db, "new-session", "wrong-wake") == []
    assert Ready.observe!(db, "other", "new-wake") == []
    assert [%{"replyId" => nil}] = Ready.observe!(db, "new-session", "new-wake")

    {_, 0} =
      System.cmd("sqlite3", [
        db,
        "INSERT INTO messages VALUES('answer','new-session','prompt','assistant','DEPLOY READY test');"
      ])

    assert [%{"replyId" => "answer", "status" => "delivered"}] =
             Ready.observe!(db, "new-session", "new-wake")
  end

  test "observer preserves exact reply binding on the composed O2 schema" do
    alias Tightbeam.{DB, Schema}
    dir = Path.join(System.tmp_dir!(), "readiness-o2-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "state.db")
    name = String.to_atom("readiness_o2_#{System.unique_integer([:positive])}")
    db = start_supervised!({DB, name: name, path: path})
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [["row-driven-o2-v1-019"]]} = DB.query(db, "SELECT shape FROM schema_stamp")

    :ok =
      DB.execute(db, """
      INSERT INTO turns(sessionKey,wakeId,messageId,origin,prompt,status,createdAt)
        VALUES ('new-session','new-wake','prompt','process:fixture','DEPLOY READY test','delivered',1);
      INSERT INTO messages(id,sessionKey,replyToMessageId,role,content,timestamp,llmVisibleMessageId)
        VALUES ('wrong','other','prompt','assistant','DEPLOY READY test',1,'wrong');
      """)

    assert [%{"replyId" => nil}] = Ready.observe!(path, "new-session", "new-wake")

    :ok =
      DB.execute(db, """
      INSERT INTO messages(id,sessionKey,replyToMessageId,role,content,timestamp,llmVisibleMessageId)
        VALUES ('answer','new-session','prompt','assistant','DEPLOY READY test',2,'answer');
      """)

    assert [%{"replyId" => "answer", "status" => "delivered"}] =
             Ready.observe!(path, "new-session", "new-wake")

    assert Ready.observe!(path, "new-session", "other-wake") == []
    assert Ready.observe!(path, "other-session", "new-wake") == []
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  test "mode rejects typos instead of entering full destructive smoke" do
    assert Ready.mode!("readiness") == :readiness
    assert_raise ArgumentError, fn -> Ready.mode!("ready") end
  end
end
