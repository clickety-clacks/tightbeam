defmodule Tightbeam.ClientE2E.Substrate do
  @moduledoc """
  The SUBSTRATE column of the journey oracles: what the gateway recorded,
  read the way SMOKE.md reads it — `sqlite3 <base_dir>/state.db`.

  The driver reads the database as an OUTSIDE observer, through the same
  command the runbook names, rather than through `Tightbeam.DB`. That is the
  point: an in-process read would be the gateway telling the driver what the
  gateway believes, and the duality contract (client-e2e-v1 §Substrate
  oracles) asks for an independent second witness. The gateway keeps the file
  in WAL mode, so a concurrent reader sees committed state without blocking
  the writer.

  Correlation note that shapes nearly every query here: the wire's
  `clientMessageId` is NOT `turns.messageId`. The client id lands on
  `messages.clientMessageId`; the turn row points at the SERVER message id.
  Every turn lookup therefore joins through `messages` — a driver that
  compared the client id against `turns.messageId` directly would find no row
  and report a phantom failure.
  """

  @type base_dir :: String.t()

  @doc """
  Runs one read-only SQL statement and returns rows as maps with string keys.

  Uses sqlite3's JSON output so values keep their types and embedded
  separators cannot corrupt the parse.
  """
  @spec query(base_dir(), String.t()) :: [map()]
  def query(base_dir, sql) do
    path = Path.join(base_dir, "state.db")

    case System.cmd("sqlite3", ["-json", "-readonly", path, sql], stderr_to_stdout: true) do
      {"", 0} ->
        []

      {output, 0} ->
        case JSON.decode(output) do
          {:ok, rows} when is_list(rows) -> rows
          _ -> raise "sqlite3 returned unparseable JSON for #{sql}: #{output}"
        end

      {output, code} ->
        raise "sqlite3 failed (#{code}) for #{sql}: #{output}"
    end
  end

  @doc "The turn row for a posted clientMessageId, or nil when no turn was enqueued."
  @spec turn_for_client_message(base_dir(), String.t()) :: map() | nil
  def turn_for_client_message(base_dir, client_message_id) do
    base_dir
    |> query("""
    SELECT t.seq, t.sessionKey, t.status, t.origin, t.error, t.startedAt, t.endedAt
    FROM turns t JOIN messages m ON m.id = t.messageId
    WHERE m.clientMessageId = #{quote_string(client_message_id)}
    """)
    |> List.first()
  end

  @doc """
  Waits until the turn for `client_message_id` reaches a terminal status.

  Terminal is the wire's own set (delivered | canceled | failed |
  failed_unknown); returns the row, or `{:error, :timeout, last_row}` so a
  failure report can say what the turn was doing when time ran out instead of
  just "timed out".
  """
  @spec await_turn_terminal(base_dir(), String.t(), timeout()) ::
          {:ok, map()} | {:error, :timeout, map() | nil}
  def await_turn_terminal(base_dir, client_message_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_turn_terminal(base_dir, client_message_id, deadline, nil)
  end

  defp await_turn_terminal(base_dir, client_message_id, deadline, last) do
    row = turn_for_client_message(base_dir, client_message_id)

    cond do
      is_map(row) and row["status"] in ~w(delivered canceled failed failed_unknown) ->
        {:ok, row}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout, row || last}

      true ->
        Process.sleep(200)
        await_turn_terminal(base_dir, client_message_id, deadline, row || last)
    end
  end

  @doc "Turn rows for a session in enqueue order."
  @spec turns_for_session(base_dir(), String.t()) :: [map()]
  def turns_for_session(base_dir, session_key) do
    query(base_dir, """
    SELECT t.seq, t.status, t.prompt, m.clientMessageId AS clientMessageId
    FROM turns t LEFT JOIN messages m ON m.id = t.messageId
    WHERE t.sessionKey = #{quote_string(session_key)}
    ORDER BY t.seq
    """)
  end

  @doc "How many turns are `running` right now, per session key."
  @spec running_by_session(base_dir()) :: %{String.t() => non_neg_integer()}
  def running_by_session(base_dir) do
    base_dir
    |> query("SELECT sessionKey, COUNT(*) AS n FROM turns WHERE status = 'running' GROUP BY sessionKey")
    |> Map.new(&{&1["sessionKey"], &1["n"]})
  end

  @doc "The sessions row, or nil."
  @spec session(base_dir(), String.t()) :: map() | nil
  def session(base_dir, session_key) do
    base_dir
    |> query("""
    SELECT sessionKey, displayName, kind, ownerUserId, origin, state, harness, model, host
    FROM sessions WHERE sessionKey = #{quote_string(session_key)}
    """)
    |> List.first()
  end

  @doc "Messages for a session in stream order (the transcript the client replays)."
  @spec messages(base_dir(), String.t()) :: [map()]
  def messages(base_dir, session_key) do
    query(base_dir, """
    SELECT seq, id, role, content, sender, clientMessageId, replyToClientMessageId
    FROM messages WHERE sessionKey = #{quote_string(session_key)} ORDER BY seq
    """)
  end

  @doc "Device rows — J0's `allowlisted` device check."
  @spec devices(base_dir()) :: [map()]
  def devices(base_dir) do
    query(base_dir, "SELECT deviceId, userId, status, claimedName FROM devices ORDER BY rowid")
  end

  @doc "User rows — J0's admin-bootstrap check."
  @spec users(base_dir()) :: [map()]
  def users(base_dir) do
    query(base_dir, "SELECT userId, isAdmin FROM users ORDER BY rowid")
  end

  @doc """
  Samples `running_by_session/1` on an interval while `task` runs, returning
  `{task_result, peak_by_session}`.

  J4 ("never more than one running for the session") and J5 ("at peak, two
  running rows with DIFFERENT sessionKeys") are both statements about a peak
  that exists only DURING the turns. Reading the table afterwards proves
  nothing about either, so the driver watches while the work happens.
  """
  @spec sample_while(base_dir(), non_neg_integer(), (-> result)) ::
          {result, %{String.t() => non_neg_integer()}}
        when result: term()
  def sample_while(base_dir, interval_ms, task) do
    owner = self()
    ref = make_ref()

    sampler =
      spawn_link(fn ->
        peaks = sample_loop(base_dir, interval_ms, %{}, owner)
        send(owner, {ref, peaks})
      end)

    result =
      try do
        task.()
      after
        send(sampler, {:stop, self()})
      end

    peaks =
      receive do
        {^ref, peaks} -> peaks
      after
        interval_ms * 4 + 1_000 -> %{}
      end

    {result, peaks}
  end

  defp sample_loop(base_dir, interval_ms, peaks, owner) do
    peaks = Map.merge(peaks, running_by_session(base_dir), fn _key, a, b -> max(a, b) end)

    receive do
      {:stop, ^owner} -> Map.merge(peaks, running_by_session(base_dir), fn _k, a, b -> max(a, b) end)
    after
      interval_ms -> sample_loop(base_dir, interval_ms, peaks, owner)
    end
  end

  defp quote_string(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
