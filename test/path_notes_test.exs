defmodule Tightbeam.PathNotesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Ledger, PathNotes, Placement, Schema, Wakes}

  @hosts ["lab1", "lab2"]

  defp paths(text, opts \\ []),
    do: text |> PathNotes.handed_on_paths(@hosts, opts) |> Enum.map(& &1.display)

  describe "handed-on paths" do
    test "repeated paths get one entry, in order, without trailing punctuation" do
      assert paths("review /a/x.md and /a/x.md, then /b/y.md.") == ["/a/x.md", "/b/y.md"]
    end

    test "a URL is not a path" do
      assert paths("see https://example.test/a/b for details") == []
      assert paths("protocol-relative //example.test/a/b") == []
    end

    test "a quoted path is the whole quoted text, spaces included" do
      assert paths(~s(read "/tmp/design notes.md" first)) == ["/tmp/design notes.md"]
      assert paths("read '/tmp/design notes.md' first") == ["/tmp/design notes.md"]
      assert paths("read `/tmp/design notes.md` first") == ["/tmp/design notes.md"]
    end

    test "apostrophes in prose do not pair with a later quote" do
      assert paths("it's at /a/b and '/c d'") == ["/a/b", "/c d"]
    end

    test "unquoted paths end at whitespace; brackets and trailing punctuation are stripped" do
      assert paths("(see /a/b) [/c/d]; </e/f>: {/g/h},") == ["/a/b", "/c/d", "/e/f", "/g/h"]
    end

    test "relative paths and other words are not paths" do
      assert paths("look in docs/spec.md, ./run.sh and ../up, or and/or") == []
    end

    test "home paths are handed on, but can be excluded" do
      assert paths("open ~/notes.md now") == ["~/notes.md"]
      assert paths("open ~/notes.md now", home: false) == []
    end

    test "a host-qualified path counts only for a configured placement host" do
      assert [%{display: "lab1:/w/log.txt", host: "lab1", path: "/w/log.txt"}] =
               PathNotes.handed_on_paths("see lab1:/w/log.txt", @hosts)

      assert paths(~s(see "lab2:/w/run notes.md")) == ["lab2:/w/run notes.md"]
      assert paths("see elsewhere:/w/log.txt and lab1://w") == []
    end

    test "a plain path has no host of its own" do
      assert [%{display: "/w/log.txt", host: nil, path: "/w/log.txt"}] =
               PathNotes.handed_on_paths("/w/log.txt", @hosts)
    end
  end

  describe "note wording" do
    test "each outcome has its exact sentence" do
      assert PathNotes.note("/tmp/spec.md", %{status: "present"}) ==
               "verified present at /tmp/spec.md"

      assert PathNotes.note("/tmp/missing.md", %{status: "absent"}) ==
               "not found at /tmp/missing.md; check before relying on it"

      assert PathNotes.note("/root/x", %{status: "could_not_access", error: "eacces"}) ==
               "could not check /root/x: eacces; check before relying on it"

      assert PathNotes.note("lab1:/x", :running) ==
               "could not check lab1:/x: check still running; check before relying on it"
    end

    test "a single-line system error passes through unchanged" do
      assert PathNotes.note("/x", %{status: "could_not_access", error: "  Permission denied "}) ==
               "could not check /x:   Permission denied ; check before relying on it"
    end

    test "line breaks in a system error become spaces so the note stays one line" do
      assert PathNotes.note("/x", %{
               status: "could_not_access",
               error: "ssh: connect to host lab1 port 22: Connection refused\r\n"
             }) ==
               "could not check /x: ssh: connect to host lab1 port 22: Connection refused; " <>
                 "check before relying on it"

      assert PathNotes.note("/x", %{status: "could_not_access", error: " first \nsecond\r\n\n"}) ==
               "could not check /x:  first  second; check before relying on it"
    end

    test "notes follow the delivered text after a blank line" do
      assert PathNotes.append("brief", ["a", "b"]) == "brief\n\na\nb"
      assert PathNotes.append("brief", []) == "brief"

      assert PathNotes.append([%{type: "text", text: "brief"}], ["a"]) ==
               [%{type: "text", text: "brief"}, %{type: "text", text: "a"}]
    end
  end

  describe "planning a delivered turn" do
    setup do
      db = start_supervised!({DB, path: ":memory:", name: :path_notes_test_db})
      :ok = Schema.ensure_all(db)

      register_hosts(db, %{"lab2" => %{ssh: "lab2.test", base_dir: "/b", cli_bin: nil}})

      :ok =
        DB.execute(db, """
        INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,host,createdAt,updatedAt)
        VALUES ('receiver','receiver','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model','lab2',1,1);
        """)

      q = fn sql, params ->
        {:ok, rows} = DB.query(db, sql, params)
        rows
      end

      %{db: db, q: q}
    end

    test "plain paths are checked on the receiving session's host, host paths on their own",
         ctx do
      local = Placement.local_host_name()

      plan =
        PathNotes.plan(ctx.q, %{
          seq: 7,
          session_key: "receiver",
          message_id: "m_7",
          origin: "agent:sender",
          prompt: "read /w/a.md and #{local}:/w/b.md and nowhere:/w/c.md",
          wake_id: "w_plain"
        })

      assert %{seq: 7, session_key: "receiver"} = plan

      assert Enum.map(plan.paths, &{&1.display, &1.checked_host, &1.route}) == [
               {"/w/a.md", "lab2", {:ok, %{ssh: "lab2.test"}}},
               {"#{local}:/w/b.md", local, {:ok, %{ssh: nil}}}
             ]
    end

    test "a turn with no handed-on path has no plan", ctx do
      assert PathNotes.plan(ctx.q, %{
               seq: 1,
               session_key: "receiver",
               message_id: "m_1",
               origin: "agent:sender",
               prompt: "see https://example.test/a/b",
               wake_id: nil
             }) == nil
    end

    test "a chat post gets no notes, but a wake a user sends does", ctx do
      turn = %{
        seq: 1,
        session_key: "receiver",
        message_id: "m_1",
        origin: "user:fixture",
        prompt: "please read /w/a.md",
        wake_id: nil
      }

      # A chat post's message carries the posting client's message identity.
      posted = fn sql, params ->
        if sql =~ "FROM messages" do
          assert params == ["m_1"]
          [["client-message-1"]]
        else
          ctx.q.(sql, params)
        end
      end

      assert PathNotes.plan(posted, turn) == nil

      sent = fn sql, params ->
        if sql =~ "FROM messages", do: [[nil]], else: ctx.q.(sql, params)
      end

      assert %{paths: [%{display: "/w/a.md"}]} = PathNotes.plan(sent, turn)
    end

    test "a batched delivery checks only paths outside chat members", ctx do
      carrier = "w_nb_carrier"

      # The batch's included members as the carrier query returns them.
      q = fn sql, params ->
        if sql =~ "notice_batch_members" do
          assert params == [carrier]
          [["w_user", "user:fixture", 1, 1], ["w_agent", "agent:sender", 2, 0]]
        else
          ctx.q.(sql, params)
        end
      end

      prompt =
        "[batched notices: 2]\nbatchId=nb_1 wake #{carrier}\n\n" <>
          "[1] source=w_user sender=user:fixture cause=c class=fyi\n[from You]\n\nlook at /w/user.md\n\n" <>
          "[2] source=w_agent sender=agent:sender cause=c class=fyi\nreview /w/agent.md\n\n" <>
          Wakes.digest_signature(2)

      plan =
        PathNotes.plan(q, %{
          seq: 3,
          session_key: "receiver",
          message_id: "m_3",
          origin: "process:tightbeam",
          prompt: prompt,
          wake_id: carrier
        })

      assert Enum.map(plan.paths, & &1.display) == ["/w/agent.md"]
    end
  end

  describe "check lifecycle" do
    setup do
      db = start_supervised!({DB, path: ":memory:", name: :path_notes_lifecycle_db})
      :ok = Schema.ensure_all(db)
      register_hosts(db, %{"lab2" => %{ssh: "lab2.test", base_dir: "/b", cli_bin: nil}})

      :ok =
        DB.execute(db, """
        INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,host,createdAt,updatedAt)
        VALUES ('receiver','receiver','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model','lab2',1,1);
        """)

      # A stand-in for ssh whose remote check never returns: it records its
      # process id and waits.
      dir = Path.join(System.tmp_dir!(), "path-notes-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      pids = Path.join(dir, "pids")
      ssh = Path.join(dir, "ssh")
      File.write!(ssh, "#!/bin/sh\necho $$ >> '#{pids}'\nexec sleep 600\n")
      File.chmod!(ssh, 0o755)
      parent = self()

      file_stat = fn _path ->
        send(parent, {:local_check, self()})
        receive do: (:never -> {:ok, %{}})
      end

      start_supervised!(
        {PathNotes, db: db, stat_config: %{ssh_executable: ssh, file_stat: file_stat}}
      )

      %{db: db, pids: pids}
    end

    test "a remote check still running when its notes are read is ended with its ssh process",
         ctx do
      turn = %{
        seq: 41,
        session_key: "receiver",
        message_id: "m_41",
        prompt: "read /w/hung.md",
        wake_id: nil
      }

      plan = PathNotes.claimed(ctx.db, turn)
      [os_pid] = await_pids(ctx.pids, 1)
      assert os_alive?(os_pid)

      assert PathNotes.notes(plan) == [
               "could not check /w/hung.md: check still running; check before relying on it"
             ]

      assert :sys.get_state(PathNotes).tracked == %{}
      assert :ets.tab2list(PathNotes) == []
      await_gone(os_pid)
    end

    test "a local check still running when its notes are read is ended", ctx do
      local = Placement.local_host_name()

      turn = %{
        seq: 42,
        session_key: "receiver",
        message_id: "m_42",
        prompt: "read #{local}:/w/hung.md",
        wake_id: nil
      }

      plan = PathNotes.claimed(ctx.db, turn)
      assert_receive {:local_check, worker}
      assert [_note] = PathNotes.notes(plan)
      assert :sys.get_state(PathNotes).tracked == %{}
      refute Process.alive?(worker)
    end

    test "checks for a turn that ends undelivered are ended with it", ctx do
      {:ok, seq} =
        Ledger.enqueue(ctx.db, %{
          session_key: "receiver",
          message_id: "m_cancel",
          origin: "agent:sender",
          prompt: "read /w/hung.md"
        })

      # The enqueue started the check.
      [os_pid] = await_pids(ctx.pids, 1)
      assert %{^seq => _} = :sys.get_state(PathNotes).tracked

      {:ok, true} =
        DB.transaction(ctx.db, fn txn -> Ledger.cancel_queued_in_txn(txn, seq, "test") end)

      # The terminal transition hands the forget to the server after commit.
      await(fn -> :sys.get_state(PathNotes).tracked == %{} end)
      assert :ets.tab2list(PathNotes) == []
      await_gone(os_pid)
    end

    test "stopping the check server ends its checks", ctx do
      PathNotes.claimed(ctx.db, %{
        seq: 43,
        session_key: "receiver",
        message_id: "m_43",
        prompt: "read /w/hung.md",
        wake_id: nil
      })

      [os_pid] = await_pids(ctx.pids, 1)
      # The server learns the process id from the check; wait for that.
      await(fn ->
        match?(%{43 => %{} = w} when map_size(w) == 1, :sys.get_state(PathNotes).tracked) and
          Enum.all?(Map.values(:sys.get_state(PathNotes).tracked[43]), & &1.os_pid)
      end)

      stop_supervised!(PathNotes)
      await_gone(os_pid)
    end
  end

  defp await_pids(file, count) do
    await(fn ->
      case File.read(file) do
        {:ok, text} -> length(String.split(text, "\n", trim: true)) == count
        _ -> false
      end
    end)

    file |> File.read!() |> String.split("\n", trim: true)
  end

  defp os_alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true))

  defp await_gone(os_pid), do: await(fn -> not os_alive?(os_pid) end)

  defp await(condition, attempts \\ 400) do
    cond do
      condition.() ->
        :ok

      attempts == 0 ->
        flunk("condition not reached")

      true ->
        Process.sleep(5)
        await(condition, attempts - 1)
    end
  end
end
