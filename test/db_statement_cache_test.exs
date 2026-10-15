defmodule Tightbeam.DBStatementCacheTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Tightbeam.DB

  setup do
    {:ok, conn} = Sqlite3.open(":memory:")
    :ok = DB.enable_statement_cache(conn)

    on_exit(fn ->
      :ok = DB.clear_statement_cache(conn)
      :ok = Sqlite3.close(conn)
    end)

    %{conn: conn}
  end

  test "a cached statement binds new values after each result", %{conn: conn} do
    assert [[1]] = DB.run_query(conn, "SELECT ?1", [1])
    assert [[2]] = DB.run_query(conn, "SELECT ?1", [2])
    assert DB.statement_cache_size(conn) == 1
  end

  test "statements beyond the per-connection bound run uncached", %{conn: conn} do
    for value <- 1..100 do
      assert [[expected]] = DB.run_query(conn, "SELECT #{value} + ?1", [1])
      assert expected == value + 1
    end

    assert DB.statement_cache_size(conn) == 64
    assert [[2]] = DB.run_query(conn, "SELECT 1 + ?1", [1])
    assert DB.statement_cache_size(conn) == 64
  end
end
