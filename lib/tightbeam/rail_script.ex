defmodule Tightbeam.RailScript do
  @moduledoc "Contained, synchronous executor for dispatch-tier rail checks."

  alias Tightbeam.{Containment, EventLog, Org, Placement}

  # The exit class for a deny reached WITHOUT the observation that names it.
  #
  # Every other class asserts something someone saw: `returned` and `out-of-set` read
  # the wrapper's stdout, `error:<N>` carries the child's own code parsed off wrapper
  # stderr, `timeout` means the wrapper's timer elapsed and it killpg'd the process
  # group, `contained` means the sandbox refused to apply. When none of those happened —
  # the port never reported, the child's code was never seen, no script was spawned at
  # all, or the substrate itself raised or exited — filling in the value the observation
  # would have carried produces an `error:1` indistinguishable from a script that really
  # exited 1. That is what made I3's "every failure names itself" unenforceable rather
  # than merely unenforced: nothing downstream could tell the two apart. The wrapper
  # cannot produce this string, so its presence is proof no verdict was observed and its
  # absence is proof one was.
  #
  # `reason` is deliberately unchanged at every site: fail-closed semantics and the
  # reason-reading consumers stay exactly as they were. Only the class splits.
  @unreported "unreported"

  @type result ::
          {:ok, token :: String.t(), exit_class :: String.t()}
          | {:error, reason :: String.t(), exit_class :: String.t()}

  @spec run(GenServer.server(), String.t(), map(), map(), map() | nil) :: result()
  def run(db, base_dir, rule, call, assignment) do
    scratch = Path.join([base_dir, "rails", "scratch", Tightbeam.Id.uuid4()])
    started = System.monotonic_time(:millisecond)

    try do
      {result, context, diagnostic} =
        try do
          File.mkdir_p!(scratch)
          File.chmod!(scratch, 0o700)
          execute(db, base_dir, scratch, rule, call, assignment)
        rescue
          _ -> {{:error, "script_error", @unreported}, empty_context(), nil}
        catch
          _, _ -> {{:error, "script_error", @unreported}, empty_context(), nil}
        end

      record(
        db,
        rule,
        call,
        context,
        result,
        System.monotonic_time(:millisecond) - started,
        diagnostic
      )

      result
    after
      File.rm_rf!(scratch)
    end
  end

  defp execute(db, base_dir, scratch, rule, call, assignment) do
    case invocation_context(db, base_dir, assignment) do
      {:ok, context, cwd} ->
        input = invocation_input(call, context)
        profile = Containment.rail_profile([scratch])
        script = Path.join([base_dir, "identity", "rails", "scripts", rule.check.script])
        wrapper = Path.join([base_dir, "bin", "tightbeam"])

        {result, diagnostic} =
          run_wrapper(
            wrapper,
            profile,
            rule.check.timeout_ms,
            script,
            cwd,
            scratch,
            rule,
            input
          )

        {result, context, diagnostic}

      {:error, context} ->
        # The holder is missing, is on another host, or its workdir would not open, so
        # no script ran at all. Same fabrication as the rescue above: recording
        # `error:1` here asserted a child exit for a child that was never spawned.
        {{:error, "script_error", @unreported}, context, nil}
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

    result = classify(status, stdout, stderr, rule.check.returns)
    {result, refusal_diagnostic(result, stderr)}
  end

  # The wrapper names WHY containment could not be applied — kernel below the Landlock
  # floor, no Landlock at all, a profile it cannot read — on its stderr. That stderr lives
  # in the scratch dir, and the scratch dir is deleted on the way out, so recording only
  # `contained` left a host that refuses EVERY rail with nothing for anyone to read. That
  # is the shape of the outage this seam came from. The adapter path already logs
  # `DENIED: <reason>`; this carries the same fact into the durable rail row.
  defp refusal_diagnostic({:error, _reason, "contained"}, stderr) do
    case String.trim(stderr) do
      "" -> "refused with no diagnostic on wrapper stderr"
      text -> String.slice(text, 0, 512)
    end
  end

  defp refusal_diagnostic(_result, _stderr), do: nil

  defp await(port, output, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, bytes}} ->
        await(port, [bytes | output], deadline)

      {^port, {:exit_status, status}} ->
        {output |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      remaining_ms ->
        # The wrapper outlived its own time-box plus the margin and never reported. It
        # was killed here, by the BEAM, having observed neither a killpg nor an exit —
        # so this is NOT wrapper exit 20, and returning 20 made the two indistinguish-
        # able in the record. `:unreported` carries the one fact that separates them.
        Port.close(port)
        {output |> Enum.reverse() |> IO.iodata_to_binary(), :unreported}
    end
  end

  defp classify(0, stdout, _stderr, returns) do
    token = String.trim(stdout)

    if token in returns,
      do: {:ok, token, "returned"},
      else: {:error, "script_out_of_set", "out-of-set"}
  end

  # Exit 10 promises the child's code on wrapper stderr. When it is not there the code
  # was never observed — the wrapper died before the child, or gave up on its own stdin,
  # or could not wait. `error:1` asserted a child exit nobody saw, and collided exactly
  # with a script that really did exit 1.
  defp classify(10, _stdout, stderr, _returns) do
    case Regex.run(~r/tightbeam rail-exec child exit: (\d+)/, stderr) do
      [_, code] -> {:error, "script_error", "error:#{code}"}
      _ -> {:error, "script_error", @unreported}
    end
  end

  defp classify(20, _stdout, _stderr, _returns), do: {:error, "script_timeout", "timeout"}

  defp classify(30, _stdout, _stderr, _returns),
    do: {:error, "script_contained_refused", "contained"}

  # The wrapper never rendered a verdict. The deny is still a timeout — the substrate's
  # own deadline is what elapsed — but the class refuses to claim the wrapper's exit 20.
  defp classify(:unreported, _stdout, _stderr, _returns),
    do: {:error, "script_timeout", @unreported}

  defp classify(status, _stdout, _stderr, _returns),
    do: {:error, "script_error", "error:#{status}"}

  defp record(db, rule, call, context, result, duration_ms, diagnostic) do
    detail =
      case result do
        {:ok, token, exit_class} ->
          detail(call, context, exit_class, duration_ms) |> Map.put(:return, token)

        {:error, reason, exit_class} ->
          detail(call, context, exit_class, duration_ms) |> Map.put(:reason, reason)
      end
      |> put_containment(diagnostic)

    try do
      EventLog.lifecycle(db, "rail_script", rule.name, JSON.encode!(detail))
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp put_containment(detail, nil), do: detail
  defp put_containment(detail, diagnostic), do: Map.put(detail, :containment, diagnostic)

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
