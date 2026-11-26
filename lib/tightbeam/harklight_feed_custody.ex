defmodule Tightbeam.HarklightFeedCustody do
  @moduledoc false
  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  # A launch row left by an earlier feed is taken over. The child's lifetime
  # lock, not this row, keeps two children from running at once.
  def arm_launch(db, handle, owner) do
    case DB.query(
           db,
           """
           INSERT INTO harklight_feed_launches(handle,owner) VALUES(?1,?2)
           ON CONFLICT(handle) DO UPDATE SET owner=excluded.owner
           RETURNING handle
           """,
           [handle, owner]
         ) do
      {:ok, [[^handle]]} -> :ok
      _ -> {:error, :feed_launch_unavailable}
    end
  end

  def launch_owner(db, handle) do
    case DB.query(db, "SELECT owner FROM harklight_feed_launches WHERE handle=?1", [handle]) do
      {:ok, [[owner]]} -> {:ok, owner}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end

  def release_launch(db, handle, owner) do
    DB.query(db, "DELETE FROM harklight_feed_launches WHERE handle=?1 AND owner=?2", [
      handle,
      owner
    ])
  end

  def release_launch_in_txn(txn, handle) do
    Txn.q(txn, "DELETE FROM harklight_feed_launches WHERE handle=?1", [handle])
  end

  # Keep an observed failure outside the feed manager until its SQLite
  # projection commits. If the filesystem also refuses the record, the
  # runtime copy still fences a replacement manager in this gateway.
  def remember(directory, handle, evidence) do
    key = {__MODULE__, directory, handle}
    :persistent_term.put(key, evidence)
  end

  def retry_write(directory, handle) do
    key = {__MODULE__, directory, handle}

    with evidence when not is_nil(evidence) <- :persistent_term.get(key, nil),
         :ok <- write(directory, handle, evidence) do
      :persistent_term.erase(key)
    end

    :ok
  end

  def pending(directory, handle) do
    case :persistent_term.get({__MODULE__, directory, handle}, nil) do
      nil -> read(directory, handle)
      evidence -> {:ok, evidence}
    end
  end

  def forget(directory, handle) do
    case File.rm(path(directory, handle)) do
      result when result in [:ok, {:error, :enoent}] ->
        :persistent_term.erase({__MODULE__, directory, handle})
        :ok

      {:error, :enotdir} ->
        # There is no on-disk record at this path. The committed SQLite
        # projection now owns the failure.
        :persistent_term.erase({__MODULE__, directory, handle})
        :ok

      error ->
        error
    end
  end

  defp read(directory, handle) do
    case File.read(path(directory, handle)) do
      {:ok, bytes} -> decode(bytes)
      {:error, :enoent} -> :clear
      error -> error
    end
  end

  defp decode(bytes) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      {:failure, status, observed_at, ended?}
      when is_integer(observed_at) and is_boolean(ended?) ->
        {:ok, {status, observed_at, ended?}}

      _ ->
        {:error, :invalid_feed_custody}
    end
  rescue
    ArgumentError -> {:error, :invalid_feed_custody}
  end

  defp write(directory, handle, {status, observed_at, ended?}) do
    target = path(directory, handle)
    temporary = target <> ".tmp"
    bytes = :erlang.term_to_binary({:failure, status, observed_at, ended?})

    result =
      with :ok <- File.mkdir_p(directory),
           {:ok, :ok} <-
             File.open(temporary, [:write, :binary], fn file ->
               with :ok <- IO.binwrite(file, bytes), do: :file.sync(file)
             end) do
        File.rename(temporary, target)
      else
        {:ok, {:error, reason}} -> {:error, reason}
        error -> error
      end

    if result != :ok, do: File.rm(temporary)
    result
  end

  defp path(directory, handle) do
    id = :crypto.hash(:sha256, handle) |> Base.encode16(case: :lower)
    Path.join(directory, id <> ".intent")
  end
end
