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

  2. Persistent per-connection delivered-seq filter. Every message carries its
     per-session store `seq`. A connection tracks `lastDeliveredSeq` per
     session for its WHOLE lifetime (not just during replay drain): any push
     with seq <= lastDeliveredSeq is dropped. This suppresses a late
     publication of a pre-watermark commit forever, closing the
     replay/live race.

  ORDERING DEPENDENCY, AND IT IS UNMET: the filter above is safe ONLY if
  publications for a session arrive in commit (seq) order, and nothing
  currently provides that. Every publication happens AFTER its transaction has
  returned, from the caller's own process — `Projection.append/2` commits at
  projection.ex:95-96 and its caller publishes afterwards — so two writers to
  one session can commit in one order and publish in the other. When they do,
  this module drops the earlier frame at :161-162 and a connected client never
  sees it; only a reconnect's replay repairs it. This module enforces the
  per-connection monotonic filter and cannot enforce the ordering it rests on.

  The publication sites, every one of them post-commit: gateway.ex:1701 (an
  agent's reply, published from the turn's own task), :1043 (a delivery echo,
  from whichever process ran the dispatch — a socket, a wake, a control route),
  and :4142, :5195, :5767 (markers), all through the helper at :5772; plus
  event_log.ex:324, after the transaction opened at :297. SCOPE OF THAT LIST:
  it is the message path, read at 422ff58. The remaining `DB.transaction`
  callers were not audited, so treat it as where to start rather than as
  exhaustive, and re-derive the lines before trusting them.

  No reproduction is known. The client-e2e concurrency journey (J5) cannot
  produce one: its two streams keep separate cursors, and one stream's turns
  are serialized by its own lane, so it never puts two concurrent writers on a
  single session. Reaching this needs exactly that — a client post's echo
  against a marker appended by something else, at the same instant.

  Making publication ride commit order is a design in its own right and is not
  attempted here.
  """

  use GenServer

  @type server :: GenServer.server()

  @typedoc "Delivery function injected by the caller — `(pid, payload)`; tests capture, prod sends to the socket."
  @type deliver :: (pid(), term() -> any())

  defstruct conns: %{}, devices: %{}, rate_windows: %{}

  # conns:   ref => %{pid, user_id, device_id, is_admin, subscriptions, gen, delivered: %{session_key => seq}}
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
  server.ts broadcastMessage). Applies each connection's monotonic filter.
  `deliver` is `(pid, payload) -> any` — injected so tests capture without a
  real socket. Callers must publish in seq order (see the moduledoc ordering
  dependency).
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

  @doc "Advance a connection's delivered watermark during replay (per session)."
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
      delivered: %{}
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
      Enum.reduce(state.conns, state.conns, fn {ref, e}, acc ->
        cond do
          e.user_id != owner or not MapSet.member?(e.subscriptions, "chat") ->
            acc

          Map.get(e.delivered, session_key, 0) >= seq ->
            # already delivered (late pre-watermark publication) — drop forever
            acc

          true ->
            deliver.(e.pid, payload)
            put_in(acc[ref].delivered[session_key], seq)
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
         update_in(state.conns[ref].delivered[session_key], fn cur -> max(cur || 0, seq) end)}
    end
  end

  defp maybe_drop(conns, nil), do: conns
  defp maybe_drop(conns, ref), do: Map.delete(conns, ref)
end
