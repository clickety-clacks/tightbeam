defmodule Tightbeam.HistoricalSchemaFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias Tightbeam.DB

  def load!(db, name, sha256) do
    sql =
      Path.join([__DIR__, "..", "fixtures", name <> ".sql.gz.b64"])
      |> File.read!()
      |> String.trim()
      |> Base.decode64!()
      |> :zlib.gunzip()

    assert Base.encode16(:crypto.hash(:sha256, sql), case: :lower) == sha256
    # The DB owner creates this empty retry table before schema activation.
    assert :ok = DB.execute(db, "DROP TABLE pending_recognition")
    assert :ok = DB.execute(db, sql)
    assert :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end
end
