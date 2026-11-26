defmodule Tightbeam.HarklightBounces do
  @moduledoc """
  Hears Harklight bounce advisories and wakes the agent they bounce to.

  A bounce reaches Tightbeam two ways and both end in `process_in_txn/3`, which
  is keyed by the advisory's own ID, so each advisory wakes once however often
  and by whichever route it is seen:

    * the feed (`capture_frames_in_txn/3`): an `advisory` record is captured in
      the same transaction as its wake and the feed checkpoint;
    * a read of sent messages (`read_pass/2`): at gateway start and at a slow
      interval, undelivered advisories are taken. This recovers bounces a
      checkpoint skipped and is how bounces on ended conversations are heard.
      The read marks nothing Delivered and reopens nothing.

  A wake's delivery is acknowledged to Harklight (`advisory-ack`) only after the
  wake is committed, from a durable row, and retried until Harklight confirms it
  or the notice turns out to be moot or delivered. A notice that is moot, or on
  an item that has ended, is recorded and never acknowledged. Only messages
  Tightbeam itself sent (its own request records) are handled; the rest, and
  every advisory type other than the bounce types, are left alone. Nothing here
  resends a message.
  """

  use GenServer
  require Logger

  alias Tightbeam.{DB, HarklightItemIds, HarklightSend, Id, Org, Placement, Supervision, Wakes}
  alias Tightbeam.DB.Txn

  # One wake carries at most this many bounces. A longer list is several wakes
  # due together, which the recipient's batch delivers as one turn.
  @chunk 40
  @ack_delays [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 64_000, 128_000, 300_000]
  @read_interval 900_000
  @max_title 120

  # The title comes from Tightbeam's own saved send, never from a lookup.
  @registration_sql """
  SELECT r.handle,r.senderId,r.messageId,h.sessionKey,h.host,
         CASE WHEN json_valid(o.payload) THEN json_extract(o.payload,'$.request.message.title') END,
         COALESCE(h.currentReceiverSessionKey,h.sessionKey)
  FROM harklight_wake_requests r
  JOIN harklight_wake_handles h ON h.handle=r.handle
  LEFT JOIN harklight_send_operations o
    ON o.senderId=r.senderId AND o.messageId=r.messageId AND o.state='bound'
  """

  def ensure_schema(db) do
    DB.execute(db, """
    CREATE TABLE IF NOT EXISTS harklight_bounces (
      advisoryId TEXT PRIMARY KEY,
      itemId TEXT NOT NULL,
      handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
      advisoryType TEXT NOT NULL,
      outcome TEXT NOT NULL CHECK(outcome IN ('woken','closed')),
      recipient TEXT REFERENCES sessions(sessionKey),
      wakeId TEXT REFERENCES wakes(wakeId),
      capturedAt INTEGER NOT NULL,
      ackOpId TEXT NOT NULL UNIQUE,
      ackJournalId TEXT,
      ackCompletedAt INTEGER,
      ackOutcome TEXT CHECK(ackOutcome IN ('acknowledged','gone','moot','delivered','not_owed')),
      CHECK ((outcome='woken' AND recipient IS NOT NULL AND wakeId IS NOT NULL)
          OR (outcome='closed' AND recipient IS NULL AND wakeId IS NULL)),
      CHECK ((ackCompletedAt IS NULL AND ackOutcome IS NULL)
          OR (ackCompletedAt IS NOT NULL AND ackOutcome IS NOT NULL))
    );
    CREATE INDEX IF NOT EXISTS harklight_bounces_owed
      ON harklight_bounces(capturedAt,advisoryId) WHERE ackCompletedAt IS NULL;
    """)
  end

  ## The kind decision. This is the only place that says what a bounce means.

  @doc """
  What an advisory is. The list of types Tightbeam acts on lives here and
  nowhere else; every other type, `possible_contradictions` included, is
  `:ignore`: no wake, no record, no acknowledgment.

    * `:full`: the message had not been opened when it bounced
      (`unseen_interval_elapsed`, current and historical, and `full_bounce`).
    * `:soft`: it had been opened but not acted on by then (`soft_bounce`).
  """
  def kind(%{"advisory_type" => type}) when type in ["unseen_interval_elapsed", "full_bounce"],
    do: :full

  def kind(%{"advisory_type" => "soft_bounce"}), do: :soft
  def kind(_), do: :ignore

  ## Feed path

  @doc """
  Capture the advisory records of one feed batch inside the batch's own
  transaction. Frames that are not advisories are untouched. The message an
  advisory concerns is the one in the same batch, when there is one; nothing is
  looked up here, so the listener is never held. A record that cannot be placed
  is left for the read path.
  """
  def capture_frames_in_txn(%Txn{} = txn, handle, frames) when is_list(frames) do
    messages =
      Map.new(
        for %{"kind" => "message", "data" => %{"item_id" => id} = data} <- frames, do: {id, data}
      )

    candidates =
      for %{"kind" => "advisory", "data" => %{"item_id" => id, "advisory" => advisory}} <-
            frames,
          is_binary(id),
          is_map(advisory) do
        %{advisory: advisory, item: messages[id], item_id: id, handle: handle}
      end

    if candidates != [], do: process_in_txn(txn, candidates, :feed)
    :ok
  end

  @doc """
  Tell the worker a feed batch committed, so its acknowledgments go out now and
  not at the next read.
  """
  def captured(frames) do
    pid = Process.whereis(__MODULE__)

    if pid && Enum.any?(frames, &match?(%{"kind" => "advisory"}, &1)),
      do: GenServer.cast(pid, :ack_requested)

    :ok
  end

  ## The shared handler

  @doc """
  Handle candidates `%{advisory:, item:, item_id:, handle:}` in one transaction.
  `item` is the message when the route has it (a read always does). Returns a
  summary. An advisory already recorded is skipped, so every route agrees on one
  wake per advisory ID.
  """
  def process_in_txn(%Txn{} = txn, candidates, source) when source in [:feed, :read] do
    now = System.system_time(:millisecond)

    settle_owed_in_txn(txn, candidates)

    checked =
      for candidate <- candidates,
          bounce?(candidate),
          reduce: {[], MapSet.new()} do
        {acc, seen} ->
          id = candidate.advisory["advisory_id"]

          if MapSet.member?(seen, id) or recorded?(txn, id),
            do: {acc, seen},
            else: {[{candidate, registration(txn, candidate)} | acc], MapSet.put(seen, id)}
      end
      |> elem(0)
      |> Enum.reverse()

    decided = for {candidate, {:ok, reg}} <- checked, do: Map.put(candidate, :reg, reg)

    # Open bounces on messages Tightbeam did not send: counted, never touched.
    left_alone =
      for {%{item: item} = candidate, :foreign} <- checked,
          is_map(item),
          not ended?(item, candidate.advisory) do
        candidate.advisory["advisory_id"]
      end

    # Moot (the person answered, saw, retracted, revised or let it expire) or a
    # real terminal: nothing to wake. Closing the item in the inbox is not one.
    {closed, open} = Enum.split_with(decided, &ended?(&1.item, &1.advisory))

    routed = for candidate <- open, do: {candidate, recipient_in_txn(txn, candidate.reg)}
    unroutable = for {candidate, :none} <- routed, do: candidate

    open =
      for {candidate, {:ok, recipient}} <- routed, do: Map.put(candidate, :recipient, recipient)

    Enum.each(unroutable, fn candidate ->
      Logger.warning(
        "Harklight bounce #{candidate.advisory["advisory_id"]} has no active session to wake for conversation #{candidate.reg.handle}; it stays unacknowledged"
      )
    end)

    # Closed rows are never acknowledged: Harklight answers an acknowledgment of
    # a moot notice with moot and not delivered, which the Agent reports as an
    # error, and the row already keeps a second wake from happening.
    Enum.each(closed, &record(txn, &1, "closed", nil, nil, now))

    woken =
      open
      |> Enum.group_by(& &1.recipient)
      |> Enum.sort_by(fn {recipient, _} -> recipient end)
      |> Enum.flat_map(fn {recipient, entries} ->
        entries
        |> Enum.sort_by(&{&1.reg.handle, &1.reg.message_id, &1.advisory["advisory_id"]})
        |> Enum.chunk_every(@chunk)
        |> Enum.flat_map(&wake_chunk(txn, recipient, &1, now))
      end)

    %{
      woken: woken,
      closed: Enum.map(closed, & &1.advisory["advisory_id"]),
      unroutable: Enum.map(unroutable, & &1.advisory["advisory_id"]),
      left_alone_open: left_alone
    }
  end

  # A woken advisory seen moot or delivered before its acknowledgment went out
  # needs none: Harklight settles a moot notice without one.
  defp settle_owed_in_txn(txn, candidates) do
    now = System.system_time(:millisecond)

    for %{advisory: %{"advisory_id" => id} = advisory} <- candidates,
        is_binary(id),
        kind(advisory) != :ignore,
        outcome =
          if(advisory["moot"] == true,
            do: "moot",
            else: if(advisory["delivered"] == true, do: "delivered")
          ),
        do:
          Txn.q(
            txn,
            "UPDATE harklight_bounces SET ackCompletedAt=?2,ackOutcome=?3 WHERE advisoryId=?1 AND ackCompletedAt IS NULL",
            [id, now, outcome]
          )

    :ok
  end

  defp ended?(item, advisory),
    do: advisory["moot"] == true or (is_map(item) and not is_nil(item["terminal"]))

  defp bounce?(%{advisory: %{"advisory_id" => id} = advisory}) when is_binary(id) and id != "",
    do: kind(advisory) != :ignore and advisory["delivered"] != true

  defp bounce?(_), do: false

  defp recorded?(txn, advisory_id),
    do: Txn.q(txn, "SELECT 1 FROM harklight_bounces WHERE advisoryId=?1", [advisory_id]) != []

  # Only a message Tightbeam sent (its own request record) on a conversation of
  # this host: `:foreign` is not ours, `:elsewhere` is ours but another host's.
  # A live advisory can resolve a migrated item through the saved binding.
  # In compatibility mode, migrated items are resolved on the read path.
  defp registration(txn, candidate) do
    item = candidate.item || %{}

    direct =
      Txn.q(txn, @registration_sql <> " WHERE r.messageId=?1", [candidate.item_id])
      |> Enum.filter(fn [_, sender | _] -> is_nil(item["sender"]) or sender == item["sender"] end)

    rows =
      if HarklightItemIds.enabled?() do
        case {direct, HarklightItemIds.migrated_in_txn(txn, candidate.item_id)} do
          {[], {:ok, handle, sender, message_id}} ->
            Txn.q(txn, @registration_sql <> " WHERE r.handle=?1 AND r.senderId=?2 AND r.messageId=?3", [
              handle,
              sender,
              message_id
            ])
            |> Enum.filter(fn [_, sender | _] -> is_nil(item["sender"]) or sender == item["sender"] end)

          {rows, _} ->
            rows
        end
      else
        legacy_registration(txn, direct, item)
      end

    case rows do
      [[handle, _sender, message_id, origin, host, title, receiver]] ->
        cond do
          candidate.handle not in [nil, handle] or item["session"] not in [nil, handle] ->
            :foreign

          host != Placement.local_host_name() ->
            :elsewhere

          true ->
            {:ok,
             %{
               handle: handle,
               message_id: message_id,
               origin: origin,
               title: title,
               receiver: receiver
             }}
        end

      _ ->
        :foreign
    end
  end

  defp legacy_registration(txn, direct, item) do
    case {direct, item["legacy_message_id"], item["sender"]} do
      {[], legacy, sender} when is_binary(legacy) and is_binary(sender) ->
        Txn.q(txn, @registration_sql <> " WHERE r.senderId=?1 AND r.messageId=?2", [
          sender,
          legacy
        ])

      {rows, _, _} ->
        rows
    end
  end

  # The conversation's receiver, or the sender when none is recorded. When that
  # session is retired or missing, its nearest active parent; the ladder ends at
  # the owner's Main when no record, no parent or a loop leaves none. A
  # retirement successor chosen for chat routing plays no part here.
  defp recipient_in_txn(txn, reg) do
    case Org.get_in_txn(txn, reg.receiver) do
      %{state: "active"} ->
        {:ok, reg.receiver}

      _ ->
        target = Supervision.ladder_target(txn, reg.receiver, 1) || owner_main(txn, reg.origin)

        case target && Org.get_in_txn(txn, target) do
          %{state: "active"} -> {:ok, target}
          _ -> :none
        end
    end
  end

  defp owner_main(txn, session_key) do
    case Org.get_in_txn(txn, session_key) do
      %{owner_user_id: owner} when is_binary(owner) -> Org.personal_session_key(owner)
      _ -> nil
    end
  end

  defp wake_chunk(txn, recipient, entries, now) do
    ids = Enum.map(entries, & &1.advisory["advisory_id"])
    digest = :crypto.hash(:sha256, Enum.join([recipient | Enum.sort(ids)], "\n"))
    wake_id = "w_harklight_bounce_" <> binary_part(Base.encode16(digest, case: :lower), 0, 40)

    wake =
      Wakes.schedule_in_txn(txn, %{
        wake_id: wake_id,
        session_key: recipient,
        origin: "process:tightbeam",
        prompt: prompt(txn, recipient, entries),
        due_at: now,
        creator_session_key: hd(entries).reg.origin,
        class: "input-needed"
      })

    Wakes.publish_change_in_txn(txn, "wake.scheduled", wake.wake_id)
    Enum.each(entries, &record(txn, &1, "woken", recipient, wake.wake_id, now))
    ids
  end

  defp record(txn, candidate, outcome, recipient, wake_id, now) do
    advisory = candidate.advisory
    owed? = outcome == "woken"

    Txn.q(
      txn,
      """
      INSERT INTO harklight_bounces(advisoryId,itemId,handle,advisoryType,outcome,recipient,
        wakeId,capturedAt,ackOpId,ackCompletedAt,ackOutcome)
      VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
      """,
      [
        advisory["advisory_id"],
        candidate.item_id,
        candidate.reg.handle,
        advisory["advisory_type"],
        outcome,
        recipient,
        wake_id,
        now,
        Id.uuid4(),
        if(owed?, do: nil, else: now),
        if(owed?, do: nil, else: "not_owed")
      ]
    )
  end

  ## What the wake says. Each sentence is true of the kind it is written for,
  ## and of the version of the message the bounce decided on.

  defp prompt(txn, recipient, entries) do
    sections =
      for kind <- [:full, :soft],
          group = Enum.filter(entries, &(kind(&1.advisory) == kind)),
          group != [] do
        section(kind, group, {txn, recipient})
      end

    Enum.join(sections, "\n\n")
  end

  # What was true when Harklight bounced it, said as of then and of the version
  # it decided on. The person may have opened or acted on it since.
  defp section(kind, group, ctx) do
    n = length(group)
    one? = n == 1

    what =
      if one?,
        do: "a version of the message below had",
        else: "a version of each of the #{n} messages below had"

    subject =
      case kind do
        :full -> "Harklight bounce: #{what} not been opened when it bounced."
        :soft -> "Harklight soft bounce: #{what} been opened but not acted on when it bounced."
      end

    Enum.join(
      [subject | Enum.map(group, &line(&1, ctx))] ++
        [
          "Decide whether #{if one?, do: "it is", else: "each is"} still valid and worth resending, and whether its importance warrants a higher priority. " <>
            "To send it again use `tightbeam harklight-send`; to withdraw it use `tightbeam harklight-retract --message <message id>`. " <>
            "Tightbeam has not resent anything and will not."
        ],
      "\n"
    )
  end

  defp line(%{advisory: advisory, item: item, reg: reg} = entry, ctx) do
    ids = "message #{reg.message_id}, conversation #{reg.handle}, started by #{reg.origin}"

    head =
      case title(item) || title(reg.title) do
        nil ->
          "- Message #{reg.message_id} (conversation #{reg.handle}, started by #{reg.origin})"

        title ->
          "- #{quoted(title)} (#{ids})"
      end

    revision =
      if is_integer(advisory["request_revision"]),
        do: "revision #{advisory["request_revision"]}, ",
        else: ""

    at =
      case advisory["evaluated_at_ms"] do
        at when is_integer(at) -> "bounced at #{time(at)}"
        _ -> "bounced"
      end

    "#{head}: #{revision}#{at}.#{receiver_clause(entry, ctx)}"
  end

  defp receiver_clause(%{reg: reg}, {txn, recipient}) do
    if reg.receiver == recipient do
      ""
    else
      who =
        case Org.get_in_txn(txn, reg.receiver) do
          %{display_name: name, state: state} ->
            "#{clean(name, 80)} (#{reg.receiver}) is #{state}"

          _ ->
            "#{reg.receiver} has no session record"
        end

      " The conversation's receiver #{who}, so this reaches you as the nearest active session above it, or Main when none is nearer."
    end
  end

  defp title(%{"message" => %{"title" => title}}) when is_binary(title) and title != "",
    do: clean(title, @max_title)

  defp title(text) when is_binary(text) and text != "", do: clean(text, @max_title)
  defp title(_), do: nil

  defp quoted(text), do: "\"" <> String.replace(text, "\"", "'") <> "\""

  defp clean(text, limit) do
    text |> to_string() |> String.replace(~r/[[:cntrl:]]/u, " ") |> String.slice(0, limit)
  end

  defp time(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, at} -> DateTime.to_iso8601(at)
      _ -> "an unrecorded time"
    end
  end

  ## Read path

  @doc """
  Read all sent messages once and handle every undelivered advisory in a single
  transaction. Marks nothing Delivered, reopens nothing.
  """
  def read_pass(db, opts \\ []) do
    with true <- registered_requests?(db) || :idle,
         {:ok, runner} <- HarklightSend.runner(opts),
         {:ok, {candidates, legacy}} <- HarklightItemIds.read_sent(runner, {[], []}, &collect_messages/2) do
      DB.transaction(db, fn txn ->
        :ok = HarklightItemIds.import_in_txn(txn, legacy)
        process_in_txn(txn, candidates, :read)
      end)
    else
      :idle -> {:ok, :idle}
      {:error, reason} -> {:error, reason}
    end
  end

  defp registered_requests?(db) do
    match?({:ok, [[1]]}, DB.query(db, "SELECT 1 FROM harklight_wake_requests LIMIT 1"))
  end

  defp collect_messages(messages, {candidates, legacy}) do
    {Enum.reduce(messages, candidates, &message_candidates/2),
     HarklightItemIds.collect_legacy(messages, legacy)}
  end

  defp message_candidates(%{"item_id" => id, "advisories" => advisories} = message, acc)
       when is_binary(id) and is_list(advisories) do
    Enum.reduce(advisories, acc, fn
      advisory, acc when is_map(advisory) ->
        [%{advisory: advisory, item: message, item_id: id, handle: nil} | acc]

      _, acc ->
        acc
    end)
  end

  defp message_candidates(_message, acc), do: acc

  ## Acknowledgment

  @doc """
  Acknowledge every woken advisory whose acknowledgment is still owed. Returns
  `{:ok, outstanding?}`. An unconfirmed attempt keeps its operation ID and
  journal and is retried with backoff. Closed rows owe nothing.
  """
  def ack_owed(db, opts \\ []) do
    with {:ok, rows} <-
           DB.query(
             db,
             """
             SELECT advisoryId,itemId,ackOpId,ackJournalId FROM harklight_bounces
             WHERE ackCompletedAt IS NULL ORDER BY capturedAt,advisoryId
             """
           ),
         true <- rows != [] || :none,
         {:ok, runner} <- HarklightSend.runner(opts) do
      outstanding =
        Enum.reduce(rows, false, fn [advisory, item, op, journal], pending ->
          # Every owed row is attempted, whatever happened to the one before.
          result = ack_one(db, runner, advisory, item, op, journal)
          pending or result != :ok
        end)

      {:ok, outstanding}
    else
      :none -> {:ok, false}
      {:error, _} -> {:ok, true}
    end
  end

  defp ack_one(db, runner, advisory, item, op, journal) do
    with {:ok, journal} <- journal(db, runner, op, journal) do
      argv = ["advisory-ack", "--item-id", item, "--advisory-id", advisory]

      result =
        Tightbeam.HarklightReceipts.recover_operation(runner, argv, op, journal, ["advisory-ack"])

      case settle(result, advisory, op) do
        :acknowledged ->
          complete(db, advisory, "acknowledged")

        :gone ->
          complete(db, advisory, "gone")

        :refused ->
          # A definite refusal recorded nothing; only then may a new key be used.
          with :pending <- already_settled(db, runner, advisory, item) do
            DB.query(
              db,
              "UPDATE harklight_bounces SET ackOpId=?2,ackJournalId=NULL WHERE advisoryId=?1 AND ackCompletedAt IS NULL",
              [advisory, Id.uuid4()]
            )

            :pending
          end

        :pending ->
          already_settled(db, runner, advisory, item)
      end
    else
      _ -> :pending
    end
  end

  # An acknowledgment that did not confirm: read the message's current
  # advisory. If it has become moot (Harklight answers an acknowledgment of a
  # moot notice with moot and not delivered, which the Agent reports as an
  # error) or is delivered, or the message is gone, there is nothing left to
  # acknowledge and the retries stop. Otherwise, or if it cannot be read, keep
  # retrying with backoff.
  defp already_settled(db, runner, advisory, item) do
    case message_get(runner, item) do
      {:ok, advisories} ->
        case Enum.find(advisories, &(&1["advisory_id"] == advisory)) do
          %{"moot" => true} ->
            Logger.info("Harklight bounce #{advisory} became moot; acknowledgment dropped")
            complete(db, advisory, "moot")

          %{"delivered" => true} ->
            complete(db, advisory, "delivered")

          _ ->
            :pending
        end

      :not_found ->
        complete(db, advisory, "gone")

      :unreadable ->
        :pending
    end
  end

  defp message_get(runner, item) do
    {output, status} = runner.(["message-get", "--item-id", item])

    frames =
      for line <- String.split(output, "\n", trim: true),
          {:ok, %{} = frame} <- [JSON.decode(line)],
          do: frame

    case {frames, status} do
      {[%{"message" => %{"advisories" => advisories}}], 0} when is_list(advisories) ->
        {:ok, advisories}

      {[%{"kind" => "refused", "error" => "not_found"}], status} when status in [2, 5] ->
        :not_found

      _ ->
        :unreadable
    end
  rescue
    _ -> :unreadable
  end

  defp journal(_db, _runner, _op, journal) when is_binary(journal), do: {:ok, journal}

  defp journal(db, runner, op, nil) do
    with {:ok, id} <- HarklightSend.journal_id(runner),
         {:ok, [[^id]]} <-
           DB.query(
             db,
             "UPDATE harklight_bounces SET ackJournalId=?2 WHERE ackOpId=?1 AND ackJournalId IS NULL RETURNING ackJournalId",
             [op, id]
           ) do
      {:ok, id}
    else
      _ -> :pending
    end
  end

  defp settle(
         {[
            %{
              "kind" => "committed",
              "operation" => "advisory-ack",
              "op_id" => op,
              "response" => %{"advisory_id" => advisory, "delivered" => true}
            }
          ], 0},
         advisory,
         op
       ),
       do: :acknowledged

  defp settle({[%{"kind" => "refused", "op_id" => op, "error" => "not_found"}], status}, _, op)
       when status in [2, 5],
       do: :gone

  defp settle({[%{"kind" => "refused", "op_id" => op}], status}, _, op) when status in [2, 5],
    do: :refused

  defp settle(_other, _advisory, _op), do: :pending

  defp complete(db, advisory, outcome) do
    case DB.query(
           db,
           "UPDATE harklight_bounces SET ackCompletedAt=?2,ackOutcome=?3 WHERE advisoryId=?1 AND ackCompletedAt IS NULL",
           [advisory, System.system_time(:millisecond), outcome]
         ) do
      {:ok, _} -> :ok
      {:error, _} -> :pending
    end
  end

  ## Worker

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  # Reads happen at start and on a slow timer; acknowledgments right after a
  # feed capture, after a read, and by backoff. Neither task has a deadline: a
  # read still running when the next tick comes is logged once and left alone.
  @impl true
  def init(opts) do
    send(self(), :ack_tick)
    send(self(), :read_tick)

    {:ok,
     %{
       db: Keyword.fetch!(opts, :db),
       opts: opts,
       ack: nil,
       ack_again: false,
       ack_attempts: 0,
       ack_timer: nil,
       read: nil,
       read_tick: nil,
       stuck_logged: false
     }}
  end

  @impl true
  def handle_cast(:ack_requested, state), do: {:noreply, start_ack(state)}

  @impl true
  def handle_info(:ack_tick, state), do: {:noreply, start_ack(%{state | ack_timer: nil})}

  def handle_info(:read_tick, state) do
    interval = Keyword.get(state.opts, :read_interval_ms, @read_interval)
    state = %{state | read_tick: Process.send_after(self(), :read_tick, interval)}

    cond do
      is_nil(state.read) ->
        %{db: db, opts: opts} = state

        task =
          Task.async(fn ->
            {:read,
             guarded(fn -> read_pass(db, opts) end, {:error, "harklight_bounce_read_crashed"})}
          end)

        {:noreply, %{state | read: task}}

      state.stuck_logged ->
        {:noreply, state}

      true ->
        Logger.warning(
          "Harklight bounce read is still running at its next tick; waiting for it, not starting another"
        )

        {:noreply, %{state | stuck_logged: true}}
    end
  end

  def handle_info({ref, {:ack, result}}, %{ack: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | ack: nil}

    state =
      case result do
        {:ok, false} ->
          if state.ack_again,
            do: start_ack(%{state | ack_again: false}),
            else: %{state | ack_attempts: 0}

        _ ->
          delays = Keyword.get(state.opts, :ack_delays, @ack_delays)
          delay = Enum.at(delays, min(state.ack_attempts, length(delays) - 1))
          timer = Process.send_after(self(), :ack_tick, delay)
          %{state | ack_timer: timer, ack_attempts: state.ack_attempts + 1, ack_again: false}
      end

    {:noreply, state}
  end

  def handle_info({ref, {:read, result}}, %{read: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, :idle} ->
        :ok

      {:ok, summary} ->
        Logger.info(
          "Harklight bounce read: woken=#{length(summary.woken)} closed=#{length(summary.closed)} " <>
            "left_alone_open=#{length(summary.left_alone_open)}"
        )

      {:error, reason} ->
        Logger.warning("Harklight bounce read failed: #{inspect(reason)}")
    end

    state = %{state | read: nil, stuck_logged: false}
    {:noreply, if(match?({:ok, %{}}, result), do: start_ack(state), else: state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      match?(%Task{ref: ^ref}, state.ack) ->
        Logger.warning("Harklight bounce acknowledgment worker stopped: #{inspect(reason)}")
        {:noreply, %{state | ack: nil, ack_timer: Process.send_after(self(), :ack_tick, 1_000)}}

      match?(%Task{ref: ^ref}, state.read) ->
        Logger.warning("Harklight bounce read worker stopped: #{inspect(reason)}")
        {:noreply, %{state | read: nil, stuck_logged: false}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_ack(%{ack: nil} = state) do
    if state.ack_timer, do: Process.cancel_timer(state.ack_timer)
    %{db: db, opts: opts} = state
    task = Task.async(fn -> {:ack, guarded(fn -> ack_owed(db, opts) end, {:ok, true})} end)
    %{state | ack: task, ack_timer: nil}
  end

  defp start_ack(state), do: %{state | ack_again: true}

  defp guarded(fun, default) do
    fun.()
  rescue
    error ->
      Logger.warning("Harklight bounce worker failed: #{Exception.message(error)}")
      default
  catch
    kind, reason ->
      Logger.warning("Harklight bounce worker failed: #{inspect({kind, reason})}")
      default
  end
end
