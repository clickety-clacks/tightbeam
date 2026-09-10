defmodule Tightbeam.DB do
  @moduledoc """
  The single-writer database owner — THE serialization seam (spec: SQLite
  ownership). One connection, owned by one process; every write goes through
  `transaction/1` here, so single-writer is a property of the topology, not a
  convention. Calls are short and bounded (prepared statements, microseconds);
  this GenServer deliberately serializes them.

  PRAGMAs are pinned on open: WAL, foreign_keys=ON, synchronous=NORMAL,
  busy_timeout=5000 (deliberate addition over the TS reference — recorded in
  the port spec). Reads share the same serialized connection in E1; a read
  pool is a later, additive concern.

  A function running inside a caller's transaction must never re-enter the DB
  owner by opening another connection or transaction. By convention,
  `*_in_txn(txn, ...)` helpers write only through the supplied transaction and
  never open their own; the five CAS tables remain separate modules by design.
  """

  use GenServer
  alias Exqlite.Sqlite3

  @typedoc "The DB owner process (name or pid) — pass a test-local name to isolate."
  @type server :: GenServer.server()

  @typedoc "One result row, positional (SELECT column order)."
  @type row :: [term()]

  defmodule Error do
    @moduledoc "SQLite failure surfaced as an exception (exqlite returns tuples; we raise)."
    defexception [:message]
  end

  ## Client

  @doc "Start the owner. Required: `:path` (SQLite file or `\":memory:\"`). Optional `:name`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Run one SQL statement with params; returns `{:ok, rows}` (rows are positional lists)."
  @spec query(server(), String.t(), [term()]) :: {:ok, [row()]} | {:error, Exception.t()}
  def query(server \\ __MODULE__, sql, params \\ [])

  def query(%{__struct__: Tightbeam.DB.Txn} = txn, sql, params) do
    {:ok, Tightbeam.DB.Txn.q(txn, sql, params)}
  rescue
    error -> {:error, error}
  end

  def query(server, sql, params) do
    GenServer.call(server, {:query, sql, params})
  end

  @doc "Execute DDL / statements without results."
  @spec execute(server(), String.t()) :: :ok | {:error, term()}
  def execute(server \\ __MODULE__, sql) do
    GenServer.call(server, {:execute, sql})
  end

  @doc """
  Run `fun` inside BEGIN IMMEDIATE … COMMIT, in the owner process — THE way to
  make a multi-statement change atomic. `fun` receives a `Txn` handle
  (`q/3`, `exec/2`, `changes/1`); any raise rolls back and is returned as
  `{:error, exception}`. Returns `{:ok, fun_result}` on commit.
  """
  @spec transaction(server(), (Tightbeam.DB.Txn.t() -> result)) ::
          {:ok, result} | {:error, Exception.t()}
        when result: term()
  def transaction(server \\ __MODULE__, fun) when is_function(fun, 1) do
    GenServer.call(server, {:transaction, fun})
  end

  @doc """
  Commit one transaction, then run a bounded publication callback before releasing the owner.

  An arity-one callback receives the prepared result and retains the original publication
  semantics. An arity-two callback receives the owner's transaction handle followed by the
  prepared result; it runs in a second transaction after the first commit. This is the
  row-commit recognition seam: the callback cannot recursively enter the DB owner.
  """
  def transaction_then(server \\ __MODULE__, prepare, after_commit)
      when is_function(prepare, 1) and
             (is_function(after_commit, 1) or is_function(after_commit, 2)) do
    GenServer.call(server, {:transaction_then, prepare, after_commit})
  end

  ## Txn handle passed to transaction callbacks (runs inside the owner process)

  require Logger

  defmodule Txn do
    @moduledoc """
    Handle passed to `Tightbeam.DB.transaction/2` callbacks. Runs in the owner
    process — never hold one outside the callback. Errors RAISE (rolling the
    transaction back) rather than returning tuples.
    """
    @type t :: %__MODULE__{
            conn: reference(),
            outbox: reference() | nil,
            outbox_owner: pid() | nil,
            query_trace: term()
          }
    defstruct [:conn, :outbox, :outbox_owner, :query_trace]

    @doc false
    def observe_queries(%__MODULE__{} = txn, trace), do: %{txn | query_trace: trace}

    @doc "Queue a nonblocking handoff for this transaction's successful COMMIT."
    def handoff(%__MODULE__{outbox: token, outbox_owner: owner}, server, message)
        when is_reference(token) and owner == self() do
      key = {__MODULE__, :outbox, token}

      case Process.get(key) do
        pending when is_list(pending) ->
          Process.put(key, [{server, message} | pending])
          :ok

        _ ->
          raise ArgumentError, "transaction handoff used outside its live phase"
      end
    end

    def handoff(%__MODULE__{}, _server, _message),
      do: raise(ArgumentError, "transaction handoff used outside its owner")

    @doc "Run one SQL statement inside the transaction; returns rows (positional lists)."
    @spec q(t(), String.t(), [term()]) :: [Tightbeam.DB.row()]
    def q(%__MODULE__{conn: conn, query_trace: trace}, sql, params \\ []) do
      trace_query(trace, sql, params)
      Tightbeam.DB.run_query(conn, sql, params)
    end

    defp trace_query(nil, _sql, _params), do: :ok

    defp trace_query(pid, sql, params) when is_pid(pid) do
      send(pid, {:core_detail_trace, {:sql_query, sql, params}})
      :ok
    end

    defp trace_query(trace, sql, params) when is_function(trace, 1) do
      trace.({:sql_query, sql, params})
      :ok
    end

    @doc "Execute a statement without results inside the transaction."
    @spec exec(t(), String.t()) :: :ok
    def exec(%__MODULE__{conn: conn}, sql), do: :ok = Sqlite3.execute(conn, sql)

    @doc "Rows changed by the last statement — the CAS check for guarded UPDATEs."
    @spec changes(t()) :: non_neg_integer()
    def changes(%__MODULE__{conn: conn}) do
      {:ok, n} = Sqlite3.changes(conn)
      n
    end
  end

  @doc false
  def record_row_commit(%Txn{conn: conn}, transition) when is_map(transition) do
    key = row_commit_key(conn)
    Process.put(key, [transition | Process.get(key, [])])
    :ok
  end

  @doc false
  def take_row_commits(%Txn{conn: conn}) do
    key = row_commit_key(conn)
    transitions = key |> Process.get([]) |> Enum.reverse()
    Process.put(key, [])
    transitions
  end

  ## Server

  @doc false
  def prepare_schema(server), do: GenServer.call(server, :prepare_schema)

  @doc false
  def finish_schema(server), do: GenServer.call(server, :finish_schema)

  @doc false
  def assert_base_admitted!(server, base) do
    case GenServer.call(server, {:assert_base_admitted, base}) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    {path, admission} = prepare_persistent_admission!(path, opts)

    try do
      if admission do
        _ = Tightbeam.LiveBaseAdmission.revalidate!(admission)
        File.mkdir_p!(admission.base)
      end

      {:ok, conn} = Sqlite3.open(path)

      try do
        if admission, do: :ok = Tightbeam.LiveBaseLock.attach_sqlite!(admission.lock, conn)

        for pragma <- [
              "PRAGMA journal_mode=WAL",
              "PRAGMA foreign_keys=ON",
              "PRAGMA synchronous=NORMAL",
              "PRAGMA busy_timeout=5000"
            ] do
          :ok = Sqlite3.execute(conn, pragma)
        end

        :ok = load_topline_unicode(conn)
        {:ok, %{conn: conn, admission: admission}}
      rescue
        error ->
          :ok = Sqlite3.close(conn)
          reraise error, __STACKTRACE__
      end
    rescue
      error ->
        if admission, do: :ok = Tightbeam.LiveBaseLock.release(admission.lock)
        reraise error, __STACKTRACE__
    end
  end

  defp prepare_persistent_admission!(":memory:", _opts), do: {":memory:", nil}

  defp prepare_persistent_admission!(path, opts) when is_binary(path) do
    alias Tightbeam.{LiveBaseAdmission, LiveBaseLock}

    if String.starts_with?(path, "file:") or Path.basename(path) != "state.db",
      do: raise(ArgumentError, "persistent DB requires a canonical base/state.db path")

    base = LiveBaseAdmission.canonical!(Path.dirname(Path.expand(path)))
    payload = LiveBaseAdmission.canonical!(Application.app_dir(:tightbeam))

    admission =
      case Keyword.fetch(opts, :guard_context) do
        {:ok, context} when is_map(context) ->
          unless context.base == base and context.payload_root == payload,
            do: raise(ArgumentError, "guard handoff must bind base and running payload")

          :ok = LiveBaseLock.claim(context.lock)

          try do
            LiveBaseAdmission.revalidate!(context)
          rescue
            error ->
              :ok = LiveBaseLock.release(context.lock)
              reraise error, __STACKTRACE__
          end

        {:ok, _} ->
          raise ArgumentError, "guard handoff requires an owned native capability"

        :error ->
          inputs = Keyword.fetch!(opts, :guard_inputs)

          unless Keyword.keyword?(inputs) and
                   Enum.all?(Keyword.keys(inputs), &(&1 in [:lock_dir, :transition])),
                 do:
                   raise(ArgumentError, "guard inputs accept only lock_dir and exact transition")

          LiveBaseAdmission.prepare!(base, Keyword.put(inputs, :payload_root, payload))
      end

    {Path.join(base, "state.db"), admission}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) do
    # A native guard attachment belongs to SQLite itself. close_v2 may defer
    # destruction until remaining statements finalize; never unlock separately
    # here. Abnormal process death uses the same Exqlite resource destructor.
    Sqlite3.close(conn)
    :ok
  end

  @impl true
  def handle_call({:assert_base_admitted, base}, _from, state) do
    unless state.admission && Tightbeam.LiveBaseAdmission.canonical!(base) == state.admission.base,
      do: raise(ArgumentError, "startup requires this base's persistent DB admission")

    :ok = Tightbeam.LiveBaseAdmission.validate_owned_files!(state.admission)
    {:reply, :ok, state}
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call(:finish_schema, _from, %{admission: nil} = state),
    do: {:reply, :ok, state}

  def handle_call(:finish_schema, _from, %{conn: conn, admission: admission} = state) do
    rows = run_query(conn, "SELECT shape FROM schema_stamp", [])
    current = Tightbeam.LiveBaseAdmission.publish_marker!(admission, rows)
    {:reply, :ok, %{state | admission: current}}
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call(:prepare_schema, _from, %{conn: conn, admission: admission} = state) do
    :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")

    try do
      if admission && admission.stamp != :fresh do
        rows = run_query(conn, "SELECT shape FROM schema_stamp", [])

        unless rows == admission.stamp,
          do:
            raise(Tightbeam.Schema.ShapeError, message: "schema changed after guarded inspection")

        :ok = Tightbeam.Schema.qualify_guard_stamp!(admission.decision, rows)
      end

      :ok =
        Sqlite3.execute(conn, """
        CREATE TABLE IF NOT EXISTS schema_stamp (
          shape TEXT PRIMARY KEY,
          stampedAt INTEGER NOT NULL
        );
        """)

      :ok = Sqlite3.execute(conn, "COMMIT")
      {:reply, :ok, state}
    rescue
      error ->
        :ok = Sqlite3.execute(conn, "ROLLBACK")
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:query, sql, params}, _from, %{conn: conn} = state) do
    {:reply, {:ok, run_query(conn, sql, params)}, state}
  rescue
    e -> {:reply, {:error, e}, state}
  end

  def handle_call({:execute, sql}, _from, %{conn: conn} = state) do
    {:reply, Sqlite3.execute(conn, sql), state}
  end

  def handle_call({:transaction, fun}, _from, %{conn: conn} = state) do
    Process.put(row_commit_key(conn), [])

    try do
      {:reply, commit_phase(conn, fun), state}
    after
      Process.delete(row_commit_key(conn))
    end
  end

  def handle_call({:transaction_then, prepare, after_commit}, _from, %{conn: conn} = state) do
    Process.put(row_commit_key(conn), [])

    try do
      reply =
        case commit_phase(conn, prepare) do
          {:ok, result} -> run_after_commit(conn, after_commit, result)
          {:error, error} -> {:error, error}
        end

      {:reply, reply, state}
    after
      Process.delete(row_commit_key(conn))
    end
  end

  defp row_commit_key(conn), do: {__MODULE__, :row_commits, conn}

  # Each real transaction owns a distinct queue. Invalidate it before sending
  # casts; later recognition failure cannot undo the first committed phase.
  defp commit_phase(conn, fun) do
    token = make_ref()
    key = {Txn, :outbox, token}
    Process.put(key, [])

    outcome =
      try do
        :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")

        try do
          result = fun.(%Txn{conn: conn, outbox: token, outbox_owner: self()})
          :ok = Sqlite3.execute(conn, "COMMIT")
          {:committed, result, Enum.reverse(Process.get(key))}
        rescue
          error ->
            :ok = Sqlite3.execute(conn, "ROLLBACK")
            {:rolled_back, error}
        end
      after
        Process.delete(key)
      end

    case outcome do
      {:committed, result, handoffs} ->
        Enum.each(handoffs, &deliver_handoff/1)
        {:ok, result}

      {:rolled_back, error} ->
        {:error, error}
    end
  end

  defp deliver_handoff({server, message}) do
    GenServer.cast(server, message)
  catch
    _, _ ->
      # A transport failure is not a database rollback or a consumer receipt.
      # Do not log arbitrary message, destination or exception contents.
      Logger.error("post-commit handoff transport failed")
      :ok
  end

  defp run_after_commit(_conn, after_commit, result) when is_function(after_commit, 1) do
    try do
      {:ok, after_commit.(result)}
    rescue
      error -> {:error, error}
    end
  end

  defp run_after_commit(conn, after_commit, result) when is_function(after_commit, 2) do
    commit_phase(conn, fn txn -> after_commit.(txn, result) end)
  end

  @doc false
  def run_query(conn, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)

    try do
      case Sqlite3.bind(stmt, params) do
        :ok -> :ok
        {:error, reason} -> raise Error, message: to_string(reason)
      end

      collect(conn, stmt, [])
    after
      Sqlite3.release(conn, stmt)
    end
  end

  defp collect(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> collect(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
      {:error, reason} -> raise Error, message: to_string(reason)
    end
  end

  defp load_topline_unicode(conn) do
    extension = if match?({:unix, :darwin}, :os.type()), do: ".dylib", else: ".so"
    path = Application.app_dir(:tightbeam, "priv/topline_unicode#{extension}")
    :ok = Sqlite3.enable_load_extension(conn, true)

    try do
      [[nil]] =
        run_query(conn, "SELECT load_extension(?1, 'sqlite3_topline_unicode_init')", [path])

      :ok
    after
      :ok = Sqlite3.enable_load_extension(conn, false)
    end
  end
end
