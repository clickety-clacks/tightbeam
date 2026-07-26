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
    SELECT t.seq, t.sessionKey, t.status, t.origin, t.error, t.createdAt, t.startedAt, t.endedAt
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

  @doc "The session's latest harness pointer — J7 reads its `reason` (loaded vs fallback)."
  @spec harness_pointer(base_dir(), String.t()) :: map() | nil
  def harness_pointer(base_dir, session_key) do
    base_dir
    |> query("""
    SELECT reason, harnessSessionId, harness, machine
    FROM harness_pointers WHERE sessionKey = #{quote_string(session_key)}
    ORDER BY id DESC LIMIT 1
    """)
    |> List.first()
  end

  @doc "The turn row a wake-delivered message produced, by that message's id."
  @spec turn_for_wake(base_dir(), String.t()) :: map() | nil
  def turn_for_wake(base_dir, message_id) do
    base_dir
    |> query("""
    SELECT seq, status, wakeId, origin, error
    FROM turns WHERE messageId = #{quote_string(message_id)}
    """)
    |> List.first()
  end

  @doc """
  The turn row a specific wake produced, by wakeId — the only correlation that
  cannot stitch one wake's delivery to another's evidence.
  """
  @spec turn_by_wake_id(base_dir(), String.t()) :: map() | nil
  def turn_by_wake_id(base_dir, wake_id) do
    base_dir
    |> query("""
    SELECT seq, status, wakeId, messageId, origin, error
    FROM turns WHERE wakeId = #{quote_string(wake_id)}
    """)
    |> List.first()
  end

  @doc """
  Waits for a wake's turn row to appear and reach a terminal status, returning
  the row (or the last seen shape) so a failure can name what it was doing.
  """
  @spec await_wake_turn(base_dir(), String.t(), timeout()) :: map() | nil
  def await_wake_turn(base_dir, wake_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_wake_turn(base_dir, wake_id, deadline, nil)
  end

  defp poll_wake_turn(base_dir, wake_id, deadline, last) do
    row = turn_by_wake_id(base_dir, wake_id)

    cond do
      is_map(row) and row["status"] in ~w(delivered canceled failed failed_unknown) -> row
      System.monotonic_time(:millisecond) >= deadline -> row || last
      true ->
        Process.sleep(200)
        poll_wake_turn(base_dir, wake_id, deadline, row || last)
    end
  end

  @doc "Wake rows still pending — J8 asserts a scheduled wake is visible before it fires."
  @spec pending_wakes(base_dir()) :: [map()]
  def pending_wakes(base_dir) do
    query(
      base_dir,
      "SELECT wakeId, sessionKey, state, dueAt, prompt FROM wakes WHERE state = 'pending' ORDER BY dueAt"
    )
  end

  @doc """
  The org's CLI bearer token from `<base_dir>/gateway.json` — the credential
  `tb` itself uses, so the driver's wake goes through the same facade an
  operator would.
  """
  @spec cli_token(base_dir()) :: {:ok, String.t()} | {:error, term()}
  def cli_token(base_dir) do
    path = Path.join(base_dir, "gateway.json")

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"cliToken" => token}} when is_binary(token) <- JSON.decode(bytes) do
      {:ok, token}
    else
      {:error, reason} -> {:error, {:no_cli_token, path, reason}}
      other -> {:error, {:no_cli_token, path, other}}
    end
  end

  @doc """
  Samples the running set on an interval while `task` runs, returning
  `{task_result, samples}` where each sample is a map of session key => number
  of turns running for it AT THAT INSTANT.

  Per-sample observations, not per-session maxima. A maximum per session, merged
  across different samples, cannot distinguish "both lanes ran at once" from
  "one ran, finished, then the other ran" — it would report sequential execution
  as concurrency, the one thing J5 exists to disprove. Counts rather than sets
  because J4 asks a different question of the same samples: never more than one
  turn running for ONE session.
  """
  @spec sample_while(base_dir(), non_neg_integer(), (-> result)) ::
          {result, [%{String.t() => non_neg_integer()}]}
        when result: term()
  def sample_while(base_dir, interval_ms, task) do
    owner = self()
    ref = make_ref()

    sampler =
      spawn_link(fn ->
        send(owner, {ref, sample_loop(base_dir, interval_ms, [], owner)})
      end)

    result =
      try do
        task.()
      after
        send(sampler, {:stop, self()})
      end

    samples =
      receive do
        {^ref, samples} -> samples
      after
        interval_ms * 4 + 1_000 -> []
      end

    {result, samples}
  end

  @doc """
  True when SOME SINGLE sample caught every one of `session_keys` running at
  the same instant — the simultaneous-lane witness J5 asserts.
  """
  @spec simultaneous?([%{String.t() => non_neg_integer()}], [String.t()]) :: boolean()
  def simultaneous?(samples, session_keys) do
    Enum.any?(samples, fn sample ->
      Enum.all?(session_keys, &(Map.get(sample, &1, 0) > 0))
    end)
  end

  @doc "The largest number of DISTINCT sessions seen running in any one sample."
  @spec widest_sample([%{String.t() => non_neg_integer()}]) :: non_neg_integer()
  def widest_sample(samples), do: samples |> Enum.map(&map_size/1) |> Enum.max(fn -> 0 end)

  @doc """
  The most turns seen running for ONE session in any single sample — J4's
  strict-order witness ("never more than one `running` for the session").
  """
  @spec busiest_lane([%{String.t() => non_neg_integer()}], String.t()) :: non_neg_integer()
  def busiest_lane(samples, session_key) do
    samples |> Enum.map(&Map.get(&1, session_key, 0)) |> Enum.max(fn -> 0 end)
  end

  @doc """
  Whether two turn rows overlapped in wall-clock time, from their own
  `startedAt`/`endedAt` — deterministic simultaneous evidence that does not
  depend on catching them with a sampler.

  Two corrections a probe caught in the first version:

  - Boundaries are STRICT. One turn ending on the same millisecond another
    begins is a hand-off, not an overlap, and millisecond resolution makes that
    a real outcome rather than a curiosity.
  - A row with no `endedAt` is STILL RUNNING, so its interval extends to now,
    not to its own start. Collapsing it to a point meant an in-flight turn
    could never be seen overlapping anything.
  """
  @spec turns_overlapped?(map() | nil, map() | nil) :: boolean()
  def turns_overlapped?(a, b) do
    with {:ok, a_start, a_end} <- interval(a),
         {:ok, b_start, b_end} <- interval(b) do
      a_start < b_end and b_start < a_end
    else
      _ -> false
    end
  end

  defp interval(%{"startedAt" => start} = row) when is_integer(start) do
    case row["endedAt"] do
      finish when is_integer(finish) -> {:ok, start, finish}
      _ -> {:ok, start, System.system_time(:millisecond)}
    end
  end

  defp interval(_), do: :error

  defp sample_loop(base_dir, interval_ms, samples, owner) do
    sample = running_by_session(base_dir)

    receive do
      {:stop, ^owner} -> Enum.reverse([running_by_session(base_dir), sample | samples])
    after
      interval_ms -> sample_loop(base_dir, interval_ms, [sample | samples], owner)
    end
  end

  defp quote_string(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
