defmodule Tightbeam.RevocationFixture do
  @moduledoc false
  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  # Test-only durable close at a specified fixture time. Keep production guards
  # active and bind the recorded actor/reason to the actual current generation.
  def close!(db, assignment_id, ts, reason) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        revocation_id = "fixture-revocation-" <> assignment_id <> "-" <> Integer.to_string(ts)

        Txn.q(
          txn,
          """
          INSERT INTO assignment_revocations
            (id,assignmentId,revokedAt,revokedByUser,reason)
          VALUES (?1,?2,?3,'flynn',?4)
          """,
          [revocation_id, assignment_id, ts, reason]
        )

        Txn.q(
          txn,
          """
          INSERT INTO assignment_revocation_generations(revocationId,assignmentId,reopeningId)
          VALUES (?1,?2,(SELECT id FROM assignment_reopenings WHERE assignmentId=?2 ORDER BY id DESC LIMIT 1))
          """,
          [revocation_id, assignment_id]
        )

        Txn.q(
          txn,
          """
          UPDATE assignments SET state='closed',outcome='revoked',closedAt=?2,
            closedByUser='flynn',closedBySession=NULL,closingAttestId=NULL WHERE id=?1
          """,
          [assignment_id, ts]
        )

        if Txn.changes(txn) != 1, do: raise("fixture assignment missing")
        :ok
      end)

    :ok
  end
end
