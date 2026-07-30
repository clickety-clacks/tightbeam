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

  ORDERING LIVES HERE, and nowhere else. Both the capture (which reads the
  ledger) and the read happen inside this one serialized process, in arrival
  order — never across a process gap, never reconstructed from a timestamp
  comparison after the fact. A newer observation supersedes the session's
  previous window, including the observation that finds no running turn: the
  freshest look wins, so a stale message cannot outlive a look that saw none.

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
    call(server, {:observe, db, session_key}, :ok)
  end

  @doc "The message captured for this session's open window, or nil."
  @spec observed(String.t(), GenServer.server()) :: String.t() | nil
  def observed(session_key, server \\ __MODULE__) do
    call(server, {:observed, session_key}, nil)
  end

  @impl true
  def init(:ok), do: {:ok, %{windows: %{}}}

  @impl true
  def handle_call({:observe, db, session_key}, _from, state) do
    now = now()

    windows =
      case Ledger.running_turn_message_id(db, session_key) do
        nil -> Map.delete(prune(state.windows, now), session_key)
        message_id -> Map.put(prune(state.windows, now), session_key, {message_id, now})
      end

    {:reply, :ok, %{state | windows: windows}}
  end

  # Reading does NOT consume. §4.1 rules the open-window join: every
  # artifact-record from the session while the window is open binds the captured
  # message, so one command recording several artifacts labels all of them alike.
  def handle_call({:observed, session_key}, _from, state) do
    windows = prune(state.windows, now())

    observed =
      case Map.get(windows, session_key) do
        {message_id, _opened_at} -> message_id
        nil -> nil
      end

    {:reply, observed, %{state | windows: windows}}
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
  # is exactly the hookless case the evidence classes already describe.
  defp call(server, message, on_unavailable) do
    GenServer.call(server, message)
  catch
    :exit, _ -> on_unavailable
  end

  defp now, do: System.monotonic_time(:millisecond)
end
