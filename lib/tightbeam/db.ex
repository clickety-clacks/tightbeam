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
  """

  use GenServer
  alias Exqlite.Sqlite3

  @type server :: GenServer.server()
  @type sql :: String.t()
  @type params :: [term()]
  @type rows :: [[term()]]
  @type state :: %{conn: reference()}

  defmodule Error do
    defexception [:message]
  end

  ## Client

  @doc "Start the single-writer database owner for the configured path."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Run one SQL statement with params; returns {:ok, rows} (list of lists)."
  @spec query(server(), sql(), params()) :: {:ok, rows()} | {:error, term()}
  def query(server \\ __MODULE__, sql, params \\ []) do
    GenServer.call(server, {:query, sql, params})
  end

  @doc "Execute DDL / statements without results."
  @spec execute(server(), sql()) :: :ok | {:error, term()}
  def execute(server \\ __MODULE__, sql) do
    GenServer.call(server, {:execute, sql})
  end

  @doc """
  Run `fun` inside BEGIN IMMEDIATE … COMMIT. `fun` receives a txn handle
  supporting `q/2` and `exec/1`; any raise rolls back and re-raises.
  Returns {:ok, fun_result}.
  """
  @spec transaction(server(), (Txn.t() -> term())) :: {:ok, term()} | {:error, term()}
  def transaction(server \\ __MODULE__, fun) when is_function(fun, 1) do
    GenServer.call(server, {:transaction, fun})
  end

  @doc "Rows changed by the last statement on this connection."
  @spec changes(server()) :: non_neg_integer()
  def changes(server \\ __MODULE__), do: GenServer.call(server, :changes)

  ## Txn handle passed to transaction callbacks (runs inside the owner process)

  defmodule Txn do
    @moduledoc "A transaction handle that keeps all statements on the owner's connection."
    @type t :: %__MODULE__{conn: reference()}
    defstruct [:conn]

    @doc "Run one query on the transaction's owned connection."
    @spec q(t(), Tightbeam.DB.sql(), Tightbeam.DB.params()) :: Tightbeam.DB.rows()
    def q(%__MODULE__{conn: conn}, sql, params \\ []),
      do: Tightbeam.DB.run_query(conn, sql, params)

    @doc "Execute one result-free statement on the transaction's owned connection."
    @spec exec(t(), Tightbeam.DB.sql()) :: :ok
    def exec(%__MODULE__{conn: conn}, sql), do: :ok = Sqlite3.execute(conn, sql)

    @doc "Return the rows changed by the transaction's last statement."
    @spec changes(t()) :: non_neg_integer()
    def changes(%__MODULE__{conn: conn}) do
      {:ok, n} = Sqlite3.changes(conn)
      n
    end
  end

  ## Server

  @doc "Open the database connection and pin the required PRAGMAs."
  @spec init(keyword()) :: {:ok, state()}
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

    {:ok, %{conn: conn}}
  end

  @doc "Handle serialized query, execution, transaction, and change-count calls."
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
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
    :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")

    try do
      result = fun.(%Txn{conn: conn})
      :ok = Sqlite3.execute(conn, "COMMIT")
      {:reply, {:ok, result}, state}
    rescue
      e ->
        :ok = Sqlite3.execute(conn, "ROLLBACK")
        {:reply, {:error, e}, state}
    end
  end

  def handle_call(:changes, _from, %{conn: conn} = state) do
    {:ok, n} = Sqlite3.changes(conn)
    {:reply, n, state}
  end

  @doc "Run a prepared query on the owner's connection and always release its statement."
  @spec run_query(reference(), sql(), params()) :: rows()
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
end
