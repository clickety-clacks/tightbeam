defmodule Tightbeam.TranscriptTest do
  @moduledoc """
  Proofs for spec transcript-verb-v1.

  Everything here is on OUR side of the ACP seam: SQL, ordering, the history
  barrier, authorization, the router's own refusals, and what Dispatch writes to
  `events.payload`. Rows are written directly where the test needs a shape
  production cannot be asked for on demand (equal and regressed timestamps, a
  pre-attribution-column turn); the schema/attribution proof also drives one
  REAL `Gateway.deliver_prompt/4` so the join is shown against a
  production-written message/turn pair, not only against staged rows.
  """
  use Tightbeam.TestCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Tightbeam.{
    Assets,
    ConnRegistry,
    DB,
    Devices,
    Dispatch,
    EventLog,
    Gateway,
    Ledger,
    Org,
    Projection,
    Roles,
    Transcript,
    Wakes
  }

  alias Tightbeam.Wire.Router

  @entry_keys ~w(id at role sender content attachments reply_to_message_id
                 turn_seq model harness assignment_id job_ref)a

  defmodule LaneDoorbell do
    @moduledoc false
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}
    def handle_call({:ensure_lane, _key}, _from, parent), do: {:reply, :ok, parent}
    def handle_call(_other, _from, parent), do: {:reply, :ok, parent}
  end

  setup do
    db = :"transcript_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [Assets, Devices, EventLog, Ledger, Projection, Org, Roles, Wakes],
        do: :ok = module.ensure_schema(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn',0,1),('kay',0,1),('root',1,1)"
      )

    owned = session!(db, "owned", "flynn", "Coder Session")
    foreign = session!(db, "foreign", "kay", "Kay Session")

    %{db: db, owned: owned, foreign: foreign}
  end

  ## Proof 1 — tail default

  test "proof 1: no cursor returns the newest limit rows, oldest-first", ctx do
    ids = seed(ctx.db, "owned", 6)

    page = read(ctx, %{session_key: "owned", limit: 3})

    assert Enum.map(page.messages, & &1.id) == Enum.slice(ids, 3, 3)
    assert page.oldest_id == Enum.at(ids, 3)
    assert page.newest_id == Enum.at(ids, 5)
    assert page.session_key == "owned"
    assert page.display_name == "Coder Session"

    # A longer session has older rows; a tail already holds the newest visible end.
    assert page.has_more_before
    refute page.has_more_after
  end

  ## Proof 2 — paging

  test "proof 2: before walks strictly older, after strictly newer, and neither strands", ctx do
    ids = seed(ctx.db, "owned", 7)

    # Page the whole session backwards: every visible message exactly once.
    {visited, last_page} = walk_back(ctx, %{session_key: "owned", limit: 2}, [])
    assert visited == ids
    refute last_page.has_more_before

    # Every before page that has newer visible rows above it says so.
    first_back = read(ctx, %{session_key: "owned", limit: 2, before: Enum.at(ids, 6)})
    assert Enum.map(first_back.messages, & &1.id) == Enum.slice(ids, 4, 2)
    assert first_back.has_more_after
    assert first_back.has_more_before

    # After pages: true while rows remain, false once caught up.
    mid = read(ctx, %{session_key: "owned", limit: 2, after: Enum.at(ids, 0)})
    assert Enum.map(mid.messages, & &1.id) == Enum.slice(ids, 1, 2)
    assert mid.has_more_after

    caught_up = read(ctx, %{session_key: "owned", limit: 50, after: Enum.at(ids, 6)})
    assert caught_up.messages == []
    assert caught_up.oldest_id == nil
    assert caught_up.newest_id == nil
    refute caught_up.has_more_after
    assert caught_up.has_more_before

    # An empty catch-up must not strand: the caller keeps the id it PASSED, and
    # that retained id still yields the next row once one is appended.
    retained = Enum.at(ids, 6)
    [fresh] = seed(ctx.db, "owned", 1)
    resumed = read(ctx, %{session_key: "owned", limit: 50, after: retained})
    assert Enum.map(resumed.messages, & &1.id) == [fresh]
  end

  ## Proof 3 — seq ordering under hostile timestamps

  test "proof 3: equal and regressed timestamps still order by seq in every mode", ctx do
    # Timestamp order deliberately disagrees with seq order: an implementation
    # ordering by `timestamp` (or by the random `id`) cannot pass this.
    a = message!(ctx.db, "owned", "user", "alpha", timestamp: 500)
    b = message!(ctx.db, "owned", "user", "bravo", timestamp: 500)
    c = message!(ctx.db, "owned", "user", "charlie", timestamp: 100)
    d = message!(ctx.db, "owned", "user", "delta", timestamp: 400)
    ordered = [a, b, c, d]

    tail = read(ctx, %{session_key: "owned", limit: 50})
    assert Enum.map(tail.messages, & &1.id) == ordered

    assert Enum.map(read(ctx, %{session_key: "owned", before: d}).messages, & &1.id) ==
             [a, b, c]

    assert Enum.map(read(ctx, %{session_key: "owned", after: a}).messages, & &1.id) ==
             [b, c, d]

    # Paging across the hostile rows neither skips nor duplicates.
    {visited, _} = walk_back(ctx, %{session_key: "owned", limit: 2}, [])
    assert visited == ordered
  end

  ## Proof 4 — cursor refusal

  test "proof 4: a foreign or nonexistent cursor is one byte-identical not_found", ctx do
    seed(ctx.db, "owned", 2)
    [foreign_id] = seed(ctx.db, "foreign", 1)

    foreign = read(ctx, %{session_key: "owned", before: foreign_id})
    missing = read(ctx, %{session_key: "owned", before: "s_does_not_exist"})

    assert foreign == missing
    assert foreign.code == "not_found"

    # Neither body names the id, and neither degenerates into the tail.
    encoded = JSON.encode!(foreign)
    refute encoded =~ foreign_id
    refute encoded =~ "s_does_not_exist"
    refute Map.has_key?(foreign, :messages)

    assert read(ctx, %{session_key: "owned", after: foreign_id}) ==
             read(ctx, %{session_key: "owned", after: "s_does_not_exist"})
  end

  ## Proof 5 — the history barrier

  test "proof 5: cleared rows are never served and never set a flag", ctx do
    ids = seed(ctx.db, "owned", 4)
    page = read(ctx, %{session_key: "owned", limit: 2})
    held_oldest = page.oldest_id
    held_newest = page.newest_id

    # Advance the barrier THROUGH the held rows, then commit newer ones.
    clear_through!(ctx.db, "owned", held_newest)
    fresh = seed(ctx.db, "owned", 2)

    # Nothing at or below the barrier is served, in any mode.
    tail = read(ctx, %{session_key: "owned", limit: 50})
    assert Enum.map(tail.messages, & &1.id) == fresh
    refute tail.has_more_before

    # An at-or-below cursor still RESOLVES (existence-based) and floors the range.
    before_page = read(ctx, %{session_key: "owned", before: held_oldest})
    assert before_page.messages == []
    assert before_page.oldest_id == nil
    assert before_page.newest_id == nil
    refute before_page.has_more_before
    assert before_page.has_more_after

    after_page = read(ctx, %{session_key: "owned", after: held_newest})
    assert Enum.map(after_page.messages, & &1.id) == fresh
    refute after_page.has_more_after

    # hasMoreAfter is computed from rows still above the returned page.
    narrow = read(ctx, %{session_key: "owned", limit: 1, after: held_newest})
    assert Enum.map(narrow.messages, & &1.id) == [hd(fresh)]
    assert narrow.has_more_after

    # A row committed above the barrier is served; the cleared ones are gone.
    assert length(ids) == 4
    refute Enum.any?(tail.messages, &(&1.id in Enum.take(ids, 2)))

    # `--name` lastActivityAt reflects visible rows only.
    [candidate] = read(ctx, %{name: "Coder Session"}).candidates
    {:ok, [[visible_at]]} = DB.query(ctx.db, "SELECT timestamp FROM messages WHERE id = ?1", [List.last(fresh)])
    assert candidate.last_activity_at == visible_at
  end

  ## Proof 6 — name lookup

  test "proof 6: a name resolves to a candidate CHOICE, never to content", ctx do
    session!(ctx.db, "coder-two", "flynn", "Coder Session Two")
    session!(ctx.db, "retired-one", "flynn", "Retired Coder", state: "retired")
    session!(ctx.db, "literal", "flynn", "100% Coverage")

    # Exact single match is STILL a one-row candidate list, never content.
    exact = read(ctx, %{name: "100% Coverage"})
    assert [%{session_key: "literal", display_name: "100% Coverage"}] = exact.candidates
    refute Map.has_key?(exact, :messages)

    # `%` in a stored name matches literally; `%` in the QUERY does not wildcard.
    assert Enum.map(read(ctx, %{name: "100%"}).candidates, & &1.session_key) == ["literal"]
    assert read(ctx, %{name: "100%Coverage"}).candidates == []

    # Partial, case-insensitive.
    partial = read(ctx, %{name: "coder"})

    assert Enum.sort(Enum.map(partial.candidates, & &1.session_key)) ==
             ["coder-two", "literal", "owned", "retired-one"] -- ["literal"]

    # Zero matches is an empty list, not an error.
    assert read(ctx, %{name: "no such session"}).candidates == []

    # Retired sessions participate and carry their state.
    assert Enum.find(partial.candidates, &(&1.session_key == "retired-one")).state == "retired"

    # Ordering: lastActivityAt DESC, then sessionKey ASC on a tie. All four have
    # no messages, so all four tie on their createdAt, seeded equal.
    assert Enum.map(partial.candidates, & &1.session_key) ==
             ["coder-two", "owned", "retired-one"]

    # A REGRESSED highest-visible-seq timestamp ranks the session lower even
    # though its newest message has the highest seq — best-effort display data,
    # not seq ordering. That is exactly why entries never order by timestamp.
    message!(ctx.db, "coder-two", "user", "recent", timestamp: 9_000)
    message!(ctx.db, "owned", "user", "regressed but newer seq", timestamp: 0)
    ranked = Enum.map(read(ctx, %{name: "coder"}).candidates, & &1.session_key)
    assert Enum.take(ranked, 2) == ["coder-two", "retired-one"]
    assert List.last(ranked) == "owned"

    # Both flags, and neither, are usage errors.
    assert %{code: "invalid"} = read(ctx, %{session_key: "owned", name: "Coder Session"})
    assert %{code: "invalid"} = read(ctx, %{})
    assert %{code: "invalid"} = read(ctx, %{session_key: "owned", before: "a", after: "b"})
  end

  ## Proof 7 — authorization and the wire non-target declaration

  test "proof 7: owner and admin read; everyone else gets one not_found", ctx do
    seed(ctx.db, "owned", 2)
    session!(ctx.db, "gone", "flynn", "Gone Session", state: "retired")
    retired_ids = seed(ctx.db, "gone", 1)

    assert length(read(ctx, %{session_key: "owned"}).messages) == 2
    assert Enum.map(read(ctx, %{session_key: "gone"}).messages, & &1.id) == retired_ids

    admin = read(ctx, %{session_key: "owned"}, {:user, "root"})
    assert length(admin.messages) == 2

    # A session principal reads through its own session's owner.
    assert length(read(ctx, %{session_key: "owned"}, {:session, "owned"}).messages) == 2

    # Non-owner and unknown key are byte-identical.
    forbidden = read(ctx, %{session_key: "owned"}, {:user, "kay"})
    unknown = read(ctx, %{session_key: "no-such-session"}, {:user, "kay"})
    assert forbidden == unknown
    assert forbidden.code == "not_found"
    assert read(ctx, %{session_key: "owned"}, {:session, "foreign"}) == forbidden

    # `--name` cannot enumerate what the caller may not read.
    assert Enum.map(read(ctx, %{name: "Session"}, {:user, "kay"}).candidates, & &1.session_key) ==
             ["foreign"]
  end

  test "proof 7 (wire): transcript takes no typed target, and its event has a nil sessionKey",
       ctx do
    opts = router_opts(ctx)

    # The legitimate call: the key travels as a body PARAM, no typed target.
    ok =
      dispatch(opts, %{
        verb: "transcript",
        asUser: "flynn",
        params: %{sessionKey: "owned"}
      })

    assert ok.status == 200
    assert %{"result" => %{"sessionKey" => "owned"}} = JSON.decode!(ok.resp_body)

    {:ok, [[event_session_key]]} =
      DB.query(ctx.db, "SELECT sessionKey FROM events WHERE verb = 'transcript' AND kind = 'verb'")

    assert is_nil(event_session_key)

    # Every top-level targeting shape is refused BEFORE any lookup, with bytes
    # that cannot distinguish unknown from readable from forbidden.
    bodies = [
      %{verb: "transcript", asUser: "flynn", sessionKey: "no-such-session"},
      %{verb: "transcript", asUser: "flynn", sessionKey: "owned"},
      %{verb: "transcript", asUser: "flynn", sessionKey: "foreign"},
      %{verb: "transcript", asUser: "flynn", target: "owned"},
      %{verb: "transcript", asUser: "flynn", sessionKey: "owned", role: "whatever"},
      %{verb: "transcript", asUser: "flynn", userId: "flynn"},
      %{verb: "transcript", asUser: "flynn", role: "whatever"}
    ]

    before_events = verb_event_count(ctx.db)
    responses = Enum.map(bodies, &dispatch(opts, &1))

    for response <- responses do
      assert response.status == 400
    end

    assert responses |> Enum.map(& &1.resp_body) |> Enum.uniq() |> length() == 1

    assert JSON.decode!(hd(responses).resp_body) == %{
             "error" => %{
               "code" => "invalid_message",
               "message" => "transcript takes no typed target"
             }
           }

    # None of them reached dispatch, so none emitted a verb event.
    assert verb_event_count(ctx.db) == before_events
  end

  ## Proof 8 — schema and attribution

  test "proof 8: entries match the pinned key set and carry their turn's attribution", ctx do
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    # A REAL production write: one transaction commits the echo and its turn.
    assert :appended =
             Gateway.deliver_prompt("owned", "user:flynn", "the real prompt",
               db: ctx.db,
               client_message_id: "c_real"
             )

    {:ok, [[prompt_id, turn_seq]]} =
      DB.query(
        ctx.db,
        "SELECT m.id, t.seq FROM messages m JOIN turns t ON t.messageId = m.id WHERE m.sessionKey = 'owned'"
      )

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE turns SET model='fable', harness='claude', assignmentId='asg_1', jobRef='wi_1' WHERE seq=#{turn_seq}"
      )

    reply_id = message!(ctx.db, "owned", "assistant", "the real reply", reply_to: prompt_id, sender: "tightbeam")
    marker_id = message!(ctx.db, "owned", "assistant", "[context cleared]")

    page = read(ctx, %{session_key: "owned", limit: 50})
    assert Enum.map(page.messages, & &1.id) == [prompt_id, reply_id, marker_id]

    # EXACT key set — a missing or extra key fails.
    for entry <- page.messages do
      assert Enum.sort(Map.keys(entry)) == Enum.sort(@entry_keys)
    end

    [prompt, reply, marker] = page.messages

    # A `user` entry joins on turns.messageId = entry.id.
    assert prompt.role == "user"
    assert prompt.turn_seq == turn_seq
    assert prompt.model == "fable"
    assert prompt.harness == "claude"
    assert prompt.assignment_id == "asg_1"
    assert prompt.job_ref == "wi_1"

    # An `assistant` entry joins through its replyToMessageId.
    assert reply.role == "assistant"
    assert reply.sender == "tightbeam"
    assert reply.reply_to_message_id == prompt_id
    assert reply.turn_seq == turn_seq
    assert reply.assignment_id == "asg_1"

    # A marker message has no reply link, so no turn and null attribution.
    assert marker.reply_to_message_id == nil

    for field <- [:turn_seq, :model, :harness, :assignment_id, :job_ref] do
      assert Map.fetch!(marker, field) == nil
    end

    # A pre-attribution-column turn: the migration adds nullable columns with no
    # backfill, so its message carries a turnSeq but null assignmentId/jobRef.
    legacy_msg = message!(ctx.db, "owned", "user", "legacy prompt")
    legacy_seq = turn!(ctx.db, "owned", legacy_msg, model: "fable", harness: "claude")
    legacy = Enum.find(read(ctx, %{session_key: "owned"}).messages, &(&1.id == legacy_msg))
    assert legacy.turn_seq == legacy_seq
    assert legacy.assignment_id == nil
    assert legacy.job_ref == nil
  end

  test "proof 8 (source): exactly one qualified enqueue_in_txn call and no enqueue/2 call" do
    # `turns.messageId` has no UNIQUE constraint, so the 0-or-1 join rests on
    # this write invariant instead. A second production enqueue path fails here.
    files = Path.wildcard("lib/**/*.ex")

    qualified =
      for file <- files,
          {ref, body} <- definitions(file),
          call <- enqueue_calls(body),
          do: {file, ref, call}

    assert Enum.filter(qualified, &(elem(&1, 2) == :enqueue_in_txn)) == [
             {"lib/tightbeam/gateway.ex", "deliver_prompt_in_txn/5", :enqueue_in_txn}
           ]

    assert Enum.filter(qualified, &(elem(&1, 2) == :enqueue)) == []
  end

  ## Proof 9 — limit

  test "proof 9: the default is 50 and an over-cap request is clamped", ctx do
    seed(ctx.db, "owned", 52)

    assert length(read(ctx, %{session_key: "owned"}).messages) == Transcript.default_limit()
    assert Transcript.default_limit() == 50

    # The clamp is observable in the returned count.
    seed(ctx.db, "owned", 500)
    clamped = read(ctx, %{session_key: "owned", limit: 5_000})
    assert length(clamped.messages) == Transcript.max_limit()
    assert Transcript.max_limit() == 500
  end

  ## Proof 10 — elision

  test "proof 10: a successful read is audited by params and count, never by content", ctx do
    body = "a distinctive body string only this row holds"
    message!(ctx.db, "owned", "user", body)

    params = %{session_key: "owned", limit: 10}
    assert {:ok, result} = dispatch_verb(ctx, params)
    assert Enum.any?(result.messages, &(&1.content == body))

    assert verb_payload(ctx.db) == %{
             elided: true,
             params: %{session_key: "owned", limit: 10},
             count: 1
           }

    # The content that WAS returned appears nowhere in the audit row.
    refute raw_payload(ctx.db, "verb") =~ body

    {:ok, [[event_session_key]]} =
      DB.query(ctx.db, "SELECT sessionKey FROM events WHERE kind = 'verb' AND verb = 'transcript'")

    assert is_nil(event_session_key)
  end

  test "proof 10 (denial): a denied transcript call keeps its un-elided error", ctx do
    assert {:error, %{code: "not_found"}} =
             dispatch_verb(ctx, %{session_key: "no-such-session"})

    raw = raw_payload(ctx.db, "denied")
    {decoded, _} = Code.eval_string(raw)
    assert decoded == %{code: "not_found", message: "session not found"}
    refute raw =~ "elided"
  end

  test "proof 10 (crash): a raise cannot carry the row it was holding into the payload", ctx do
    body = "a second distinctive body the crash must not leak"
    message!(ctx.db, "owned", "user", body)

    # The handler reads, then raises HOLDING the page. A MatchError renders
    # `inspect(term)`, so an un-elided crash row would write the content verbatim.
    handlers = %{
      "transcript" => fn call ->
        page = Transcript.read(ctx.db, call)
        raise MatchError, term: page
      end
    }

    call = %{
      verb: "transcript",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{session_key: "owned"}
    }

    assert {:error, %{code: "server_error"}} = Dispatch.dispatch(ctx.db, handlers, call)

    # EXACTLY these four keys — in particular no `message`, which is where
    # `Exception.message/1` would have put the row the handler was holding.
    assert verb_payload(ctx.db) == %{
             elided: true,
             params: %{session_key: "owned"},
             crash: true,
             code: "server_error"
           }

    raw = raw_payload(ctx.db, "verb")
    refute raw =~ "message:"
    refute raw =~ body
  end

  ## Helpers — reads

  defp read(ctx, params, principal \\ {:user, "flynn"}) do
    Transcript.read(ctx.db, %{params: params, principal: principal})
  end

  defp walk_back(ctx, params, acc) do
    page = read(ctx, params)
    acc = Enum.map(page.messages, & &1.id) ++ acc

    if page.has_more_before do
      walk_back(ctx, Map.put(params, :before, page.oldest_id), acc)
    else
      {acc, page}
    end
  end

  ## Helpers — rows

  defp session!(db, key, owner, display_name, opts \\ []) do
    session =
      Org.create(db, %{
        session_key: key,
        display_name: display_name,
        owner_user_id: owner,
        origin: "user:#{owner}",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    if opts[:state] == "retired" do
      {:ok, _} =
        DB.query(db, "UPDATE sessions SET state = 'retired' WHERE sessionKey = ?1", [key])
    end

    # Candidate ties are only meaningful against a fixed createdAt.
    {:ok, _} = DB.query(db, "UPDATE sessions SET createdAt = 1 WHERE sessionKey = ?1", [key])
    session
  end

  defp seed(db, session_key, count) do
    for index <- 1..count do
      message!(db, session_key, "user", "message #{System.unique_integer([:positive])}-#{index}")
    end
  end

  # Direct insert: the tests need control of `timestamp` (proof 3's equal and
  # regressed values) and of reply linkage, neither of which production exposes.
  defp message!(db, session_key, role, content, opts \\ []) do
    id = "s_" <> Tightbeam.Id.uuid4()

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO messages
          (id, sessionKey, role, content, timestamp, sender, replyToMessageId,
           llmVisibleMessageId, attachments)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?1, '[]')
        """,
        [
          id,
          session_key,
          role,
          content,
          Keyword.get(opts, :timestamp, System.system_time(:millisecond)),
          Keyword.get(opts, :sender),
          Keyword.get(opts, :reply_to)
        ]
      )

    id
  end

  defp turn!(db, session_key, message_id, opts) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO turns (sessionKey, messageId, origin, prompt, model, harness, createdAt)
        VALUES (?1, ?2, 'user:flynn', 'legacy', ?3, ?4, 1)
        """,
        [session_key, message_id, opts[:model], opts[:harness]]
      )

    {:ok, [[seq]]} =
      DB.query(db, "SELECT seq FROM turns WHERE messageId = ?1", [message_id])

    seq
  end

  defp clear_through!(db, session_key, message_id) do
    {:ok, [[seq]]} = DB.query(db, "SELECT seq FROM messages WHERE id = ?1", [message_id])

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET clearedThroughSeq = ?2 WHERE sessionKey = ?1", [
        session_key,
        seq
      ])
  end

  ## Helpers — dispatch and wire

  defp dispatch_verb(ctx, params) do
    handlers = %{"transcript" => fn call -> Transcript.read(ctx.db, call) end}

    Dispatch.dispatch(ctx.db, handlers, %{
      verb: "transcript",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: params
    })
  end

  # `events.payload` is `inspect/1` output, not JSON (event_log.ex encode/1), so
  # the raw string is what a reader of the audit trail actually sees — and the
  # string is what "the content appears NOWHERE in the payload" is asserted over.
  defp raw_payload(db, kind) do
    {:ok, [[payload]]} =
      DB.query(db, "SELECT payload FROM events WHERE kind = ?1 AND verb = 'transcript'", [kind])

    payload
  end

  defp verb_payload(db) do
    {term, _bindings} = Code.eval_string(raw_payload(db, "verb"))
    term
  end

  defp verb_event_count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM events WHERE verb = 'transcript'")
    count
  end

  defp router_opts(ctx) do
    [
      db: ctx.db,
      base_dir: System.tmp_dir!(),
      handlers: %{"transcript" => fn call -> Transcript.read(ctx.db, call) end},
      cli_token: "tbc_transcript",
      session_status: fn _ -> nil end
    ]
  end

  defp dispatch(opts, body) do
    conn(:post, "/agent/dispatch", JSON.encode!(body))
    |> put_req_header("authorization", "Bearer tbc_transcript")
    |> Router.call(Router.init(opts))
  end

  ## Helpers — source structure

  defp definitions(file) do
    ast = file |> File.read!() |> Code.string_to_quoted!()

    {_, found} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, body]} = node, acc when kind in [:def, :defp] ->
          {node, [{definition_ref(head), body} | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp definition_ref({:when, _, [head | _]}), do: definition_ref(head)
  defp definition_ref({name, _, args}) when is_list(args), do: "#{name}/#{length(args)}"
  defp definition_ref({name, _, nil}), do: "#{name}/0"

  # Only QUALIFIED calls — `Ledger.enqueue_in_txn(...)` — so the Ledger module's
  # own definitions and its internal wrapper call are not miscounted as new sinks.
  defp enqueue_calls(body) do
    {_, found} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, aliases}, name]}, _, args} = node, acc
        when name in [:enqueue_in_txn, :enqueue] ->
          if List.last(aliases) == :Ledger and length(args) == 2,
            do: {node, [name | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end
end
