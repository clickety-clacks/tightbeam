defmodule Tightbeam.ArtifactCustody do
  @moduledoc false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  def ensure_schema(db) do
    DB.execute(db, """
    CREATE TABLE IF NOT EXISTS artifact_custody (
      artifactId TEXT PRIMARY KEY REFERENCES artifacts(artifactId),
      status TEXT NOT NULL CHECK (status IN ('pinned','unpinned'))
    );
    """)
  end

  def column(table) do
    "(SELECT status FROM artifact_custody WHERE artifact_custody.artifactId=#{table}.artifactId)"
  end

  def store(txn, id, status) do
    Txn.q(
      txn,
      "INSERT INTO artifact_custody(artifactId,status) VALUES (?1,?2) ON CONFLICT(artifactId) DO UPDATE SET status=excluded.status",
      [id, status]
    )

    :ok
  end
end
