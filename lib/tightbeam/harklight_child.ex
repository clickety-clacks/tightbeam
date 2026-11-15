defmodule Tightbeam.HarklightChild do
  @moduledoc false

  # open runs inside the manager's admission callback. Readiness means the
  # wrapper already owns its lifetime lock; no unregistered launch can pass a
  # moving marker or a subsequent restart barrier.
  def open(key, executable, args, opts) do
    {helper, lock} = paths(key, opts)

    options = [
      :binary,
      :exit_status,
      args: ["harklight-child", "--lock", lock, "--", executable | args]
    ]

    options =
      if Keyword.get(opts, :stderr_to_stdout, true),
        do: [:stderr_to_stdout | options],
        else: options

    port = Port.open({:spawn_executable, helper}, options)

    case ready(port, "") do
      {:ok, initial} ->
        {:ok, port, initial}

      error ->
        request_stop(port)
        if Port.info(port), do: Port.close(port)
        error
    end
  rescue
    error -> {:error, {:child_launch, Exception.message(error)}}
  end

  def command({manager, handle, executable}, args) do
    case GenServer.call(manager, {:launch_child, handle, executable, args}, :infinity) do
      {:ok, port, initial} -> collect(port, initial)
      {:error, reason} -> raise "Harklight child launch refused: #{inspect(reason)}"
    end
  end

  def collect(port, initial) do
    try do
      true = Port.command(port, "continue\n")
      collect_output(port, [initial])
    after
      request_stop(port)
      if Port.info(port), do: Port.close(port)
    end
  end

  def request_stop(port) do
    if Port.info(port), do: Port.command(port, "stop
")
    :ok
  rescue
    ArgumentError -> :ok
  end

  def await_stopped(key, opts) do
    {helper, lock} = paths(key, opts)

    case System.cmd(helper, ["harklight-child", "--lock", lock, "--wait"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> {:error, {:child_exit_unconfirmed, status}}
    end
  rescue
    error -> {:error, {:child_exit_unconfirmed, Exception.message(error)}}
  end

  defp paths(key, opts) do
    base = Keyword.get_lazy(opts, :base_dir, &Tightbeam.BaseDir.resolve/0)
    helper = Keyword.get(opts, :cli_path, Path.join([base, "bin", "tightbeam"]))
    id = :crypto.hash(:sha256, :erlang.term_to_binary(key)) |> Base.encode16(case: :lower)
    {helper, Path.join([base, "harklight-children", id <> ".lock"])}
  end

  defp ready(port, pending) do
    receive do
      {^port, {:data, bytes}} ->
        case :binary.split(pending <> bytes, "
") do
          ["TIGHTBEAM_CHILD_READY", rest] -> {:ok, rest}
          [_] -> ready(port, pending <> bytes)
          _ -> {:error, :child_readiness_invalid}
        end

      {^port, {:exit_status, status}} ->
        {:error, {:child_start_failed, status}}
    after
      30_000 -> {:error, :child_readiness_unknown}
    end
  end

  defp collect_output(port, chunks) do
    receive do
      {^port, {:data, bytes}} ->
        collect_output(port, [bytes | chunks])

      {^port, {:exit_status, status}} ->
        {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}

      {:EXIT, pid, reason} when is_pid(pid) ->
        exit(reason)
    end
  end
end
