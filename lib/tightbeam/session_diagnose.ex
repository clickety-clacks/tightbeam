defmodule Tightbeam.SessionDiagnose do
  @moduledoc false
  import Plug.Conn

  @max_body 1024
  @max_response 4096
  @lane_timeout 200

  # Scope is an explicit operator configuration, not a guessed session owner.
  # No DB, lane creation, adapter call or domain mutation belongs on this path.
  def scope(encoded) when is_binary(encoded) and byte_size(encoded) <= 8192 do
    case JSON.decode(encoded) do
      {:ok, entries} when is_map(entries) and map_size(entries) <= 8 ->
        if Enum.all?(entries, fn {key, owner} ->
             is_binary(key) and byte_size(key) in 1..512 and
               is_binary(owner) and byte_size(owner) in 1..128
           end), do: entries, else: raise(ArgumentError, "invalid diagnostic scope")

      _ ->
        raise ArgumentError, "invalid diagnostic scope"
    end
  end

  def scope(_), do: raise(ArgumentError, "invalid diagnostic scope")

  def handle(conn, deps) do
    with :ok <- authenticate(conn, deps[:cli_token]),
         :ok <- compatible(conn),
         {:ok, bytes, conn} <-
           read_body(conn, length: @max_body, read_length: @max_body, read_timeout: 500),
         {:ok, body} <- JSON.decode(bytes),
         %{"sessionKey" => key, "asUser" => owner} <- body,
         true <- map_size(body) == 2 and is_binary(key) and is_binary(owner),
         true <- byte_size(key) in 1..512 and byte_size(owner) in 1..128,
         true <- Map.get(deps[:diagnostic_scope] || %{}, key) == owner do
      metadata_deps = Map.take(deps, [:db, :lane_registry])

      case bounded_snapshot(fn -> snapshot(key, metadata_deps) end) do
        {:ok, value} -> reply(conn, 200, %{result: value})
        :timeout -> reply(conn, 503, %{error: %{code: "diagnostic_snapshot_timeout"}})
        :unavailable -> reply(conn, 503, %{error: %{code: "diagnostic_unavailable"}})
      end
    else
      {:error, :incompatible_cli} -> reply(conn, 426, %{error: %{code: "incompatible_cli"}})
      {:error, :unauthorized} -> reply(conn, 401, %{error: %{code: "unauthorized"}})
      false -> reply(conn, 403, %{error: %{code: "diagnostic_scope_refused"}})
      _ -> reply(conn, 400, %{error: %{code: "invalid_diagnostic_request"}})
    end
  rescue
    _ -> reply(conn, 503, %{error: %{code: "diagnostic_unavailable"}})
  catch
    _, _ -> reply(conn, 503, %{error: %{code: "diagnostic_unavailable"}})
  end

  @doc false
  def bounded_snapshot(fun) when is_function(fun, 0) do
    parent = self()
    reply_alias = :erlang.alias()
    tag = make_ref()

    {guardian, monitor} =
      spawn_monitor(fn ->
        caller_monitor = Process.monitor(parent)
        guardian = self()

        {worker, worker_monitor} =
          spawn_monitor(fn ->
            result =
              try do
                {:ok, fun.()}
              rescue
                _ -> :unavailable
              catch
                _, _ -> :unavailable
              end

            send(guardian, {tag, result})
          end)

        # This deadline and caller monitor survive request-process termination.
        # Only our metadata helper is terminated, never an observed process.
        receive do
          {^tag, result} -> send(reply_alias, {tag, result})
          {:DOWN, ^worker_monitor, :process, ^worker, _} -> :ok
          {:DOWN, ^caller_monitor, :process, ^parent, _} -> Process.exit(worker, :kill)
        after
          500 -> Process.exit(worker, :kill)
        end
      end)

    try do
      receive do
        {^tag, result} -> result
        {:DOWN, ^monitor, :process, ^guardian, _} -> :unavailable
      after
        500 -> :timeout
      end
    after
      # Revocation drops future replies. A reply already delivered during the
      # timeout selection is removed only after revocation closes the race.
      :erlang.unalias(reply_alias)
      Process.demonitor(monitor, [:flush])

      receive do
        {^tag, _} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp compatible(conn) do
    version =
      case get_req_header(conn, "x-tightbeam-cli-version") do
        [value] -> value
        _ -> nil
      end

    case Tightbeam.CliCompatibility.check(version) do
      :ok -> :ok
      _ -> {:error, :incompatible_cli}
    end
  end

  defp authenticate(conn, expected) when is_binary(expected) and byte_size(expected) > 0 do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) == byte_size(expected) ->
        if Plug.Crypto.secure_compare(token, expected), do: :ok, else: {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp authenticate(_, _), do: {:error, :unauthorized}

  defp reply(conn, status, value) do
    bytes = JSON.encode!(value)

    {status, bytes} =
      if byte_size(bytes) <= @max_response,
        do: {status, bytes},
        else: {503, ~s({"error":{"code":"diagnostic_response_limit"}})}

    conn |> put_resp_content_type("application/json") |> send_resp(status, bytes)
  end

  def snapshot(key, deps) do
    registry = deps[:lane_registry] || Tightbeam.LaneRegistry

    lane =
      case Process.whereis(registry) do
        nil ->
          nil

        _ ->
          case Registry.lookup(registry, key) do
            [{pid, _}] -> pid
            _ -> nil
          end
      end

    recorded = lane_record(lane)

    %{
      schemaVersion: 1,
      sessionKey: key,
      sampledAtMs: System.system_time(:millisecond),
      db: process_metadata(deps[:db] || Tightbeam.DB),
      lane: %{process: process_metadata(lane), recorded: recorded},
      applicationDraining: Tightbeam.Application.draining?(),
      operationPhase: "unavailable_not_recorded",
      currentSql: "unavailable_not_recorded",
      dbCaller: "unavailable_not_recorded",
      ledgerCounts: "unavailable_without_db_query",
      reservationGate:
        Map.get(recorded, :reservationPresent, "unavailable_without_lane_snapshot"),
      parkGate: "unavailable_without_db_query",
      claimError: "unavailable_not_recorded",
      scanAttemptAt: "unavailable_not_recorded"
    }
  end

  defp lane_record(nil), do: %{status: "absent"}

  defp lane_record(pid) do
    case GenServer.call(pid, :diagnostic_snapshot, @lane_timeout) do
      %{
        currentSeq: seq,
        taskPresent: present,
        taskAlive: alive,
        reservationPresent: reserved,
        settlementRechecking: rechecking,
        deferredDrain: deferred
      }
      when (is_nil(seq) or is_integer(seq)) and is_boolean(present) and is_boolean(alive) and
             is_boolean(reserved) and is_boolean(rechecking) and is_boolean(deferred) ->
        %{
          status: "available",
          currentSeq: seq,
          taskPresent: present,
          taskAlive: alive,
          reservationPresent: reserved,
          settlementRechecking: rechecking,
          deferredDrain: deferred
        }

      _ ->
        %{status: "unavailable"}
    end
  catch
    :exit, _ -> %{status: "unavailable_busy_or_exited"}
  end

  def process_metadata(name) when is_atom(name) and not is_nil(name),
    do: process_metadata(Process.whereis(name))

  def process_metadata(pid) when is_pid(pid) do
    case Process.info(pid, [:status, :current_function, :message_queue_len]) do
      nil ->
        %{exists: false}

      info ->
        {module, function, arity} = info[:current_function]

        %{
          exists: true,
          status: Atom.to_string(info[:status]),
          queueLength: info[:message_queue_len],
          currentFunction: %{
            module: Atom.to_string(module),
            function: Atom.to_string(function),
            arity: arity
          }
        }
    end
  end

  def process_metadata(_), do: %{exists: false}
end
