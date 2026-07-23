defmodule Tightbeam.RailScript do
  @moduledoc "Contained, synchronous executor for dispatch-tier rail checks."

  alias Tightbeam.{Containment, EventLog, Org, Placement}

  @type result ::
          {:ok, token :: String.t(), exit_class :: String.t()}
          | {:error, reason :: String.t(), exit_class :: String.t()}

  @spec run(GenServer.server(), String.t(), map(), map(), map() | nil) :: result()
  def run(db, base_dir, rule, call, assignment) do
    scratch = Path.join([base_dir, "rails", "scratch", Tightbeam.Id.uuid4()])
    started = System.monotonic_time(:millisecond)

    try do
      {result, context} =
        try do
          File.mkdir_p!(scratch)
          File.chmod!(scratch, 0o700)
          execute(db, base_dir, scratch, rule, call, assignment)
        rescue
          _ -> {{:error, "script_error", "error:1"}, empty_context()}
        catch
          _, _ -> {{:error, "script_error", "error:1"}, empty_context()}
        end

      record(db, rule, call, context, result, System.monotonic_time(:millisecond) - started)
      result
    after
      File.rm_rf!(scratch)
    end
  end

  defp execute(db, base_dir, scratch, rule, call, assignment) do
    case invocation_context(db, base_dir, assignment) do
      {:ok, context, cwd} ->
        input = invocation_input(call, context)
        profile = Containment.profile([scratch])
        script = Path.join([base_dir, "identity", "rails", "scripts", rule.check.script])
        wrapper = Path.join([base_dir, "bin", "tightbeam"])

        {run_wrapper(
           wrapper,
           profile,
           rule.check.timeout_ms,
           script,
           cwd,
           scratch,
           rule,
           input
         ), context}

      {:error, context} ->
        {{:error, "script_error", "error:1"}, context}
    end
  end

  defp invocation_context(_db, _base_dir, nil) do
    context = empty_context()
    {:ok, context, nil}
  end

  defp invocation_context(db, base_dir, assignment) do
    case Org.get(db, assignment.holder_key) do
      nil ->
        {:error, empty_context()}

      holder ->
        config = %{
          base_dir: base_dir,
          port: Application.get_env(:tightbeam, :port, 0)
        }

        workdir = Placement.workdir_path(config, holder)

        context = %{
          holder_key: holder.session_key,
          holder_workdir: workdir,
          host: holder.host,
          holder_harness: holder.harness,
          holder_archetype: holder.archetype
        }

        if holder.host != Placement.local_host_name() do
          {:error, context}
        else
          ensure_local_holder_workdir(config, holder, context)
        end
    end
  end

  defp ensure_local_holder_workdir(config, holder, context) do
    try do
      workdir = Placement.holder_workdir(config, holder)
      {:ok, %{context | holder_workdir: workdir}, workdir}
    rescue
      _ -> {:error, context}
    catch
      _, _ -> {:error, context}
    end
  end

  defp empty_context do
    %{
      holder_key: nil,
      holder_workdir: nil,
      host: nil,
      holder_harness: nil,
      holder_archetype: nil
    }
  end

  defp invocation_input(call, context) do
    JSON.encode!(%{
      verb: Map.fetch!(call, :verb),
      origin: Map.fetch!(call, :origin),
      principal: serialize_principal(Map.get(call, :principal)),
      session_key: Map.get(call, :session_key),
      params: Map.fetch!(call, :params),
      context: context
    })
  end

  defp serialize_principal(nil), do: nil

  defp serialize_principal({:remedy, %{statute: statute, action: action}}),
    do: "remedy:#{action}:#{statute}"

  defp serialize_principal({kind, value}), do: "#{kind}:#{value}"

  defp run_wrapper(wrapper, profile, timeout_ms, script, cwd, scratch, rule, input) do
    stderr_path = Path.join(scratch, "rail-exec.stderr")
    cwd = cwd || scratch
    path = System.get_env("PATH") || "/usr/bin:/bin"

    args = [
      "-i",
      "PATH=#{path}",
      "HOME=#{scratch}",
      "TIGHTBEAM_RAIL=#{rule.name}",
      "/bin/sh",
      "-c",
      ~s(stderr_path=$1; shift; exec "$@" 2>"$stderr_path"),
      "tightbeam-rail",
      stderr_path,
      wrapper,
      "rail-exec",
      "--profile",
      profile,
      "--timeout-ms",
      Integer.to_string(timeout_ms),
      "--",
      script
    ]

    port =
      Port.open({:spawn_executable, "/usr/bin/env"}, [
        :binary,
        :exit_status,
        :hide,
        {:args, args},
        {:cd, cwd}
      ])

    true = Port.command(port, input <> "\n")
    deadline = System.monotonic_time(:millisecond) + timeout_ms + 2_000
    {stdout, status} = await(port, [], deadline)

    stderr =
      case File.read(stderr_path) do
        {:ok, bytes} -> bytes
        _ -> ""
      end

    classify(status, stdout, stderr, rule.check.returns)
  end

  defp await(port, output, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, bytes}} ->
        await(port, [bytes | output], deadline)

      {^port, {:exit_status, status}} ->
        {output |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      remaining_ms ->
        Port.close(port)
        {output |> Enum.reverse() |> IO.iodata_to_binary(), 20}
    end
  end

  defp classify(0, stdout, _stderr, returns) do
    token = String.trim(stdout)

    if token in returns,
      do: {:ok, token, "returned"},
      else: {:error, "script_out_of_set", "out-of-set"}
  end

  defp classify(10, _stdout, stderr, _returns) do
    code =
      case Regex.run(~r/tightbeam rail-exec child exit: (\d+)/, stderr) do
        [_, code] -> code
        _ -> "1"
      end

    {:error, "script_error", "error:#{code}"}
  end

  defp classify(20, _stdout, _stderr, _returns), do: {:error, "script_timeout", "timeout"}

  defp classify(30, _stdout, _stderr, _returns),
    do: {:error, "script_contained_refused", "contained"}

  defp classify(status, _stdout, _stderr, _returns),
    do: {:error, "script_error", "error:#{status}"}

  defp record(db, rule, call, context, result, duration_ms) do
    detail =
      case result do
        {:ok, token, exit_class} ->
          detail(call, context, exit_class, duration_ms) |> Map.put(:return, token)

        {:error, reason, exit_class} ->
          detail(call, context, exit_class, duration_ms) |> Map.put(:reason, reason)
      end

    try do
      EventLog.lifecycle(db, "rail_script", rule.name, JSON.encode!(detail))
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp detail(call, _context, exit_class, duration_ms) do
    %{
      edge: edge(call),
      ref: gated_ref(call),
      verb: Map.fetch!(call, :verb),
      exit_class: exit_class,
      duration_ms: duration_ms,
      origin: Map.fetch!(call, :origin)
    }
  end

  defp edge(call), do: if(Map.get(call, :edge, :verb) == :turn_end, do: "turn-end", else: "verb")

  defp gated_ref(call) do
    params = Map.fetch!(call, :params)

    params[:assignment_id] || params[:work_item_id] || params["assignment_id"] ||
      params["work_item_id"]
  end
end
