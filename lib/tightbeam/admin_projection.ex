defmodule Tightbeam.AdminProjection do
  @moduledoc "Durable row-version floors for branch-local administrative projections."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS admin_projection_versions (
    resource    TEXT NOT NULL,
    primaryKey  TEXT NOT NULL,
    rowVersion  INTEGER NOT NULL CHECK (rowVersion > 0),
    updatedAt   INTEGER NOT NULL,
    fingerprint TEXT,
    item        TEXT,
    PRIMARY KEY (resource, primaryKey)
  );
  CREATE TABLE IF NOT EXISTS identity_publication_markers (
    invocationId      TEXT NOT NULL,
    expectedPriorLive TEXT NOT NULL,
    candidateRevision TEXT,
    treeFingerprint   TEXT NOT NULL,
    principal         TEXT NOT NULL,
    validationResult  TEXT NOT NULL CHECK (validationResult IN ('accepted', 'denied')),
    cause             TEXT,
    denialCode        TEXT,
    denialMessage     TEXT,
    denialExpected    TEXT,
    denialActual      TEXT,
    state             TEXT NOT NULL CHECK (state IN ('pending', 'accepted', 'denied')),
    createdAt         INTEGER NOT NULL,
    updatedAt         INTEGER NOT NULL,
    PRIMARY KEY (invocationId, expectedPriorLive)
  );
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Read one durable identity validation-publication marker."
  def identity_publication_marker(source, invocation_id, expected_prior) do
    case query(
           source,
           """
           SELECT invocationId, expectedPriorLive, candidateRevision, treeFingerprint,
                  principal, validationResult, cause, denialCode, denialMessage,
                  denialExpected, denialActual, state, createdAt, updatedAt
           FROM identity_publication_markers
           WHERE invocationId = ?1 AND expectedPriorLive = ?2
           """,
           [invocation_id, expected_prior]
         ) do
      [
        [
          invocation,
          expected,
          candidate,
          fingerprint,
          principal,
          result,
          cause,
          denial_code,
          denial_message,
          denial_expected,
          denial_actual,
          state,
          created,
          updated
        ]
      ] ->
        %{
          invocation_id: invocation,
          expected_prior: expected,
          candidate_revision: candidate,
          tree_fingerprint: fingerprint,
          principal: principal,
          validation_result: result,
          cause: cause,
          denial_code: denial_code,
          denial_message: denial_message,
          denial_expected: denial_expected,
          denial_actual: denial_actual,
          state: state,
          created_at: created,
          updated_at: updated
        }

      [] ->
        nil
    end
  end

  @doc "Read the one marker for an invocation before replaying a mutation."
  def identity_publication_marker_by_invocation(source, invocation_id) do
    case query(
           source,
           "SELECT expectedPriorLive FROM identity_publication_markers WHERE invocationId = ?1",
           [invocation_id]
         ) do
      [[expected_prior]] -> identity_publication_marker(source, invocation_id, expected_prior)
      [] -> nil
    end
  end

  @doc "Create the sole pending marker after candidate-tree validation succeeds."
  def begin_identity_publication(db, invocation_id, candidate, principal) do
    case DB.transaction(db, fn txn ->
           begin_identity_publication_in_txn(txn, invocation_id, candidate, principal)
         end) do
      {:ok, marker} -> {:ok, marker}
      {:error, error} -> {:error, error}
    end
  end

  def begin_identity_publication_in_txn(%Txn{} = txn, invocation_id, candidate, principal) do
    now = System.system_time(:millisecond)

    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO identity_publication_markers
        (invocationId, expectedPriorLive, candidateRevision, treeFingerprint,
         principal, validationResult, cause, denialCode, denialMessage,
         denialExpected, denialActual, state, createdAt, updatedAt)
      VALUES (?1, ?2, ?3, ?4, ?5, 'accepted', NULL, NULL, NULL, NULL, NULL,
              'pending', ?6, ?6)
      """,
      [
        invocation_id,
        candidate.expected_prior,
        candidate.candidate_revision,
        candidate.tree_fingerprint,
        principal,
        now
      ]
    )

    identity_publication_marker(txn, invocation_id, candidate.expected_prior)
  end

  @doc "Finalize a pending identity marker exactly once."
  def finish_identity_publication_in_txn(%Txn{} = txn, marker, state, cause \\ nil, denial \\ nil)
      when state in ["accepted", "denied"] do
    validation_result = if state == "accepted", do: "accepted", else: "denied"
    denial_code = if denial, do: Map.get(denial, :code) || Map.get(denial, "code")
    denial_message = if denial, do: Map.get(denial, :message) || Map.get(denial, "message")
    denial_expected = if denial, do: Map.get(denial, :expected) || Map.get(denial, "expected")
    denial_actual = if denial, do: Map.get(denial, :actual) || Map.get(denial, "actual")

    Txn.q(
      txn,
      """
      UPDATE identity_publication_markers
      SET validationResult = ?3, cause = ?4, denialCode = ?5,
          denialMessage = ?6, denialExpected = ?7, denialActual = ?8,
          state = ?3, updatedAt = ?9
      WHERE invocationId = ?1 AND expectedPriorLive = ?2 AND state = 'pending'
      """,
      [
        marker.invocation_id,
        marker.expected_prior,
        validation_result,
        cause,
        denial_code,
        denial_message,
        denial_expected,
        denial_actual,
        System.system_time(:millisecond)
      ]
    )

    :ok
  end

  @doc "Record a pre-commit typed validation denial without a candidate revision."
  def deny_identity_validation(
        db,
        invocation_id,
        expected_prior,
        fingerprint,
        principal,
        cause,
        denial
      ) do
    now = System.system_time(:millisecond)

    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        """
        INSERT OR IGNORE INTO identity_publication_markers
          (invocationId, expectedPriorLive, candidateRevision, treeFingerprint,
           principal, validationResult, cause, denialCode, denialMessage,
           denialExpected, denialActual, state, createdAt, updatedAt)
        VALUES (?1, ?2, NULL, ?3, ?4, 'denied', ?5, ?6, ?7, NULL, NULL,
                'denied', ?8, ?8)
        """,
        [
          invocation_id,
          expected_prior,
          fingerprint,
          principal,
          cause,
          Map.fetch!(denial, :code),
          Map.fetch!(denial, :message),
          now
        ]
      )

      identity_publication_marker(txn, invocation_id, expected_prior)
    end)
  end

  @spec key(String.t() | [String.t()]) :: String.t()
  def key(value) when is_binary(value), do: value
  def key(parts) when is_list(parts), do: JSON.encode!(parts)

  @spec version(DB.server() | Txn.t(), String.t(), String.t() | [String.t()]) ::
          pos_integer() | nil
  def version(source, resource, primary_key) do
    rows =
      case source do
        %Txn{} = txn ->
          Txn.q(
            txn,
            "SELECT rowVersion FROM admin_projection_versions WHERE resource=?1 AND primaryKey=?2",
            [resource, key(primary_key)]
          )

        db ->
          {:ok, result} =
            DB.query(
              db,
              "SELECT rowVersion FROM admin_projection_versions WHERE resource=?1 AND primaryKey=?2",
              [resource, key(primary_key)]
            )

          result
      end

    case rows do
      [[row_version]] -> row_version
      [] -> nil
    end
  end

  @spec allocate_in_txn(Txn.t(), String.t(), String.t() | [String.t()], integer(), keyword()) ::
          pos_integer()
  def allocate_in_txn(%Txn{} = txn, resource, primary_key, updated_at, opts \\ [])
      when is_integer(updated_at) do
    encoded_key = key(primary_key)
    fingerprint = Keyword.get(opts, :fingerprint)
    item = Keyword.get(opts, :item)

    Txn.q(
      txn,
      """
      INSERT INTO admin_projection_versions
        (resource, primaryKey, rowVersion, updatedAt, fingerprint, item)
      VALUES (?1, ?2, 1, ?3, ?4, ?5)
      ON CONFLICT(resource, primaryKey) DO UPDATE SET
        rowVersion=admin_projection_versions.rowVersion + 1,
        updatedAt=excluded.updatedAt,
        fingerprint=excluded.fingerprint,
        item=excluded.item
      """,
      [resource, encoded_key, updated_at, fingerprint, item]
    )

    [[row_version]] =
      Txn.q(
        txn,
        "SELECT rowVersion FROM admin_projection_versions WHERE resource=?1 AND primaryKey=?2",
        [resource, encoded_key]
      )

    row_version
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end
end
