defmodule Tightbeam.TurnObservations do
  @moduledoc """
  THE single writer for the artifact-record observation window
  (artifact-carrier-proposal-v1 §4.1).

  Tightbeam has no gateway→CLI channel that varies per turn, so a request cannot
  carry the turn that fired it. What the substrate CAN have is a per-tool-call
  OBSERVATION whose turn is resolved at observation time: the substrate-reserved
  `PreToolUse` entry (`Tightbeam.Rails.observation_entry/0`) calls the gateway
  when it sees a `tightbeam artifact-record` command, and this process captures
  the caller session's running `messages.id` AT THAT MOMENT. The subsequent
  `artifact-record` reads the window instead of re-deriving a turn that may
  already have ended.

  Capturing at observation time rather than at request time is the whole point:
  a slow command that spans a turn boundary, and a cancel (which terminalizes
  before it kills the serving task, `session_lane.ex`), both still bind the turn
  that launched the command.

  WHAT THE WINDOW IS NOT. It is joined to the arriving request by SESSION AND
  TIME — not by a nonce, not by matching command text (rejected in §4.1 as
  fragile). So a window is a narrowed concurrency claim, never proof, which is
  why the class it produces is `tool-call-observed` — "the substrate observed
  this turn invoking this verb" — and never an unforgeability claim.

  ORDERING LIVES HERE, and nowhere else. The capture and the WHOLE evidence
  resolution — window lookup AND the ledger fallback — happen inside this one
  serialized process, in arrival order, never across a process gap. Resolving in
  two places was the first version's defect: the window was read here and the
  ledger in the request process, so a turn could terminalize in the scheduling
  gap between them and the row landed `none` describing an instant neither read
  saw. Inside one callback there is no such gap — nothing can change the window
  mid-resolution, because the only thing that changes it is a message to this
  same process, and this process is busy.

  A newer observation supersedes the session's previous window, including the
  observation that finds no running turn: the freshest look wins, so a stale
  message cannot outlive a look that saw none.

  A CALL THE CALLER GAVE UP ON MUST NOT ACT LATER. A `GenServer.call` that times
  out leaves its message in this mailbox, so an observation the caller already
  treated as failed could otherwise open a window minutes later and STRENGTHEN
  some unrelated record to `tool-call-observed` — degradation inventing evidence,
  which is the wrong direction to fail in. Every post that MUTATES the window
  therefore carries the deadline its caller will wait until, and the writer
  compares against it immediately before mutating — after its own ledger read,
  because that read is itself long enough to cross the deadline.

  The window is DELIBERATELY NOT DURABLE. A window that outlives the turn that
  opened it has no value, so `turns.requestRef` — the ledger's declared-unused
  slot named as its possible durable home — stays unused: restart-survival would
  buy nothing, and the slot is keyed by turn while a window must be keyed by
  session and outlive its own turn's terminalization.

  Unavailability degrades to a weaker evidence class and never to a refusal.
  `artifact-record` fails OPEN (R1): if this process is gone, the record still
  lands, as `session-concurrent` or `none`.
  """

  use GenServer

  alias Tightbeam.Ledger

  # How long a caller waits, and therefore the deadline it stamps on its post.
  # One number for both, so "the caller gave up" and "the post expired" are the
  # same instant by construction and cannot drift apart.
  #
  # Deliberately WELL INSIDE `DB.query/3`'s own 5s call timeout. At 5s the two
  # coincide, and then the writer is as likely to be killed by its own ledger
  # read as it is to survive and drop the abandoned post — which would make the
  # fence below unreachable exactly when it is needed. The fence only works if
  # the writer outlives the caller that gave up. Two seconds is also the right
  # product answer on its own terms: this sits in the artifact-record request
  # path, and a writer that cannot answer a single indexed read in two seconds
  # should be degraded around rather than waited on.
  @call_timeout_ms 2_000

  # How long a captured turn stays bindable. The hook fires immediately before
  # the command runs, so a bare `tightbeam artifact-record` consumes its window
  # in milliseconds; the budget exists for the composite case
  # (`mix test && tightbeam artifact-record …`), where the record can legitimately
  # arrive minutes later. Erring SHORT is the safe direction: an expired window
  # falls back to `session-concurrent`/`none`, which is truthful, whereas an
  # over-long one lets a turn's window bind a later turn's unobserved record and
  # label a wrong message `tool-call-observed`.
  @window_ttl_ms 5 * 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Capture the session's running turn as the open window, superseding any
  previous one. No running turn closes the window rather than leaving it.
  """
  @spec observe(GenServer.server(), String.t(), GenServer.server()) :: :ok
  def observe(db, session_key, server \\ __MODULE__) do
    call(server, {:observe, db, session_key, now() + @call_timeout_ms}, fn -> :ok end)
  end

  @doc """
  The whole turn edge for a record, decided in ONE serialized operation.

  Both sources are consulted here, with nothing able to run between them, so the
  answer is one snapshot rather than two reads of two different instants.
  """
  @spec evidence(GenServer.server(), String.t(), GenServer.server()) ::
          {String.t() | nil, String.t()}
  def evidence(db, session_key, server \\ __MODULE__) do
    call(server, {:evidence, db, session_key}, fn -> ledger_evidence(db, session_key) end)
  end

  @impl true
  def init(:ok), do: {:ok, %{windows: %{}}}

  # The deadline rides only on the posts that MUTATE the window. A read carries
  # none: arriving late it changes nothing but the prune, which is idempotent
  # bookkeeping, and its caller has already answered itself from the ledger.
  #
  # It is compared TWICE, and the second one is the one that matters. Checking
  # only on arrival leaves the ledger read itself inside the abandonment window:
  # `DB.query/3` tolerates 5s and the caller waits 2s, so a stalled read can
  # return to a writer whose caller left long ago and mutate anyway. The check
  # that guards the mutation is the one immediately before it.
  #
  # The arrival check is not redundant, it is back-pressure. Posts expire
  # precisely when reads are stalling, and that is the worst moment to issue one
  # more read on behalf of a caller that is already gone.
  @impl true
  def handle_call({:observe, db, session_key, deadline}, _from, state) do
    if expired?(deadline) do
      {:reply, :ok, state}
    else
      running = Ledger.running_turn_message_id(db, session_key)

      if expired?(deadline) do
        {:reply, :ok, state}
      else
        now = now()

        windows =
          case running do
            nil -> Map.delete(prune(state.windows, now), session_key)
            message_id -> Map.put(prune(state.windows, now), session_key, {message_id, now})
          end

        {:reply, :ok, %{state | windows: windows}}
      end
    end
  end

  # Reading does NOT consume. §4.1 rules the open-window join: every
  # artifact-record from the session while the window is open binds the captured
  # message, so one command recording several artifacts labels all of them alike.
  def handle_call({:evidence, db, session_key}, _from, state) do
    windows = prune(state.windows, now())

    evidence =
      case Map.get(windows, session_key) do
        {message_id, _opened_at} -> {message_id, "tool-call-observed"}
        nil -> ledger_evidence(db, session_key)
      end

    {:reply, evidence, %{state | windows: windows}}
  end

  defp ledger_evidence(db, session_key) do
    case Ledger.running_turn_message_id(db, session_key) do
      message_id when is_binary(message_id) -> {message_id, "session-concurrent"}
      nil -> {nil, "none"}
    end
  end

  # Every entry is visited on every call, which is what keeps the map bounded
  # without a timer: a session that never records again is forgotten by the next
  # call from any session.
  defp prune(windows, now) do
    Map.reject(windows, fn {_session_key, {_message_id, opened_at}} ->
      now - opened_at >= @window_ttl_ms
    end)
  end

  # The writer is a named child, and a call path that must not refuse cannot be
  # allowed to raise because it is absent. Missing writer = no observation, which
  # is exactly the hookless case the evidence classes already describe. A timeout
  # exits here too, and the deadline riding on the message is what stops the
  # abandoned call from acting after this process has moved on.
  defp call(server, message, on_unavailable) do
    GenServer.call(server, message, @call_timeout_ms)
  catch
    :exit, _ -> on_unavailable.()
  end

  defp expired?(deadline), do: now() >= deadline

  defp now, do: System.monotonic_time(:millisecond)
end
