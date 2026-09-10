defmodule Tightbeam.LiveBaseLock do
  @moduledoc false
  @on_load :load_native
  def load_native do
    path = :filename.join(:code.priv_dir(:tightbeam), ~c"live_base_lock")
    :erlang.load_nif(path, 0)
  end

  # Never expose these resource capabilities through configuration or the wire.
  # claim transfers the monitor, not the descriptor; no unlock occurs.
  def acquire(_absolute_private_path), do: :erlang.nif_error(:not_loaded)
  def assert_path(_resource, _absolute_private_path), do: :erlang.nif_error(:not_loaded)

  # Ordinary pinned SQLite owns its coordination artifacts. The connection is
  # read-only, checkpoint-on-close is explicitly disabled, and the native lock
  # duplicate remains attached until SQLite actually destroys the connection.
  def inspect_schema!(resource, path) do
    alias Exqlite.Sqlite3
    # Validate ownership before any database open, without transferring it.
    token =
      case attachment_token(resource) do
        {:ok, token} -> token
        {:error, reason} -> raise "schema inspection capability refused: #{inspect(reason)}"
      end

    for file <- [path, path <> "-wal", path <> "-shm", path <> "-journal"] do
      case File.lstat(file) do
        {:ok, %{type: :regular}} -> :ok
        {:error, :enoent} -> :ok
        other -> raise "schema inspection file refused: #{inspect(other)}"
      end
    end

    {:ok, conn} = Sqlite3.open(path, mode: :readonly)

    try do
      :ok = Sqlite3.enable_load_extension(conn, true)

      try do
        [[nil]] =
          Tightbeam.DB.run_query(
            conn,
            "SELECT load_extension(?1, 'sqlite3_livebaseinspection_init')",
            [Application.app_dir(:tightbeam, "priv/live_base_lock.so")]
          )
      after
        :ok = Sqlite3.enable_load_extension(conn, false)
      end

      [[1]] = Tightbeam.DB.run_query(conn, "SELECT tightbeam_attach_base_lock(?1)", [token])
      Tightbeam.DB.run_query(conn, "SELECT shape FROM schema_stamp", [])
    after
      :ok = Sqlite3.close(conn)
    end
  end

  def attachment_token(resource) do
    token = :crypto.strong_rand_bytes(32)
    with :ok <- prepare_attachment(resource, token), do: {:ok, token}
  end

  # Called by the DB owner while its acquired capability remains held.
  # Never release the original until SQLite owns a duplicate. A failed attach
  # closes SQLite first; successful close_v2 retains the duplicate while busy.
  def attach_sqlite!(resource, conn) do
    alias Exqlite.Sqlite3

    try do
      :ok = claim(resource)
      {:ok, token} = attachment_token(resource)
      :ok = Sqlite3.enable_load_extension(conn, true)

      try do
        [[nil]] =
          Tightbeam.DB.run_query(
            conn,
            "SELECT load_extension(?1, 'sqlite3_livebaselock_init')",
            [Application.app_dir(:tightbeam, "priv/live_base_lock.so")]
          )
      after
        :ok = Sqlite3.enable_load_extension(conn, false)
      end

      [[1]] = Tightbeam.DB.run_query(conn, "SELECT tightbeam_attach_base_lock(?1)", [token])
      :ok
    rescue
      error ->
        # Do not release the capability on a close error: retain fail-closed
        # ownership until process/resource teardown can complete it.
        :ok = Sqlite3.close(conn)
        :ok = release(resource)
        reraise error, __STACKTRACE__
    end
  end

  def prepare_attachment(_resource, _token), do: :erlang.nif_error(:not_loaded)
  def claim(_resource), do: :erlang.nif_error(:not_loaded)
  def release(_resource), do: :erlang.nif_error(:not_loaded)
end
