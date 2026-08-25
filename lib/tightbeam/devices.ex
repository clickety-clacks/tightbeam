defmodule Tightbeam.Devices do
  @moduledoc """
  Device pairing + token store (TS reference: src/wire/devices.ts — port its
  behavior exactly; its test file is the acceptance oracle).

  USERS own identity and admin-ness; DEVICES are credentials attached to a
  user (membership). Pairing with a claimed name is a request to join that
  user; approval is the authentication ceremony. The FIRST user ever is admin
  (cold-start rule); `is_admin` on a device is DERIVED from the owning user at
  read time, never stored on the device — admin follows the person, not the
  phone. Tokens are opaque per-device bearers (third credential class,
  gateway-owned; prefix `tbt_`).
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @type db :: GenServer.server()

  @typedoc "A device row; `is_admin` is derived from the owning user via JOIN."
  @type device :: %{
          device_id: String.t(),
          user_id: String.t(),
          claimed_name: String.t(),
          status: String.t(),
          is_admin: boolean(),
          token: String.t() | nil,
          platform: String.t() | nil,
          model: String.t() | nil,
          created_at: integer()
        }

  @type user :: %{
          user_id: String.t(),
          is_admin: boolean(),
          creation_kind: String.t(),
          created_at: integer()
        }

  @typedoc "Pairing outcome — mirrors the TS PairOutcome union."
  @type pair_outcome ::
          {:paired, device()} | {:pending, device()} | :denied

  @ddl """
  CREATE TABLE IF NOT EXISTS users (
    userId       TEXT PRIMARY KEY,
    isAdmin      INTEGER NOT NULL DEFAULT 0,
    creationKind TEXT NOT NULL DEFAULT 'legacy' CHECK (creationKind IN (
      'cold_start','gateway_local_bootstrap','device_pair','admin_add','legacy'
    )),
    createdAt    INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS devices (
    deviceId    TEXT PRIMARY KEY,
    userId      TEXT NOT NULL REFERENCES users(userId),
    claimedName TEXT NOT NULL,
    status      TEXT NOT NULL CHECK (status IN ('allowlisted','pending','denied')),
    token       TEXT UNIQUE,
    platform    TEXT,
    model       TEXT,
    createdAt   INTEGER NOT NULL
  );
  CREATE TRIGGER IF NOT EXISTS users_gateway_owned_insert
  BEFORE INSERT ON users
  WHEN NEW.creationKind = 'legacy'
  BEGIN
    SELECT RAISE(ABORT, 'bootstrap_owned_by_gateway');
  END;
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc """
  Pair a device. Semantics (devices.ts `pair`) — all in ONE transaction:
  - Known denied device → :denied. Known pending → {:pending, device}.
  - Known allowlisted → rotate its token, {:paired, device}.
  - Unknown device: user_id is slugged from claimed_name
    (lowercase, non-alphanumerics → "-", trimmed; empty → "user") and the
    device is pending with a nil token. `Tightbeam.ColdStart` owns the only
    first-device exception and calls the in-transaction helpers below.
  """
  @spec pair(db(), %{
          device_id: String.t(),
          claimed_name: String.t(),
          platform: String.t() | nil,
          model: String.t() | nil
        }) :: pair_outcome()
  def pair(db \\ Tightbeam.DB, input) do
    transaction!(db, fn txn -> pair_in_txn(txn, input) end)
  end

  @doc false
  @spec pair_in_txn(Txn.t(), map()) :: pair_outcome()
  def pair_in_txn(%Txn{} = txn, input) do
    device_id = Map.fetch!(input, :device_id)

    case select_device(txn, "d.deviceId = ?1", [device_id]) do
      [row] ->
        case to_device(row) do
          %{status: "denied"} ->
            :denied

          %{status: "pending"} = device ->
            {:pending, device}

          %{status: "allowlisted"} ->
            Txn.q(txn, "UPDATE devices SET token = ?2 WHERE deviceId = ?1", [
              device_id,
              mint_token()
            ])

            {:paired, must_get(txn, device_id)}
        end

      [] ->
        claimed_name = Map.fetch!(input, :claimed_name)
        user_id = slug_user_id(claimed_name)
        ensure_user_in_txn(txn, user_id, "device_pair")
        device = insert_device_in_txn(txn, Map.put(input, :user_id, user_id), "pending", nil)
        {:pending, device}
    end
  end

  @doc "Device by bearer token — ONLY if allowlisted (revoked/pending tokens never resolve)."
  @spec by_token(db(), String.t()) :: device() | nil
  def by_token(db \\ Tightbeam.DB, token) do
    {:ok, rows} =
      DB.query(db, select_device_sql() <> " WHERE d.token = ?1 AND d.status = 'allowlisted'", [
        token
      ])

    one_device_or_nil(rows)
  end

  @doc "Device by id regardless of status (for auth-failure reason mapping)."
  @spec by_id(db(), String.t()) :: device() | nil
  def by_id(db \\ Tightbeam.DB, device_id) do
    {:ok, rows} = DB.query(db, select_device_sql() <> " WHERE d.deviceId = ?1", [device_id])
    one_device_or_nil(rows)
  end

  @doc """
  Approve a pending device: status → allowlisted, mint a fresh token, and
  attach to the claimed user (or the explicit override `user_id`, creating it
  non-admin if new). Raises on unknown device.
  """
  @spec approve(db(), String.t(), String.t() | nil) :: device()
  def approve(db \\ Tightbeam.DB, device_id, user_id \\ nil) do
    transaction!(db, fn txn ->
      must_get(txn, device_id)
      if user_id, do: ensure_user_in_txn(txn, user_id)

      Txn.q(
        txn,
        """
          UPDATE devices
          SET status = 'allowlisted', userId = COALESCE(?2, userId), token = ?3
          WHERE deviceId = ?1
        """,
        [device_id, user_id, mint_token()]
      )

      must_get(txn, device_id)
    end)
  end

  @doc "Deny a device: status → denied, token cleared. Raises on unknown device."
  @spec deny(db(), String.t()) :: :ok
  def deny(db \\ Tightbeam.DB, device_id) do
    transaction!(db, fn txn ->
      must_get(txn, device_id)

      Txn.q(txn, "UPDATE devices SET status = 'denied', token = NULL WHERE deviceId = ?1", [
        device_id
      ])

      :ok
    end)
  end

  @doc "Revoke a device's token (status unchanged — it re-pairs). Raises on unknown device."
  @spec revoke(db(), String.t()) :: :ok
  def revoke(db \\ Tightbeam.DB, device_id) do
    transaction!(db, fn txn ->
      must_get(txn, device_id)
      Txn.q(txn, "UPDATE devices SET token = NULL WHERE deviceId = ?1", [device_id])
      :ok
    end)
  end

  @doc "User row by id, or nil."
  @spec user(db(), String.t()) :: user() | nil
  def user(db \\ Tightbeam.DB, user_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT userId, isAdmin, creationKind, createdAt FROM users WHERE userId = ?1",
        [
          user_id
        ]
      )

    case rows do
      [row] -> to_user(row)
      [] -> nil
    end
  end

  @doc "Add a user. The shared cold-start insertion rule makes the first user admin."
  @spec add_user(db(), String.t(), boolean()) :: user()
  def add_user(db \\ Tightbeam.DB, user_id, is_admin) do
    transaction!(db, fn txn ->
      insert_user_in_txn(txn, user_id, is_admin)

      must_get_user(txn, user_id)
    end)
  end

  @doc "Set a user's admin bit (the promote-user verb's write). Raises on unknown user."
  @spec set_user_admin(db(), String.t(), boolean()) :: user()
  def set_user_admin(db \\ Tightbeam.DB, user_id, is_admin) do
    transaction!(db, fn txn ->
      must_get_user(txn, user_id)

      Txn.q(txn, "UPDATE users SET isAdmin = ?2 WHERE userId = ?1", [
        user_id,
        if(is_admin, do: 1, else: 0)
      ])

      must_get_user(txn, user_id)
    end)
  end

  @doc "Pending devices, oldest first (the approval queue)."
  @spec list_pending(db()) :: [device()]
  def list_pending(db \\ Tightbeam.DB) do
    {:ok, rows} =
      DB.query(db, select_device_sql() <> " WHERE d.status = 'pending' ORDER BY d.createdAt")

    Enum.map(rows, &to_device/1)
  end

  @doc "Count of users with at least one allowlisted device."
  @spec user_count(db()) :: non_neg_integer()
  def user_count(db \\ Tightbeam.DB) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT COUNT(DISTINCT userId) FROM devices WHERE status = 'allowlisted'")

    count
  end

  defp select_device_sql do
    """
    SELECT d.deviceId, d.userId, d.claimedName, d.status, d.token, d.platform,
           d.model, d.createdAt, u.isAdmin
    FROM devices d JOIN users u ON u.userId = d.userId
    """
  end

  defp select_device(txn, where, params) do
    Txn.q(txn, select_device_sql() <> " WHERE #{where}", params)
  end

  @doc false
  def get_device_in_txn(%Txn{} = txn, device_id) do
    case select_device(txn, "d.deviceId = ?1", [device_id]) do
      [row] -> to_device(row)
      [] -> nil
    end
  end

  @doc false
  def get_device_by_token_in_txn(%Txn{} = txn, token) do
    case select_device(txn, "d.token = ?1 AND d.status = 'allowlisted'", [token]) do
      [row] -> to_device(row)
      [] -> nil
    end
  end

  @doc false
  def get_user_in_txn(%Txn{} = txn, user_id) do
    case Txn.q(
           txn,
           "SELECT userId, isAdmin, creationKind, createdAt FROM users WHERE userId = ?1",
           [
             user_id
           ]
         ) do
      [row] -> to_user(row)
      [] -> nil
    end
  end

  @doc false
  def insert_device_in_txn(%Txn{} = txn, input, status, token)
      when status in ~w(allowlisted pending denied) do
    created_at = now()

    Txn.q(
      txn,
      """
      INSERT INTO devices
        (deviceId, userId, claimedName, status, token, platform, model, createdAt)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
      """,
      [
        Map.fetch!(input, :device_id),
        Map.fetch!(input, :user_id),
        Map.fetch!(input, :claimed_name),
        status,
        token,
        Map.get(input, :platform),
        Map.get(input, :model),
        created_at
      ]
    )

    must_get(txn, Map.fetch!(input, :device_id))
  end

  defp must_get(txn, device_id) do
    case select_device(txn, "d.deviceId = ?1", [device_id]) do
      [row] -> to_device(row)
      [] -> raise ArgumentError, "unknown device: #{device_id}"
    end
  end

  defp one_device_or_nil([row]), do: to_device(row)
  defp one_device_or_nil([]), do: nil

  defp to_device([
         device_id,
         user_id,
         claimed_name,
         status,
         token,
         platform,
         model,
         created_at,
         is_admin
       ]) do
    %{
      device_id: device_id,
      user_id: user_id,
      claimed_name: claimed_name,
      status: status,
      is_admin: is_admin == 1,
      token: token,
      platform: platform,
      model: model,
      created_at: created_at
    }
  end

  @doc false
  def ensure_user_in_txn(%Txn{} = txn, user_id, creation_kind \\ "device_pair")
      when creation_kind in ~w(cold_start gateway_local_bootstrap device_pair admin_add legacy) do
    case Txn.q(txn, "SELECT userId FROM users WHERE userId = ?1", [user_id]) do
      [] ->
        insert_user_in_txn(txn, user_id, false, creation_kind)

      [_] ->
        :ok
    end
  end

  @doc false
  def insert_user_in_txn(%Txn{} = txn, user_id, requested_admin, creation_kind \\ "admin_add")
      when creation_kind in ~w(cold_start gateway_local_bootstrap device_pair admin_add legacy) do
    created_at = now()

    Txn.q(
      txn,
      """
      INSERT INTO users (userId, isAdmin, creationKind, createdAt)
      VALUES (
        ?1,
        CASE WHEN (SELECT COUNT(*) FROM users) = 0 THEN 1 ELSE ?2 END,
        ?3,
        ?4
      )
      """,
      [user_id, if(requested_admin, do: 1, else: 0), creation_kind, created_at]
    )

    :ok
  end

  defp must_get_user(txn, user_id) do
    case Txn.q(
           txn,
           "SELECT userId, isAdmin, creationKind, createdAt FROM users WHERE userId = ?1",
           [
             user_id
           ]
         ) do
      [row] -> to_user(row)
      [] -> raise ArgumentError, "unknown user: #{user_id}"
    end
  end

  defp to_user([user_id, is_admin, creation_kind, created_at]) do
    %{
      user_id: user_id,
      is_admin: is_admin == 1,
      creation_kind: creation_kind,
      created_at: created_at
    }
  end

  @doc false
  def slug_user_id(claimed_name) do
    case claimed_name
         |> String.downcase()
         |> String.replace(~r/[^a-z0-9]+/, "-")
         |> String.trim("-") do
      "" -> "user"
      slug -> slug
    end
  end

  @doc false
  def mint_token do
    "tbt_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)
end
