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

  `transaction_then/3` is the one bounded exception to short database-only
  calls: it retains the owner as a writer fence while a committed marker guards
  one external publication.

  A function running inside a caller's transaction must never re-enter the DB
  owner by opening another connection or transaction. By convention,
  `*_in_txn(txn, ...)` helpers write only through the supplied transaction and
  never open their own; the five CAS tables remain separate modules by design.
  """

  use GenServer
  alias Exqlite.Sqlite3

  require Logger

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
  def query(server \\ __MODULE__, sql, params \\ []) do
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
  Commit one transaction, then run `after_commit` before releasing the DB owner.

  This is the publication fence for an external mutation that requires durable
  database evidence first. `prepare` receives a `Txn`; its result reaches
  `after_commit` only after COMMIT. Other database calls remain queued until
  `after_commit` returns. A prepare failure rolls back. An after-commit failure
  returns an error without rolling back the already durable transaction.
  """
  @spec transaction_then(
          server(),
          (Tightbeam.DB.Txn.t() -> prepared),
          (prepared -> result)
        ) :: {:ok, result} | {:error, Exception.t()}
        when prepared: term(), result: term()
  def transaction_then(server \\ __MODULE__, prepare, after_commit)
      when is_function(prepare, 1) and is_function(after_commit, 1) do
    GenServer.call(server, {:transaction_then, prepare, after_commit})
  end

  @doc """
  Run one atomic SQLite table rebuild while foreign-key enforcement is paused.

  The DB owner changes the pragma, transaction, integrity check, and restoration
  in one serialized call. Callers cannot observe or write through the connection
  while enforcement is off.
  """
  @spec foreign_key_rebuild(server(), (Tightbeam.DB.Txn.t() -> result)) ::
          {:ok, result} | {:error, Exception.t()}
        when result: term()
  def foreign_key_rebuild(server \\ __MODULE__, fun) when is_function(fun, 1) do
    GenServer.call(server, {:foreign_key_rebuild, fun})
  end

  ## Txn handle passed to transaction callbacks (runs inside the owner process)

  defmodule Txn do
    @moduledoc """
    Handle passed to `Tightbeam.DB.transaction/2` callbacks. Runs in the owner
    process — never hold one outside the callback. Errors RAISE (rolling the
    transaction back) rather than returning tuples.
    """
    @type t :: %__MODULE__{conn: reference(), outbox: reference(), query_trace: term()}
    defstruct [:conn, :outbox, :query_trace]

    @doc false
    def observe_queries(%__MODULE__{} = txn, trace), do: %{txn | query_trace: trace}

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

    @doc "Queue one nonblocking GenServer handoff for immediately after this transaction commits."
    @spec handoff(t(), GenServer.server(), term()) :: :ok
    def handoff(%__MODULE__{outbox: outbox}, server, message) do
      key = {__MODULE__, outbox}

      case Process.get(key) do
        handoffs when is_list(handoffs) ->
          Process.put(key, [{server, message} | handoffs])
          :ok

        nil ->
          raise ArgumentError, "transaction handoff used outside its transaction"
      end
    end
  end

  ## Server

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    {:ok, conn} = Sqlite3.open(path)

    for pragma <- [
          "PRAGMA journal_mode=WAL",
          "PRAGMA foreign_keys=ON",
          "PRAGMA synchronous=NORMAL",
          "PRAGMA busy_timeout=5000"
        ] do
      :ok = Sqlite3.execute(conn, pragma)
    end

    :ok = load_topline_unicode(conn)

    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_call({:query, sql, params}, _from, %{conn: conn} = state) do
    {:reply, {:ok, run_query(conn, sql, params)}, state}
  rescue
    e -> {:reply, {:error, e}, state}
  end

  def handle_call({:execute, sql}, _from, %{conn: conn} = state) do
    {:reply, Sqlite3.execute(conn, sql), state}
  end

  def handle_call({:transaction, fun}, _from, %{conn: conn} = state) do
    outbox = make_ref()
    outbox_key = {Txn, outbox}
    Process.put(outbox_key, [])
    :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")

    outcome =
      try do
        result = fun.(%Txn{conn: conn, outbox: outbox})
        :ok = Sqlite3.execute(conn, "COMMIT")
        {:committed, result, Process.get(outbox_key, []) |> Enum.reverse()}
      rescue
        e ->
          :ok = Sqlite3.execute(conn, "ROLLBACK")
          {:rolled_back, e}
      after
        Process.delete(outbox_key)
      end

    case outcome do
      {:committed, result, handoffs} ->
        Enum.each(handoffs, &deliver_handoff/1)
        {:reply, {:ok, result}, state}

      {:rolled_back, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:transaction_then, prepare, after_commit}, _from, %{conn: conn} = state) do
    outbox = make_ref()
    outbox_key = {Txn, outbox}
    Process.put(outbox_key, [])
    :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")

    prepared =
      try do
        result = prepare.(%Txn{conn: conn, outbox: outbox})
        :ok = Sqlite3.execute(conn, "COMMIT")
        {:committed, result, Process.get(outbox_key, []) |> Enum.reverse()}
      rescue
        error ->
          :ok = Sqlite3.execute(conn, "ROLLBACK")
          {:rolled_back, error}
      after
        Process.delete(outbox_key)
      end

    reply =
      case prepared do
        {:committed, result, handoffs} ->
          Enum.each(handoffs, &deliver_handoff/1)

          try do
            {:ok, after_commit.(result)}
          rescue
            error -> {:error, error}
          end

        {:rolled_back, error} ->
          {:error, error}
      end

    {:reply, reply, state}
  end

  def handle_call({:foreign_key_rebuild, fun}, _from, %{conn: conn} = state) do
    reply =
      try do
        :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys=OFF")
        :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")

        try do
          result = fun.(%Txn{conn: conn})

          case run_query(conn, "PRAGMA foreign_key_check", []) do
            [] -> :ok
            rows -> raise Error, message: "foreign key check failed: #{inspect(rows)}"
          end

          :ok = Sqlite3.execute(conn, "COMMIT")
          {:ok, result}
        rescue
          error ->
            :ok = Sqlite3.execute(conn, "ROLLBACK")
            {:error, error}
        end
      after
        :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")
      end

    {:reply, reply, state}
  end

  defp deliver_handoff({server, message}) do
    GenServer.cast(server, message)
  catch
    kind, reason ->
      Logger.error(
        "post-commit handoff to #{inspect(server)} failed: #{Exception.format(kind, reason)}"
      )

      :ok
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
