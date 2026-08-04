defmodule Tightbeam.ConnRegistry do
  @moduledoc """
  Owns the set of live authed connections and all fan-out. A Bandit WebSock
  handler is one process per socket, but broadcast scoping, device takeover,
  and the replay/live de-dup barrier are shared state, so they live here.

  Two load-bearing mechanisms:

  1. Generation-tagged takeover. Each device slot holds a monotonically
     increasing generation. A new auth for a device atomically installs a new
     (gen+1) registration BEFORE the old socket is told to close; the old
     connection's unregister compares generations and cannot delete its
     replacement. So a slow-closing old socket can never evict the new one.

  2. Replay/live de-dup, and ONLY that. Replay hands a reconnecting client
     everything after its cursor; live publication runs concurrently. A message
     could therefore be sent twice, so a connection remembers how far REPLAY got
     per session (`replayed_through`) and suppresses a live frame at or below it.

  WHAT THIS DELIBERATELY NO LONGER DOES. That watermark used to be advanced by
  live delivery as well, and the filter dropped anything at or below the highest
  seq ever sent. Two writers to one session — a client post's echo and a running
  turn's reply, from two different processes with nothing ordering them — commit
  20 then 21 and can publish in the other order, because publication happens
  after each transaction returns rather than inside it. The client got 21, the
  watermark advanced to 21, and 20 was then dropped as "already delivered".

  It was not recoverable. Replay serves rows after the CLIENT's own cursor
  (wire/socket.ex, `Projection.list_after/5` selecting `seq >`), and that cursor
  had advanced past 20 when 21 arrived, so no reconnect and no re-auth ever
  restored it. A reply the store held perfectly was gone from that client's view
  for good.

  So delivery no longer withholds anything it has not literally already sent.
  Out-of-order arrival is now a cosmetic ordering question the client can settle
  from the seq it already receives on every message, instead of a silent
  permanent loss. The narrower cost — a genuine double-publish of one seq would
  now reach the client twice — buys back the only failure here that could not be
  seen or undone, and duplicates are neither.

  Publication order is still not guaranteed by anything, and this module still
  cannot provide it. It simply no longer converts that into deletion.
  """

  use GenServer

  @type server :: GenServer.server()

  @typedoc "Delivery function injected by the caller — `(pid, payload)`; tests capture, prod sends to the socket."
  @type deliver :: (pid(), term() -> any())

  defstruct conns: %{}, devices: %{}, rate_windows: %{}

  # conns:   ref => %{pid, user_id, device_id, is_admin, subscriptions, gen,
  #                     replayed_through: %{session_key => seq}}
  # devices: device_id => %{ref, gen}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Register/authenticate a connection for a device. Returns
  {:ok, ref, replaced} where `replaced` is the ref of the taken-over socket
  (or nil). The caller sends session_replaced+close to `replaced` — AFTER this
  returns, so the new registration already owns the slot.
  """
  @spec register(server(), %{
          pid: pid(),
          user_id: String.t(),
          device_id: String.t(),
          is_admin: boolean(),
          subscriptions: MapSet.t(String.t())
        }) ::
          {:ok, reference(), reference() | nil}
  def register(
        server \\ __MODULE__,
        %{pid: _, user_id: _, device_id: _, is_admin: _, subscriptions: %MapSet{}} = conn
      ) do
    GenServer.call(server, {:register, conn})
  end

  @doc "Unregister a connection (idempotent; generation-guarded for device slot)."
  @spec unregister(server(), reference()) :: :ok
  def unregister(server \\ __MODULE__, ref), do: GenServer.cast(server, {:unregister, ref})

  @doc """
  Publish a per-session message (with its store seq) to the OWNER's
  connections only — admin grants powers, never a merged feed; not one byte
  of another user's content reaches an admin device (TS parity:
  server.ts broadcastMessage). Suppresses only what replay already sent to that
  connection. `deliver` is `(pid, payload) -> any` — injected so tests capture
  without a real socket.

  CALLERS NEED NOT PUBLISH IN SEQ ORDER, and nothing guarantees they do. Out of
  order is delivered out of order, carrying the seq that lets a client settle it;
  it is no longer treated as a duplicate and deleted.
  """
  @spec publish_message(server(), String.t(), String.t(), integer(), term(), deliver()) :: :ok
  def publish_message(server \\ __MODULE__, session_key, owner_user_id, seq, payload, deliver) do
    GenServer.call(server, {:publish_message, session_key, owner_user_id, seq, payload, deliver})
  end

  @doc "Publish a non-message event (turn state, typing, stream) to the owner only — no seq filter."
  @spec broadcast(server(), String.t(), term(), deliver()) :: :ok
  def broadcast(server \\ __MODULE__, owner_user_id, payload, deliver) do
    GenServer.call(server, {:broadcast, owner_user_id, payload, deliver})
  end

  @doc "Publish an assignment-grain doorbell to the holder owner's work-state subscribers."
  @spec publish_work_state(server(), String.t(), term(), deliver()) :: :ok
  def publish_work_state(server \\ __MODULE__, owner_user_id, payload, deliver) do
    GenServer.call(server, {:publish_work_state, owner_user_id, payload, deliver})
  end

  @doc "Publish a work-item-grain doorbell to its owners' work-state subscribers."
  @spec publish_work_item(server(), MapSet.t(String.t()), term(), deliver()) :: :ok
  def publish_work_item(server \\ __MODULE__, owner_user_ids, payload, deliver) do
    GenServer.call(server, {:publish_work_item, owner_user_ids, payload, deliver})
  end

  @doc "Advance a connection's REPLAYED-through watermark (per session)."
  @spec note_replayed(server(), reference(), String.t(), integer()) :: :ok
  def note_replayed(server \\ __MODULE__, ref, session_key, seq) do
    GenServer.cast(server, {:note_replayed, ref, session_key, seq})
  end

  @doc "Apply a global per-device sliding-window rate limit."
  @spec within_rate_limit(server(), String.t(), atom(), pos_integer(), pos_integer()) :: boolean()
  def within_rate_limit(server \\ __MODULE__, device_id, kind, limit, window_ms) do
    GenServer.call(server, {:within_rate_limit, device_id, kind, limit, window_ms})
  end

  ## Server

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:register, conn}, _from, state) do
    ref = make_ref()
    device_id = conn.device_id
    prior = state.devices[device_id]
    gen = (prior && prior.gen + 1) || 1

    entry = %{
      pid: conn.pid,
      user_id: conn.user_id,
      device_id: device_id,
      is_admin: conn.is_admin,
      subscriptions: conn.subscriptions,
      gen: gen,
      replayed_through: %{}
    }

    replaced = prior && prior.ref

    # The old pid must be captured before its entry is removed. Installation
    # of the replacement happens in this same callback before the message can
    # be acted upon, preserving the generation takeover invariant.
    if prior && state.conns[prior.ref] && is_pid(state.conns[prior.ref].pid) do
      send(state.conns[prior.ref].pid, {:takeover_close})
    end

    state = %{
      state
      | conns: state.conns |> Map.put(ref, entry) |> maybe_drop(replaced),
        devices: Map.put(state.devices, device_id, %{ref: ref, gen: gen})
    }

    {:reply, {:ok, ref, replaced}, state}
  end

  def handle_call({:publish_message, session_key, owner, seq, payload, deliver}, _from, state) do
    conns =
      Enum.reduce(state.conns, state.conns, fn {_ref, e}, acc ->
        cond do
          e.user_id != owner or not MapSet.member?(e.subscriptions, "chat") ->
            acc

          Map.get(e.replayed_through, session_key, 0) >= seq ->
            # Already sent to this connection BY REPLAY. The only real duplicate.
            acc

          true ->
            # Everything else is delivered. A live frame is never withheld because a
            # HIGHER one arrived first: it is not a duplicate, and withholding it loses
            # it for good — replay serves rows after the client's own cursor, which has
            # already moved past it, so no reconnect restores it.
            deliver.(e.pid, payload)
            acc
        end
      end)

    {:reply, :ok, %{state | conns: conns}}
  end

  def handle_call({:broadcast, owner, payload, deliver}, _from, state) do
    for {_ref, e} <- state.conns,
        e.user_id == owner and MapSet.member?(e.subscriptions, "chat"),
        do: deliver.(e.pid, payload)

    {:reply, :ok, state}
  end

  def handle_call({:publish_work_state, owner, payload, deliver}, _from, state) do
    for {_ref, e} <- state.conns,
        e.user_id == owner and MapSet.member?(e.subscriptions, "work_state"),
        do: deliver.(e.pid, payload)

    {:reply, :ok, state}
  end

  def handle_call({:publish_work_item, owners, payload, deliver}, _from, state) do
    for {_ref, e} <- state.conns,
        MapSet.member?(owners, e.user_id) and MapSet.member?(e.subscriptions, "work_state"),
        do: deliver.(e.pid, payload)

    {:reply, :ok, state}
  end

  def handle_call({:within_rate_limit, device_id, kind, limit, window_ms}, _from, state) do
    now = System.monotonic_time(:millisecond)
    key = {device_id, kind}
    recent = state.rate_windows |> Map.get(key, []) |> Enum.filter(&(&1 > now - window_ms))
    allowed = length(recent) < limit
    windows = Map.put(state.rate_windows, key, if(allowed, do: [now | recent], else: recent))
    {:reply, allowed, %{state | rate_windows: windows}}
  end

  @impl true
  def handle_cast({:unregister, ref}, state) do
    case state.conns[ref] do
      nil ->
        {:noreply, state}

      e ->
        # Generation guard: only clear the device slot if THIS ref still owns it.
        devices =
          case state.devices[e.device_id] do
            %{ref: ^ref} -> Map.delete(state.devices, e.device_id)
            _ -> state.devices
          end

        {:noreply, %{state | conns: Map.delete(state.conns, ref), devices: devices}}
    end
  end

  def handle_cast({:note_replayed, ref, session_key, seq}, state) do
    case state.conns[ref] do
      nil ->
        {:noreply, state}

      _ ->
        {:noreply,
         update_in(state.conns[ref].replayed_through[session_key], fn cur ->
           max(cur || 0, seq)
         end)}
    end
  end

  defp maybe_drop(conns, nil), do: conns
  defp maybe_drop(conns, ref), do: Map.delete(conns, ref)
end
