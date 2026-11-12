defmodule Tightbeam.Ephemeral do
  @moduledoc "One-turn archetype lifecycle and return delivery."

  require Logger

  alias Tightbeam.{DB, Org, Rules, Wakes}
  alias Tightbeam.DB.Txn

  # R2.2-R2.5: stamp the election at spawn, independently of later identity edits.
  def migrate(db) do
    case DB.transaction(db, fn txn ->
           Txn.exec(txn, """
           CREATE TABLE IF NOT EXISTS ephemeral_migration (
             id INTEGER PRIMARY KEY CHECK(id=0)
           )
           """)

           if Txn.q(txn, "SELECT id FROM ephemeral_migration") == [] do
             Txn.exec(txn, """
             CREATE TABLE ephemeral_sessions (
               sessionKey TEXT PRIMARY KEY REFERENCES sessions(sessionKey),
               callerSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
               turnUsed INTEGER NOT NULL DEFAULT 0 CHECK(turnUsed IN (0,1))
             );
             INSERT INTO ephemeral_migration VALUES(0);
             """)
           end

           :ok
         end) do
      {:ok, :ok} ->
        set_available(db, true)

      {:error, error} ->
        Logger.error("Ephemeral migration failed; feature unavailable: #{inspect(error)}")
        set_available(db, false)
    end
  end

  defp set_available(db, available) do
    {:ok, _} = DB.transaction(db, fn _ -> Process.put({__MODULE__, :available}, available) end)
    :ok
  end

  def available?(%Txn{}), do: Process.get({__MODULE__, :available}, true)

  def available?(db) do
    {:ok, available} = DB.transaction(db, &available?/1)
    available
  end

  def session?(%Txn{} = txn, key) do
    available?(txn) and
      Txn.q(txn, "SELECT 1 FROM ephemeral_sessions WHERE sessionKey=?1", [key]) != []
  end

  def session?(db, key) do
    {:ok, result} = DB.transaction(db, &session?(&1, key))
    result
  end

  def stamp_in_txn(txn, key, caller) do
    unless available?(txn), do: raise("ephemeral feature unavailable")

    Txn.q(txn, "INSERT INTO ephemeral_sessions(sessionKey,callerSessionKey) VALUES(?1,?2)", [
      key,
      caller
    ])
  end

  def caller(db, key) do
    case query(db, "SELECT callerSessionKey FROM ephemeral_sessions WHERE sessionKey=?1", [key]) do
      [[caller]] -> caller
      [] -> nil
    end
  end

  # R2.3 and the inspection-only purpose. Refuse before the rule engine can escalate.
  def read_only?(db, call) do
    key =
      case call[:principal] do
        {:session, key} -> key
        _ -> origin_session(db, call.origin)
      end

    is_binary(key) and session?(db, key)
  end

  defp origin_session(_db, "session:" <> key), do: key

  defp origin_session(db, "agent:" <> role) do
    case Tightbeam.Origin.resolve_agent(db, role) do
      {:ok, key, false} -> key
      _ -> nil
    end
  end

  defp origin_session(_db, _origin), do: nil

  def retire_turn_in_txn(txn, seq) do
    if available?(txn) do
      case single_turn_policy() do
        :unavailable ->
          :ok

        policy ->
          case Txn.q(
                 txn,
                 "SELECT e.sessionKey,t.status FROM turns t JOIN ephemeral_sessions e ON e.sessionKey=t.sessionKey WHERE t.seq=?1",
                 [seq]
               ) do
            [[key, status]] ->
              return_in_txn(txn, key, terminal_summary(status), policy.result_recipients)

              if policy.automatic_retirement do
                retire_in_txn(txn, key)
              else
                :ok
              end

            [] ->
              :ok
          end
      end
    end

    :ok
  end

  # R2.2: the terminal CAS owns retirement, including failed and canceled turns.
  def retire_in_txn(txn, key) do
    if session?(txn, key) do
      Txn.q(
        txn,
        """
        UPDATE sessions SET state='retired', mechanicalStatus='idle', updatedAt=MAX(updatedAt+1,?2)
        WHERE sessionKey=?1 AND state='active'
        """,
        [key, System.system_time(:millisecond)]
      )

      Tightbeam.SentinelSubscriptions.end_session_in_txn(txn, key)

      session = Org.get_in_txn(txn, key)

      Tightbeam.Firehose.Publisher.committed_in_txn(txn, "session.retired", session, %{
        "sessionKey" => key
      })
    end

    :ok
  end

  defp terminal_summary("delivered"), do: "Helper completed without a final message."
  defp terminal_summary("canceled"), do: "Helper turn was canceled."

  defp terminal_summary("failed_unknown"),
    do: "Helper turn was interrupted and recovered as failed."

  defp terminal_summary(_), do: "Helper turn failed."

  def final_message_in_txn(txn, key, text) when is_binary(text) do
    Txn.q(txn, "UPDATE wakes SET prompt=?2 WHERE wakeId=?1 AND state='pending'", [
      "ephemeral-result:" <> key,
      "Ephemeral spawn result from #{key}:\n\n" <> text
    ])

    :ok
  end

  def final_message_in_txn(_txn, _key, _text), do: :ok

  # R2.5: the existing scheduler delivers the final response to the first
  # available address in the declared order.
  def return_in_txn(txn, key, text) do
    case single_turn_policy() do
      :unavailable ->
        :ok

      policy ->
        return_in_txn(txn, key, text, policy.result_recipients)
    end
  end

  defp return_in_txn(txn, key, text, recipients) do
    if session?(txn, key) and Wakes.get_in_txn(txn, "ephemeral-result:" <> key) == nil do
      caller = caller(txn, key)

      case recipient(txn, caller, recipients) do
        target when is_binary(target) ->
          Wakes.schedule_in_txn(txn, %{
            wake_id: "ephemeral-result:" <> key,
            session_key: target,
            origin: "session:" <> key,
            prompt: "Ephemeral spawn result from #{key}:\n\n" <> text,
            due_at: System.system_time(:millisecond)
          })

        nil ->
          Logger.warning(
            "Dropping ephemeral result from #{key}: no available address was selected"
          )
      end
    end

    :ok
  end

  defp recipient(_txn, nil, _order), do: nil

  defp recipient(txn, caller, order) do
    Enum.find_value(order, fn
      "caller" ->
        case Txn.q(
               txn,
               "SELECT sessionKey FROM sessions WHERE sessionKey=?1 AND state!='retired'",
               [caller]
             ) do
          [[key]] -> key
          [] -> nil
        end

      "parent" ->
        case Txn.q(
               txn,
               "SELECT p.sessionKey FROM sessions c JOIN sessions p ON p.sessionKey=c.spawnedBy " <>
                 "WHERE c.sessionKey=?1 AND p.state!='retired'",
               [caller]
             ) do
          [[key]] -> key
          [] -> nil
        end
    end)
  end

  defp single_turn_policy do
    case Rules.reaction_policy("single-turn-session") do
      nil ->
        family_count =
          Rules.effective_snapshot()
          |> Map.get(:reactions, [])
          |> Enum.count(&(&1.mode == :settings and &1.family == "single-turn-session"))

        if family_count > 1, do: unavailable_single_turn_policy("ambiguous"), else: :unavailable

      %{settings: settings} when is_map(settings) ->
        automatic_retirement = Map.get(settings, "automatic_retirement")
        recipients = Map.get(settings, "result_recipients")
        keys = settings |> Map.keys() |> Enum.sort()

        if is_boolean(automatic_retirement) and is_list(recipients) and
             keys == ["automatic_retirement", "result_recipients"] and
             Enum.all?(recipients, &(&1 in ["caller", "parent"])) and
             length(Enum.uniq(recipients)) == length(recipients) do
          %{automatic_retirement: automatic_retirement, result_recipients: recipients}
        else
          unavailable_single_turn_policy("invalid")
        end

      _ ->
        unavailable_single_turn_policy("invalid")
    end
  end

  defp unavailable_single_turn_policy(reason) do
    Logger.warning(
      "substrate settings family single-turn-session is #{reason}; no retirement or result route was selected"
    )

    :unavailable
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end
end
