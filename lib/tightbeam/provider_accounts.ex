defmodule Tightbeam.ProviderAccounts do
  @moduledoc """
  Durable identities for provider logins and the account serving each harness on
  a host. Credential files and their lifecycle belong to Tightbeam.Credentials.
  """

  alias Tightbeam.{DB, Id, Schema}
  alias Tightbeam.DB.Txn

  def enabled?, do: Application.get_env(:tightbeam, :provider_accounts_enabled, false) == true

  @shape "provider-accounts-v1"
  @account_fields ~w(id host provider harness label kind slot loginState loginReason identityKey identityReason enabled signedInAt updatedAt rowVersion)
  @serving_fields ~w(harness host accountId revision reason sinceAt previousAccountId)
  @limit_fields ~w(id accountId identityKey scope observedAt lastObservedAt resetAt resetSource standingId evidenceKind evidenceTurnSeq clearedAt clearCause)

  @account_select Enum.join(@account_fields, ",")
  @serving_select Enum.join(@serving_fields, ",")
  @limit_select Enum.join(@limit_fields, ",")

  @schema """
  CREATE TABLE provider_accounts (
    id TEXT PRIMARY KEY NOT NULL,
    host TEXT NOT NULL,
    provider TEXT NOT NULL,
    harness TEXT NOT NULL,
    label TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 80),
    kind TEXT NOT NULL CHECK (kind IN ('subscription', 'api_key')),
    slot TEXT NOT NULL CHECK (slot = 'shared' OR slot = id),
    loginState TEXT NOT NULL CHECK (loginState IN ('signed_in', 'needs_sign_in', 'unknown', 'removed')),
    loginReason TEXT NOT NULL CHECK (loginReason IN ('ok', 'never_verified', 'rejected_by_provider', 'expired_not_refreshed', 'scope_insufficient', 'file_missing', 'unreadable', 'host_unreachable', 'duplicate_account', 'removed_by_operator')),
    identityKey TEXT,
    identityReason TEXT CHECK (identityReason IN ('not_checked', 'file_missing', 'unreadable', 'not_exposed_by_provider', 'host_unreachable')),
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    signedInAt INTEGER,
    updatedAt INTEGER NOT NULL,
    rowVersion INTEGER NOT NULL,
    UNIQUE (host, harness, slot),
    UNIQUE (harness, host, id),
    CHECK (kind != 'api_key' OR slot = 'shared'),
    CHECK ((identityKey IS NULL) = (identityReason IS NOT NULL))
  );

  CREATE UNIQUE INDEX provider_accounts_active_label
  ON provider_accounts (host, harness, label) WHERE loginState != 'removed';

  CREATE TABLE account_serving (
    harness TEXT NOT NULL,
    host TEXT NOT NULL,
    accountId TEXT,
    revision INTEGER NOT NULL CHECK (revision > 0),
    reason TEXT NOT NULL CHECK (reason IN ('initial', 'operator', 'exhausted', 'login_unusable', 'removed', 'recovered_from_none', 'none_signed_in', 'all_removed')),
    sinceAt INTEGER NOT NULL,
    previousAccountId TEXT,
    PRIMARY KEY (harness, host),
    FOREIGN KEY (harness, host, accountId) REFERENCES provider_accounts (harness, host, id),
    FOREIGN KEY (harness, host, previousAccountId) REFERENCES provider_accounts (harness, host, id)
  );

  CREATE TABLE account_limits (
    id TEXT PRIMARY KEY NOT NULL,
    accountId TEXT NOT NULL REFERENCES provider_accounts (id),
    identityKey TEXT,
    scope TEXT NOT NULL CHECK (
      scope IN ('account', 'primary', 'secondary', 'five_hour', 'seven_day')
      OR scope GLOB 'additional:?*' OR scope GLOB 'limit:?*'
    ),
    observedAt INTEGER NOT NULL,
    lastObservedAt INTEGER NOT NULL CHECK (lastObservedAt >= observedAt),
    resetAt INTEGER,
    resetSource TEXT NOT NULL CHECK (resetSource IN ('provider_stated', 'reading', 'assumed', 'none')),
    standingId TEXT NOT NULL,
    evidenceKind TEXT NOT NULL,
    evidenceTurnSeq INTEGER,
    clearedAt INTEGER,
    clearCause TEXT CHECK (clearCause IN ('reset_passed', 'probe_succeeded', 'reading_below_limit', 'turn_succeeded', 'signed_in_again', 'operator', 'assumed_expiry', 'account_removed')),
    CHECK ((resetAt IS NULL) = (resetSource = 'none')),
    CHECK ((clearedAt IS NULL) = (clearCause IS NULL))
  );

  CREATE INDEX account_limits_account ON account_limits (accountId, observedAt, id);
  CREATE INDEX account_limits_active_identity ON account_limits (identityKey, scope)
  WHERE clearedAt IS NULL AND identityKey IS NOT NULL;

  CREATE UNIQUE INDEX account_limits_one_standing
  ON account_limits (accountId, scope) WHERE clearedAt IS NULL;

  CREATE TABLE capacity_windows (
    accountId TEXT NOT NULL REFERENCES provider_accounts (id),
    windowId TEXT NOT NULL,
    windowScope TEXT NOT NULL CHECK (windowScope IN ('account', 'model')),
    model TEXT,
    usedPercent REAL NOT NULL CHECK (usedPercent BETWEEN 0 AND 100),
    resetAt INTEGER,
    windowSeconds INTEGER,
    observedAt INTEGER NOT NULL,
    readAttemptAt INTEGER NOT NULL CHECK (readAttemptAt <= observedAt),
    freshness TEXT NOT NULL,
    PRIMARY KEY (accountId, windowId),
    CHECK (windowScope = 'model' OR model IS NULL)
  );

  ALTER TABLE turns ADD COLUMN accountId TEXT REFERENCES provider_accounts (id);
  """

  @doc false
  def ensure_schema(db) do
    case DB.transaction(db, fn txn ->
           :ok =
             Txn.exec(txn, """
             CREATE TABLE IF NOT EXISTS provider_account_schema_stamp (
               id INTEGER PRIMARY KEY CHECK (id = 0),
               shape TEXT NOT NULL
             )
             """)

           case Txn.q(txn, "SELECT shape FROM provider_account_schema_stamp") do
             [] ->
               :ok = Txn.exec(txn, @schema)
               Txn.q(txn, "INSERT INTO provider_account_schema_stamp VALUES (0, ?1)", [@shape])

             [[@shape]] ->
               :ok

             rows ->
               raise Schema.ShapeError,
                 message: "incompatible provider account schema stamp: #{inspect(rows)}"
           end

           schema_checkpoint()
           :ok
         end) do
      {:ok, :ok} ->
        :ok

      {:error, %Schema.ShapeError{} = error} ->
        raise error

      {:error, error} ->
        raise Schema.ShapeError, message: "provider account migration failed: #{inspect(error)}"
    end
  end

  @doc "List provider accounts, including removed accounts kept for attribution."
  def list(db \\ DB) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{@account_select} FROM provider_accounts ORDER BY host, harness, label, id"
      )

    Enum.map(rows, &account_row/1)
  end

  @doc "Read one account by its stable ID."
  def get(db \\ DB, id) do
    {:ok, rows} =
      DB.query(db, "SELECT #{@account_select} FROM provider_accounts WHERE id = ?1", [id])

    one(rows, &account_row/1)
  end

  @doc "Read the serving account and selection revision for a harness on a host."
  def serving(db \\ DB, harness, host) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{@serving_select} FROM account_serving WHERE harness = ?1 AND host = ?2",
        [to_string(harness), host]
      )

    one(rows, &Map.new(Enum.zip(@serving_fields, &1)))
  end

  @doc "List the observed limits for an account, newest first."
  def limits(db \\ DB, account_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{@limit_select} FROM account_limits WHERE accountId = ?1 ORDER BY observedAt DESC, id",
        [account_id]
      )

    Enum.map(rows, &Map.new(Enum.zip(@limit_fields, &1)))
  end

  @doc false
  def shared_id(db, harness, host) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT id FROM provider_accounts WHERE host = ?1 AND harness = ?2 AND slot = 'shared'",
        [host, to_string(harness)]
      )

    one(rows, &hd/1)
  end

  @doc false
  def record_existing_shared(
        db,
        host,
        provider,
        harness,
        kind,
        state,
        reason,
        signed_in_at,
        registration \\ nil
      ) do
    account_id = "acct_" <> Id.uuid4()
    now = System.system_time(:millisecond)
    {base_dir, ssh} = registration || {nil, nil}

    DB.transaction(db, fn txn ->
      # A replaced remote worker can finish a read from the old directory after
      # registration changes. Check the source and publish the slot atomically.
      Txn.q(
        txn,
        """
        INSERT INTO provider_accounts
          (id, host, provider, harness, label, kind, slot, loginState, loginReason,
           identityReason, enabled, signedInAt, updatedAt, rowVersion)
        SELECT ?1, ?2, ?3, ?4, 'default', ?5, 'shared', ?6, ?7,
               'not_checked', 1, ?8, ?9, ?9
        WHERE ?10 IS NULL OR EXISTS (
          SELECT 1 FROM hosts WHERE name=?2 AND baseDir=?10 AND ssh IS ?11
        )
        ON CONFLICT (host, harness, slot) DO NOTHING
        """,
        [
          account_id,
          host,
          to_string(provider),
          to_string(harness),
          to_string(kind),
          state,
          reason,
          signed_in_at,
          now,
          base_dir,
          ssh
        ]
      )

      if Txn.changes(txn) == 1 do
        Txn.q(
          txn,
          """
          INSERT INTO account_serving (harness, host, accountId, revision, reason, sinceAt)
          VALUES (?1, ?2, ?3, 1, 'initial', ?4)
          """,
          [to_string(harness), host, account_id, now]
        )
      end

      :ok
    end)
  end

  if Mix.env() == :test do
    # The crash test stops this VM after the schema writes, before COMMIT.
    defp schema_checkpoint do
      if checkpoint = Application.get_env(:tightbeam, :provider_schema_checkpoint) do
        checkpoint.()
      end
    end
  else
    defp schema_checkpoint, do: :ok
  end

  defp account_row(values) do
    @account_fields
    |> Enum.zip(values)
    |> Map.new()
    |> Map.update!("enabled", &(&1 == 1))
  end

  defp one([], _decode), do: nil
  defp one([row], decode), do: decode.(row)
end
