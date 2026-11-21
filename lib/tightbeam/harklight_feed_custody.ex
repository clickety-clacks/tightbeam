defmodule Tightbeam.HarklightFeedCustody do
  @moduledoc false

  # Keep an observed failure outside the feed manager until its SQLite
  # projection commits. If the filesystem also refuses the record, the
  # runtime copy still fences a replacement manager in this gateway.
  def remember(directory, handle, evidence) do
    key = {__MODULE__, directory, handle}
    :persistent_term.put(key, evidence)

    case write(directory, handle, evidence) do
      :ok -> :persistent_term.erase(key)
      {:error, _} -> :ok
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
      {:failure, status, observed_at} when is_integer(observed_at) ->
        {:ok, {status, observed_at}}

      _ ->
        {:error, :invalid_feed_custody}
    end
  rescue
    ArgumentError -> {:error, :invalid_feed_custody}
  end

  defp write(directory, handle, {status, observed_at}) do
    target = path(directory, handle)
    temporary = target <> ".tmp"
    bytes = :erlang.term_to_binary({:failure, status, observed_at})

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
