defmodule Tightbeam.Firehose.Rebuild do
  @moduledoc """
  Fresh canonical reads for the ruled Firehose rebuild subset.

  The Registry flag is the closed capability boundary. A class without that
  flag cannot be rebuilt through this seam.
  """

  alias Tightbeam.Firehose.{Publisher, Registry}
  alias Tightbeam.{StateResources, StateVisibility}

  @spec classes() :: [String.t()]
  def classes do
    Registry.rows()
    |> Enum.flat_map(fn {class, row} -> if row[:rebuild], do: [class], else: [] end)
    |> Enum.sort()
  end

  @spec fetch(GenServer.server(), String.t(), map(), String.t(), boolean()) ::
          {:ok, map()} | :not_found | :forbidden | :unsupported
  def fetch(db, class, refs, user_id, is_admin)
      when is_map(refs) and is_binary(user_id) and byte_size(user_id) > 0 and
             is_boolean(is_admin) do
    with {:ok, %{rebuild: true}} <- Registry.fetch(class),
         raw when not is_nil(raw) <- query(db, class, refs, user_id),
         notice = Publisher.committed_notice(class, raw, rebuild_refs(class, raw, refs)),
         true <- StateVisibility.visible?(db, notice, user_id, is_admin) do
      {:ok, notice["payload"]}
    else
      :error -> :unsupported
      nil -> :not_found
      false -> :forbidden
      {:ok, _row} -> :unsupported
    end
  end

  defp query(db, "config.updated", refs, _user_id) do
    StateResources.query_config(db, fetch!(refs, "key"))
  end

  defp query(db, "host_env.updated", refs, _user_id) do
    StateResources.query_host_environment(
      db,
      fetch!(refs, "host"),
      fetch!(refs, "harness"),
      fetch!(refs, "name")
    )
  end

  defp query(db, "host.registered", refs, _user_id),
    do: StateResources.query_host(db, fetch!(refs, "host"))

  defp query(db, class, refs, _user_id)
       when class in ~w(user.added user.promoted),
       do: StateResources.query_user(db, fetch!(refs, "userId"))

  defp query(db, class, refs, _user_id)
       when class in ~w(device.approved device.denied device.revoked),
       do: StateResources.query_device(db, fetch!(refs, "deviceId"))

  defp query(db, "read_marker.updated", refs, user_id) do
    marker_user = refs["userId"] || principal_user(refs["principal"]) || user_id
    StateResources.query_read_marker(db, marker_user, fetch!(refs, "scopeKey"))
  end

  defp query(db, "critical_lease.updated", refs, _user_id),
    do: StateResources.query_critical_state(db, fetch!(refs, "sessionKey"))

  defp query(db, "attest.filed", refs, _user_id),
    do: StateResources.query_attest(db, fetch!(refs, "attestId"))

  defp query(db, "condition_fact.filed", refs, _user_id),
    do: StateResources.query_condition_fact(db, fetch!(refs, "factId"))

  defp query(db, "message.created", refs, _user_id),
    do: StateResources.query_message(db, fetch!(refs, "messageId"))

  defp query(db, "prod.fired", refs, _user_id),
    do: StateResources.query_production(db, fetch!(refs, "eventId"))

  defp query(db, "identity.updated", refs, _user_id) do
    db
    |> StateResources.query_identity(%{"name" => fetch!(refs, "name")})
    |> List.first()
  end

  defp query(db, "kungfu.updated", refs, _user_id),
    do: StateResources.query_kungfu(db, fetch!(refs, "name"))

  defp rebuild_refs("condition_fact.filed", %{origin: origin}, refs),
    do: Map.put_new(refs, "principal", origin)

  defp rebuild_refs("read_marker.updated", %{user_id: user_id}, refs),
    do: Map.put_new(refs, "userId", user_id)

  defp rebuild_refs(_class, _raw, refs), do: refs

  defp fetch!(refs, key) do
    case Map.fetch(refs, key) do
      {:ok, value} when is_binary(value) and value != "" -> value
      {:ok, value} when is_integer(value) -> value
      _ -> raise ArgumentError, "missing Firehose rebuild ref: #{key}"
    end
  end

  defp principal_user("user:" <> user_id), do: user_id
  defp principal_user(_principal), do: nil
end
