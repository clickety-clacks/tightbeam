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
    deliveryEvidenceId TEXT,
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

  @doc """
  Create the table and the indexes the later owners scan on.

  The census fence and the boot sweep both select every retirement-blocking row
  for one session, so that pair is indexed together (§B5).
  """
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    case DB.transaction(db, fn txn ->
           Txn.exec(txn, @ddl)

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
      createdAt: created_at,
      updatedAt: updated_at,
      resolvedAt: resolved_at,
      revision: revision
    }
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
