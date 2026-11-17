defmodule Tightbeam.PathNotes do
  @moduledoc """
  Presence notes for file paths that a delivered turn hands on to its
  receiving session.

  When a prompt turn is delivered, each distinct handed-on path in its text gets
  one line after the text saying whether a stat of that path succeeded on the
  receiving session's host (or on the host a `host:/path` token names). The
  check never holds the delivery: checks start when the turn is enqueued (and
  again, for anything not yet started, when its lane claims it), run in their
  own processes, and whatever has not returned when the turn is sent is reported
  as still running. There is deliberately no timeout and no wait.

  User-authored chat posts get no notes, including chat members of a batched
  delivery. The authored turn and wake rows are never rewritten; notes are added
  only to the text handed to the harness.

  This module is also the one place that recognizes handed-on paths, so
  `check-attest` uses the same definition for paths written in an attest note.
  """

  use GenServer
  require Logger

  alias Tightbeam.{AttestFileCheck, DB, Placement, Wakes}
  alias Tightbeam.DB.Txn

  @table __MODULE__

  # A quote, then text that starts like a path, then the same quote. Requiring
  # the path start right after the quote keeps apostrophes in prose ("it's")
  # from pairing with a later quote.
  @quoted ~r/(["'`])((?:\/|~\/|[^\s"'`\/:]+:\/)[^\n]*?)\1/
  @host_path ~r/^([^\/:\s]+):(\/.*)$/s
  @token ~r/\S+/u
  @leading_brackets ["(", "[", "{", "<"]
  @trailing_punctuation [".", ",", ";", ":", ")", "]", "}", ">"]

  # ---------------------------------------------------------------------------
  # Recognizing handed-on paths

  @doc """
  The distinct handed-on paths in `text`, in order of first appearance.

  Each entry is `%{display: as_handed_on, host: named_host_or_nil, path: path}`.
  `host` is set only for a `host:/path` token whose host is in `host_names`;
  otherwise the path is meant for the receiving (or filing) session's host.
  With `home: false`, `~/` paths are not returned.
  """
  @spec handed_on_paths(String.t(), [String.t()], keyword()) :: [map()]
  def handed_on_paths(text, host_names, opts \\ []) when is_binary(text) do
    home? = Keyword.get(opts, :home, true)
    hosts = MapSet.new(host_names)
    quoted = quoted_paths(text, hosts, home?, 0, [])

    # Quoted paths are taken whole, so their spans are blanked before the
    # whitespace tokenizer runs; byte positions stay aligned for ordering.
    masked =
      Enum.reduce(quoted, text, fn {start, length, _path}, acc ->
        binary_part(acc, 0, start) <>
          String.duplicate(" ", length) <>
          binary_part(acc, start + length, byte_size(acc) - start - length)
      end)

    unquoted =
      @token
      |> Regex.scan(masked, return: :index)
      |> Enum.flat_map(fn [{start, length}] ->
        token = masked |> binary_part(start, length) |> strip_token()

        case classify(token, hosts, home?) do
          nil -> []
          path -> [{start, length, path}]
        end
      end)

    (quoted ++ unquoted)
    |> Enum.sort_by(fn {start, _length, _path} -> start end)
    |> Enum.map(fn {_start, _length, path} -> path end)
    |> Enum.uniq_by(& &1.display)
  end

  defp quoted_paths(text, hosts, home?, offset, acc) do
    case Regex.run(@quoted, text, return: :index, offset: offset) do
      nil ->
        Enum.reverse(acc)

      [{start, length}, _quote, {content_start, content_length}] ->
        content = binary_part(text, content_start, content_length)

        case classify(content, hosts, home?) do
          nil -> quoted_paths(text, hosts, home?, start + 1, acc)
          path -> quoted_paths(text, hosts, home?, start + length, [{start, length, path} | acc])
        end
    end
  end

  defp classify(candidate, hosts, home?) do
    cond do
      candidate == "" or String.starts_with?(candidate, "//") ->
        nil

      String.starts_with?(candidate, "/") ->
        %{display: candidate, host: nil, path: candidate}

      String.starts_with?(candidate, "~/") ->
        if home?, do: %{display: candidate, host: nil, path: candidate}

      true ->
        case Regex.run(@host_path, candidate) do
          [_, host, path] ->
            if MapSet.member?(hosts, host) and not String.starts_with?(path, "//"),
              do: %{display: candidate, host: host, path: path}

          nil ->
            nil
        end
    end
  end

  defp strip_token(token), do: token |> strip_leading() |> strip_trailing()

  defp strip_leading(<<char::binary-size(1), rest::binary>>) when char in @leading_brackets,
    do: strip_leading(rest)

  defp strip_leading(token), do: token

  defp strip_trailing(""), do: ""

  defp strip_trailing(token) do
    last = binary_part(token, byte_size(token) - 1, 1)

    if last in @trailing_punctuation,
      do: strip_trailing(binary_part(token, 0, byte_size(token) - 1)),
      else: token
  end

  # ---------------------------------------------------------------------------
  # Note wording (spec R6)

  @doc "The path note for one checked path."
  @spec note(String.t(), :running | map()) :: String.t()
  def note(display, %{status: "present"}), do: "verified present at #{display}"

  def note(display, %{status: "absent"}),
    do: "not found at #{display}; check before relying on it"

  def note(display, %{status: "could_not_access", error: error}),
    do: "could not check #{display}: #{one_line(error)}; check before relying on it"

  def note(display, :running),
    do: "could not check #{display}: check still running; check before relying on it"

  # A note is one line. The system error is passed through as reported; only
  # its surrounding whitespace and line breaks are flattened.
  defp one_line(error) do
    error
    |> to_string()
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  @doc "Add notes after delivered content, separated by a blank line."
  @spec append(String.t() | [map()], [String.t()]) :: String.t() | [map()]
  def append(content, []), do: content

  def append(content, notes) when is_binary(content),
    do: content <> "\n\n" <> Enum.join(notes, "\n")

  def append(blocks, notes) when is_list(blocks),
    do: blocks ++ [%{type: "text", text: Enum.join(notes, "\n")}]

  # ---------------------------------------------------------------------------
  # Delivery

  @doc """
  Plan the checks for a turn about to be delivered, and start any not already
  running. Called by the turn runner when its lane claims the turn. Returns the
  plan `notes/1` reads at send time, or nil when the turn hands on no path.
  """
  @spec claimed(DB.server(), map(), GenServer.server()) :: map() | nil
  def claimed(db, turn, server \\ __MODULE__) do
    case plan(db_query(db), turn) do
      nil ->
        nil

      plan ->
        GenServer.cast(server, {:start, plan, :claimed})
        plan
    end
  rescue
    error ->
      Logger.error(
        "path notes could not be planned for turn #{turn.seq}: #{Exception.message(error)}"
      )

      nil
  end

  @doc """
  The notes for a planned turn, from whatever checks have returned by now.
  Never waits.
  """
  @spec notes(map() | nil, GenServer.server()) :: [String.t()]
  def notes(plan, server \\ __MODULE__)
  def notes(nil, _server), do: []

  def notes(plan, server) do
    notes =
      Enum.map(plan.paths, fn entry ->
        note(entry.display, result(check_key(plan, entry)))
      end)

    GenServer.cast(server, {:forget, plan.seq})
    notes
  end

  @doc "Add the plan's notes to prepared turn content."
  def annotate(%{content: content} = prepared, plan, server \\ __MODULE__) do
    %{prepared | content: append(content, notes(plan, server))}
  rescue
    error ->
      Logger.error("path notes could not be added: #{Exception.message(error)}")
      prepared
  end

  defp result(key) do
    case :ets.whereis(@table) do
      :undefined ->
        :running

      _table ->
        case :ets.lookup(@table, key) do
          [{^key, {:done, result}}] -> result
          _ -> :running
        end
    end
  end

  @doc """
  Start checks for a turn as soon as its row is committed. Queues a handoff
  that runs only if the enqueue commits; the enqueue itself does no extra work.
  """
  @spec enqueued_in_txn(Txn.t(), integer()) :: :ok
  def enqueued_in_txn(%Txn{outbox: token, outbox_owner: owner} = txn, seq)
      when is_reference(token) and owner == self() do
    Txn.handoff(txn, __MODULE__, {:enqueued, seq})
  end

  def enqueued_in_txn(%Txn{}, _seq), do: :ok

  @doc false
  def plan(q, turn) do
    with text when is_binary(text) <- scannable_text(q, turn),
         hosts = host_routes(q),
         [_ | _] = paths <- handed_on_paths(text, Map.keys(hosts)) do
      receiving =
        case q.("SELECT host FROM sessions WHERE sessionKey=?1", [turn.session_key]) do
          [[host]] -> host
          [] -> nil
        end

      %{
        seq: turn.seq,
        session_key: turn.session_key,
        paths:
          Enum.map(paths, fn path ->
            checked_host = path.host || receiving

            path
            |> Map.put(:checked_host, checked_host)
            |> Map.put(:route, route(hosts, checked_host))
          end)
      }
    else
      _ -> nil
    end
  end

  @doc false
  # The configured placement hosts and how to reach each one, read the way
  # `Placement.hosts/2` builds them: the local host is always local.
  def host_routes(q) do
    q.("SELECT name, ssh FROM hosts", [])
    |> Map.new(fn [name, ssh] -> {name, %{ssh: ssh}} end)
    |> Map.put(Placement.local_host_name(), %{ssh: nil})
  end

  defp route(_hosts, nil), do: {:error, "no host is recorded for the receiving session"}

  defp route(hosts, host) do
    case Map.fetch(hosts, host) do
      {:ok, route} -> {:ok, route}
      :error -> {:error, "unknown host: #{host}"}
    end
  end

  # The delivered text that is not user-authored chat. A chat post is a message
  # a client posted, so it carries that client's message identity; a wake or
  # brief a user sends through a verb does not, and is checked like any other.
  defp scannable_text(q, %{wake_id: "w_nb_" <> _ = wake_id, prompt: prompt}) do
    members =
      q.(
        """
        SELECT m.sourceWakeId, m.senderPrincipal, m.publicationSeq,
               w.sourceClientIdentity IS NOT NULL
        FROM notice_batches b
        JOIN notice_batch_members m ON m.batchId=b.batchId
        JOIN wakes w ON w.wakeId=m.sourceWakeId
        WHERE b.deliveryWakeId=?1 AND m.state='included'
        """,
        [wake_id]
      )

    without_chat_members(prompt, members)
  end

  defp scannable_text(q, %{message_id: message_id, prompt: prompt}) do
    case q.("SELECT clientMessageId FROM messages WHERE id=?1", [message_id]) do
      [[client_message_id]] when is_binary(client_message_id) -> nil
      _ -> prompt
    end
  end

  # A batched delivery renders each member under its own header line. Drop the
  # segments of chat members; keep the envelope and everything else.
  defp without_chat_members(prompt, members) do
    starts =
      members
      |> Enum.flat_map(fn [source, sender, seq, chat] ->
        case :binary.match(prompt, "[#{seq}] source=#{source} sender=#{sender} ") do
          {start, _} -> [{start, chat == 1}]
          :nomatch -> []
        end
      end)
      |> Enum.sort()

    member_end =
      case :binary.matches(prompt, "\n\n" <> Wakes.digest_signature(length(members))) do
        [] -> byte_size(prompt)
        matches -> matches |> List.last() |> elem(0)
      end

    case starts do
      [] ->
        prompt

      [{first, _} | _] ->
        ends = Enum.map(tl(starts), &elem(&1, 0)) ++ [member_end]

        kept =
          starts
          |> Enum.zip(ends)
          |> Enum.reject(fn {{_start, chat?}, _end} -> chat? end)
          |> Enum.map(fn {{start, _chat?}, stop} -> binary_part(prompt, start, stop - start) end)

        Enum.join(
          [binary_part(prompt, 0, first) | kept] ++
            [binary_part(prompt, member_end, byte_size(prompt) - member_end)],
          "\n"
        )
    end
  end

  defp db_query(db) do
    fn sql, params ->
      {:ok, rows} = DB.query(db, sql, params)
      rows
    end
  end

  defp check_key(plan, entry), do: {plan.seq, entry.checked_host, entry.path}

  # ---------------------------------------------------------------------------
  # Check server: owns the results table and the check processes.

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    {:ok,
     %{
       db: Keyword.fetch!(opts, :db),
       stat_config: Keyword.get(opts, :stat_config, %{}),
       tracked: %{}
     }}
  end

  @impl true
  def handle_cast({:enqueued, seq}, state) do
    turn =
      case DB.query(
             state.db,
             "SELECT sessionKey, messageId, prompt, wakeId FROM turns WHERE seq=?1 AND status='queued'",
             [seq]
           ) do
        {:ok, [[session_key, message_id, prompt, wake_id]]} ->
          %{
            seq: seq,
            session_key: session_key,
            message_id: message_id,
            prompt: prompt,
            wake_id: wake_id
          }

        _ ->
          nil
      end

    case turn && plan(db_query(state.db), turn) do
      nil -> {:noreply, state}
      plan -> {:noreply, start(state, plan)}
    end
  rescue
    error ->
      Logger.error(
        "path checks for enqueued turn #{seq} not started: #{Exception.message(error)}"
      )

      {:noreply, state}
  end

  def handle_cast({:start, plan, :claimed}, state) do
    # A session runs one turn at a time in seq order, so once a later turn is
    # claimed no earlier turn of that session will read its notes.
    stale =
      for {seq, session_key} <- state.tracked,
          session_key == plan.session_key and seq < plan.seq,
          do: seq

    state = Enum.reduce(stale, state, &forget(&2, &1))
    {:noreply, start(state, plan)}
  end

  def handle_cast({:forget, seq}, state), do: {:noreply, forget(state, seq)}

  @impl true
  def handle_info({:checked, {seq, _host, _path} = key, result}, state) do
    if Map.has_key?(state.tracked, seq), do: :ets.insert(@table, {key, {:done, result}})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start(state, plan) do
    server = self()

    Enum.each(plan.paths, fn entry ->
      key = check_key(plan, entry)

      if :ets.insert_new(@table, {key, :running}) do
        stat_config = state.stat_config
        spawn(fn -> send(server, {:checked, key, check(entry, stat_config)}) end)
      end
    end)

    %{state | tracked: Map.put(state.tracked, plan.seq, plan.session_key)}
  end

  defp check(%{route: {:error, reason}}, _config),
    do: %{status: "could_not_access", error: reason}

  defp check(%{route: {:ok, route}, path: path}, config) do
    AttestFileCheck.stat(route, path, config)
  rescue
    error -> %{status: "could_not_access", error: Exception.message(error)}
  end

  defp forget(state, seq) do
    :ets.match_delete(@table, {{seq, :_, :_}, :_})
    %{state | tracked: Map.delete(state.tracked, seq)}
  end
end
