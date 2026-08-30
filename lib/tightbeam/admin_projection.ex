defmodule Tightbeam.AdminProjection do
  @moduledoc """
  Durable version floors and publication stamps for the six safe admin resources.

  DB-backed resources allocate through `allocate_in_txn/5` inside the product
  transaction. Served-identity resources store their already-sanitized public
  snapshot only after Git publication succeeds. Neither seam publishes by
  itself; the owner queues the firehose handoff on the same transaction.
  """

  require Logger

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher
  alias Tightbeam.StateResources

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
  CREATE TABLE IF NOT EXISTS host_environment_projection (
    host         TEXT NOT NULL,
    harness      TEXT NOT NULL,
    name         TEXT NOT NULL,
    valuePresent INTEGER NOT NULL CHECK (valuePresent IN (0, 1)),
    updatedAt    INTEGER NOT NULL,
    rowVersion   INTEGER NOT NULL CHECK (rowVersion > 0),
    PRIMARY KEY (host, harness, name)
  );
  CREATE TABLE IF NOT EXISTS admin_projection_faults (
    resource   TEXT NOT NULL,
    primaryKey TEXT NOT NULL,
    code       TEXT NOT NULL,
    detail     TEXT NOT NULL,
    occurredAt INTEGER NOT NULL,
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
    state             TEXT NOT NULL CHECK (state IN ('pending', 'accepted', 'denied')),
    createdAt         INTEGER NOT NULL,
    updatedAt         INTEGER NOT NULL,
    PRIMARY KEY (invocationId, expectedPriorLive)
  );
  """

  @doc "Create the additive projection schema and seed floors for existing DB rows."
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    with :ok <- ensure_storage(db) do
      now = System.system_time(:millisecond)

      case DB.transaction(db, fn txn -> backfill_in_txn(txn, now) end) do
        {:ok, :ok} -> :ok
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc false
  def ensure_storage(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Read one durable identity validation-publication marker."
  def identity_publication_marker(source, invocation_id, expected_prior) do
    case query(
           source,
           """
           SELECT invocationId, expectedPriorLive, candidateRevision, treeFingerprint,
                  principal, validationResult, cause, denialCode, denialMessage,
                  state, createdAt, updatedAt
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

  @doc false
  def begin_identity_publication_in_txn(
        %Txn{} = txn,
        invocation_id,
        candidate,
        principal
      ) do
    now = System.system_time(:millisecond)

    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO identity_publication_markers
        (invocationId, expectedPriorLive, candidateRevision, treeFingerprint,
         principal, validationResult, cause, denialCode, denialMessage,
         state, createdAt, updatedAt)
      VALUES (?1, ?2, ?3, ?4, ?5, 'accepted', NULL, NULL, NULL, 'pending', ?6, ?6)
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
  def finish_identity_publication_in_txn(
        %Txn{} = txn,
        marker,
        state,
        cause \\ nil,
        denial \\ nil
      )
      when state in ["accepted", "denied"] do
    validation_result = if state == "accepted", do: "accepted", else: "denied"
    denial_code = if denial, do: Map.get(denial, :code) || Map.get(denial, "code")
    denial_message = if denial, do: Map.get(denial, :message) || Map.get(denial, "message")

    Txn.q(
      txn,
      """
      UPDATE identity_publication_markers
      SET validationResult = ?3, cause = ?4, denialCode = ?5,
          denialMessage = ?6, state = ?3, updatedAt = ?7
      WHERE invocationId = ?1 AND expectedPriorLive = ?2 AND state = 'pending'
      """,
      [
        marker.invocation_id,
        marker.expected_prior,
        validation_result,
        cause,
        denial_code,
        denial_message,
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
           state, createdAt, updatedAt)
        VALUES (?1, ?2, NULL, ?3, ?4, 'denied', ?5, ?6, ?7, 'denied', ?8, ?8)
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

  @doc "Canonical storage key for one or more immutable primary-key parts."
  @spec key(String.t() | [String.t()]) :: String.t()
  def key(value) when is_binary(value), do: value
  def key(parts) when is_list(parts), do: JSON.encode!(parts)

  @doc "Read a durable version floor outside or inside a transaction."
  @spec version(DB.server() | Txn.t(), String.t(), String.t() | [String.t()]) ::
          pos_integer() | nil
  def version(source, resource, primary_key) do
    case query(
           source,
           "SELECT rowVersion FROM admin_projection_versions WHERE resource = ?1 AND primaryKey = ?2",
           [
             resource,
             key(primary_key)
           ]
         ) do
      [[row_version]] -> row_version
      [] -> nil
    end
  end

  @doc "Allocate the next durable version inside the product transaction."
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
        rowVersion = admin_projection_versions.rowVersion + 1,
        updatedAt = excluded.updatedAt,
        fingerprint = excluded.fingerprint,
        item = excluded.item
      """,
      [resource, encoded_key, updated_at, fingerprint, item]
    )

    [[row_version]] =
      Txn.q(
        txn,
        "SELECT rowVersion FROM admin_projection_versions WHERE resource = ?1 AND primaryKey = ?2",
        [resource, encoded_key]
      )

    row_version
  end

  @doc "Return the last successfully stamped served-resource item."
  @spec stamped_item(DB.server() | Txn.t(), String.t(), String.t()) :: map() | nil
  def stamped_item(source, resource, primary_key) do
    case query(
           source,
           "SELECT item, rowVersion FROM admin_projection_versions WHERE resource = ?1 AND primaryKey = ?2",
           [resource, key(primary_key)]
         ) do
      [[item, row_version]] when is_binary(item) ->
        item
        |> JSON.decode!()
        |> Map.put("rowVersion", row_version)

      [] ->
        nil
    end
  end

  @doc "True when a served-resource source fingerprint is already stamped."
  @spec fingerprint_matches?(Txn.t(), String.t(), String.t(), String.t()) :: boolean()
  def fingerprint_matches?(%Txn{} = txn, resource, primary_key, fingerprint) do
    Txn.q(
      txn,
      "SELECT 1 FROM admin_projection_versions WHERE resource = ?1 AND primaryKey = ?2 AND fingerprint = ?3",
      [resource, key(primary_key), fingerprint]
    ) != []
  end

  @doc "Seed a served-resource stamp without advancing an existing floor."
  @spec seed_stamp_in_txn(Txn.t(), String.t(), String.t(), String.t(), map(), integer()) :: :ok
  def seed_stamp_in_txn(%Txn{} = txn, resource, primary_key, fingerprint, item, updated_at) do
    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO admin_projection_versions
        (resource, primaryKey, rowVersion, updatedAt, fingerprint, item)
      VALUES (?1, ?2, 1, ?3, ?4, ?5)
      """,
      [resource, key(primary_key), updated_at, fingerprint, JSON.encode!(item)]
    )

    :ok
  end

  @doc "Persist a loud publication-stamp fault in a separate recovery transaction."
  @spec record_fault(DB.server(), String.t(), String.t(), term()) :: :ok
  def record_fault(db, resource, primary_key, detail) do
    occurred_at = System.system_time(:millisecond)
    rendered = Exception.format_banner(:error, detail)

    case DB.transaction(db, fn txn ->
           Txn.q(
             txn,
             """
             INSERT INTO admin_projection_faults
               (resource, primaryKey, code, detail, occurredAt)
             VALUES (?1, ?2, 'projection_stamp_failed', ?3, ?4)
             ON CONFLICT(resource, primaryKey) DO UPDATE SET
               code = excluded.code, detail = excluded.detail, occurredAt = excluded.occurredAt
             """,
             [resource, key(primary_key), rendered, occurred_at]
           )

           :ok
         end) do
      {:ok, :ok} ->
        Logger.error(
          "unresolved projection stamp fault resource=#{resource} key=#{key(primary_key)}: #{rendered}"
        )

        :ok

      {:error, fault_error} ->
        Logger.error(
          "UNRECORDED projection stamp fault resource=#{resource} key=#{key(primary_key)} " <>
            "stamp=#{rendered} fault_store=#{Exception.message(fault_error)}"
        )

        :ok
    end
  end

  @doc "Clear a resolved fault in the successful stamp transaction."
  @spec clear_fault_in_txn(Txn.t(), String.t(), String.t()) :: :ok
  def clear_fault_in_txn(%Txn{} = txn, resource, primary_key) do
    Txn.q(
      txn,
      "DELETE FROM admin_projection_faults WHERE resource = ?1 AND primaryKey = ?2",
      [resource, key(primary_key)]
    )

    :ok
  end

  @doc "Stable SHA-256 fingerprint of an already allowlisted item."
  @spec fingerprint(map()) :: String.t()
  def fingerprint(item) when is_map(item) do
    :crypto.hash(:sha256, JSON.encode!(item)) |> Base.encode16(case: :lower)
  end

  @doc "Seed the committed served-identity and kungfu snapshots without publishing boot notices."
  @spec bootstrap_served(DB.server(), String.t()) :: :ok
  def bootstrap_served(db, base_dir) do
    entries = served_entries(db, base_dir)
    now = System.system_time(:millisecond)

    case DB.transaction(db, fn txn ->
           Enum.each(entries, fn entry ->
             seed_stamp_in_txn(
               txn,
               entry.resource,
               entry.key,
               fingerprint(entry.item),
               entry.item,
               now
             )
           end)

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  @doc "Build the allowlisted source entries after a successful Git publication."
  @spec served_entries(DB.server(), String.t()) :: [map()]
  def served_entries(db, base_dir) do
    identity =
      db
      |> StateResources.identity_snapshot(base_dir)
      |> canonical_without_version("identity")

    kungfu =
      base_dir
      |> StateResources.kungfu_names()
      |> Enum.flat_map(fn name ->
        case StateResources.kungfu_snapshot(base_dir, name) do
          nil ->
            []

          snapshot ->
            [
              %{
                resource: "kungfu",
                key: name,
                class: "kungfu.updated",
                refs: %{"name" => name},
                item: canonical_without_version(snapshot, "kungfu")
              }
            ]
        end
      end)

    [
      %{
        resource: "identity",
        key: "served",
        class: "identity.updated",
        refs: %{"name" => "served"},
        item: identity
      }
      | kungfu
    ]
  end

  @doc "Stamp changed served-resource fingerprints and queue their notices atomically."
  @spec stamp_publication(DB.server(), map(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, map()}
  def stamp_publication(db, call, entries, opts \\ []) when is_list(entries) do
    entries = Enum.map(entries, &normalize_served_entry/1)

    result =
      DB.transaction(db, fn txn ->
        if before_stamp = Keyword.get(opts, :before_stamp), do: before_stamp.(txn)
        Publisher.maybe_observed_accepted_in_txn(txn, call)

        changed =
          Enum.flat_map(entries, fn entry ->
            source_fingerprint = fingerprint(entry.item)

            if fingerprint_matches?(txn, entry.resource, entry.key, source_fingerprint) do
              []
            else
              updated_at = System.system_time(:millisecond)

              row_version =
                allocate_in_txn(txn, entry.resource, entry.key, updated_at,
                  fingerprint: source_fingerprint,
                  item: JSON.encode!(entry.item)
                )

              clear_fault_in_txn(txn, entry.resource, entry.key)
              payload = Map.put(entry.item, "rowVersion", row_version)
              Publisher.committed_in_txn(txn, entry.class, payload, entry.refs)
              [payload]
            end
          end)

        changed
      end)

    case result do
      {:ok, changed} ->
        {:ok, changed}

      {:error, error} ->
        Enum.each(entries, &record_fault(db, &1.resource, &1.key, error))

        {:error,
         %{
           code: "projection_stamp_failed",
           message: "published identity bytes could not be stamped for state projection"
         }}
    end
  end

  defp backfill_in_txn(txn, now) do
    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO admin_projection_versions
        (resource, primaryKey, rowVersion, updatedAt)
      SELECT 'config', key, 1, updatedAt FROM org_settings
      """
    )

    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO admin_projection_versions
        (resource, primaryKey, rowVersion, updatedAt)
      SELECT 'hosts', name, 1, ?1 FROM hosts
      """,
      [now]
    )

    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO admin_projection_versions
        (resource, primaryKey, rowVersion, updatedAt)
      SELECT 'users', userId, 1, createdAt FROM users
      """
    )

    for [host, harness, name, set_at] <-
          Txn.q(
            txn,
            "SELECT host, harness, name, setAt FROM harness_env_overlays ORDER BY host, harness, name"
          ) do
      encoded_key = key([host, harness, name])

      Txn.q(
        txn,
        """
        INSERT OR IGNORE INTO admin_projection_versions
          (resource, primaryKey, rowVersion, updatedAt)
        VALUES ('host environment', ?1, 1, ?2)
        """,
        [encoded_key, set_at]
      )

      [[row_version]] =
        Txn.q(
          txn,
          "SELECT rowVersion FROM admin_projection_versions WHERE resource = 'host environment' AND primaryKey = ?1",
          [encoded_key]
        )

      Txn.q(
        txn,
        """
        INSERT OR IGNORE INTO host_environment_projection
          (host, harness, name, valuePresent, updatedAt, rowVersion)
        VALUES (?1, ?2, ?3, 1, ?4, ?5)
        """,
        [host, harness, name, set_at, row_version]
      )
    end

    :ok
  end

  defp normalize_served_entry(%{
         resource: resource,
         key: key,
         class: class,
         refs: refs,
         item: item
       })
       when resource in ~w(identity kungfu) and is_binary(key) and is_binary(class) and
              is_map(refs) and is_map(item) do
    %{
      resource: resource,
      key: key,
      class: class,
      refs: refs,
      item: canonical_without_version(item, resource)
    }
  end

  defp normalize_served_entry(_entry),
    do: raise(ArgumentError, "invalid served-resource projection entry")

  defp canonical_without_version(item, "identity") do
    item |> Map.put("rowVersion", 1) |> StateResources.identity() |> Map.delete("rowVersion")
  end

  defp canonical_without_version(item, "kungfu") do
    item |> Map.put("rowVersion", 1) |> StateResources.kungfu() |> Map.delete("rowVersion")
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end
end
