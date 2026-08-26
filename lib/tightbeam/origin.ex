defmodule Tightbeam.Origin do
  @moduledoc """
  The origin-class vocabulary in code: the one parser for an origin string,
  and the projection of its class onto the wire's `startedBy` axis.

  Origin classes are a CLOSED set (T3, bible §wakes): `user:<id>` (a human),
  `agent:<handle>` (a session), `process:<name>` (automation — cron, CI,
  webhooks), and two substrate-reserved classes that transports cannot name:
  `remedy:<statute>` for rail remedies and `bootstrap:first-user` for the
  transaction-scoped first-user authority.

  `started_by/1` collapses that set to the three-way axis a chat client renders
  from — did a human start this session, did an agent hire it, or did the
  substrate itself stand it up — so no client ever parses an origin string.
  The origin stays on the wire beside it as the detailed provenance.
  """

  require Logger

  @unclassified_key {__MODULE__, :warned_unclassified}

  @type class :: :user | :agent | :process | :remedy | :bootstrap
  @type started_by :: String.t()

  @doc "Parse an origin into `{class, identifier}`, or `:malformed`."
  @spec parse(term()) :: {class(), String.t()} | :malformed
  def parse(origin) when is_binary(origin) do
    case String.split(origin, ":", parts: 2) do
      ["user", rest] when rest != "" -> {:user, rest}
      ["agent", rest] when rest != "" -> {:agent, rest}
      ["process", rest] when rest != "" -> {:process, rest}
      ["remedy", rest] when rest != "" -> {:remedy, rest}
      ["bootstrap", rest] when rest != "" -> {:bootstrap, rest}
      _ -> :malformed
    end
  end

  def parse(_), do: :malformed

  @doc "The origin's class as a string, or nil when the origin is malformed."
  @spec class(term()) :: String.t() | nil
  def class(origin) do
    case parse(origin) do
      {class, _} -> Atom.to_string(class)
      :malformed -> nil
    end
  end

  @doc """
  Who started a session: `"user"`, `"agent"`, or `"substrate"`. TOTAL — every
  session classifies, because a client that has to handle a missing value has
  to invent a policy for it.
  """
  @spec started_by(term()) :: started_by()
  def started_by(origin) do
    case parse(origin) do
      {:user, _} -> "user"
      {:agent, _} -> "agent"
      {:process, _} -> "substrate"
      {:remedy, _} -> "substrate"
      {:bootstrap, _} -> "substrate"
      :malformed -> unclassified(origin)
    end
  end

  # An origin outside the closed class set cannot be produced by any writer —
  # the column is NOT NULL and every creation path stamps a class — so reaching
  # here is a substrate defect, never client input. We classify "substrate"
  # rather than raise or return nil: the conservative answer hides the session
  # from the chat list until the operator adopts it, which is the right failure
  # for a session whose provenance we cannot read, and one bad row must not take
  # down the catalog frame carrying every other session. Warned ONCE per node so
  # the defect is visible without a snapshot of N bad rows becoming N log lines.
  defp unclassified(origin) do
    unless :persistent_term.get(@unclassified_key, false) do
      :persistent_term.put(@unclassified_key, true)

      Logger.warning(
        "session origin #{inspect(origin)} is outside the closed class set; " <>
          "reporting startedBy=substrate"
      )
    end

    "substrate"
  end
end
