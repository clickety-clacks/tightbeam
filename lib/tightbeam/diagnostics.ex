defmodule Tightbeam.Diagnostics do
  @moduledoc """
  Bounded, DB-independent storage for privacy-safe gateway diagnostics.

  Producers format and submit; one writer drains. Submission is non-blocking and
  returns only `:accepted` or `:dropped`, so an observed operation is never
  delayed by the sink.

  The health counters live in an `:atomics` array published once under a fixed
  `:persistent_term` key rather than in the writer's state. `/version` must stay
  answerable exactly when the writer is backlogged, and a `GenServer.call` would
  queue behind the backlog it is reporting on.
  """

  use GenServer

  @segment_bytes 16 * 1024 * 1024
  @segment_records 4_096
  @segments 4
  @memory_records @segment_records * @segments

  # The ingress holds formatted records, so a producer formats before it submits
  # and an unrepresentable record never occupies capacity.
  @ingress_records 8_192
  @max_record_bytes 4_096
  @max_text_bytes 256
  @text_fields [:operation, :cause, :principal_ref]

  @health_key {__MODULE__, :health}
  @health_slots 5
  @write_failures 1
  @last_failure_at 2
  @dropped_records 3
  @last_drop_at 4
  @ingress_depth 5

  @allowed_fields ~w(schema_version observed_at_ms event actor request_id db_call_id
    operation effect_kind principal_kind principal_ref queue_ms execute_ms callback_ms
    callback_sql_ms callback_outside_sql_ms total_ms elapsed_ms timeout_source budget_ms
    sqlite_timeout_source sqlite_busy_budget_ms result_class cause response_state http_status
    gateway_accepted effect_state action)a

  @empty_health %{
    write_failures: 0,
    last_failure_at: nil,
    dropped_records: 0,
    last_drop_at: nil
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def emit(record, server \\ __MODULE__) when is_map(record) do
    case GenServer.whereis(server) do
      nil -> :dropped
      _pid -> submit(sanitize(record), server)
    end
  end

  @doc """
  Gateway-owned sink health, read without touching the writer.

  Zeros when no sink has ever started: absent counters never claim that an
  absent record proves no event occurred.
  """
  def health do
    case :persistent_term.get(@health_key, nil) do
      nil ->
        @empty_health

      ref ->
        %{
          write_failures: :atomics.get(ref, @write_failures),
          last_failure_at: presence(:atomics.get(ref, @last_failure_at)),
          dropped_records: :atomics.get(ref, @dropped_records),
          last_drop_at: presence(:atomics.get(ref, @last_drop_at))
        }
    end
  end

  @doc false
  def records(server \\ __MODULE__), do: GenServer.call(server, :records)

  def classify_db_timeout(records, db_call_id) do
    abandoned =
      Enum.find(records, &(&1.event == "db_call_abandoned" and &1.db_call_id == db_call_id))

    completed =
      Enum.find(records, &(&1.event == "db_server_completed" and &1.db_call_id == db_call_id))

    case {abandoned, completed} do
      {nil, _} ->
        nil

      {%{budget_ms: budget}, %{queue_ms: queue}} when queue >= budget ->
        "db_mailbox_queue_overrun"

      {%{budget_ms: budget}, %{queue_ms: queue, total_ms: total}}
      when queue < budget and total >= budget ->
        "db_execute_overrun"

      {_abandoned, _completed_or_absent} ->
        "db_caller_timeout"
    end
  end

  # Ruled degraded startup, not boot refusal (att_4b05b3cb). `init/1` touches no
  # filesystem: the sink is the first child of a `rest_for_one` supervisor, so a
  # directory it cannot create would otherwise stop the DB, the wake scheduler,
  # and the listener. Nothing here may raise into `Supervisor.start_link/2`.
  # Directory, mode, and active-segment work moved to `prepare/1`, which runs on
  # the already-caught write path and reports a failure as the write failure it
  # is.
  @impl true
  def init(opts) do
    {:ok,
     %{
       path: Keyword.get(opts, :path),
       health: publish_health(),
       notify: Keyword.get(opts, :notify),
       records: :queue.new(),
       record_count: 0,
       # Unmeasured, not measured-as-empty. `prepare/1` fills these from the
       # file before the first append can consult them, so the R6 bounds still
       # see the occupancy a previous writer left behind.
       prepared: false,
       complete_tail: true,
       bytes: 0,
       count: 0
     }}
  end

  @impl true
  def handle_cast({:emit, record, line, bytes}, state) do
    if state.health, do: :atomics.sub(state.health, @ingress_depth, 1)
    if state.notify, do: send(state.notify, {:diagnostic, record})

    state =
      if state.path do
        with {:ok, prepared} <- prepare(state),
             {:ok, rotated} <- rotate_if_needed(prepared, bytes) do
          append(rotated, line, bytes)
        else
          # `prepare/1` and `rotate_if_needed/2` have already recorded the
          # failure against the state they return, so this only carries it.
          {:error, unwritten} -> unwritten
        end
      else
        state
      end

    {:noreply, bounded_enqueue(state, record)}
  end

  @impl true
  def handle_call(:records, _from, state), do: {:reply, :queue.to_list(state.records), state}

  defp submit(record, server) do
    json = JSON.encode!(record)
    ref = :persistent_term.get(@health_key, nil)

    cond do
      byte_size(json) > @max_record_bytes ->
        drop(ref)

      is_nil(ref) ->
        accept(server, record, json, nil)

      :atomics.add_get(ref, @ingress_depth, 1) > @ingress_records ->
        :atomics.sub(ref, @ingress_depth, 1)
        drop(ref)

      true ->
        accept(server, record, json, ref)
    end
  end

  defp accept(server, record, json, _ref) do
    line = [json, ?\n]
    GenServer.cast(server, {:emit, record, line, IO.iodata_length(line)})
    :accepted
  end

  defp drop(nil), do: :dropped

  defp drop(ref) do
    :atomics.add(ref, @dropped_records, 1)
    :atomics.put(ref, @last_drop_at, System.system_time(:millisecond))
    :dropped
  end

  # R6: the fallback carries neither the rejected record nor the raw error, and
  # the observed domain result does not change.
  defp record_write_failure(state) do
    IO.puts(
      :stderr,
      JSON.encode!(%{
        schema_version: "db-gateway-v1",
        event: "diagnostic_sink_unavailable",
        actor: "process:tightbeam",
        observed_at_ms: System.system_time(:millisecond)
      })
    )

    if state.health do
      :atomics.add(state.health, @write_failures, 1)
      :atomics.put(state.health, @last_failure_at, System.system_time(:millisecond))
    end

    state
  end

  # The ref is published once per VM so a producer's read stays a plain lookup.
  # A starting sink zeroes the slots: the counts are in-memory and belong to the
  # sink now running, not to a dead one.
  defp publish_health do
    ref =
      case :persistent_term.get(@health_key, nil) do
        nil ->
          fresh = :atomics.new(@health_slots, signed: true)
          :persistent_term.put(@health_key, fresh)
          fresh

        existing ->
          existing
      end

    Enum.each(1..@health_slots, &:atomics.put(ref, &1, 0))
    ref
  end

  defp presence(0), do: nil
  defp presence(value), do: value

  defp sanitize(record) do
    record
    |> Map.take(@allowed_fields)
    |> Map.put(:schema_version, "db-gateway-v1")
    |> Map.put_new(:actor, "process:tightbeam")
    |> Map.put_new(:observed_at_ms, System.system_time(:millisecond))
    |> clamp_text()
  end

  # Only these fields carry free text; the rest are bounded IDs, enums, and
  # integers. Clamping them keeps every record inside the 4,096-byte bound.
  defp clamp_text(record) do
    Enum.reduce(@text_fields, record, fn field, acc ->
      case Map.get(acc, field) do
        value when is_binary(value) and byte_size(value) > @max_text_bytes ->
          Map.put(acc, field, valid_prefix(binary_part(value, 0, @max_text_bytes)))

        _other ->
          acc
      end
    end)
  end

  # Truncating on a byte boundary can split a codepoint, and invalid UTF-8 would
  # fail encoding instead of shortening a field.
  defp valid_prefix(binary) do
    if String.valid?(binary),
      do: binary,
      else: valid_prefix(binary_part(binary, 0, byte_size(binary) - 1))
  end

  # Nothing on this path may raise. The sink is the first child of a
  # `rest_for_one` supervisor, so an exception here stops the DB and every
  # later child: a full disk would become a gateway restart. R6 gives the
  # answer for a sink that cannot write, and it is one stderr line plus a
  # counter with the observed domain result unchanged, so a rotation that
  # cannot complete is reported as the write failure it is.
  defp rotate_if_needed(%{count: count, bytes: bytes, complete_tail: complete} = state, incoming)
       when not complete or count >= @segment_records or bytes + incoming > @segment_bytes do
    with :ok <- shift_segments(state.path),
         :ok <- create_active(state.path) do
      {:ok, %{state | bytes: 0, count: 0, complete_tail: true}}
    else
      # The counters are deliberately left alone. They describe the active
      # file, which was not rotated, and zeroing them here would let the
      # writer append past both bounds while reporting that it had not.
      {:error, _reason} -> {:error, record_write_failure(state)}
    end
  end

  defp rotate_if_needed(state, _incoming), do: {:ok, state}

  # A discarded rename result is a silent retention violation: the shift looks
  # done, the counters reset, and the writer keeps appending to a segment it
  # believes is empty.
  defp shift_segments(path) do
    Enum.reduce_while((@segments - 1)..1//-1, :ok, fn index, :ok ->
      source = if index == 1, do: path, else: path <> ".#{index - 1}"
      destination = path <> ".#{index}"

      cond do
        not File.exists?(source) -> {:cont, :ok}
        File.rename(source, destination) == :ok -> {:cont, :ok}
        true -> {:halt, {:error, :rename_failed}}
      end
    end)
  end

  defp append(state, line, bytes) do
    case File.write(state.path, line, [:append, :binary]) do
      :ok -> %{state | bytes: state.bytes + bytes, count: state.count + 1}
      # A failed append may have written a prefix. Re-measure before another
      # append so an accepted JSON record never becomes part of a torn line.
      {:error, _reason} -> record_write_failure(%{state | prepared: false})
    end
  end

  defp bounded_enqueue(%{record_count: @memory_records} = state, record) do
    {{:value, _oldest}, records} = :queue.out(state.records)
    %{state | records: :queue.in(record, records)}
  end

  defp bounded_enqueue(state, record) do
    %{state | records: :queue.in(record, state.records), record_count: state.record_count + 1}
  end

  # One spelling of the setup, on the path where raising is never the answer.
  # The earlier `ensure_file/1` bang spelling reserved the boot-refusal question
  # to the spec owner; att_4b05b3cb ruled degraded startup, so the bang is gone
  # rather than moved.
  #
  # Preparation is attempted per record until it succeeds. A sink whose
  # directory appears later therefore starts writing without a restart, and one
  # whose directory never appears reports each rejected record exactly as a
  # failed append does.
  defp prepare(%{prepared: true} = state), do: {:ok, state}

  defp prepare(%{path: path} = state) do
    directory = Path.dirname(path)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- create_active(path),
         # R6 bounds what the sink retains, not what one run of it appended. A
         # new writer inherits whatever the previous one left in the active
         # segment, so the counters start from the file's measured occupancy.
         # Starting them at zero over a preserved file lets a restart carry the
         # active segment past both bounds, and repeated restarts grow it
         # without limit.
         {:ok, {bytes, count, complete_tail}} <- occupancy(path) do
      {:ok, %{state | prepared: true, bytes: bytes, count: count, complete_tail: complete_tail}}
    else
      {:error, _reason} -> {:error, record_write_failure(state)}
    end
  end

  defp create_active(path) do
    with :ok <- if(File.exists?(path), do: :ok, else: File.write(path, "")) do
      File.chmod(path, 0o600)
    end
  end

  # Reading the file is a measurement, not an inference about its shape: every
  # record is appended with exactly one trailing newline, so newlines are
  # records. A torn trailing write remains in its segment, which is rotated
  # before the next append. Readers can skip that final incomplete line without
  # losing earlier records or swallowing the next accepted record (R6/B4).
  #
  # Every step returns its error instead of raising. This measurement moved out
  # of `init/1` onto the writer's own path, where `File.stream!` would have
  # turned an unreadable segment into a supervisor restart of the DB.
  defp occupancy(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, count, complete_tail} <- count_records(path, size) do
      {:ok, {size, count, complete_tail}}
    end
  end

  defp count_records(_path, 0), do: {:ok, 0, true}

  defp count_records(path, _size) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          newlines(io, 0, true)
        after
          File.close(io)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp newlines(io, acc, complete_tail) do
    case IO.binread(io, 65_536) do
      chunk when is_binary(chunk) and byte_size(chunk) > 0 ->
        newlines(io, acc + length(:binary.matches(chunk, "\n")), :binary.last(chunk) == ?\n)

      :eof ->
        {:ok, acc, complete_tail}

      {:error, _reason} = error ->
        error
    end
  end
end
