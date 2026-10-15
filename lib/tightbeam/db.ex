defmodule Tightbeam.DB do
  @moduledoc """
  Single-writer database owner. Transactions and statements that write are
  serialized here. File-backed databases also open four read-only connections
  for plain queries, so WAL readers do not wait behind a writer. Private
  in-memory databases retain their single connection.
  """

  use GenServer
  require Logger
  alias Exqlite.Sqlite3
  alias Tightbeam.{DBObservation, ErrorDiagnostic}

  defmodule Migration do
    @moduledoc false
    @enforce_keys [:server]
    defstruct [:server]
    @type t :: %__MODULE__{server: GenServer.server()}
  end

  @typedoc "The DB owner, or its explicit boot-only migration context."
  @type server :: GenServer.server() | Migration.t()

  @doc """
  Give schema bootstrap an explicit unbounded client context. Pass this value
  through delegated schema calls; it changes neither the owner nor application
  configuration. Discard it after bootstrap. Runtime callers keep their bounded
  server handle, and SQLite's separate lock-wait bound is unchanged.
  """
  @spec migration_context(server()) :: Migration.t()
  def migration_context(%Migration{} = context), do: context
  def migration_context(server), do: %Migration{server: server}

  @typedoc "One result row, positional (SELECT column order)."
  @type row :: [term()]

  defmodule Error do
    @moduledoc "SQLite failure surfaced as an exception (exqlite returns tuples; we raise)."
    defexception [:message]
  end

  defmodule Timeout do
    @moduledoc "A sanitized caller timeout; never contains SQL, params or the DB message."
    defexception [
      :request_id,
      :db_call_id,
      :operation,
      :effect_kind,
      :elapsed_ms,
      :budget_ms,
      timeout_source: "otp_db_call",
      effect_state: "unknown",
      message: "database operation timed out"
    ]
  end

  defmodule ReferenceFenceError do
    @moduledoc "A reference write was refused while an archetype is being released."
    defexception [:archetypes]

    @impl true
    def message(%__MODULE__{archetypes: archetypes}) do
      "archetype release in progress: #{Enum.join(archetypes, ", ")}"
    end
  end

  defmodule DeadlineExceeded do
    @moduledoc false
    defexception message: "database transaction deadline exceeded"
  end

  defmodule Overloaded do
    @moduledoc "The database owner has reached its fixed queue limit; retry later."
    defexception message: "database owner overloaded"
  end

  @queue_limit 128
  @deadline_key {__MODULE__, :deadline}
  @statement_cache_key {__MODULE__, :statement_cache}
  # Bound per-connection statement memory while letting recent hot queries stay cached.
  @statement_cache_limit 64

  @doc false
  def overloaded?(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, length} -> length >= @queue_limit
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc false
  def background_pass(fun, deferred \\ :ok) do
    case fun.() do
      {:error, %Overloaded{}} ->
        Logger.debug("database overloaded; background pass deferred")
        deferred

      result ->
        result
    end
  rescue
    _error in Overloaded ->
      Logger.debug("database overloaded; background pass deferred")
      deferred

    error in MatchError ->
      if match?({:error, %Overloaded{}}, error.term) do
        Logger.debug("database overloaded; background pass deferred")
        deferred
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc false
  def reader(server, sql) do
    if Regex.match?(~r/\A(?:\s|--[^\n]*(?:\n|$)|\/\*[\s\S]*?\*\/)*(SELECT|WITH|EXPLAIN)\b/i, sql) do
      with pid when is_pid(pid) <- GenServer.whereis(server),
           [_ | _] = readers <- :persistent_term.get({__MODULE__, pid}, []) do
        Enum.at(readers, :erlang.phash2(self(), length(readers)))
      else
        _ -> nil
      end
    else
      nil
    end
  end

  @doc false
  def read_query(conn, sql, params) do
    {:ok, run_query(conn, sql, params)}
  rescue
    error -> {:error, error}
  end

  @doc false
  def enable_statement_cache(conn) do
    key = {@statement_cache_key, conn}
    if is_nil(Process.get(key)), do: Process.put(key, %{})
    :ok
  end

  @doc false
  def clear_statement_cache(conn) do
    case Process.delete({@statement_cache_key, conn}) do
      cache when is_map(cache) ->
        Enum.each(Map.values(cache), &Sqlite3.release(conn, &1))

      _ ->
        :ok
    end

    :ok
  end

  @doc false
  def statement_cache_size(conn) do
    case Process.get({@statement_cache_key, conn}) do
      cache when is_map(cache) -> map_size(cache)
      _ -> 0
    end
  end

  ## Client

  # How long a client waits for the owner to answer. Every call here used to
  # take the inherited GenServer default of 5s — not a knob, just what nobody
  # passed. Calls are short (prepared statements, microseconds); this bounds a
  # wedged or deeply queued owner, so it is a ceiling, not a budget.
  #
  # Validated once in `init/1` rather than on this path: the DB client path is
  # hot, and a bad value should stop the owner starting, not surface as a
  # per-call crash.
  # 30s is a conservative queue-plus-execution ceiling for a single serialized
  # runtime owner, not a migration budget. Ecto.Repo uses 15s per query and
  # SqlClient defaults to 30s of network reads (different semantics); our
  # supported transient owner backlog already exceeds GenServer's 5s default.
  # Keep this bounded, configurable ceiling without changing the 5s SQLite
  # lock wait. See docs/migration-timeouts.md for comparisons and limitations.
  @default_call_timeout_ms 30_000

  @doc "Configured client wait for a DB call, ms (`:db_call_timeout_ms`, default 30_000)."
  @spec call_timeout() :: pos_integer()
  def call_timeout do
    Application.get_env(:tightbeam, :db_call_timeout_ms, @default_call_timeout_ms)
  end

  @doc false
  @spec validate_call_timeout!() :: pos_integer()
  def validate_call_timeout! do
    case Application.get_env(:tightbeam, :db_call_timeout_ms, @default_call_timeout_ms) do
      ms when is_integer(ms) and ms > 0 ->
        ms

      bad ->
        raise ArgumentError,
              ":db_call_timeout_ms must be a positive integer of milliseconds, got #{inspect(bad)}"
    end
  end

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
    observed_call(server, {:query, sql, params}, "db.query", call_timeout())
  end

  @doc false
  def query_for(server, operation, sql, params)
      when operation in ["auth.session_by_cli_token", "wake.due_scan"] do
    case server do
      %{__struct__: Tightbeam.DB.Txn} -> query(server, sql, params)
      _ -> observed_call(server, {:query, sql, params}, operation, call_timeout())
    end
  end

  @doc """
  `query/3` bounded by the caller's monotonic deadline.

  The wait is the SMALLER of the configured call timeout and the time left, so
  an enclosing deadline can only shorten it. Returns `DeadlineExceeded` rather
  than exiting, because a caller holding a deadline has somewhere else to be.
  """
  @spec query_until(server(), String.t(), [term()], integer()) ::
          {:ok, [row()]} | {:error, Exception.t() | term()}
  def query_until(server, sql, params, deadline) when is_integer(deadline) do
    case timeout_until(deadline) do
      :expired ->
        {:error, %DeadlineExceeded{}}

      timeout ->
        try do
          DBObservation.call(server, {:query, sql, params}, "db.query", timeout, :deadline)
        catch
          :exit, {:timeout, _} -> {:error, %DeadlineExceeded{}}
          :exit, reason -> {:error, reason}
        end
    end
  end

  defp timeout_until(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0, do: :expired, else: min(call_timeout(), remaining)
  end

  @doc "Execute DDL / statements without results."
  @spec execute(server(), String.t()) :: :ok | {:error, term()}
  def execute(server \\ __MODULE__, sql) do
    observed_call(server, {:execute, sql}, "db.execute", call_timeout())
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
    observed_call(server, {:transaction, fun}, "db.transaction", call_timeout())
  end

  @doc """
  Run a transaction only while the monotonic deadline remains available.

  The deadline is enforced by the DB owner, not only by the caller's wait:
  queued work is rejected before it starts, SQLite lock waits use the remaining
  time, and a callback that overruns is rolled back before commit.
  """
  @spec transaction_until(server(), (Tightbeam.DB.Txn.t() -> result), integer()) ::
          {:ok, result} | {:error, Exception.t() | term()}
        when result: term()
  def transaction_until(server \\ __MODULE__, fun, deadline)
      when is_function(fun, 1) and is_integer(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, %DeadlineExceeded{}}
    else
      try do
        DBObservation.call(
          server,
          {:transaction_until, fun, deadline},
          "db.transaction",
          remaining + 50,
          :deadline
        )
      catch
        :exit, {:timeout, _} -> {:error, %DeadlineExceeded{}}
        :exit, reason -> {:error, reason}
      end
    end
  end

  @doc """
  Commit one transaction, then run a publication callback after the owner has replied.

  An arity-one callback receives the prepared result in the caller process. Keeping arbitrary
  publication work out of the DB owner means a slow filesystem or Git operation cannot stop
  unrelated callers from being served. An arity-two callback receives the owner's transaction
  handle followed by the prepared result; it runs in a second transaction after the first
  commit. This is the row-commit recognition seam: the callback cannot recursively enter the
  DB owner.
  """
  def transaction_then(server \\ __MODULE__, prepare, after_commit)

  def transaction_then(server, prepare, after_commit)
      when is_function(prepare, 1) and is_function(after_commit) do
    transaction_then(server, prepare, after_commit, [])
  end

  @doc false
  def transaction_then(server, prepare, after_commit, opts)
      when is_function(prepare, 1) and is_function(after_commit) do
    deadline = System.monotonic_time(:millisecond) + call_timeout()

    case DBObservation.call(
           server,
           if(opts == [],
             do: {:transaction_then, prepare, after_commit},
             else: {:transaction_then, prepare, after_commit, opts}
           ),
           "db.transaction",
           call_timeout()
         ) do
      {:ok, %Tightbeam.Recognition.Pending{} = pending} ->
        Tightbeam.Recognition.inline(server, pending, after_commit, opts, deadline)

      other ->
        other
    end
  end

  @doc false
  def publish_transaction(server, callback) do
    DBObservation.call(
      server,
      {:transaction, callback},
      "db.transaction",
      call_timeout(),
      :publication
    )
  end

  @doc "Atomically check references and hold a monitored archetype-release fence."
  @spec begin_reference_fence(
          server(),
          [String.t()],
          (Tightbeam.DB.Txn.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, reference(), term()} | {:error, term()}
  def begin_reference_fence(server \\ __MODULE__, archetypes, check)
      when is_list(archetypes) and is_function(check, 1) do
    DBObservation.call(
      server,
      {:begin_reference_fence, Enum.uniq(archetypes), check, self()},
      "db.reference_fence",
      call_timeout()
    )
  end

  @doc "Release a fence previously returned by begin_reference_fence/3."
  @spec end_reference_fence(server(), reference()) :: :ok
  def end_reference_fence(server \\ __MODULE__, token) when is_reference(token) do
    DBObservation.call(
      server,
      {:end_reference_fence, token},
      "db.reference_fence",
      call_timeout()
    )
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
            query_trace: term(),
            fenced_archetypes: MapSet.t(),
            deadline: integer() | :infinity
          }
    defstruct [
      :conn,
      :outbox,
      :outbox_owner,
      :query_trace,
      fenced_archetypes: MapSet.new(),
      deadline: :infinity
    ]

    # Two independent guards on one transaction handle. `fenced_archetypes` is
    # reference safety and `deadline` is time; neither reads the other's field
    # and neither changes when the other fires. They are carried together only
    # because a transaction has exactly one handle.
    @doc false
    @spec assert_archetype_available!(t(), String.t()) :: :ok
    def assert_archetype_available!(%__MODULE__{fenced_archetypes: fenced}, archetype)
        when is_binary(archetype) do
      if MapSet.member?(fenced, archetype) do
        raise Tightbeam.DB.ReferenceFenceError, archetypes: [archetype]
      end

      :ok
    end

    @doc false
    def ensure_before_deadline(%__MODULE__{deadline: :infinity}), do: :ok

    def ensure_before_deadline(%__MODULE__{deadline: deadline})
        when is_integer(deadline) do
      if System.monotonic_time(:millisecond) < deadline do
        :ok
      else
        raise Tightbeam.DB.DeadlineExceeded
      end
    end

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
    def q(%__MODULE__{conn: conn, query_trace: trace} = txn, sql, params \\ []) do
      ensure_before_deadline(txn)
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
    def exec(%__MODULE__{conn: conn} = txn, sql) do
      ensure_before_deadline(txn)
      Tightbeam.DB.execute_sql!(conn, sql)
    end

    @doc "Rows changed by the last statement — the CAS check for guarded UPDATEs."
    @spec changes(t()) :: non_neg_integer()
    def changes(%__MODULE__{conn: conn} = txn) do
      ensure_before_deadline(txn)
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
  def prepare_schema(server),
    do: observed_call(server, :prepare_schema, "schema.ensure", call_timeout())

  @doc false
  def finish_schema(server),
    do: observed_call(server, :finish_schema, "schema.ensure", call_timeout())

  defp call(%Migration{server: server}, request) do
    operation = if is_tuple(request), do: elem(request, 0), else: request
    started = System.monotonic_time(:millisecond)
    Logger.info("database migration call #{operation}: begin")
    result = GenServer.call(server, request, :infinity)
    elapsed = System.monotonic_time(:millisecond) - started
    outcome = if match?({:error, _}, result), do: "failed", else: "finished"
    Logger.info("database migration call #{operation}: #{outcome} elapsed_ms=#{elapsed}")
    result
  end

  defp call(server, request), do: GenServer.call(server, request, call_timeout())

  # Current 0.1.9 schema bootstrap passes this explicit context through query,
  # DDL, and schema calls. Preserve its unbounded migration wait and logging;
  # only ordinary runtime owner calls use the diagnostic envelope.
  defp observed_call(%Migration{} = context, request, _operation, _budget),
    do: call(context, request)

  defp observed_call(server, request, operation, budget),
    do: DBObservation.call(server, request, operation, budget)

  @doc """
  Run a schema migration in the DB owner without the runtime client deadline.

  Migrations are serialized, transactional work whose duration is determined by
  the database size. They must not be sent through the ordinary bounded runtime
  calls: a caller timeout can leave the owner finishing the transaction while a
  cleanup call waits behind it and reports the wrong phase. The SQLite
  `busy_timeout` remains the connection's lock-wait bound; this `:infinity`
  applies only to the caller waiting for this migration result.

  Primary references: `GenServer.call/3` timeout semantics
  (https://www.erlang.org/doc/apps/stdlib/gen_server.html#call/3) and SQLite's
  `busy_timeout` pragma (https://sqlite.org/pragma.html#pragma_busy_timeout) and
  `ignore_check_constraints` pragma
  (https://sqlite.org/pragma.html#pragma_ignore_check_constraints).
  """
  @spec migration_transaction(
          server(),
          atom(),
          [String.t()],
          [String.t()],
          (Tightbeam.DB.Txn.t() -> result)
        ) :: {:ok, result} | {:error, Exception.t()}
        when result: term()
  def migration_transaction(server, label, before, restore, fun)
      when is_atom(label) and is_list(before) and is_list(restore) and is_function(fun, 1) do
    call(migration_context(server), {:migration_transaction, label, before, restore, fun})
  end

  @doc false
  def assert_base_admitted!(server, base) do
    case DBObservation.call(
           server,
           {:assert_base_admitted, base},
           "schema.ensure",
           call_timeout()
         ) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @impl true
  def init(opts) do
    # Before the connection: a bad call timeout stops this owner starting, which
    # under the tree's rest_for_one ordering stops the boot, rather than
    # crashing the first caller that happens to need the DB.
    _ = validate_call_timeout!()

    path = Keyword.fetch!(opts, :path)
    {path, admission} = prepare_persistent_admission!(path, opts)

    if admission do
      _ = Tightbeam.LiveBaseAdmission.revalidate!(admission)
      File.mkdir_p!(admission.base)
    end

    {:ok, conn} = Sqlite3.open(path)

    try do
      for pragma <- [
            "PRAGMA journal_mode=WAL",
            "PRAGMA foreign_keys=ON",
            "PRAGMA synchronous=NORMAL",
            "PRAGMA busy_timeout=5000"
          ] do
        execute_sql!(conn, pragma)
      end

      :ok = load_topline_unicode(conn)
      if path == ":memory:", do: :ok = Tightbeam.Recognition.ensure_sqlite_schema(conn)
      {:ok, retry} = Tightbeam.Recognition.start_link(self(), path == ":memory:")
      readers = open_readers(path)
      :persistent_term.put({__MODULE__, self()}, readers)

      {:ok,
       %{conn: conn, readers: readers, retry: retry, admission: admission, reference_fences: %{}}}
    rescue
      error ->
        :ok = Sqlite3.close(conn)
        reraise error, __STACKTRACE__
    end
  end

  defp open_readers(":memory:"), do: []

  defp open_readers(path) do
    Enum.map(1..4, fn _ ->
      {:ok, reader} = Tightbeam.DB.Reader.start_link(path)
      reader
    end)
  end

  defp prepare_persistent_admission!(":memory:", _opts), do: {":memory:", nil}

  defp prepare_persistent_admission!(path, opts) when is_binary(path) do
    alias Tightbeam.LiveBaseAdmission

    if String.starts_with?(path, "file:") or Path.basename(path) != "state.db",
      do: raise(ArgumentError, "persistent DB requires a canonical base/state.db path")

    base = LiveBaseAdmission.canonical!(Path.dirname(Path.expand(path)))

    payload =
      opts
      |> Keyword.get(:payload_root, Application.app_dir(:tightbeam))
      |> LiveBaseAdmission.canonical!()

    inputs = Keyword.fetch!(opts, :guard_inputs)

    unless Keyword.keyword?(inputs) and Enum.all?(Keyword.keys(inputs), &(&1 == :transition)),
      do: raise(ArgumentError, "guard inputs accept only an exact transition")

    admission = LiveBaseAdmission.prepare!(base, Keyword.put(inputs, :payload_root, payload))
    {Path.join(base, "state.db"), admission}
  end

  @impl true
  def terminate(_reason, %{conn: conn, readers: readers, retry: retry}) do
    Process.unlink(retry)
    Process.exit(retry, :shutdown)
    :persistent_term.erase({Tightbeam.Recognition, self()})
    :persistent_term.erase({__MODULE__, self()})
    Enum.each(readers, &GenServer.stop/1)
    :ok = clear_statement_cache(conn)
    # close_v2 may defer destruction until remaining statements finalize.
    # Abnormal process death uses the same Exqlite resource destructor.
    Sqlite3.close(conn)
    :ok
  end

  @impl true
  def handle_call({:db_call, envelope, payload}, from, state) do
    # Delegate to the existing handler so admission, fences, deadlines and all
    # state transitions retain their current owner and ordering (R2/R3).
    DBObservation.server(envelope, 5_000, fn ->
      with_deadline(
        envelope.deadline,
        fn ->
          handle_call(payload, from, state)
        end,
        state
      )
    end)
  end

  defp observed_transaction(callback, state, run) do
    case DBObservation.transaction_metadata(callback) do
      {:ok, envelope, original_callback} ->
        DBObservation.server(envelope, 5_000, fn ->
          with_deadline(envelope.deadline, fn -> run.(original_callback) end, state)
        end)

      :none ->
        run.(callback)
    end
  end

  defp with_deadline(deadline, fun, state) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:reply, {:error, %DeadlineExceeded{}}, state}
    else
      previous = Process.put(@deadline_key, deadline)

      try do
        fun.()
      after
        if previous, do: Process.put(@deadline_key, previous), else: Process.delete(@deadline_key)
      end
    end
  end

  def handle_call({:assert_base_admitted, base}, _from, state) do
    unless state.admission && Tightbeam.LiveBaseAdmission.canonical!(base) == state.admission.base,
      do: raise(ArgumentError, "startup requires this base's persistent DB admission")

    :ok = Tightbeam.LiveBaseAdmission.validate_owned_files!(state.admission)
    {:reply, :ok, state}
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call(:finish_schema, _from, %{admission: nil, conn: conn} = state) do
    :ok = enable_statement_cache(conn)
    {:reply, :ok, state}
  end

  def handle_call(:finish_schema, _from, %{conn: conn, admission: admission} = state) do
    rows = run_query(conn, "SELECT shape FROM schema_stamp", [])
    current = Tightbeam.LiveBaseAdmission.publish_marker!(admission, rows)
    :ok = enable_statement_cache(conn)
    {:reply, :ok, %{state | admission: current}}
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call(:prepare_schema, _from, %{conn: conn, admission: admission} = state) do
    execute_sql!(conn, "BEGIN IMMEDIATE")

    try do
      if admission && admission.stamp != :fresh do
        rows = run_query(conn, "SELECT shape FROM schema_stamp", [])

        unless rows == admission.stamp,
          do:
            raise(Tightbeam.Schema.ShapeError, message: "schema changed after guarded inspection")

        :ok = Tightbeam.Schema.qualify_guard_stamp!(admission.decision, rows)
      end

      :ok =
        execute_sql!(conn, """
        CREATE TABLE IF NOT EXISTS schema_stamp (
          shape TEXT PRIMARY KEY,
          stampedAt INTEGER NOT NULL
        );
        """)

      execute_sql!(conn, "COMMIT")
      {:reply, :ok, state}
    rescue
      error ->
        execute_sql!(conn, "ROLLBACK")
        {:reply, {:error, error}, state}
    end
  end

  def handle_call(
        {:migration_transaction, label, before, restore, fun},
        _from,
        %{conn: conn} = state
      ) do
    Logger.info("database migration #{label}: begin")
    Process.put(row_commit_key(conn), [])

    result =
      try do
        :ok = execute_migration_pragmas(conn, before)
        commit_phase(conn, fun, fenced_archetypes(state))
      rescue
        error -> {:error, error}
      after
        Process.delete(row_commit_key(conn))
      end

    case restore_migration_pragmas(conn, restore) do
      [] ->
        outcome = if match?({:ok, _}, result), do: "committed", else: "failed"
        Logger.info("database migration #{label}: #{outcome}; runtime checks restored")
        {:reply, result, state}

      errors ->
        primary =
          case result do
            {:error, error} -> Exception.message(error)
            {:ok, _} -> "transaction committed"
          end

        error = %Error{
          message: "migration #{label}: #{primary}; pragma restoration failed: #{inspect(errors)}"
        }

        # Never reuse a connection whose enforcement state could not be restored.
        # Preserve the primary failure alongside the cleanup failure.
        {:stop, error, {:error, error}, state}
    end
  end

  def handle_call({:query, sql, params}, _from, %{conn: conn} = state) do
    reply =
      if DBObservation.audit_active?() do
        commit_phase(conn, fn txn -> Txn.q(txn, sql, params) end, fenced_archetypes(state))
      else
        {:ok, run_query(conn, sql, params)}
      end

    {:reply, reply, state}
  rescue
    e -> {:reply, {:error, e}, state}
  end

  def handle_call({:execute, sql}, _from, %{conn: conn} = state) do
    reply =
      if DBObservation.audit_active?() do
        case commit_phase(conn, fn _ -> execute_sql!(conn, sql) end, fenced_archetypes(state)) do
          {:ok, :ok} -> :ok
          error -> error
        end
      else
        execute_sql(conn, sql)
      end

    {:reply, reply, state}
  end

  def handle_call({:transaction, fun}, _from, %{conn: conn} = state) do
    observed_transaction(fun, state, fn callback ->
      Process.put(row_commit_key(conn), [])

      try do
        {:reply, commit_phase(conn, callback, fenced_archetypes(state)), state}
      after
        Process.delete(row_commit_key(conn))
      end
    end)
  end

  def handle_call({:transaction_until, fun, deadline}, _from, %{conn: conn} = state) do
    observed_transaction(fun, state, fn callback ->
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        DBObservation.sqlite_budget(nil)
        {:reply, {:error, %DeadlineExceeded{}}, state}
      else
        DBObservation.sqlite_budget(max(remaining, 1))
        execute_sql!(conn, "PRAGMA busy_timeout=#{max(remaining, 1)}")
        Process.put(row_commit_key(conn), [])

        try do
          {:reply, commit_phase(conn, callback, fenced_archetypes(state), deadline), state}
        after
          Process.delete(row_commit_key(conn))
          restored = execute_sql(conn, "PRAGMA busy_timeout=5000")
          if restored != :ok, do: DBObservation.cleanup_failure(restored)
        end
      end
    end)
  end

  def handle_call(
        {:transaction_then, prepare, after_commit},
        from,
        state
      ) do
    handle_call({:transaction_then, prepare, after_commit, []}, from, state)
  end

  def handle_call(
        {:transaction_then, prepare, after_commit, opts},
        _from,
        %{conn: conn} = state
      )
      when is_function(after_commit) do
    observed_transaction(prepare, state, fn callback ->
      Process.put(row_commit_key(conn), [])

      try do
        reply =
          commit_phase(
            conn,
            fn txn ->
              result = callback.(txn)
              transitions = take_row_commits(txn)
              Tightbeam.Recognition.record(txn, after_commit, result, transitions, opts)
            end,
            fenced_archetypes(state)
          )

        {:reply, reply, state}
      after
        Process.delete(row_commit_key(conn))
      end
    end)
  end

  def handle_call(
        {:begin_reference_fence, archetypes, check, owner},
        _from,
        %{conn: conn, reference_fences: fences} = state
      ) do
    case overlapping_fences(fences, archetypes) do
      [] ->
        case fence_check_phase(conn, check, fenced_archetypes(state)) do
          {:ok, result} ->
            token = make_ref()
            monitor = Process.monitor(owner)

            fence = %{archetypes: MapSet.new(archetypes), owner: owner, monitor: monitor}

            {:reply, {:ok, token, result},
             %{state | reference_fences: Map.put(fences, token, fence)}}

          {:error, error} ->
            {:reply, {:error, error}, state}
        end

      overlapping ->
        {:reply, {:error, %ReferenceFenceError{archetypes: overlapping}}, state}
    end
  end

  def handle_call(
        {:end_reference_fence, token},
        {owner, _tag},
        %{reference_fences: fences} = state
      ) do
    case Map.get(fences, token) do
      %{owner: ^owner, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, %{state | reference_fences: Map.delete(fences, token)}}

      nil ->
        {:reply, :ok, state}

      _fence ->
        {:reply, {:error, :not_fence_owner}, state}
    end
  end

  @impl true
  def handle_cast({:dispatch_audit, record, deadline}, %{conn: conn} = state) do
    case commit_phase(conn, record, fenced_archetypes(state), deadline) do
      {:ok, _} -> :ok
      {:error, _} -> Logger.warning("dispatch audit could not be recorded")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, %{reference_fences: fences} = state) do
    fences =
      Enum.reduce(fences, fences, fn {token, fence}, acc ->
        if fence.monitor == monitor and fence.owner == owner,
          do: Map.delete(acc, token),
          else: acc
      end)

    {:noreply, %{state | reference_fences: fences}}
  end

  defp row_commit_key(conn), do: {__MODULE__, :row_commits, conn}

  defp execute_migration_pragmas(conn, statements) do
    Enum.each(statements, fn statement -> :ok = Sqlite3.execute(conn, statement) end)
    :ok
  end

  defp restore_migration_pragmas(conn, statements) do
    Enum.flat_map(statements, fn statement ->
      case Sqlite3.execute(conn, statement) do
        :ok -> []
        error -> [{statement, error}]
      end
    end)
  end

  @commit_phase_key {__MODULE__, :commit_phase}

  # Each real transaction owns a distinct queue. Invalidate it before sending
  # casts; later recognition failure cannot undo the first committed phase.
  # Runtime calls inherit their caller's absolute deadline. Explicit deadlines
  # can shorten it; migration callbacks retain an unbounded transaction handle.
  defp commit_phase(conn, fun, fenced_archetypes, deadline \\ nil) do
    deadline =
      case {deadline, Process.get(@deadline_key, :infinity)} do
        {nil, inherited} -> inherited
        {explicit, :infinity} -> explicit
        {explicit, inherited} -> min(explicit, inherited)
      end

    token = make_ref()
    key = {Txn, :outbox, token}
    Process.put(key, [])

    txn = %Txn{
      conn: conn,
      outbox: token,
      outbox_owner: self(),
      fenced_archetypes: fenced_archetypes,
      deadline: deadline
    }

    previous_phase = Process.get(@commit_phase_key)
    Process.put(@commit_phase_key, :before_begin)

    outcome =
      try do
        # Before BEGIN, so an already-spent deadline never opens a transaction.
        # This raise is why the outer rescue below exists: there is nothing to
        # roll back yet.
        Txn.ensure_before_deadline(txn)
        Process.put(@commit_phase_key, :begin)
        execute_sql!(conn, "BEGIN IMMEDIATE")

        try do
          Process.put(@commit_phase_key, :callback)

          changes_before =
            if DBObservation.audit_active?(), do: Txn.q(txn, "SELECT total_changes()")

          result = DBObservation.callback(fn -> fun.(txn) end)

          if changes_before do
            changes_after = Txn.q(txn, "SELECT total_changes()")
            DBObservation.audit_in_txn(txn, changes_after != changes_before)
          end

          Process.put(@commit_phase_key, :before_commit)
          Txn.ensure_before_deadline(txn)
          Process.put(@commit_phase_key, :commit)
          execute_sql!(conn, "COMMIT")
          {:committed, result, Enum.reverse(Process.get(key))}
        rescue
          error ->
            origin_stacktrace = __STACKTRACE__
            failed_phase = Process.get(@commit_phase_key)

            # Not `:ok =`: under a deadline the busy_timeout is the remaining
            # time, so ROLLBACK can itself fail, and asserting on it would
            # replace the real error with a MatchError.
            #
            # But the result may not be DISCARDED either. This is the only place
            # that learns the connection was not restored, and the tuple below
            # asserts a rollback that may not have happened. Say so, and still
            # return the real error.
            Process.put(@commit_phase_key, :rollback)

            case execute_sql(conn, "ROLLBACK") do
              :ok ->
                {:rolled_back, caller_error(error, failed_phase, origin_stacktrace)}

              other ->
                DBObservation.cleanup_failure(other)
                log_rollback_failure(other)

                cleanup = DBObservation.cleanup_failure_diagnostic(other)

                {:rolled_back, caller_error(error, failed_phase, origin_stacktrace, cleanup)}
            end
        end
      rescue
        error ->
          {:rolled_back, caller_error(error, Process.get(@commit_phase_key), __STACKTRACE__)}
      after
        Process.delete(key)
        restore_commit_phase(previous_phase)
      end

    case outcome do
      {:committed, result, handoffs} ->
        Enum.each(handoffs, &deliver_handoff/1)
        {:ok, result}

      {:rolled_back, error} ->
        {:error, error}
    end
  end

  defp caller_error(error, phase, stacktrace, cleanup \\ nil) do
    existing_diagnostic = Map.get(error, :diagnostic) || Map.get(error, "diagnostic")
    facts = [operation: "db.transaction", origin: "db_owner"]
    facts = if is_atom(phase), do: facts ++ [phase: Atom.to_string(phase)], else: facts

    facts =
      case existing_diagnostic do
        node when is_map(node) -> facts ++ [cause: node]
        nil -> facts
        other -> facts ++ [reason_cause: other]
      end

    diagnostic = ErrorDiagnostic.exception(error, stacktrace, facts)
    diagnostic = if cleanup, do: Map.put(diagnostic, "cleanup", cleanup), else: diagnostic
    ErrorDiagnostic.put(error, diagnostic)
  end

  defp log_rollback_failure(result) do
    case DBObservation.sqlite_class(result) do
      nil -> Logger.error("transaction rollback failed")
      result_class -> Logger.error("transaction rollback failed (#{result_class})")
    end
  end

  defp restore_commit_phase(nil), do: Process.delete(@commit_phase_key)
  defp restore_commit_phase(phase), do: Process.put(@commit_phase_key, phase)

  defp deliver_handoff({server, message}) do
    GenServer.cast(server, message)
  catch
    _, _ ->
      # A transport failure is not a database rollback or a consumer receipt.
      # Do not log arbitrary message, destination or exception contents.
      Logger.error("post-commit handoff transport failed")
      :ok
  end

  defp fenced_archetypes(%{reference_fences: fences}) do
    Enum.reduce(fences, MapSet.new(), fn {_token, fence}, acc ->
      MapSet.union(acc, fence.archetypes)
    end)
  end

  defp overlapping_fences(fences, archetypes) do
    wanted = MapSet.new(archetypes)

    fences
    |> Enum.flat_map(fn {_token, fence} ->
      MapSet.to_list(MapSet.intersection(wanted, fence.archetypes))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp fence_check_phase(conn, check, fenced_archetypes) do
    execute_sql!(conn, "BEGIN IMMEDIATE")

    try do
      result =
        DBObservation.callback(fn ->
          check.(%Txn{
            conn: conn,
            fenced_archetypes: fenced_archetypes,
            deadline: Process.get(@deadline_key, :infinity)
          })
        end)

      case result do
        {:ok, value} ->
          execute_sql!(conn, "COMMIT")
          {:ok, value}

        {:error, reason} ->
          execute_sql!(conn, "ROLLBACK")
          {:error, reason}

        other ->
          execute_sql!(conn, "ROLLBACK")
          {:error, {:invalid_reference_fence_check, other}}
      end
    rescue
      error ->
        execute_sql!(conn, "ROLLBACK")
        {:error, error}
    end
  end

  @doc false
  def run_query(conn, sql, params) do
    DBObservation.sqlite(fn -> run_query_measured(conn, sql, params) end)
  end

  @doc false
  def execute_sql(conn, sql), do: DBObservation.sqlite(fn -> Sqlite3.execute(conn, sql) end)

  @doc false
  def execute_sql!(conn, sql),
    do: DBObservation.sqlite(fn -> :ok = Sqlite3.execute(conn, sql) end)

  defp run_query_measured(conn, sql, params) do
    {stmt, cached?} = prepare_statement(conn, sql)

    try do
      bound = Sqlite3.bind(stmt, params)

      DBObservation.sqlite_error(bound, fn ->
        case bound do
          :ok -> :ok
          {:error, reason} -> raise Error, message: to_string(reason)
        end
      end)

      collect(conn, stmt, [])
    after
      unless cached?, do: Sqlite3.release(conn, stmt)
    end
  end

  defp prepare_statement(conn, sql) do
    key = {@statement_cache_key, conn}

    case Process.get(key) do
      cache when is_map(cache) ->
        case Map.fetch(cache, sql) do
          {:ok, stmt} ->
            {stmt, true}

          :error when map_size(cache) < @statement_cache_limit ->
            {:ok, stmt} = Sqlite3.prepare(conn, sql)
            Process.put(key, Map.put(cache, sql, stmt))
            {stmt, true}

          :error ->
            Process.put(key, %{})
            Enum.each(Map.values(cache), &Sqlite3.release(conn, &1))
            {:ok, stmt} = Sqlite3.prepare(conn, sql)
            Process.put(key, %{sql => stmt})
            {stmt, true}
        end

      _ ->
        {:ok, stmt} = Sqlite3.prepare(conn, sql)
        {stmt, false}
    end
  end

  defp collect(conn, stmt, acc) do
    result = Sqlite3.step(conn, stmt)

    DBObservation.sqlite_error(result, fn ->
      case result do
        {:row, row} -> collect(conn, stmt, [row | acc])
        :done -> Enum.reverse(acc)
        {:error, reason} -> raise Error, message: to_string(reason)
      end
    end)
  end

  @doc false
  def load_topline_unicode(conn) do
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
