defmodule Tightbeam.Productions.Bubble do
  @moduledoc """
  The fault-bubbling production (spec production-machine-v1 §Fault bubbling).

  This module is one rule of a Newell production machine: a declared left-hand
  side over durable working memory (`bubble_production_matches?/3`) and a
  procedural right-hand side (`climb/3`). It is NOT an obligation of the
  failing turn — the turn's own session already has the row, the reason and
  the marker by the time this fires; deleting this module would not touch
  those three. It RECOGNIZES a terminal row and tells someone who can act.

  Who can act is never guessed — it is demonstrated. A notice to a parent is
  itself a turn; its terminal state is the evidence. `delivered` ends the
  climb (the recipient demonstrably ran a turn; what to do next is its
  judgment). `failed`, `canceled` and `failed_unknown` all continue it — each
  is a recipient not SHOWN able. The climb carries its cause as
  `turns.requestRef = "bubble:<cause_seq>"`, and every rung re-derives the
  prose from the cause turn's row: no prose is ever parsed, prose is
  presentation. Exactly-once per (cause, recipient) rides `turns.wakeId`
  UNIQUE with a deterministic key.

  The terminal rung is not a turn. When the lineage is exhausted, the alert
  to the owner is a substrate-authored wire message — store-and-push, no
  model, no tokens, structurally incapable of sharing the failure mode that
  caused the climb — and the standing `user-alerted` fact (scope: the owner
  USER id, never a composed session key) records that the user has been told.
  While it stands, failures under that owner do not re-climb. The first
  DELIVERED turn for any of the owner's sessions is the observed proof that
  capacity exists, and retracts it. Recovery is recognized, never declared.
  """

  alias Tightbeam.{ConditionFacts, ConnRegistry, DB, EventLog, Gateway, Org, Projection}
  alias Tightbeam.Wire.Payloads

  require Logger

  @bubbling_terminals ~w(failed failed_unknown)
  @climbing_notice_terminals ~w(failed canceled failed_unknown)
  @lineage_hop_limit 32

  @doc """
  Post-commit recognition site for every terminal transition, wired through
  the lane's existing `on_terminal` hook — which also fires from the
  republish sweep, so boot-recovered `failed_unknown` rows and retire-drained
  `canceled` rows are recognized without their own sites. The row is already
  committed truth; this only recognizes it. Safe to call for every terminal
  and safe to call twice: the LHS decides, and the enqueue dedupes.
  """
  @spec recognize_terminal(DB.server(), integer()) :: :ok
  def recognize_terminal(db, seq) do
    case turn_context(db, seq) do
      %{status: status} = turn -> recognize(db, seq, status, turn)
      nil -> :ok
    end
  end

  defp recognize(db, seq, "delivered", turn) do
    # Retraction is observed, not declared: a delivered turn is proof the
    # owner has capacity. Guarded by the cheap any?/2 read because almost
    # every database has never filed a user-alerted fact and this runs on
    # every delivered turn.
    if ConditionFacts.any?(db, "user-alerted") and
         ConditionFacts.standing?(db, "user-alerted", turn.owner) do
      file_fact(db, "user-alert-cleared", turn.owner)

      EventLog.lifecycle(
        db,
        "user_alert_cleared",
        turn.owner,
        "observed delivered turn seq=#{seq}"
      )
    end

    :ok
  end

  defp recognize(db, _seq, terminal, turn) do
    if bubble_production_matches?(db, terminal, turn) do
      climb(db, turn)
    else
      :ok
    end
  end

  @doc """
  The production's complete LHS, in one site, over durable state only (spec
  production-machine-v1 §Legibility): the terminal starts or continues a
  bubble ∧ no standing `user-alerted` fact for the owner. The turn's-session-
  exists conjunct is enforced upstream by `turn_context/2` answering at all —
  a context this function receives has already passed it. Where to climb TO
  is the RHS's problem: a parentless cause session matches and then ends
  silently, because its own marker already told the only audience there is.

  Terminal admission, decided per state: `failed` and `failed_unknown` start
  a bubble — the work not happening with nobody having decided that. A
  `canceled` CAUSE turn never starts one: cancellation IS a decision, made by
  an authority, and bubbling it would report a decision as a fault. A
  `canceled` NOTICE still climbs — the underlying fault remains untold.
  """
  @spec bubble_production_matches?(DB.server(), String.t(), map()) :: boolean()
  def bubble_production_matches?(db, terminal, turn) do
    terminal_admits?(terminal, turn.notice?) and
      not ConditionFacts.standing?(db, "user-alerted", turn.owner)
  end

  defp terminal_admits?(terminal, notice?) do
    if notice?,
      do: terminal in @climbing_notice_terminals,
      else: terminal in @bubbling_terminals
  end

  # RHS. Find the nearest ACTIVE ancestor of the session the terminal landed
  # in and enqueue the notice there; with none left, the terminal rung fires.
  # TWO UNLIKE ABSENCES, kept apart (review B2 — collapsing them silenced a
  # whole class of fault): `:parentless` means the session row is missing
  # at all — its own marker already told the only audience there is, so a
  # fresh cause ends silently (spec §Fault bubbling 2). `:exhausted` means it
  # HAS a lineage and no rung of it is active — a retired rung can never run
  # a turn, so this is the climb ending, and the climb ending is the alert
  # (spec §5), whether what died here was a notice or the cause itself.
  defp climb(db, turn) do
    case next_active_ancestor(db, turn.session_key) do
      :parentless ->
        if turn.notice?, do: terminal_alert(db, turn), else: :ok

      :exhausted ->
        terminal_alert(db, turn)

      {:ok, recipient} ->
        enqueue_notice(db, turn, recipient)
    end
  end

  defp enqueue_notice(db, turn, recipient) do
    case cause_row(db, turn.cause_seq) do
      {:ok, cause} -> enqueue_notice(db, turn, recipient, cause)
      :missing -> report_missing_cause(db, turn)
    end
  end

  defp enqueue_notice(db, turn, recipient, cause) do
    prompt =
      "Turn #{turn.cause_seq} in #{cause.session_key} could not run: " <>
        "#{cause.error || "reason unrecorded"}. You are the nearest ancestor " <>
        "shown able to run a turn. What to do about it is your judgment."

    result =
      Gateway.deliver_prompt(recipient, "process:tightbeam", prompt,
        db: db,
        sender: "process:tightbeam",
        device_id: "process:tightbeam",
        client_message_id: "bubble:#{turn.cause_seq}:#{recipient}",
        wake_id: "bubble:#{turn.cause_seq}:#{recipient}",
        request_ref: "bubble:#{turn.cause_seq}"
      )

    case result do
      # :duplicate is the dedupe working — a crash between recognition and
      # enqueue re-attempted into the UNIQUE key, exactly as designed.
      r when r in [:appended, :duplicate] -> :ok
      # :skipped means the target evaporated between our read and the
      # delivery transaction. The notice turn was never created, so nothing
      # will terminalize and continue the climb — do it now.
      :skipped -> climb(db, %{turn | session_key: recipient, notice?: true})
      _ -> :ok
    end
  end

  # The terminal rung. Ordering is deliberate: the user is TOLD first, the
  # fact files second — a crash between them re-alerts on the next failure (a
  # duplicate sentence), where the other order would file suppression without
  # anyone having been told (a silent fault, the one unforgivable outcome).
  defp terminal_alert(db, turn) do
    case cause_row(db, turn.cause_seq) do
      {:ok, cause} -> terminal_alert(db, turn, cause)
      :missing -> report_missing_cause(db, turn)
    end
  end

  # ONE TRANSACTION (spec §5, literally: "in the same transaction it files
  # user-alerted"): the lifecycle record, the marker in the owner's main
  # stream, and the standing fact commit together — no window where the fact
  # suppresses climbs for an alert nobody received, and none where the user
  # was told but the machine forgot. The wire push happens after commit and
  # may find nobody connected; store is truth, replay serves them.
  defp terminal_alert(db, turn, cause) do
    message =
      "[no agent can act]\n\nWork owned by you cannot run, and no agent in " <>
        "its lineage could be told: every ancestor's notice turn also " <>
        "failed. Original failure — turn #{turn.cause_seq} in " <>
        "#{cause.session_key}: #{cause.error || "reason unrecorded"}. " <>
        "Tightbeam will not repeat this alert until a turn is observed to " <>
        "run; any turn delivering clears it."

    main_key = Org.personal_session_key(turn.owner)

    {:ok, published} =
      DB.transaction(db, fn txn ->
        EventLog.lifecycle_in_txn(
          txn,
          "lineage_exhausted",
          turn.owner,
          "cause_seq=#{turn.cause_seq} session=#{cause.session_key}"
        )

        ConditionFacts.file_in_txn(txn, %{
          kind: "user-alerted",
          scope: turn.owner,
          origin: "process:tightbeam"
        })

        # The owner's main-session key is COMPOSED; when no row carries the
        # stream, the fact and the record still commit — log it and be done;
        # the alert becomes product surface when a main session exists.
        case DB.Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey = ?1", [main_key]) do
          [["active"]] ->
            {:appended, marker} =
              Projection.append_substrate_in_txn(txn, main_key, message, :high)

            Tightbeam.Firehose.Publisher.message_in_txn(txn, main_key, marker, turn.owner)
            {:ok, marker}

          _ ->
            :no_stream
        end
      end)

    case published do
      {:ok, marker} ->
        ConnRegistry.publish_message(
          Tightbeam.ConnRegistry,
          main_key,
          turn.owner,
          marker.seq,
          Payloads.server_message(marker),
          fn pid, payload -> send(pid, {:push_message, main_key, marker.seq, payload}) end
        )

      :no_stream ->
        Logger.info(
          "lineage exhausted for #{turn.owner} with no active main session: " <>
            "alert recorded and standing; no stream to carry it yet"
        )
    end

    :ok
  end

  defp report_missing_cause(db, turn) do
    Logger.error(
      "bubble for #{turn.session_key} names cause turn #{turn.cause_seq}, " <>
        "which does not exist; recognition declines rather than fabricating a cause"
    )

    EventLog.lifecycle(
      db,
      "bubble_cause_missing",
      turn.session_key,
      "cause_seq=#{turn.cause_seq}"
    )

    :ok
  end

  # One read serving both the LHS and the RHS: the turn row joined to its
  # session's lineage and owner. `cause_seq` is the ORIGINAL failed turn —
  # this turn's own seq unless its requestRef marks it as a rung of an
  # existing climb.
  defp turn_context(db, seq) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT t.sessionKey, t.requestRef, s.ownerUserId, t.status
        FROM turns AS t JOIN sessions AS s ON s.sessionKey = t.sessionKey
        WHERE t.seq = ?1
        """,
        [seq]
      )

    case rows do
      [[session_key, request_ref, owner, status]] ->
        case parse_cause_seq(request_ref, seq) do
          :malformed ->
            Logger.error(
              "turn #{seq} in #{session_key} carries a malformed bubble marker " <>
                "(requestRef=#{inspect(request_ref)}); recognition declines rather " <>
                "than climbing on a reference that names nothing"
            )

            EventLog.lifecycle(db, "bubble_marker_malformed", session_key, "seq=#{seq}")
            nil

          {kind, cause_seq} ->
            %{
              session_key: session_key,
              owner: owner,
              status: status,
              cause_seq: cause_seq,
              notice?: kind == :notice
            }
        end

      [] ->
        nil
    end
  end

  defp parse_cause_seq("bubble:" <> cause, _seq) do
    case Integer.parse(cause) do
      {cause_seq, ""} -> {:notice, cause_seq}
      # A malformed marker is DIRT (review M5): a turn that claims to be a
      # rung of a climb but names no cause must not be promoted to the start
      # of a new bubble — notices about notices do not exist — and must not
      # be silently indulged. Report it; recognition declines.
      _ -> :malformed
    end
  end

  defp parse_cause_seq(_other, seq), do: {:cause, seq}

  # Found and not-found are different facts (review M4): a missing cause row
  # is dirt to report, never a fabricated "unknown" the substrate asserts as
  # truth to a parent or a user.
  defp cause_row(db, cause_seq) do
    {:ok, rows} =
      DB.query(db, "SELECT sessionKey, error FROM turns WHERE seq = ?1", [cause_seq])

    case rows do
      [[session_key, error]] -> {:ok, %{session_key: session_key, error: error}}
      [] -> :missing
    end
  end

  # First ancestor with an ACTIVE session row, walking operationalParent. A missing
  # or retired rung is climbed past — it can never run a turn, which is the
  # same fact a canceled notice proves, learned one enqueue cheaper. The two
  # empty answers are DIFFERENT facts and stay different values: a session
  # with no row is `:parentless`; a session whose lineage exists but
  # holds no active rung is `:exhausted`.
  defp next_active_ancestor(db, session_key, hops \\ 0)

  defp next_active_ancestor(_db, _session_key, hops) when hops > @lineage_hop_limit,
    do: :exhausted

  defp next_active_ancestor(db, session_key, hops) do
    case DB.query(db, "SELECT operationalParent FROM sessions WHERE sessionKey = ?1", [
           session_key
         ]) do
      {:ok, [[parent]]} when is_binary(parent) ->
        if parent == session_key do
          :exhausted
        else
          case DB.query(db, "SELECT state FROM sessions WHERE sessionKey = ?1", [parent]) do
            {:ok, [["active"]]} -> {:ok, parent}
            _ -> exhausted_past(db, parent, hops)
          end
        end

      _ when hops == 0 ->
        :parentless

      _ ->
        :exhausted
    end
  end

  # Climbing past a dead rung: whatever the rest of the walk answers, this
  # lineage EXISTS, so an empty tail is exhaustion, never parentlessness.
  defp exhausted_past(db, parent, hops) do
    case next_active_ancestor(db, parent, hops + 1) do
      :parentless -> :exhausted
      other -> other
    end
  end

  defp file_fact(db, kind, scope) do
    case DB.transaction(db, fn txn ->
           ConditionFacts.file_in_txn(txn, %{
             kind: kind,
             scope: scope,
             origin: "process:tightbeam"
           })
         end) do
      {:ok, %{fact_id: _}} ->
        :ok

      other ->
        Logger.error("bubble could not file #{kind} for #{scope}: #{inspect(other)}")
        :ok
    end
  end
end
