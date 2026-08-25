defmodule Tightbeam.Transcript do
  @moduledoc """
  Read the client-visible conversation out of the substrate's OWN rows —
  `messages` joined to `turns`, filtered by `sessions.clearedThroughSeq`. A pure
  read: no table, no column, no emission of its own (spec transcript-verb-v1).

  Not the harness transcript file. The conversation is already substrate truth
  (an accepted prompt commits its echo and its turn in one transaction), the
  rows live on the gateway even when the session's harness does not, and rows
  filter per session against owner/admin where a file path cannot.

  SCOPE: prompts, replies, and their linkage — the same rows the client renders.
  NOT the agent's tool calls or thinking; the persisted message shape holds
  conversation fields, not either of those. "What did the agent DO" is
  `work-item-trace` plus forensics.

  Two entry points, never one that guesses (Flynn ruling): `session_key` is
  retrieval, `name` is LOOKUP that returns a candidate CHOICE and never content.

  Ordering is `messages.seq` — `INTEGER PRIMARY KEY AUTOINCREMENT` — everywhere.
  `id` is random and `timestamp` can tie or regress, so neither may order a page.
  """

  alias Tightbeam.{DB, Org}

  @default_limit 50
  @max_limit 500

  @doc "The default page size when the caller names none."
  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @doc "The hard cap: a larger request is clamped, never refused."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc """
  Retrieval (`session_key`) or name lookup (`name`), per the call's params.

  Returns the pinned page/candidate map, or a `%{code: …}` error map — which is
  what makes an authorization refusal a Dispatch denial rather than a result.
  """
  @spec read(DB.server(), map()) :: map()
  def read(db, call) do
    case mode(call.params) do
      {:session, key} -> retrieve(db, key, call.params, call.principal)
      {:name, name} -> lookup(db, name, call.principal)
      {:error, error} -> error
    end
  end

  ## Mode and cursor selection — both pairs are mutually exclusive

  defp mode(params) do
    session = string_param(params, :session_key)
    name = string_param(params, :name)

    cond do
      session && name ->
        {:error, invalid("--session and --name are mutually exclusive")}

      session ->
        {:session, session}

      name ->
        {:name, name}

      true ->
        {:error, invalid("transcript requires --session <sessionKey> or --name <displayName>")}
    end
  end

  defp cursor(params) do
    before_id = string_param(params, :before)
    after_id = string_param(params, :after)

    cond do
      before_id && after_id -> {:error, invalid("--before and --after are mutually exclusive")}
      before_id -> {:before, before_id}
      after_id -> {:after, after_id}
      true -> :tail
    end
  end

  # Above the cap the request is CLAMPED, and the clamp is observable in the
  # returned count. A value that is not a positive integer takes the default.
  defp limit(params) do
    case params[:limit] do
      n when is_integer(n) and n > 0 -> min(n, @max_limit)
      _ -> @default_limit
    end
  end

  ## Retrieval

  # Session STATE never gates retrieval: `Org.get/2` fetches by key with no state
  # predicate, and an authorized caller can read a retired session.
  defp retrieve(db, session_key, params, principal) do
    caller = caller(db, principal)
    session = Org.get(db, session_key)

    if session && readable?(caller, session) do
      case cursor(params) do
        {:error, error} -> error
        selection -> page(db, session, selection, limit(params))
      end
    else
      # An unknown key and a session this caller may not read are the same answer.
      not_found()
    end
  end

  defp page(db, session, selection, limit) do
    case resolve_cursor(db, session.session_key, selection) do
      {:error, error} ->
        error

      {:ok, bound} ->
        entries = select(db, session.session_key, session.cleared_through_seq, bound, limit)
        flags = flags(db, session, bound, entries)

        %{
          session_key: session.session_key,
          display_name: session.display_name,
          messages: entries,
          oldest_id: (entries != [] && List.first(entries).id) || nil,
          newest_id: (entries != [] && List.last(entries).id) || nil,
          has_more_before: flags.before,
          has_more_after: flags.after
        }
    end
  end

  # EXISTENCE-based, not visibility-based: the retained row resolves even at or
  # below the barrier, and only the returned RANGE is floored. That is what lets
  # a caller whose history was cleared between pages catch up from the id it
  # already holds instead of being stranded.
  defp resolve_cursor(_db, _session_key, :tail), do: {:ok, :tail}

  defp resolve_cursor(db, session_key, {direction, id}) do
    case cursor_seq(db, session_key, id) do
      nil -> {:error, cursor_not_found()}
      seq -> {:ok, {direction, seq}}
    end
  end

  defp cursor_seq(db, session_key, id) do
    {:ok, rows} = DB.query(db, "SELECT seq, sessionKey FROM messages WHERE id = ?1", [id])

    case rows do
      # A nonexistent id and an id belonging to another session are one answer.
      [[seq, ^session_key]] -> seq
      _ -> nil
    end
  end

  ## Range selection — every mode selects only from V (seq > barrier)

  defp select(db, session_key, barrier, :tail, limit) do
    db
    |> rows("AND m.seq > ?2 ORDER BY m.seq DESC LIMIT ?3", [session_key, barrier, limit])
    |> Enum.reverse()
  end

  defp select(db, session_key, barrier, {:before, cursor_seq}, limit) do
    db
    |> rows("AND m.seq > ?2 AND m.seq < ?3 ORDER BY m.seq DESC LIMIT ?4", [
      session_key,
      barrier,
      cursor_seq,
      limit
    ])
    |> Enum.reverse()
  end

  defp select(db, session_key, barrier, {:after, cursor_seq}, limit) do
    rows(db, "AND m.seq > ?2 ORDER BY m.seq ASC LIMIT ?3", [
      session_key,
      max(barrier, cursor_seq),
      limit
    ])
  end

  # The pinned turn join: a `user` entry joins on `turns.messageId = entry.id`, an
  # `assistant` entry on `turns.messageId = entry.replyToMessageId` (no turn when
  # that link is null). `turns.messageId` has no UNIQUE constraint; the 0-or-1
  # relationship rests on the production write invariant that
  # `Gateway.deliver_prompt_in_txn/5` is the sole turn-bearing enqueue path, which
  # a source-structure test pins.
  defp rows(db, range_sql, params) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT m.id, m.timestamp, m.role, m.sender, m.content, m.attachments,
               m.replyToMessageId, t.seq, t.model, t.thinkingLevel, t.modelContext,
               t.harness, t.assignmentId, t.jobRef
        FROM messages AS m
        LEFT JOIN turns AS t
          ON t.messageId = CASE m.role WHEN 'user' THEN m.id ELSE m.replyToMessageId END
        WHERE m.sessionKey = ?1 #{range_sql}
        """,
        params
      )

    Enum.map(rows, &entry/1)
  end

  defp entry([
         id,
         at,
         role,
         sender,
         content,
         attachments,
         reply_to_message_id,
         turn_seq,
         model,
         effort,
         model_context,
         harness,
         assignment_id,
         job_ref
       ]) do
    %{
      id: id,
      at: at,
      role: role,
      sender: sender,
      content: content,
      attachments: JSON.decode!(attachments),
      reply_to_message_id: reply_to_message_id,
      turn_seq: turn_seq,
      model: model,
      context: model_context,
      effort: effort,
      harness: harness,
      assignment_id: assignment_id,
      job_ref: job_ref
    }
  end

  ## Page flags — barrier-relative: cleared rows never make either flag true

  defp flags(db, session, bound, []) do
    # An empty page reports the direction it could still travel, so a caller is
    # never told history exists that it can never page to.
    visible? = visible_any?(db, session)

    case bound do
      :tail -> %{before: false, after: false}
      {:before, _seq} -> %{before: false, after: visible?}
      {:after, _seq} -> %{before: visible?, after: false}
    end
  end

  defp flags(db, session, _bound, entries) do
    oldest = List.first(entries).id
    newest = List.last(entries).id

    %{
      before: neighbor?(db, session, "<", oldest),
      after: neighbor?(db, session, ">", newest)
    }
  end

  defp visible_any?(db, session) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM messages WHERE sessionKey = ?1 AND seq > ?2 LIMIT 1",
        [session.session_key, session.cleared_through_seq]
      )

    count > 0
  end

  defp neighbor?(db, session, comparison, id) do
    {:ok, [[count]]} =
      DB.query(
        db,
        """
        SELECT COUNT(*) FROM messages
        WHERE sessionKey = ?1 AND seq > ?2
          AND seq #{comparison} (SELECT seq FROM messages WHERE id = ?3)
        LIMIT 1
        """,
        [session.session_key, session.cleared_through_seq, id]
      )

    count > 0
  end

  ## Name lookup — a CHOICE, never content

  defp lookup(db, name, principal) do
    caller = caller(db, principal)

    candidates =
      db
      |> candidate_rows(name)
      |> Enum.filter(&readable?(caller, &1))
      |> Enum.map(
        &Map.take(&1, [:session_key, :display_name, :state, :owner_user_id, :last_activity_at])
      )

    %{candidates: candidates}
  end

  # `lastActivityAt` is the timestamp of the session's highest VISIBLE message
  # seq, or the session's own createdAt when it has none. Ordering by it is
  # BEST-EFFORT DISPLAY DATA — a stored timestamp can tie or regress — which is
  # why the seq-only discipline governs entries and not this ranking.
  defp candidate_rows(db, name) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT s.sessionKey, s.displayName, s.state, s.ownerUserId,
               COALESCE(
                 (SELECT m.timestamp FROM messages AS m
                  WHERE m.sessionKey = s.sessionKey AND m.seq > s.clearedThroughSeq
                  ORDER BY m.seq DESC LIMIT 1),
                 s.createdAt
               ) AS lastActivityAt
        FROM sessions AS s
        WHERE lower(s.displayName) LIKE lower(?1) ESCAPE '\\'
        ORDER BY lastActivityAt DESC, s.sessionKey ASC
        """,
        ["%" <> escape_like(name) <> "%"]
      )

    Enum.map(rows, fn [key, display_name, state, owner, last_activity_at] ->
      %{
        session_key: key,
        display_name: display_name,
        state: state,
        owner_user_id: owner,
        last_activity_at: last_activity_at
      }
    end)
  end

  # `%` and `_` in the caller's name are LITERAL, never wildcards.
  defp escape_like(name) do
    name
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  ## Authorization — session owner or admin, resolved once per call

  defp caller(db, {:user, user}) do
    case DB.query(db, "SELECT isAdmin FROM users WHERE userId = ?1", [user]) do
      {:ok, [[admin]]} -> %{owner: user, admin: admin == 1}
      _ -> %{owner: user, admin: false}
    end
  end

  defp caller(db, {:session, session_key}) do
    case DB.query(
           db,
           """
           SELECT u.userId, u.isAdmin
           FROM sessions AS s
           JOIN users AS u ON u.userId = s.ownerUserId
           WHERE s.sessionKey = ?1
           """,
           [session_key]
         ) do
      {:ok, [[owner, admin]]} -> %{owner: owner, admin: admin == 1}
      _ -> nil
    end
  end

  defp caller(_db, _principal), do: nil

  defp readable?(nil, _session), do: false
  defp readable?(%{admin: true}, _session), do: true
  defp readable?(%{owner: owner}, session), do: owner == session.owner_user_id

  ## Errors — the two not_found bodies are each byte-identical across their cases

  defp not_found, do: %{code: "not_found", message: "session not found"}
  defp cursor_not_found, do: %{code: "not_found", message: "cursor message not found"}
  defp invalid(message), do: %{code: "invalid", message: message}

  defp string_param(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
