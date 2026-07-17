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

  @type user :: %{user_id: String.t(), is_admin: boolean(), created_at: integer()}

  @typedoc "Pairing outcome — mirrors the TS PairOutcome union."
  @type pair_outcome ::
          {:paired, device()} | {:pending, device()} | :denied

  @ddl """
  CREATE TABLE IF NOT EXISTS users (
    userId    TEXT PRIMARY KEY,
    isAdmin   INTEGER NOT NULL DEFAULT 0,
    createdAt INTEGER NOT NULL
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
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc """
  Pair a device. Semantics (devices.ts `pair`) — all in ONE transaction:
  - Known denied device → :denied. Known pending → {:pending, device}.
  - Known allowlisted → rotate its token, {:paired, device}.
  - Unknown device: user_id is slugged from claimed_name
    (lowercase, non-alphanumerics → "-", trimmed; empty → "user"). If NO users
    exist yet, the user bootstraps as admin and the device is allowlisted with
    a fresh token ({:paired, _}); otherwise the device is pending with a nil
    token ({:pending, _}) — including new devices claiming an EXISTING user.
  """
  @spec pair(db(), %{
          device_id: String.t(),
          claimed_name: String.t(),
          platform: String.t() | nil,
          model: String.t() | nil
        }) :: pair_outcome()
  def pair(db \\ Tightbeam.DB, input) do
    raise "TODO(sol): port devices.ts pair/1 — #{inspect({db, input})}"
  end

  @doc "Device by bearer token — ONLY if allowlisted (revoked/pending tokens never resolve)."
  @spec by_token(db(), String.t()) :: device() | nil
  def by_token(db \\ Tightbeam.DB, token) do
    raise "TODO(sol): #{inspect({db, token})}"
  end

  @doc "Device by id regardless of status (for auth-failure reason mapping)."
  @spec by_id(db(), String.t()) :: device() | nil
  def by_id(db \\ Tightbeam.DB, device_id) do
    raise "TODO(sol): #{inspect({db, device_id})}"
  end

  @doc """
  Approve a pending device: status → allowlisted, mint a fresh token, and
  attach to the claimed user (or the explicit override `user_id`, creating it
  non-admin if new). Raises on unknown device.
  """
  @spec approve(db(), String.t(), String.t() | nil) :: device()
  def approve(db \\ Tightbeam.DB, device_id, user_id \\ nil) do
    raise "TODO(sol): #{inspect({db, device_id, user_id})}"
  end

  @doc "Deny a device: status → denied, token cleared. Raises on unknown device."
  @spec deny(db(), String.t()) :: :ok
  def deny(db \\ Tightbeam.DB, device_id) do
    raise "TODO(sol): #{inspect({db, device_id})}"
  end

  @doc "Revoke a device's token (status unchanged — it re-pairs). Raises on unknown device."
  @spec revoke(db(), String.t()) :: :ok
  def revoke(db \\ Tightbeam.DB, device_id) do
    raise "TODO(sol): #{inspect({db, device_id})}"
  end

  @doc "User row by id, or nil."
  @spec user(db(), String.t()) :: user() | nil
  def user(db \\ Tightbeam.DB, user_id) do
    raise "TODO(sol): #{inspect({db, user_id})}"
  end

  @doc "Set a user's admin bit (the promote-user verb's write). Raises on unknown user."
  @spec set_user_admin(db(), String.t(), boolean()) :: user()
  def set_user_admin(db \\ Tightbeam.DB, user_id, is_admin) do
    raise "TODO(sol): #{inspect({db, user_id, is_admin})}"
  end

  @doc "Pending devices, oldest first (the approval queue)."
  @spec list_pending(db()) :: [device()]
  def list_pending(db \\ Tightbeam.DB) do
    raise "TODO(sol): #{inspect(db)}"
  end

  @doc "Count of users with at least one allowlisted device."
  @spec user_count(db()) :: non_neg_integer()
  def user_count(db \\ Tightbeam.DB) do
    raise "TODO(sol): #{inspect(db)}"
  end
end
