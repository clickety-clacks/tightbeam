defmodule Tightbeam.FirstRunTour do
  @moduledoc false

  require Logger
  alias Tightbeam.{Archetypes, DB, Org, Placement, Roles}
  alias Tightbeam.DB.Txn

  @setting "first-run-tour"
  @role "tour-guide"
  @pending "pending"

  def enabled?, do: System.get_env("TIGHTBEAM_FIRST_RUN_ONBOARDING") == "true"

  # Only the DB birth transaction may call this. Existing installations and
  # bootstrap receipts left by older binaries never get this row.
  def mark_fresh_in_txn(%Txn{} = txn) do
    if enabled?() do
      Txn.q(txn, "INSERT INTO org_settings(key,value,updatedAt) VALUES(?1,?2,?3)", [
        @setting,
        @pending,
        System.system_time(:millisecond)
      ])
    end

    :ok
  end

  def eligible?(db) do
    case DB.query(db, "SELECT value FROM org_settings WHERE key=?1", [@setting]) do
      {:ok, [[_receipt]]} -> true
      _ -> false
    end
  end

  def ensure(db, defaults) do
    if enabled?() and Org.get_setting(db, @setting) == @pending and Archetypes.get(@role) do
      case DB.transaction(db, &seed_in_txn(&1, defaults)) do
        {:ok, _} -> :ok
        {:error, error} -> Logger.warning("Tour Guide seed failed: #{Exception.message(error)}")
      end
    end

    :ok
  end

  defp seed_in_txn(txn, defaults) do
    with [[@pending]] <- Txn.q(txn, "SELECT value FROM org_settings WHERE key=?1", [@setting]),
         [[owner]] <-
           Txn.q(txn, "SELECT userId FROM users WHERE isAdmin=1 ORDER BY createdAt,rowid LIMIT 1"),
         main = Org.personal_session_key(owner),
         [[1]] <- Txn.q(txn, "SELECT 1 FROM sessions WHERE sessionKey=?1", [main]) do
      provider = Map.fetch!(defaults, :provider)
      provider = if is_function(provider, 0), do: provider.(), else: provider

      session =
        Org.create_in_txn(txn, %{
          display_name: Org.initial_display_name_in_txn(txn, "Tour Guide"),
          kind: "custom",
          adopted: true,
          owner_user_id: owner,
          origin: "process:tightbeam",
          spawned_by: main,
          handle: @role,
          archetype: @role,
          host: Placement.local_host_name(),
          harness: defaults |> Map.fetch!(:harness) |> to_string(),
          provider: to_string(provider),
          model: Map.fetch!(defaults, :model)
        })

      Roles.create_in_txn!(txn, @role, owner, session.session_key)

      Txn.q(txn, "UPDATE org_settings SET value=?1,updatedAt=?2 WHERE key=?3", [
        session.session_key,
        System.system_time(:millisecond),
        @setting
      ])
    end

    :ok
  end
end
