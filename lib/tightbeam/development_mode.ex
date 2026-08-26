defmodule Tightbeam.DevelopmentMode do
  @moduledoc "The typed organization development-mode setting and its truthful session projection."

  alias Tightbeam.{DB, Org}
  alias Tightbeam.DB.Txn

  @setting "development-mode"

  @type value :: String.t()
  @type setting :: %{enabled: boolean(), value: value(), revision: non_neg_integer()}

  @doc "The canonical setting key."
  def setting, do: @setting

  @doc "Read the setting value and config row version in one database statement."
  @spec current(DB.server() | Txn.t()) :: setting()
  def current(source) do
    case query(source, """
         SELECT s.value, v.rowVersion
         FROM org_settings AS s
         JOIN admin_projection_versions AS v
           ON v.resource = 'config' AND v.primaryKey = s.key
         WHERE s.key = 'development-mode'
         """) do
      [] ->
        %{enabled: false, value: "off", revision: 0}

      [[value, revision]] when value in ["on", "off"] and is_integer(revision) and revision > 0 ->
        %{enabled: value == "on", value: value, revision: revision}

      rows ->
        raise "invalid development-mode setting projection: #{inspect(rows)}"
    end
  end

  @doc "Project one current setting against the supplied visible active sessions."
  @spec status(DB.server(), [Org.session()] | nil) :: map()
  def status(source, sessions \\ nil) do
    setting = current(source)
    sessions = sessions || Org.list_for_user(source, "", true)

    status_for(setting, sessions)
  end

  @doc "Project an already-linearized setting pair against active sessions."
  @spec status_for(setting(), [Org.session()]) :: map()
  def status_for(setting, sessions) do
    {stale, unmaterialized} =
      Enum.reduce(sessions, {[], []}, fn session, {stale, unmaterialized} ->
        case session.development_mode_revision do
          nil ->
            {stale, [session.session_key | unmaterialized]}

          revision
          when revision != setting.revision or session.development_mode_value != setting.value ->
            {[session.session_key | stale], unmaterialized}

          _revision ->
            {stale, unmaterialized}
        end
      end)

    setting
    |> Map.put(:stale_sessions, Enum.sort(stale))
    |> Map.put(:unmaterialized_sessions, Enum.sort(unmaterialized))
  end

  @doc "Convert the internal projection to the exact CLI list shape."
  def wire_status(status) do
    %{
      enabled: status.enabled,
      value: status.value,
      revision: status.revision,
      staleSessions: status.stale_sessions,
      unmaterializedSessions: status.unmaterialized_sessions
    }
  end

  defp query(%Txn{} = txn, sql), do: Txn.q(txn, sql)

  defp query(db, sql) do
    {:ok, rows} = DB.query(db, sql)
    rows
  end
end
