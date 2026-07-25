defmodule Tightbeam.Harness.Support do
  @moduledoc false

  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]

  def ssh_opts, do: @ssh_opts

  def local?(target), do: target.host_config.ssh == nil

  def system_cmd([command | args]), do: System.cmd(command, args, stderr_to_stdout: true)

  def run!(target, command) do
    case target.sh.(command) do
      {_output, 0} -> :ok
      {_output, exit} -> raise "command failed with exit #{exit}: #{Enum.join(command, " ")}"
    end
  end

  def shell_quote(script), do: "'" <> String.replace(script, "'", "'\\''") <> "'"

  def bounded_probe(binary, target) do
    run = Map.get(target, :run, &system_cmd/1)
    timeout = Map.get(target, :timeout, 2_000)

    with bin when is_binary(bin) <- binary,
         {:ok, {output, 0}} <- bounded_run(run, [bin, "--version"], timeout) do
      {:ok, %{bin: bin, version: String.trim(output)}}
    else
      nil ->
        {:error, :not_found}

      {:ok, {output, status}} ->
        {:error,
         {:exec_failed, "exit=#{status} output=#{inspect(String.trim(to_string(output)))}"}}

      {:error, detail} ->
        {:error, {:exec_failed, detail}}
    end
  end

  defp bounded_run(run, command, timeout) do
    task =
      Task.async(fn ->
        try do
          {:ok, run.(command)}
        rescue
          error -> {:error, Exception.message(error)}
        catch
          kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "runner exited: #{inspect(reason)}"}
      nil -> {:error, "timed out after #{timeout}ms"}
    end
  end
end
