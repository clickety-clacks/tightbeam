defmodule Tightbeam.ManagedProcesses do
  @moduledoc """
  Durable custody for a process that outlives its launching turn.

  A process may outlive the turn that launched it only after it acquires a
  durable lease here. Otherwise the launching turn owns it and must terminate
  it when the turn ends (spec `art_6817803a` rev6 §B1).

  This record is deliberately NOT `harness_processes`. That one is adapter
  identity for a harness the coordinator owns; this one is general custody for
  any Tightbeam-owned process, and overloading it would tie two lifecycles that
  terminate for different reasons (§B2).

  ## What this module is, and is not

  It owns the row, the closed state set, and the compare-and-set discipline.
  It launches nothing, signals nothing, and reconciles nothing — those owners
  arrive in later steps and all of them mutate through `transition/4` so the
  revision rule holds in one place.

  ## Revision

  Every mutation names the state and revision it expects, changes exactly one
  row, and increments the revision. Zero changed rows means another transition
  won; the caller reloads and returns that durable result rather than retrying
  blind (§B2). This is the only concurrency primitive the later owners get.

  ## Two causes, never merged

  `stopCause` is why the process must stop. `uncertaintyCause` is why its
  identity cannot be proved. An identity uncertainty NEVER overwrites a stop
  cause (§B2, §B5) — a row can be simultaneously "must stop, ordered by
  retirement" and "cannot prove which PID that is", and collapsing those two
  into one column is how a process gets reported as stopped when nobody has
  proved anything about it.

  ## What must not be stored

  There is no column for a raw command line, environment values, credentials,
  or a device code, because there is no safe way to hold them here (§B2, §B6).
  A one-time code belongs to the authorized delivery sink alone; this row keeps
  only `deliveryEvidenceId` pointing at it. The absence of the column is the
  enforcement: a later contributor cannot write a secret to a field that does
  not exist.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @typedoc "The closed state set (§B3)."
  @type state ::
          :preparing
          | :launch_cancel_requested
          | :running
          | :stop_requested
          | :launch_failed
          | :launch_canceled
          | :exited
          | :killed
          | :stop_failed
          | :identity_unknown

  # Nonterminal: work is still expected to happen.
  @nonterminal ~w(preparing launch_cancel_requested running stop_requested)

  # Terminal: the physical fact is settled and nothing further is owed.
  @terminal ~w(launch_failed launch_canceled exited killed)

  # Durable UNRESOLVED. Not terminal, not proof the process lives, and not
  # deletable. These block retirement finalization until new evidence arrives
  # (§B3). `process-reconcile` is the repeatable repair, and the fail-closed
  # result is an accepted outcome rather than a bug to paper over.
  @unresolved ~w(stop_failed identity_unknown)

  @states @nonterminal ++ @terminal ++ @unresolved

  @stop_causes ~w(owner_stop lease_expired session_retired)
  @uncertainty_causes ~w(launch_handoff_unknown stop_signal_unproven boot_identity_mismatch)

  @doc "Every lawful state."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "States that still owe work."
  @spec nonterminal_states() :: [String.t()]
  def nonterminal_states, do: @nonterminal

  @doc "States whose physical fact is settled."
  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal

  @doc "States that block retirement until new evidence arrives."
  @spec unresolved_states() :: [String.t()]
  def unresolved_states, do: @unresolved

  @doc "States that block a session from finalizing retirement (§B5)."
  @spec retirement_blocking_states() :: [String.t()]
  def retirement_blocking_states, do: @nonterminal ++ @unresolved

  # The identity tuple that proves WHICH process this row is about. PID alone
  # never proves ownership — a reused PID after reboot is a different process —
  # so ownership requires all four (§B5).
  @identity_columns ~w(osPid processGroupId bootIdentity launchToken)

  @doc "The four columns that together prove process identity."
  @spec identity_columns() :: [String.t()]
  def identity_columns, do: @identity_columns

  # `stop_requested` and `running` are the two states that authorize acting on
  # a live process: one signals it, the other says the workload was released.
  # Both are meaningless without a proven identity, so the table refuses them
  # without the full tuple. This is a CHECK rather than a guard in Elixir
  # because a guard is advice to the next contributor and a CHECK is physics:
  # a stop request against an unknown PID cannot be written at all, which is
  # what stops us signalling a stranger's process. A stop wanted before
  # identity exists is `launch_cancel_requested` instead (§B3).
  @ddl """
  CREATE TABLE IF NOT EXISTS managed_processes (
    processId         TEXT PRIMARY KEY,
    ownerUserId       TEXT NOT NULL,
    ownerSessionKey   TEXT NOT NULL,
    sessionGeneration INTEGER NOT NULL,
    launchTurnSeq     INTEGER,
    host              TEXT NOT NULL,
    purpose           TEXT NOT NULL,
    commandDescriptor TEXT NOT NULL,
    osPid             INTEGER,
    processGroupId    INTEGER,
    bootIdentity      TEXT,
    launchToken       TEXT,
    brokerIdentity    TEXT,
    launchDeadline    INTEGER NOT NULL,
    leaseExpiresAt    INTEGER NOT NULL,
    cancelRequestedAt INTEGER,
    releaseGrantedAt  INTEGER,
    stopCause         TEXT CHECK (stopCause IS NULL OR stopCause IN
                      ('owner_stop','lease_expired','session_retired')),
    uncertaintyCause  TEXT CHECK (uncertaintyCause IS NULL OR uncertaintyCause IN
                      ('launch_handoff_unknown','stop_signal_unproven','boot_identity_mismatch')),
    stopAttemptCount  INTEGER NOT NULL DEFAULT 0 CHECK (stopAttemptCount >= 0),
    state             TEXT NOT NULL CHECK (state IN
                      ('preparing','launch_cancel_requested','running','stop_requested',
                       'launch_failed','launch_canceled','exited','killed',
                       'stop_failed','identity_unknown')),
    lastError         TEXT,
    -- The FOUR fields §B6 permits from a delivery receipt, and no more. The
    -- URL and one-time code are not among them: the authorized delivery row or
    -- the stopgap attest is the ONLY durable sink allowed to hold the code, and
    -- this row merely POINTS at it. `deliveryEventKind` is a safe label such as
    -- `device_code_emitted`, never the value that was emitted.
    deliveryEvidenceId  TEXT,
    deliveryResult      TEXT CHECK (deliveryResult IS NULL OR deliveryResult IN
                        ('succeeded','failed','timed_out')),
    deliveryProviderKind TEXT,
    deliveryEventKind   TEXT,
    createdAt         INTEGER NOT NULL,
    updatedAt         INTEGER NOT NULL,
    resolvedAt        INTEGER,
    revision          INTEGER NOT NULL CHECK (revision > 0),
    CHECK (state NOT IN ('running','stop_requested') OR
           (osPid IS NOT NULL AND processGroupId IS NOT NULL AND
            bootIdentity IS NOT NULL AND launchToken IS NOT NULL)),
    CHECK (releaseGrantedAt IS NULL OR state IN ('running','exited','killed','stop_requested','stop_failed','identity_unknown'))
  );
  """

  # THE RETIREMENT FENCE (§B5, built additively per owner authority att_54f4348d).
  #
  # rev6 §B5 asks for `sessions.state` to gain a `retiring` value between
  # `active` and `retired`. It cannot: `org.ex` declares
  # `CHECK (state IN ('active','retired'))`, its DDL is
  # `CREATE TABLE IF NOT EXISTS`, and `schema.ex` forbids in-place repair, so a
  # conformant third value would force the schema stamp to move and REFUSE every
  # database already in the field, live installs included. The owner approved
  # this additive shape instead: a separate row carries "this session is
  # retiring", and `sessions.state` flips straight to `retired` only when the
  # finalizer proves nothing is left to resolve.
  #
  # The row is the generation holder too. §B5 wants retirement to increment a
  # session generation so a late identity bind can tell that retirement moved on
  # underneath it; each retirement opens a fence at the next generation, and a
  # managed row captures that number at insert.
  #
  # Co-located with the process record on purpose: the fence exists ONLY to gate
  # process custody, and a new module would also have been a new file outside
  # this assignment's declared paths.
  @fence_ddl """
  CREATE TABLE IF NOT EXISTS session_retirement_fence (
    sessionKey      TEXT PRIMARY KEY,
    generation      INTEGER NOT NULL CHECK (generation > 0),
    state           TEXT NOT NULL CHECK (state IN ('retiring','retired')),
    retirementEpoch INTEGER NOT NULL CHECK (retirementEpoch >= 0),
    principal       TEXT NOT NULL,
    openedAt        INTEGER NOT NULL,
    finalizedAt     INTEGER,
    revision        INTEGER NOT NULL CHECK (revision > 0),
    CHECK ((state = 'retiring' AND finalizedAt IS NULL) OR
           (state = 'retired'  AND finalizedAt IS NOT NULL))
  );
  """

  @doc """
  Create the table and the indexes the later owners scan on.

  The census fence and the boot sweep both select every retirement-blocking row
  for one session, so that pair is indexed together (§B5).
  """
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    case DB.transaction(db, fn txn ->
           Txn.exec(txn, @ddl)
           Txn.exec(txn, @fence_ddl)

           Txn.exec(
             txn,
             "CREATE INDEX IF NOT EXISTS managed_processes_owner_state ON managed_processes (ownerSessionKey, state)"
           )

           Txn.exec(
             txn,
             "CREATE INDEX IF NOT EXISTS managed_processes_launch_deadline ON managed_processes (state, launchDeadline)"
           )

           Txn.exec(
             txn,
             "CREATE INDEX IF NOT EXISTS managed_processes_lease_expiry ON managed_processes (state, leaseExpiresAt)"
           )

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @columns ~w(processId ownerUserId ownerSessionKey sessionGeneration launchTurnSeq host
              purpose commandDescriptor osPid processGroupId bootIdentity launchToken
              brokerIdentity launchDeadline leaseExpiresAt cancelRequestedAt releaseGrantedAt
              stopCause uncertaintyCause stopAttemptCount state lastError deliveryEvidenceId
              deliveryResult deliveryProviderKind deliveryEventKind
              createdAt updatedAt resolvedAt revision)

  @select "SELECT #{Enum.join(@columns, ", ")} FROM managed_processes"

  @doc """
  Insert the `preparing` row that opens custody (§B5 step 1).

  The caller supplies the session generation it captured while proving the
  session active. Binding that generation here is what lets a later identity
  bind detect that retirement moved on in between, and refuse to expose
  `running` against a session that is already retiring.
  """
  @spec insert_preparing(Txn.t(), map()) :: {:ok, map()} | {:error, term()}
  def insert_preparing(txn, attrs) do
    row = %{
      process_id: Map.fetch!(attrs, :process_id),
      owner_user_id: Map.fetch!(attrs, :owner_user_id),
      owner_session_key: Map.fetch!(attrs, :owner_session_key),
      session_generation: Map.fetch!(attrs, :session_generation),
      launch_turn_seq: Map.get(attrs, :launch_turn_seq),
      host: Map.fetch!(attrs, :host),
      purpose: Map.fetch!(attrs, :purpose),
      command_descriptor: Map.fetch!(attrs, :command_descriptor),
      launch_deadline: Map.fetch!(attrs, :launch_deadline),
      lease_expires_at: Map.fetch!(attrs, :lease_expires_at),
      launch_token: Map.fetch!(attrs, :launch_token),
      now: Map.fetch!(attrs, :now)
    }

    Txn.q(
      txn,
      """
      INSERT INTO managed_processes
        (processId, ownerUserId, ownerSessionKey, sessionGeneration, launchTurnSeq, host,
         purpose, commandDescriptor, launchToken, launchDeadline, leaseExpiresAt,
         stopAttemptCount, state, createdAt, updatedAt, revision)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 0, 'preparing', ?12, ?12, 1)
      """,
      [
        row.process_id,
        row.owner_user_id,
        row.owner_session_key,
        row.session_generation,
        row.launch_turn_seq,
        row.host,
        row.purpose,
        row.command_descriptor,
        row.launch_token,
        row.launch_deadline,
        row.lease_expires_at,
        row.now
      ]
    )

    {:ok, get_in_txn(txn, row.process_id)}
  end

  @doc "Read one row, or nil."
  @spec get(DB.server(), String.t()) :: map() | nil
  def get(db \\ DB, process_id) do
    {:ok, rows} = DB.query(db, @select <> " WHERE processId = ?1", [process_id])

    case rows do
      [row] -> to_row(row)
      [] -> nil
    end
  end

  @doc "Read one row inside an open transaction, or nil."
  @spec get_in_txn(Txn.t(), String.t()) :: map() | nil
  def get_in_txn(txn, process_id) do
    case Txn.q(txn, @select <> " WHERE processId = ?1", [process_id]) do
      [row] -> to_row(row)
      [] -> nil
    end
  end

  @doc """
  Every row for one session that blocks its retirement (§B5).

  This is the census the retirement fence runs, so it must return nonterminal
  AND unresolved rows in one read. A census that returned only nonterminal rows
  would let a session finalize while an `identity_unknown` row still names a
  process nobody has proved anything about.
  """
  @spec retirement_blockers_in_txn(Txn.t(), String.t()) :: [map()]
  def retirement_blockers_in_txn(txn, session_key) do
    placeholders =
      retirement_blocking_states()
      |> Enum.with_index(2)
      |> Enum.map_join(", ", fn {_state, i} -> "?#{i}" end)

    txn
    |> Txn.q(
      @select <>
        " WHERE ownerSessionKey = ?1 AND state IN (#{placeholders}) ORDER BY createdAt",
      [session_key | retirement_blocking_states()]
    )
    |> Enum.map(&to_row/1)
  end

  @doc """
  The one mutation seam: compare state and revision, change one row, bump the
  revision (§B2).

  `expected_state` may be a single state or a list, because several lawful
  transitions accept more than one origin — a stop request is reachable from
  `running` and from `stop_failed`, and forcing the caller to guess which one
  it is racing against would reintroduce the read-then-write window this exists
  to close.

  Returns `{:ok, row}` with the new row when this caller won, and
  `{:lost, row}` with the CURRENT durable row when another transition won
  first. `{:lost, _}` is an ordinary outcome, not an error: the caller reports
  the winning durable result rather than retrying blind.
  """
  @spec transition(Txn.t(), String.t(), keyword(), map()) ::
          {:ok, map()} | {:lost, map() | nil}
  def transition(txn, process_id, expect, changes) do
    expected_states = List.wrap(Keyword.fetch!(expect, :state))
    expected_revision = Keyword.fetch!(expect, :revision)
    now = Map.fetch!(changes, :now)

    {set_sql, set_params} = set_clause(Map.delete(changes, :now))

    state_placeholders =
      expected_states
      |> Enum.with_index(length(set_params) + 3)
      |> Enum.map_join(", ", fn {_s, i} -> "?#{i}" end)

    revision_index = length(set_params) + 3 + length(expected_states)

    Txn.q(
      txn,
      """
      UPDATE managed_processes
      SET #{set_sql}, updatedAt = ?1, revision = revision + 1
      WHERE processId = ?2 AND state IN (#{state_placeholders}) AND revision = ?#{revision_index}
      """,
      [now, process_id] ++ set_params ++ expected_states ++ [expected_revision]
    )

    if Txn.changes(txn) == 1 do
      {:ok, get_in_txn(txn, process_id)}
    else
      {:lost, get_in_txn(txn, process_id)}
    end
  end

  # The ONLY columns a transition may write, and their spelling. One map rather
  # than a writable-list plus a name-lookup, because two structures would have
  # to agree and the day they stop agreeing is the day a transition writes a
  # column nobody meant to expose.
  #
  # Absent by design: `processId`, `ownerUserId`, `ownerSessionKey`,
  # `sessionGeneration`, `launchTurnSeq`, `launchToken`, `host`, `purpose`,
  # `commandDescriptor`, `launchDeadline`, `createdAt`. Those establish WHOSE
  # process this is and what it was allowed to be; a transition that could
  # rewrite them would defeat the identity proof everything else rests on.
  @writable %{
    state: "state",
    os_pid: "osPid",
    process_group_id: "processGroupId",
    boot_identity: "bootIdentity",
    broker_identity: "brokerIdentity",
    lease_expires_at: "leaseExpiresAt",
    cancel_requested_at: "cancelRequestedAt",
    release_granted_at: "releaseGrantedAt",
    stop_cause: "stopCause",
    uncertainty_cause: "uncertaintyCause",
    stop_attempt_count: "stopAttemptCount",
    last_error: "lastError",
    delivery_evidence_id: "deliveryEvidenceId",
    delivery_result: "deliveryResult",
    delivery_provider_kind: "deliveryProviderKind",
    delivery_event_kind: "deliveryEventKind",
    resolved_at: "resolvedAt"
  }

  @doc "The fields a transition may write, mapped to their column spelling."
  @spec writable_fields() :: %{atom() => String.t()}
  def writable_fields, do: @writable

  defp set_clause(changes) do
    changes
    |> Enum.map(fn {field, value} ->
      case Map.fetch(@writable, field) do
        {:ok, col} ->
          {col, value}

        :error ->
          raise ArgumentError,
                "managed_processes transition cannot write #{inspect(field)}; writable: " <>
                  inspect(Map.keys(@writable))
      end
    end)
    |> Enum.with_index(3)
    |> Enum.map_reduce([], fn {{col, value}, i}, acc -> {"#{col} = ?#{i}", acc ++ [value]} end)
    |> then(fn {fragments, params} -> {Enum.join(fragments, ", "), params} end)
  end

  defp to_row([
         process_id,
         owner_user_id,
         owner_session_key,
         session_generation,
         launch_turn_seq,
         host,
         purpose,
         command_descriptor,
         os_pid,
         process_group_id,
         boot_identity,
         launch_token,
         broker_identity,
         launch_deadline,
         lease_expires_at,
         cancel_requested_at,
         release_granted_at,
         stop_cause,
         uncertainty_cause,
         stop_attempt_count,
         state,
         last_error,
         delivery_evidence_id,
         delivery_result,
         delivery_provider_kind,
         delivery_event_kind,
         created_at,
         updated_at,
         resolved_at,
         revision
       ]) do
    %{
      processId: process_id,
      ownerUserId: owner_user_id,
      ownerSessionKey: owner_session_key,
      sessionGeneration: session_generation,
      launchTurnSeq: launch_turn_seq,
      host: host,
      purpose: purpose,
      commandDescriptor: command_descriptor,
      osPid: os_pid,
      processGroupId: process_group_id,
      bootIdentity: boot_identity,
      launchToken: launch_token,
      brokerIdentity: broker_identity,
      launchDeadline: launch_deadline,
      leaseExpiresAt: lease_expires_at,
      cancelRequestedAt: cancel_requested_at,
      releaseGrantedAt: release_granted_at,
      stopCause: stop_cause,
      uncertaintyCause: uncertainty_cause,
      stopAttemptCount: stop_attempt_count,
      state: state,
      lastError: last_error,
      deliveryEvidenceId: delivery_evidence_id,
      deliveryResult: delivery_result,
      deliveryProviderKind: delivery_provider_kind,
      deliveryEventKind: delivery_event_kind,
      createdAt: created_at,
      updatedAt: updated_at,
      resolvedAt: resolved_at,
      revision: revision
    }
  end

  @fence_select "SELECT sessionKey, generation, state, retirementEpoch, principal, openedAt, finalizedAt, revision FROM session_retirement_fence"

  @doc "The retirement fence for a session, or nil if it has never retired."
  @spec fence_in_txn(Txn.t(), String.t()) :: map() | nil
  def fence_in_txn(txn, session_key) do
    case Txn.q(txn, @fence_select <> " WHERE sessionKey = ?1", [session_key]) do
      [row] -> to_fence(row)
      [] -> nil
    end
  end

  @doc "The retirement fence for a session, or nil."
  @spec fence(DB.server(), String.t()) :: map() | nil
  def fence(db \\ DB, session_key) do
    {:ok, rows} = DB.query(db, @fence_select <> " WHERE sessionKey = ?1", [session_key])

    case rows do
      [row] -> to_fence(row)
      [] -> nil
    end
  end

  @doc """
  Open the fence: this session is retiring, at a new generation (§B5).

  Idempotent on an already-open fence — an exact retirement retry must reach the
  same durable answer without opening a second fence or inventing a generation
  (§B5, "an exact retire-session retry against `retiring` reruns the durable
  process census and calls the finalizer"). A session that already finalized
  retires again at the NEXT generation, which is what makes a late identity bind
  from the previous life detectably stale.
  """
  @spec open_fence_in_txn(Txn.t(), String.t(), keyword()) :: {:ok, map()} | {:already_open, map()}
  def open_fence_in_txn(txn, session_key, opts) do
    epoch = Keyword.fetch!(opts, :retirement_epoch)
    principal = Keyword.fetch!(opts, :principal)

    case fence_in_txn(txn, session_key) do
      %{state: "retiring"} = open ->
        {:already_open, open}

      previous ->
        generation = if previous, do: previous.generation + 1, else: 1

        Txn.q(
          txn,
          """
          INSERT INTO session_retirement_fence
            (sessionKey, generation, state, retirementEpoch, principal, openedAt, revision)
          VALUES (?1, ?2, 'retiring', ?3, ?4, ?3, 1)
          ON CONFLICT(sessionKey) DO UPDATE SET
            generation = ?2, state = 'retiring', retirementEpoch = ?3, principal = ?4,
            openedAt = ?3, finalizedAt = NULL, revision = revision + 1
          """,
          [session_key, generation, epoch, principal]
        )

        {:ok, fence_in_txn(txn, session_key)}
    end
  end

  @doc """
  Close the fence, but only when nothing is left to resolve (§B5).

  Answers `{:blocked, rows}` when any nonterminal or unresolved row remains, so
  the caller can report `process_retirement_blocked` naming the process IDs, the
  launch deadlines, and `process-reconcile`. Answers `{:ok, fence}` when the
  fence moved to `retired`, and `{:already_final, fence}` when it was already
  there — an exact retry is idempotent success, not a second retirement.

  This does NOT touch `sessions.state`. Flipping that row is the caller's act,
  in this same transaction, and it lives in a file this assignment does not yet
  hold; keeping the decision here and the write there means the two cannot
  disagree about whether finalization was earned.
  """
  @spec finalize_fence_in_txn(Txn.t(), String.t(), keyword()) ::
          {:ok, map()} | {:already_final, map()} | {:blocked, [map()]} | {:error, :no_fence}
  def finalize_fence_in_txn(txn, session_key, opts) do
    generation = Keyword.fetch!(opts, :generation)
    now = Keyword.fetch!(opts, :now)

    case fence_in_txn(txn, session_key) do
      nil ->
        {:error, :no_fence}

      %{state: "retired", generation: ^generation} = fence ->
        {:already_final, fence}

      %{generation: other} = fence when other != generation ->
        # A fence at a different generation is a different retirement. Report
        # what is durable rather than finalizing someone else's.
        {:already_final, fence}

      %{state: "retiring", revision: revision} ->
        case retirement_blockers_in_txn(txn, session_key) do
          [] ->
            Txn.q(
              txn,
              """
              UPDATE session_retirement_fence
              SET state = 'retired', finalizedAt = ?2, revision = revision + 1
              WHERE sessionKey = ?1 AND state = 'retiring' AND revision = ?3
              """,
              [session_key, now, revision]
            )

            if Txn.changes(txn) == 1 do
              {:ok, fence_in_txn(txn, session_key)}
            else
              {:blocked, retirement_blockers_in_txn(txn, session_key)}
            end

          blockers ->
            {:blocked, blockers}
        end
    end
  end

  @doc """
  The census fence (§B5): settle every one of this session's process rows in the
  SAME transaction that opens the retirement fence.

  A concurrent start or reconcile either commits before this and appears in the
  census, or loses its revision compare-and-set afterwards, reloads the stop
  cause, and cannot expose `running`. That is what makes the census complete
  rather than a snapshot with a gap behind it.

  The four rules, straight from §B5, and the asymmetry is the point:

  - `preparing` -> `launch_cancel_requested`, cause `session_retired`;
  - `running` -> `stop_requested`, cause `session_retired`;
  - `identity_unknown` STAYS unresolved and only gains the cause when it has
    none — retirement orders the stop, it does not prove the process is gone;
  - `launch_cancel_requested`, `stop_requested`, `stop_failed` keep whatever
    cause they already had; only a legacy null gets filled.

  A first cause is never overwritten: whoever asked first owns the reason, and
  rewriting it would erase why the process is being stopped in favour of the
  most recent bystander.
  """
  @spec retirement_census_in_txn(Txn.t(), String.t(), keyword()) :: [map()]
  def retirement_census_in_txn(txn, session_key, opts) do
    now = Keyword.fetch!(opts, :now)

    txn
    |> retirement_blockers_in_txn(session_key)
    |> Enum.map(fn row -> census_one(txn, row, now) end)
  end

  defp census_one(txn, %{state: "preparing"} = row, now) do
    settle(txn, row, %{
      state: "launch_cancel_requested",
      cancel_requested_at: now,
      stop_cause: row.stopCause || "session_retired",
      now: now
    })
  end

  defp census_one(txn, %{state: "running"} = row, now) do
    settle(txn, row, %{
      state: "stop_requested",
      stop_cause: row.stopCause || "session_retired",
      now: now
    })
  end

  # Unresolved and already-requested rows keep their state. They gain a cause
  # only if they have none, so retirement can be the reason of record for a row
  # nobody had yet asked to stop.
  defp census_one(txn, %{stopCause: nil} = row, now) do
    settle(txn, row, %{state: row.state, stop_cause: "session_retired", now: now})
  end

  defp census_one(_txn, row, _now), do: row

  defp settle(txn, row, changes) do
    case transition(txn, row.processId, [state: row.state, revision: row.revision], changes) do
      {:ok, updated} -> updated
      {:lost, current} -> current
    end
  end

  defp to_fence([
         session_key,
         generation,
         state,
         epoch,
         principal,
         opened_at,
         finalized_at,
         revision
       ]) do
    %{
      sessionKey: session_key,
      generation: generation,
      state: state,
      retirementEpoch: epoch,
      principal: principal,
      openedAt: opened_at,
      finalizedAt: finalized_at,
      revision: revision
    }
  end

  @doc """
  The session's current retirement generation: 0 if it has never retired.

  A launch captures this at insert. A later identity bind compares it against
  the live value, which is how a bind belonging to a previous life of the
  session is detected as stale (§B5).
  """
  @spec current_generation_in_txn(Txn.t(), String.t()) :: non_neg_integer()
  def current_generation_in_txn(txn, session_key) do
    case fence_in_txn(txn, session_key) do
      nil -> 0
      fence -> fence.generation
    end
  end

  @doc """
  Bind the proven identity tuple and decide, atomically, whether the workload
  may run (§B5 steps 3-7).

  This is the single decision point the whole barrier exists to protect, so it
  is ONE transaction: bind the identity, re-check the session generation, the
  stop cause and the lease, and only then choose. Splitting the bind from the
  check is precisely the window that lets a workload be released into a session
  that has already started retiring.

  Answers:

    * `{:running, row}` — the row is `running` and `releaseGrantedAt` is set.
      This is the ONLY answer that authorizes opening the pre-exec barrier.
    * `{:stop, row}` — identity is bound and the row is `stop_requested`,
      carrying whatever cause won. The broker must NOT release; it hands the
      proven identity to the stop worker. The workload never executes.
    * `{:lost, row}` — another transition won; report that durable row.

  Note what is deliberately absent from the stop answers: no `releaseGrantedAt`
  is ever recorded on them. §B5 is explicit that a late bind "never records a
  release grant, or opens the pre-exec barrier", and recording one would leave a
  durable claim that a workload was authorized when it was not.
  """
  @spec bind_identity_in_txn(Txn.t(), String.t(), map(), keyword()) ::
          {:running, map()} | {:stop, map()} | {:unproven, map()} | {:lost, map() | nil}
  def bind_identity_in_txn(txn, process_id, identity, opts) do
    now = Keyword.fetch!(opts, :now)

    case get_in_txn(txn, process_id) do
      nil ->
        {:lost, nil}

      %{state: state} = row when state in ["preparing", "launch_cancel_requested"] ->
        # LAUNCH AUTHORITY (review att_8017ebe7 F5). The identity tuple is
        # osPid + processGroupId + bootIdentity + launchToken, and the token is
        # the half that proves this child is OURS rather than merely a real
        # process that exists. Binding pid/group/boot without it accepts any
        # broker that can name a live process — the reboot-reuse hole one level
        # up: the other three prove "this process exists", only the token proves
        # "we launched it". It is compared against the value stored at insert,
        # which the broker never sees until it is handed one.
        if Map.get(identity, :launch_token) != row.launchToken do
          {:unproven, row}
        else
          bound = %{
            os_pid: Map.fetch!(identity, :os_pid),
            process_group_id: Map.fetch!(identity, :process_group_id),
            boot_identity: Map.fetch!(identity, :boot_identity),
            broker_identity: Map.get(identity, :broker_identity),
            now: now
          }

          decide_bind(txn, row, bound, now)
        end

      row ->
        # Terminal, unresolved, or already running: this bind lost.
        {:lost, row}
    end
  end

  defp decide_bind(txn, row, bound, now) do
    generation = current_generation_in_txn(txn, row.ownerSessionKey)
    retiring? = match?(%{state: "retiring"}, fence_in_txn(txn, row.ownerSessionKey))

    stop_cause =
      cond do
        # A cause already present always wins. Whoever asked first owns the
        # reason; a later condition never rewrites it.
        row.stopCause != nil -> row.stopCause
        retiring? or generation != row.sessionGeneration -> "session_retired"
        row.leaseExpiresAt <= now -> "lease_expired"
        true -> nil
      end

    changes =
      case stop_cause do
        nil ->
          Map.merge(bound, %{state: "running", release_granted_at: now})

        cause ->
          Map.merge(bound, %{state: "stop_requested", stop_cause: cause})
      end

    case transition(txn, row.processId, [state: row.state, revision: row.revision], changes) do
      {:ok, updated} when stop_cause == nil -> {:running, updated}
      {:ok, updated} -> {:stop, updated}
      {:lost, current} -> {:lost, current}
    end
  end

  @doc """
  `process-reconcile` (§B4): the repeatable repair for every unresolved launch
  and stop state, and the verb every blocked answer is required to name.

  The caller supplies the physical evidence; this decides what it means. That
  split is deliberate. Probing the OS is the one part that cannot be done inside
  a transaction, and embedding it here would make the decision untestable
  against the cases that matter most — the ones where no evidence exists.

  `evidence`:

    * `:not_probed` — the deadline has not passed, so nothing was asked of the
      OS. Lease and cause are still settled; the launch itself is left alone.
    * `:absent` — the broker PROVED no such child exists. Only this terminalizes
      a launch, and only a proof, never a timeout on its own.
    * `{:identity, %{...}}` — a verified pre-exec identity. Continues the
      winning start or stop through `bind_identity_in_txn/4`, which re-applies
      the same atomic lease and generation checks.
    * `:unknown` — neither identity nor absence could be proved. The row becomes
      or stays `identity_unknown`, keeping any stop cause. This is a fail-closed
      RESULT, not a failure: §B3 is explicit that it may remain unresolved
      indefinitely, that retirement stays blocked while it does, and that
      Tightbeam must not delete the row, call it stopped, or promise eventual
      terminalization without new evidence.

  Lease expiry is settled FIRST and in the same transaction, because §B4 says
  reconcile "never waits for a separate sweeper to make this decision".
  """
  @spec reconcile_in_txn(Txn.t(), String.t(), keyword()) ::
          {:ok, map()} | {:blocked, map()} | {:error, :unknown_process}
  def reconcile_in_txn(txn, process_id, opts) do
    now = Keyword.fetch!(opts, :now)
    evidence = Keyword.get(opts, :evidence, :not_probed)

    case get_in_txn(txn, process_id) do
      nil -> {:error, :unknown_process}
      row -> row |> settle_lease(txn, now) |> reconcile_settled(txn, evidence, now)
    end
  end

  # Step one, always: an expired lease installs its cause when none exists, and
  # moves a launch that has not yet bound identity out of `preparing`. A row
  # with proven identity becomes a stop request; an unresolved row keeps its
  # state and merely gains the cause.
  defp settle_lease(row, txn, now) do
    cond do
      row.state in @terminal ->
        row

      row.leaseExpiresAt > now ->
        row

      true ->
        cause = row.stopCause || "lease_expired"

        target =
          case row.state do
            "preparing" -> "launch_cancel_requested"
            "running" -> "stop_requested"
            other -> other
          end

        case transition(txn, row.processId, [state: row.state, revision: row.revision], %{
               state: target,
               stop_cause: cause,
               now: now
             }) do
          {:ok, updated} -> updated
          {:lost, current} -> current
        end
    end
  end

  defp reconcile_settled(%{state: state} = row, _txn, _evidence, _now) when state in @terminal do
    {:ok, row}
  end

  defp reconcile_settled(row, _txn, :not_probed, now)
       when is_integer(now) do
    # Before the launch deadline there is nothing to prove and nothing to wait
    # on; report the state and the deadline so the caller can say when to look
    # again rather than guessing.
    {:blocked, row}
  end

  defp reconcile_settled(row, txn, :absent, now) do
    # Proven absence is the ONLY thing that terminalizes a launch. A deadline
    # alone never fabricates it (§B4, §B5).
    # `launch_timeout` is a typed LAST ERROR, not a stop cause. §B2's stop-cause
    # vocabulary is closed to owner_stop / lease_expired / session_retired —
    # reasons to stop something that is running. A launch that never started has
    # nothing to stop, and the table's CHECK refused the confusion when this
    # first tried to write it there.
    changes =
      case row.state do
        "preparing" ->
          %{state: "launch_failed", last_error: "launch_timeout"}

        "launch_cancel_requested" ->
          %{state: "launch_canceled", stop_cause: row.stopCause}

        _ ->
          %{state: "exited", stop_cause: row.stopCause}
      end

    changes = changes |> Map.put(:resolved_at, now) |> Map.put(:now, now)

    case transition(txn, row.processId, [state: row.state, revision: row.revision], changes) do
      {:ok, updated} -> {:ok, updated}
      {:lost, current} -> {:ok, current}
    end
  end

  defp reconcile_settled(row, txn, {:identity, identity}, now) do
    case bind_identity_in_txn(txn, row.processId, identity, now: now) do
      {:running, updated} -> {:ok, updated}
      {:stop, updated} -> {:blocked, updated}
      # An identity that cannot prove it is ours is not evidence of anything.
      # It becomes uncertainty, not a bind and not an absence proof.
      {:unproven, _} -> reconcile_settled(row, txn, :unknown, now)
      {:lost, current} -> {:blocked, current}
    end
  end

  defp reconcile_settled(row, txn, :unknown, now) do
    case transition(txn, row.processId, [state: row.state, revision: row.revision], %{
           state: "identity_unknown",
           uncertainty_cause: row.uncertaintyCause || "launch_handoff_unknown",
           now: now
         }) do
      {:ok, updated} -> {:blocked, updated}
      {:lost, current} -> {:blocked, current}
    end
  end

  @doc """
  `process-stop` (§B4), and the same split lease expiry and retirement use.

  The rule underneath all three is one thing: a stop request is only lawful
  against a PROVEN identity. Without one there is nothing safe to signal, so the
  request becomes a durable cause on an unresolved row instead of a pretend
  stop.

    * `preparing` -> `launch_cancel_requested`, cause installed;
    * `running` or `stop_failed` -> `stop_requested`, which the table will only
      accept with the full identity tuple present;
    * `identity_unknown` -> STAYS unresolved, gaining the cause only if it had
      none, and answers `{:blocked, row}` so the caller returns
      `process_retirement_blocked` naming `process-reconcile`.

  A retry from `stop_failed` increments `stopAttemptCount` and never creates a
  second logical stop request (§B4): the attempt count is how "we tried again"
  is recorded without duplicating the obligation.
  """
  @spec request_stop_in_txn(Txn.t(), String.t(), keyword()) ::
          {:ok, map()} | {:blocked, map()} | {:lost, map() | nil} | {:error, :unknown_process}
  def request_stop_in_txn(txn, process_id, opts) do
    now = Keyword.fetch!(opts, :now)
    cause = Keyword.get(opts, :cause, "owner_stop")

    case get_in_txn(txn, process_id) do
      nil ->
        {:error, :unknown_process}

      %{state: state} = row when state in @terminal ->
        # Already settled. Report it; do not reopen a closed obligation.
        {:ok, row}

      %{state: "preparing"} = row ->
        apply_stop(txn, row, %{
          state: "launch_cancel_requested",
          cancel_requested_at: now,
          stop_cause: row.stopCause || cause,
          now: now
        })

      %{state: "identity_unknown"} = row ->
        # No proven identity means nothing safe to signal. Record WHY it must
        # stop and leave the row unresolved — the honest answer, and the one
        # that keeps retirement blocked until evidence arrives.
        case apply_stop(txn, row, %{
               state: "identity_unknown",
               stop_cause: row.stopCause || cause,
               now: now
             }) do
          {:ok, updated} -> {:blocked, updated}
          other -> other
        end

      %{state: "stop_failed"} = row ->
        apply_stop(txn, row, %{
          state: "stop_requested",
          stop_cause: row.stopCause || cause,
          stop_attempt_count: row.stopAttemptCount + 1,
          now: now
        })

      %{state: "running"} = row ->
        apply_stop(txn, row, %{
          state: "stop_requested",
          stop_cause: row.stopCause || cause,
          now: now
        })

      %{state: state} = row when state in ["launch_cancel_requested", "stop_requested"] ->
        # One logical request already exists. Returning it, rather than issuing
        # a second, is what stops two signals chasing one process (§B4).
        {:ok, row}
    end
  end

  defp apply_stop(txn, row, changes) do
    case transition(txn, row.processId, [state: row.state, revision: row.revision], changes) do
      {:ok, updated} -> {:ok, updated}
      {:lost, current} -> {:lost, current}
    end
  end

  @doc """
  Record what the stop worker actually observed (§B5).

  The worker signals OUTSIDE the transaction and comes back here with a result.
  The two unresolved outcomes preserve the request's `stopCause` and record the
  identity problem SEPARATELY in `uncertaintyCause`, because "we were told to
  stop it" and "we could not prove which process it is" are different facts and
  a row is routinely both.

  `:killed` and `:exited` are terminal. `:stop_failed` and `:identity_unknown`
  are not: they keep blocking retirement until new evidence arrives, which is
  the fail-closed behaviour §B3 requires rather than a bug to smooth over.
  """
  @spec record_stop_outcome_in_txn(Txn.t(), String.t(), atom(), keyword()) ::
          {:ok, map()} | {:lost, map() | nil} | {:error, :unknown_process}
  def record_stop_outcome_in_txn(txn, process_id, outcome, opts) do
    now = Keyword.fetch!(opts, :now)

    case get_in_txn(txn, process_id) do
      nil ->
        {:error, :unknown_process}

      %{state: "stop_requested"} = row ->
        changes =
          case outcome do
            :killed ->
              %{state: "killed", resolved_at: now}

            :exited ->
              %{state: "exited", resolved_at: now}

            :stop_failed ->
              %{state: "stop_failed", last_error: Keyword.get(opts, :error, "signal_failed")}

            :identity_unknown ->
              %{
                state: "identity_unknown",
                uncertainty_cause: Keyword.get(opts, :uncertainty_cause, "stop_signal_unproven")
              }
          end

        apply_stop(txn, row, Map.put(changes, :now, now))

      row ->
        # The monitor may have seen a natural exit first. A later worker result
        # must not reopen or overwrite that (§B5's natural-exit-versus-stop row).
        {:lost, row}
    end
  end

  @doc """
  Every row a restart must look at, across all sessions (§B5).

  The scan covers the same set that blocks retirement — the four nonterminal
  states plus the two unresolved ones — because a crash can leave a row in any
  of them and each still owes either work or evidence. Terminal rows are
  finished and are deliberately absent.

  The caller probes each row and feeds the result back through
  `reconcile_in_txn/3`, so restart repair and the `process-reconcile` verb share
  one decision table rather than drifting into two.
  """
  @spec recovery_rows_in_txn(Txn.t()) :: [map()]
  def recovery_rows_in_txn(txn) do
    placeholders =
      retirement_blocking_states()
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_s, i} -> "?#{i}" end)

    txn
    |> Txn.q(
      @select <> " WHERE state IN (#{placeholders}) ORDER BY createdAt",
      retirement_blocking_states()
    )
    |> Enum.map(&to_row/1)
  end

  @doc """
  Every session still behind an open retirement fence (§B5).

  A restart must revisit these even when no process row changed: an older build
  could have terminalized the last process and died before finalizing the
  session, leaving it `retiring` forever with nothing left to trigger it.
  """
  @spec open_fences_in_txn(Txn.t()) :: [map()]
  def open_fences_in_txn(txn) do
    txn
    |> Txn.q(@fence_select <> " WHERE state = 'retiring' ORDER BY openedAt", [])
    |> Enum.map(&to_fence/1)
  end

  @doc "Every process this session owns, newest last."
  @spec list_for_session(DB.server(), String.t()) :: [map()]
  def list_for_session(db \\ DB, session_key) do
    {:ok, rows} =
      DB.query(db, @select <> " WHERE ownerSessionKey = ?1 ORDER BY createdAt", [session_key])

    Enum.map(rows, &to_row/1)
  end

  @doc """
  `process-extend` (§B4): push the lease out, and only from a position that
  makes that meaningful.

  §B5's race table pins both edges. Extend wins ONLY from `running` at the
  current revision with a lease that is still in the future — an expired lease
  is not extendable, because by then the stop is already the winning outcome and
  reviving it would resurrect a process the record has stopped promising to
  keep. And extend requires the session's generation to be unchanged: retirement
  moves the generation, so an extend that loses to retirement answers
  `{:session_retiring, row}` rather than silently granting a lease on a session
  that is going away.
  """
  @spec extend_lease_in_txn(Txn.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:expired, map()}
          | {:session_retiring, map()}
          | {:not_running, map()}
          | {:lost, map() | nil}
          | {:error, :unknown_process}
  def extend_lease_in_txn(txn, process_id, opts) do
    now = Keyword.fetch!(opts, :now)
    lease_expires_at = Keyword.fetch!(opts, :lease_expires_at)

    case get_in_txn(txn, process_id) do
      nil ->
        {:error, :unknown_process}

      %{state: "running"} = row ->
        cond do
          row.leaseExpiresAt <= now ->
            {:expired, row}

          current_generation_in_txn(txn, row.ownerSessionKey) != row.sessionGeneration ->
            {:session_retiring, row}

          match?(%{state: "retiring"}, fence_in_txn(txn, row.ownerSessionKey)) ->
            {:session_retiring, row}

          true ->
            case transition(txn, process_id, [state: "running", revision: row.revision], %{
                   lease_expires_at: lease_expires_at,
                   now: now
                 }) do
              {:ok, updated} -> {:ok, updated}
              {:lost, current} -> {:lost, current}
            end
        end

      row ->
        {:not_running, row}
    end
  end

  @doc """
  Consume the delivery owner's structured receipt (§B6).

  The URL and the one-time code belong to `wi_0535922b`'s delivery contract and
  to the authorized sink it writes. This CONSUMES that boundary's receipt and
  does nothing the boundary owns: it does not send the code, open the browser,
  write the attest, or schedule the re-arm.

  Four fields are permitted from the receipt and there is nowhere to put a
  fifth: the evidence id, the terminal result, the provider kind, and a safe
  event kind such as `device_code_emitted` — a LABEL for what happened, never
  the value that was emitted. The row points at the sink; it does not copy it.

  On `:succeeded`, custody continues and the process stays exactly as it was —
  a successful handoff is not a reason to stop a ceremony that is still running.
  On `:failed` or `:timed_out`, the process stays MANAGED rather than being
  terminalized here: §B6 says custody waits until it observes the delivery
  owner's abort receipt, because "the delivery failed" and "the process has
  stopped" are different facts and only the second one ends custody.
  """
  @spec consume_delivery_receipt_in_txn(Txn.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:lost, map() | nil} | {:error, :unknown_process}
  def consume_delivery_receipt_in_txn(txn, process_id, receipt, opts) do
    now = Keyword.fetch!(opts, :now)

    result =
      case Map.fetch!(receipt, :result) do
        r when r in [:succeeded, :failed, :timed_out] -> to_string(r)
      end

    case get_in_txn(txn, process_id) do
      nil ->
        {:error, :unknown_process}

      row ->
        transition(txn, process_id, [state: row.state, revision: row.revision], %{
          delivery_evidence_id: Map.fetch!(receipt, :delivery_evidence_id),
          delivery_result: result,
          delivery_provider_kind: Map.get(receipt, :provider_kind),
          delivery_event_kind: Map.get(receipt, :event_kind),
          now: now
        })
        |> case do
          {:ok, updated} -> {:ok, updated}
          {:lost, current} -> {:lost, current}
        end
    end
  end

  @doc """
  Every column of this record that holds free text, for the canary scan (§B6,
  acceptance cases 14 and 17).

  Enumerated from the table rather than hand-listed, so a column added later is
  scanned automatically instead of quietly escaping the check.
  """
  @spec text_columns(DB.server()) :: [String.t()]
  def text_columns(db \\ DB) do
    {:ok, rows} = DB.query(db, "PRAGMA table_info(managed_processes)")

    for [_cid, name, type | _] <- rows, String.upcase(to_string(type)) == "TEXT", do: name
  end

  @doc "Whether this row still owes work or evidence before its session may retire."
  @spec blocks_retirement?(map()) :: boolean()
  def blocks_retirement?(%{state: state}), do: state in (@nonterminal ++ @unresolved)

  @doc "The lawful stop causes."
  @spec stop_causes() :: [String.t()]
  def stop_causes, do: @stop_causes

  @doc "The lawful identity-uncertainty causes."
  @spec uncertainty_causes() :: [String.t()]
  def uncertainty_causes, do: @uncertainty_causes
end
