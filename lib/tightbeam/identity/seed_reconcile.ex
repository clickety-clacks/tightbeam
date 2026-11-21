defmodule Tightbeam.Identity.SeedReconcile do
  @moduledoc """
  Startup delivery of shipped seed defaults to an existing identity.

  A fresh install is seeded from `priv/seed`. An install that predates a shipped
  default has no such entry, and only a manual `tightbeam identity relearn` would
  add it. At every boot this adds the absent entries of the seed law files that
  `Identity` lists for delivery (today the finished-child notice) to the live
  identity as one recorded commit and publishes it, the same way the rail-scope
  migration does. It never changes an entry that is present, so an edited live
  copy stays as the operator left it. What it cannot add it reports as a warning
  that names the exact command.
  """

  require Logger

  alias Tightbeam.{AdminProjection, DB, Identity}

  @spec run!(String.t(), DB.server()) :: map()
  def run!(base_dir, db \\ DB) do
    result = Identity.reconcile_seed_law!(base_dir, &publish!(base_dir, db, &1))

    if result.added != [] do
      Logger.info(
        "added shipped seed rules to the live identity: " <>
          Enum.join(result.added, ", ") <> " (revision #{result.candidate.candidate_revision})"
      )
    end

    if notice = Identity.format_seed_law_attention(result.attention), do: Logger.warning(notice)

    result
  end

  # Publication and the served-identity stamp move together, so a failure rolls
  # both back and boot never serves a revision the stamp does not describe.
  defp publish!(base_dir, db, candidate) do
    {:ok, _revision} =
      case DB.transaction(db, fn txn ->
             case Identity.publish_live!(base_dir, candidate) do
               {:ok, revision} ->
                 identity = AdminProjection.served_identity_entry(txn, base_dir)

                 AdminProjection.allocate_in_txn(
                   txn,
                   "identity",
                   "served",
                   System.system_time(:millisecond),
                   fingerprint: AdminProjection.fingerprint(identity.item),
                   item: JSON.encode!(identity.item)
                 )

                 revision

               {:error, error} ->
                 raise ArgumentError, "identity publication failed: #{inspect(error)}"
             end
           end) do
        {:ok, revision} -> {:ok, revision}
        {:error, error} -> raise error
      end

    :ok
  end
end
