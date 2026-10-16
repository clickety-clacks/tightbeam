defmodule Tightbeam.Ephemeral do
  @moduledoc "One-turn archetype lifecycle and return delivery."

  alias Tightbeam.{DB, Org, Wakes}
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
               createdAt INTEGER NOT NULL
             );
             CREATE TRIGGER ephemeral_assignment_insert BEFORE INSERT ON assignments
             WHEN EXISTS(SELECT 1 FROM ephemeral_sessions WHERE sessionKey=NEW.holderKey)
             BEGIN SELECT RAISE(ABORT,'ephemeral sessions cannot hold assignments'); END;
             CREATE TRIGGER ephemeral_assignment_update BEFORE UPDATE OF holderKey ON assignments
             WHEN EXISTS(SELECT 1 FROM ephemeral_sessions WHERE sessionKey=NEW.holderKey)
             BEGIN SELECT RAISE(ABORT,'ephemeral sessions cannot hold assignments'); END;
             CREATE TRIGGER ephemeral_card_insert BEFORE INSERT ON work_items
             WHEN EXISTS(SELECT 1 FROM ephemeral_sessions WHERE sessionKey=NEW.deliveryOwnerSessionKey)
             BEGIN SELECT RAISE(ABORT,'ephemeral sessions cannot own work items'); END;
             CREATE TRIGGER ephemeral_card_update BEFORE UPDATE OF deliveryOwnerSessionKey ON work_items
             WHEN EXISTS(SELECT 1 FROM ephemeral_sessions WHERE sessionKey=NEW.deliveryOwnerSessionKey)
             BEGIN SELECT RAISE(ABORT,'ephemeral sessions cannot own work items'); END;
             INSERT INTO ephemeral_migration VALUES(0);
             """)
           end

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  def session?(db, key) do
    query(db, "SELECT 1 FROM ephemeral_sessions WHERE sessionKey=?1", [key]) != []
  end

  def stamp_in_txn(txn, key, caller) do
    Txn.q(txn, "INSERT INTO ephemeral_sessions VALUES(?1,?2,?3)", [
      key,
      caller,
      System.system_time(:millisecond)
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
    case query(db, "SELECT boundSessionKey FROM roles WHERE name=?1", [role]) do
      [[key]] -> key
      [] -> nil
    end
  end

  defp origin_session(_db, _origin), do: nil

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

      session = Org.get_in_txn(txn, key)

      Tightbeam.Firehose.Publisher.committed_in_txn(txn, "session.retired", session, %{
        "sessionKey" => key
      })
    end

    :ok
  end

  # R2.5: the existing scheduler delivers the final response to the spawning agent.
  def return_in_txn(txn, key, text) do
    if caller = caller(txn, key) do
      Wakes.schedule_in_txn(txn, %{
        wake_id: "ephemeral-result:" <> key,
        session_key: caller,
        origin: "session:" <> key,
        prompt: "Ephemeral spawn result from #{key}:\n\n" <> text,
        due_at: System.system_time(:millisecond)
      })
    end

    :ok
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end
end
