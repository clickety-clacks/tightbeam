defmodule Tightbeam.CursorSigning do
  @moduledoc """
  Owns the server-held material used to authenticate opaque REST cursors.

  The canonical record stays on disk. A provider value names a provider-lifetime
  observer and contains no material. The observer serializes lifecycle changes
  across connected application nodes, reads one complete record for each HMAC,
  and fails closed after an indeterminate durability outcome.

  Canonical-path absence is an explicit unprovisioned bootstrap state. Normal
  startup never generates material. A local owner must provision it explicitly
  before the listener can be admitted.
  """

  import Bitwise

  @material_bytes 32
  @domain_separator <<"tightbeam/rest-read-plane-d1/cursor/v1", 0>>
  @record_name "rest-cursor-signing.v1"
  @record_mode 0o600
  @record_mode_mask 0o7777
  @directory_mode 0o700
  @read_attempts 8
  @indeterminate {:indeterminate_commit, :cursor_signing_authority_may_have_advanced}

  defmodule Error do
    @moduledoc false
    defexception reason: :unavailable, message: "cursor signing is unavailable"

    @type t :: %__MODULE__{reason: atom(), message: String.t()}
  end

  @enforce_keys [:record_path, :owner_uid, :observer]
  @derive {Inspect, only: []}
  defstruct [:record_path, :owner_uid, :observer]

  @opaque t :: %__MODULE__{
            record_path: String.t(),
            owner_uid: non_neg_integer(),
            observer: pid()
          }

  @typedoc "A lifecycle refusal that contains no path, material, or generation detail."
  @type lifecycle_refusal ::
          {:error,
           :cursor_signing_unprovisioned
           | :cursor_signing_mutation_in_progress
           | :cursor_signing_quarantined
           | :cursor_signing_recovery_refused}

  @doc """
  Explicitly provisions the first material generation.

  The operation is admitted only from the unprovisioned state. It reports
  success only after the material file and containing directory are durable.
  """
  @spec provision(String.t()) :: :ok | {:error, Error.t()} | lifecycle_refusal() | tuple()
  def provision(base_dir) do
    with {:ok, provider} <- load(base_dir) do
      observer_call(provider, {:mutate, :provision}, :provision_failed)
    end
  rescue
    _error -> error(:provision_failed)
  catch
    _kind, _reason -> error(:provision_failed)
  end

  @doc "Same as `provision/1`, but raises a redacted typed error on refusal."
  @spec provision!(String.t()) :: :ok
  def provision!(base_dir) do
    case provision(base_dir) do
      :ok -> :ok
      {:error, %Error{} = reason} -> raise reason
      {:error, reason} -> raise Error, reason: reason
      {:indeterminate_commit, reason} -> raise Error, reason: reason
    end
  end

  @doc """
  Classifies the canonical path and returns its provider without retaining bytes.

  An absent canonical path returns an unprovisioned provider. A present path is
  validated and its containing directory is synchronized before the provider
  enters healthy state. A present invalid or unsynchronizable record leaves the
  observer quarantined and returns a redacted typed error.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, Error.t()} | lifecycle_refusal()
  def load(base_dir) do
    with {:ok, provider} <- provider(base_dir),
         :ok <- observer_call(provider, :load_status, :unavailable) do
      {:ok, provider}
    end
  rescue
    _error -> error(:unavailable)
  catch
    _kind, _reason -> error(:unavailable)
  end

  @doc "Same as `load/1`, but raises a redacted typed error on refusal."
  @spec load!(String.t()) :: t()
  def load!(base_dir) do
    case load(base_dir) do
      {:ok, provider} -> provider
      {:error, %Error{} = reason} -> raise reason
      {:error, reason} -> raise Error, reason: reason
    end
  end

  @doc "Validates an injected provider and requires healthy lifecycle state."
  @spec validate(t()) :: :ok | {:error, Error.t()} | lifecycle_refusal()
  def validate(%__MODULE__{} = provider) do
    observer_call(
      provider,
      {:validate, provider.record_path, provider.owner_uid},
      :invalid_injection
    )
  end

  def validate(_provider), do: error(:invalid_injection)

  @doc "Same as `validate/1`, but raises a redacted typed error on refusal."
  @spec validate!(term()) :: t()
  def validate!(provider) do
    case validate(provider) do
      :ok -> provider
      {:error, %Error{} = reason} -> raise reason
      {:error, reason} -> raise Error, reason: reason
    end
  end

  @doc "Checks request admission atomically against the provider lifecycle."
  @spec admit_request(t()) :: :ok | {:error, Error.t()} | lifecycle_refusal()
  def admit_request(%__MODULE__{} = provider) do
    observer_call(provider, :admit_request, :operation_failed)
  end

  def admit_request(_provider), do: error(:invalid_injection)

  @doc "Computes one HMAC-SHA-256 value from one complete current record read."
  @spec sign(t(), iodata()) :: {:ok, <<_::256>>} | {:error, Error.t()} | lifecycle_refusal()
  def sign(%__MODULE__{} = provider, input) do
    with {:ok, input} <- iodata(input) do
      observer_call(provider, {:sign, input}, :operation_failed)
    end
  rescue
    _error -> error(:operation_failed)
  catch
    _kind, _reason -> error(:operation_failed)
  end

  def sign(_provider, _input), do: error(:invalid_injection)

  @doc "Checks one HMAC-SHA-256 value against one complete current record read."
  @spec verify(t(), iodata(), binary()) ::
          {:ok, boolean()} | {:error, Error.t()} | lifecycle_refusal()
  def verify(%__MODULE__{} = provider, input, signature) when is_binary(signature) do
    with {:ok, input} <- iodata(input) do
      observer_call(provider, {:verify, input, signature}, :operation_failed)
    end
  rescue
    _error -> error(:operation_failed)
  catch
    _kind, _reason -> error(:operation_failed)
  end

  def verify(%__MODULE__{}, _input, _signature), do: error(:invalid_signature)
  def verify(_provider, _input, _signature), do: error(:invalid_injection)

  @doc "Atomically replaces the active record with fresh material."
  @spec rotate(t()) :: :ok | {:error, Error.t()} | lifecycle_refusal() | tuple()
  def rotate(%__MODULE__{} = provider) do
    observer_call(provider, {:mutate, :rotate}, :rotation_failed)
  end

  def rotate(_provider), do: error(:invalid_injection)

  @doc """
  Recovers a quarantined provider from the sole canonical record.

  Recovery validates the complete record, synchronizes its directory once,
  proves that the validated record stayed canonical, and only then re-enables
  that exact generation.
  """
  @spec recover(t()) :: :ok | {:error, Error.t()} | lifecycle_refusal()
  def recover(%__MODULE__{} = provider) do
    observer_call(provider, {:mutate, :recover}, :operation_failed)
  end

  def recover(_provider), do: error(:invalid_injection)

  @doc false
  @spec lifecycle(t()) :: :healthy | :unprovisioned | :quarantined | :mutation_in_progress
  def lifecycle(%__MODULE__{} = provider) do
    observer_call(provider, :lifecycle, :operation_failed)
  end

  def lifecycle(_provider), do: error(:invalid_injection)

  defp provider(base_dir) do
    with {:ok, owner_uid} <- effective_uid(),
         {:ok, base_dir} <- base_directory(base_dir),
         record_path = Path.join([base_dir, "secrets", @record_name]),
         {:ok, observer} <- start_observer(record_path, owner_uid) do
      {:ok, %__MODULE__{record_path: record_path, owner_uid: owner_uid, observer: observer}}
    end
  end

  defp start_observer(record_path, owner_uid) do
    name = {:cursor_signing_observer, :crypto.hash(:sha256, record_path)}

    case GenServer.start(__MODULE__.Observer, {record_path, owner_uid}, name: {:global, name}) do
      {:ok, observer} -> {:ok, observer}
      {:error, {:already_started, observer}} when is_pid(observer) -> {:ok, observer}
      {:error, _reason} -> error(:unavailable)
    end
  end

  defp observer_call(%__MODULE__{observer: observer}, message, fallback)
       when is_pid(observer) do
    GenServer.call(observer, message, :infinity)
  catch
    :exit, _reason -> error(fallback)
  end

  defp iodata(input) do
    {:ok, IO.iodata_to_binary(input)}
  rescue
    _error -> error(:invalid_input)
  end

  defp base_directory(base_dir) when is_binary(base_dir) and byte_size(base_dir) > 0,
    do: {:ok, Path.expand(base_dir)}

  defp base_directory(_base_dir), do: error(:invalid_base_dir)

  defmodule Observer do
    @moduledoc false
    use GenServer

    alias Tightbeam.CursorSigning
    alias Tightbeam.CursorSigning.Error

    @impl true
    def init({record_path, owner_uid}) do
      Process.flag(:trap_exit, true)

      {:ok,
       %{
         record_path: record_path,
         owner_uid: owner_uid,
         lifecycle: :starting,
         startup_result: nil,
         mutation: nil
       }}
    end

    @impl true
    def handle_call(:load_status, _from, %{mutation: mutation} = state)
        when not is_nil(mutation) do
      {:reply, {:error, :cursor_signing_mutation_in_progress}, state}
    end

    def handle_call(:load_status, from, %{lifecycle: :starting} = state) do
      reference = make_ref()
      owner = elem(from, 0)
      owner_monitor = Process.monitor(owner)

      {worker, worker_monitor} =
        spawn_monitor(fn ->
          result = CursorSigning.initial_lifecycle(state.record_path, state.owner_uid)
          send(self_observer(), {:mutation_prepared, reference, result})
        end)

      mutation = %{
        reference: reference,
        operation: :startup,
        from: from,
        owner: owner,
        owner_monitor: owner_monitor,
        owner_alive: true,
        worker: worker,
        worker_monitor: worker_monitor,
        phase: :starting,
        prior_lifecycle: :starting,
        temporary: nil
      }

      send(worker, {:observer, self()})
      {:noreply, %{state | mutation: mutation}}
    end

    def handle_call(:load_status, _from, state) do
      result =
        case state.lifecycle do
          :healthy ->
            CursorSigning.validate_current(state.record_path, state.owner_uid)

          :unprovisioned ->
            :ok

          :quarantined ->
            state.startup_result || {:error, :cursor_signing_quarantined}
        end

      {:reply, result, state}
    end

    def handle_call({:validate, record_path, owner_uid}, _from, state) do
      result =
        if record_path == state.record_path and owner_uid == state.owner_uid do
          with :ok <- lifecycle_result(state) do
            CursorSigning.validate_current(record_path, owner_uid)
          end
        else
          CursorSigning.error(:invalid_injection)
        end

      {:reply, result, state}
    end

    def handle_call(:lifecycle, _from, %{mutation: mutation} = state)
        when not is_nil(mutation) do
      {:reply, :mutation_in_progress, state}
    end

    def handle_call(:lifecycle, _from, state), do: {:reply, state.lifecycle, state}

    def handle_call(:admit_request, _from, state) do
      {:reply, lifecycle_result(state), state}
    end

    def handle_call({:sign, input}, _from, state) do
      result =
        with :ok <- lifecycle_result(state),
             {:ok, material} <-
               CursorSigning.read_record(
                 state.record_path,
                 state.owner_uid,
                 CursorSigning.read_attempts()
               ) do
          {:ok, :crypto.mac(:hmac, :sha256, material, [CursorSigning.domain_separator(), input])}
        end

      {:reply, result, state}
    end

    def handle_call({:verify, input, signature}, _from, state) do
      result =
        with :ok <- lifecycle_result(state),
             {:ok, material} <-
               CursorSigning.read_record(
                 state.record_path,
                 state.owner_uid,
                 CursorSigning.read_attempts()
               ) do
          expected =
            :crypto.mac(:hmac, :sha256, material, [CursorSigning.domain_separator(), input])

          {:ok,
           byte_size(signature) == byte_size(expected) and
             Plug.Crypto.secure_compare(signature, expected)}
        end

      {:reply, result, state}
    end

    def handle_call({:mutate, _operation}, _from, %{mutation: mutation} = state)
        when not is_nil(mutation) do
      {:reply, {:error, :cursor_signing_mutation_in_progress}, state}
    end

    def handle_call({:mutate, operation}, from, state) do
      case mutation_allowed(operation, state.lifecycle) do
        :ok ->
          reference = make_ref()
          owner = elem(from, 0)
          owner_monitor = Process.monitor(owner)

          {worker, worker_monitor} =
            spawn_monitor(fn ->
              result =
                CursorSigning.prepare_mutation(
                  operation,
                  state.record_path,
                  state.owner_uid
                )

              send(self_observer(), {:mutation_prepared, reference, result})
            end)

          mutation = %{
            reference: reference,
            operation: operation,
            from: from,
            owner: owner,
            owner_monitor: owner_monitor,
            owner_alive: true,
            worker: worker,
            worker_monitor: worker_monitor,
            phase: if(operation == :recover, do: :recovering, else: :preparing),
            prior_lifecycle: state.lifecycle,
            temporary: nil
          }

          send(worker, {:observer, self()})
          {:noreply, %{state | mutation: mutation, startup_result: nil}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end

    @impl true
    def handle_info({:mutation_prepared, reference, result}, state) do
      case state.mutation do
        %{reference: ^reference, phase: :starting} = mutation ->
          state = finish_worker(state, mutation)
          finish_startup(result, state)

        %{reference: ^reference, phase: :recovering} = mutation ->
          state = finish_worker(state, mutation)
          finish_recovery(result, state)

        %{reference: ^reference, phase: :preparing} = mutation ->
          state = finish_worker(state, mutation)
          finish_preparation(result, state)

        _other ->
          {:noreply, state}
      end
    end

    def handle_info({:directory_synced, reference, result}, state) do
      case state.mutation do
        %{reference: ^reference, phase: :published_unsynchronized} = mutation ->
          state = finish_worker(state, mutation)
          finish_published_sync(result, state)

        _other ->
          {:noreply, state}
      end
    end

    def handle_info({:finish_mutation, reference, reply}, state) do
      case state.mutation do
        %{reference: ^reference, phase: :terminal} = mutation ->
          if mutation.owner_alive, do: GenServer.reply(mutation.from, reply)
          {:noreply, clear_mutation(state)}

        _other ->
          {:noreply, state}
      end
    end

    def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
      cond do
        state.mutation && state.mutation.owner_monitor == monitor ->
          owner_died(state)

        state.mutation && state.mutation.worker_monitor == monitor ->
          worker_died(state)

        true ->
          {:noreply, state}
      end
    end

    def handle_info(_message, state), do: {:noreply, state}

    defp self_observer do
      receive do
        {:observer, observer} -> observer
      end
    end

    defp mutation_allowed(:provision, :unprovisioned), do: :ok
    defp mutation_allowed(:provision, :healthy), do: CursorSigning.error(:already_provisioned)
    defp mutation_allowed(:provision, :quarantined), do: {:error, :cursor_signing_quarantined}
    defp mutation_allowed(:rotate, :healthy), do: :ok
    defp mutation_allowed(:rotate, :unprovisioned), do: {:error, :cursor_signing_unprovisioned}
    defp mutation_allowed(:rotate, :quarantined), do: {:error, :cursor_signing_quarantined}
    defp mutation_allowed(:recover, :quarantined), do: :ok
    defp mutation_allowed(:recover, :unprovisioned), do: {:error, :cursor_signing_unprovisioned}
    defp mutation_allowed(:recover, :healthy), do: {:error, :cursor_signing_recovery_refused}

    defp lifecycle_result(%{mutation: mutation}) when not is_nil(mutation),
      do: {:error, :cursor_signing_mutation_in_progress}

    defp lifecycle_result(%{lifecycle: :healthy}), do: :ok

    defp lifecycle_result(%{lifecycle: :unprovisioned}),
      do: {:error, :cursor_signing_unprovisioned}

    defp lifecycle_result(%{lifecycle: :quarantined}), do: {:error, :cursor_signing_quarantined}

    defp finish_preparation({:ok, temporary}, %{mutation: mutation} = state) do
      if mutation.owner_alive do
        case CursorSigning.publish(mutation.operation, temporary, state.record_path) do
          :ok ->
            {worker, worker_monitor} =
              spawn_monitor(fn ->
                result = CursorSigning.sync_parent_once(state.record_path)
                send(self_observer(), {:directory_synced, mutation.reference, result})
              end)

            send(worker, {:observer, self()})

            mutation = %{
              mutation
              | temporary: nil,
                worker: worker,
                worker_monitor: worker_monitor,
                phase: :published_unsynchronized
            }

            {:noreply, %{state | mutation: mutation}}

          {:error, %Error{} = reason} ->
            CursorSigning.remove_temporary(temporary)
            reply_and_restore(state, {:error, reason})
        end
      else
        CursorSigning.remove_temporary(temporary)
        {:noreply, restore_prior(state)}
      end
    end

    defp finish_preparation({:error, %Error{} = reason}, state) do
      if state.mutation.owner_alive do
        reply_and_restore(state, {:error, reason})
      else
        {:noreply, restore_prior(state)}
      end
    end

    defp finish_preparation(_result, state) do
      finish_preparation(CursorSigning.error(:unavailable), state)
    end

    defp finish_recovery({:ok, :recovered}, state) do
      if state.mutation.owner_alive do
        finish_with_lifecycle(state, :ok, :healthy)
      else
        {:noreply, clear_mutation(%{state | lifecycle: :quarantined})}
      end
    end

    defp finish_recovery(_result, state) do
      if state.mutation.owner_alive do
        finish_with_lifecycle(
          state,
          {:error, :cursor_signing_recovery_refused},
          :quarantined
        )
      else
        {:noreply, clear_mutation(%{state | lifecycle: :quarantined})}
      end
    end

    defp finish_startup({:healthy, :ok}, state) do
      finish_with_lifecycle(state, :ok, :healthy)
    end

    defp finish_startup({:unprovisioned, :ok}, state) do
      finish_with_lifecycle(state, :ok, :unprovisioned)
    end

    defp finish_startup({:quarantined, {:error, _reason} = failure}, state) do
      finish_with_lifecycle(state, failure, :quarantined, failure)
    end

    defp finish_startup(_result, state) do
      failure = CursorSigning.error(:unavailable)
      finish_with_lifecycle(state, failure, :quarantined, failure)
    end

    defp finish_published_sync(:ok, state) do
      if state.mutation.owner_alive do
        finish_with_lifecycle(state, :ok, :healthy)
      else
        {:noreply, clear_mutation(%{state | lifecycle: :quarantined})}
      end
    end

    defp finish_published_sync(_result, state) do
      finish_with_lifecycle(state, CursorSigning.indeterminate(), :quarantined)
    end

    defp owner_died(%{mutation: %{phase: :published_unsynchronized} = mutation} = state) do
      Process.demonitor(mutation.worker_monitor, [:flush])
      Process.exit(mutation.worker, :kill)

      {:noreply,
       state
       |> Map.put(:lifecycle, :quarantined)
       |> Map.put(:startup_result, nil)
       |> clear_mutation()}
    end

    defp owner_died(%{mutation: mutation} = state) do
      mutation = %{mutation | owner_alive: false, owner_monitor: nil}
      {:noreply, %{state | mutation: mutation}}
    end

    defp worker_died(%{mutation: %{phase: :published_unsynchronized}} = state) do
      finish_with_lifecycle(state, CursorSigning.indeterminate(), :quarantined)
    end

    defp worker_died(%{mutation: %{phase: :recovering}} = state) do
      finish_recovery(:worker_died, state)
    end

    defp worker_died(%{mutation: %{phase: :starting}} = state) do
      finish_startup(:worker_died, state)
    end

    defp worker_died(state) do
      finish_preparation(CursorSigning.error(:unavailable), state)
    end

    defp finish_worker(state, mutation) do
      Process.demonitor(mutation.worker_monitor, [:flush])
      %{state | mutation: %{mutation | worker: nil, worker_monitor: nil}}
    end

    defp reply_and_restore(state, reply) do
      finish_with_lifecycle(state, reply, state.mutation.prior_lifecycle)
    end

    defp finish_with_lifecycle(state, reply, lifecycle, startup_result \\ nil)

    defp finish_with_lifecycle(
           %{mutation: mutation} = state,
           reply,
           lifecycle,
           startup_result
         ) do
      send(self(), {:finish_mutation, mutation.reference, reply})

      {:noreply,
       state
       |> Map.put(:lifecycle, lifecycle)
       |> Map.put(:startup_result, startup_result)
       |> Map.put(:mutation, %{mutation | phase: :terminal})}
    end

    defp restore_prior(%{mutation: mutation} = state) do
      state
      |> Map.put(:lifecycle, mutation.prior_lifecycle)
      |> clear_mutation()
    end

    defp clear_mutation(%{mutation: nil} = state), do: state

    defp clear_mutation(%{mutation: mutation} = state) do
      if mutation.owner_monitor, do: Process.demonitor(mutation.owner_monitor, [:flush])
      %{state | mutation: nil}
    end
  end

  @doc false
  def domain_separator, do: @domain_separator

  @doc false
  def read_attempts, do: @read_attempts

  @doc false
  def indeterminate, do: @indeterminate

  @doc false
  def error(reason), do: {:error, %Error{reason: reason}}

  @doc false
  def initial_lifecycle(record_path, owner_uid) do
    directory = Path.dirname(record_path)

    case File.lstat(record_path) do
      {:error, :enoent} ->
        case File.lstat(directory) do
          {:error, :enoent} -> {:unprovisioned, :ok}
          {:ok, _stat} -> classify_absent_record(directory, owner_uid)
          {:error, _reason} -> {:quarantined, error(:unavailable)}
        end

      {:ok, _stat} ->
        case recover_canonical(record_path, owner_uid) do
          {:ok, :recovered} -> {:healthy, :ok}
          {:error, %Error{} = reason} -> {:quarantined, {:error, reason}}
          _other -> {:quarantined, error(:unavailable)}
        end

      {:error, _reason} ->
        {:quarantined, error(:unavailable)}
    end
  rescue
    _error -> {:quarantined, error(:unavailable)}
  catch
    _kind, _reason -> {:quarantined, error(:unavailable)}
  end

  defp classify_absent_record(directory, owner_uid) do
    case validate_directory(directory, owner_uid) do
      :ok -> {:unprovisioned, :ok}
      {:error, %Error{} = reason} -> {:quarantined, {:error, reason}}
    end
  end

  @doc false
  def prepare_mutation(:provision, record_path, owner_uid) do
    directory = Path.dirname(record_path)

    with :ok <- ensure_base_and_private_directory(directory, owner_uid),
         :ok <- refuse_existing(record_path),
         material <- :crypto.strong_rand_bytes(@material_bytes),
         temporary <- provision_path(directory),
         :ok <- create_record(temporary, material, owner_uid) do
      {:ok, temporary}
    end
  rescue
    _error -> error(:provision_failed)
  catch
    _kind, _reason -> error(:provision_failed)
  end

  def prepare_mutation(:rotate, record_path, owner_uid) do
    directory = Path.dirname(record_path)

    with :ok <- validate_directory(directory, owner_uid),
         {:ok, _material} <- read_record(record_path, owner_uid, @read_attempts),
         material <- :crypto.strong_rand_bytes(@material_bytes),
         temporary <- rotation_path(directory),
         :ok <- create_record(temporary, material, owner_uid) do
      {:ok, temporary}
    end
  rescue
    _error -> error(:rotation_failed)
  catch
    _kind, _reason -> error(:rotation_failed)
  end

  def prepare_mutation(:recover, record_path, owner_uid) do
    recover_canonical(record_path, owner_uid)
  rescue
    _error -> {:error, :cursor_signing_recovery_refused}
  catch
    _kind, _reason -> {:error, :cursor_signing_recovery_refused}
  end

  @doc false
  def publish(:provision, temporary, record_path) do
    with :ok <- refuse_existing(record_path) do
      case File.rename(temporary, record_path) do
        :ok -> :ok
        {:error, _reason} -> error(:provision_failed)
      end
    end
  end

  def publish(:rotate, temporary, record_path) do
    case File.rename(temporary, record_path) do
      :ok -> :ok
      {:error, _reason} -> error(:rotation_failed)
    end
  end

  @doc false
  def sync_parent_once(record_path), do: sync_directory(Path.dirname(record_path))

  @doc false
  def remove_temporary(nil), do: :ok

  def remove_temporary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp ensure_base_and_private_directory(directory, owner_uid) do
    base_dir = Path.dirname(directory)

    with :ok <- mkdir_base(base_dir),
         :ok <- ensure_private_directory(directory, owner_uid) do
      :ok
    end
  end

  defp mkdir_base(base_dir) do
    case File.mkdir_p(base_dir) do
      :ok ->
        with :ok <- sync_directory(base_dir),
             :ok <- sync_directory(Path.dirname(base_dir)) do
          :ok
        end

      {:error, _reason} ->
        error(:unavailable)
    end
  end

  defp ensure_private_directory(directory, owner_uid) do
    case File.lstat(directory) do
      {:ok, _stat} ->
        validate_directory(directory, owner_uid)

      {:error, :enoent} ->
        case File.mkdir(directory) do
          :ok ->
            with :ok <- chmod(directory, @directory_mode),
                 :ok <- validate_directory(directory, owner_uid),
                 :ok <- sync_directory(directory),
                 :ok <- sync_directory(Path.dirname(directory)) do
              :ok
            end

          {:error, :eexist} ->
            validate_directory(directory, owner_uid)

          {:error, _reason} ->
            error(:unavailable)
        end

      {:error, _reason} ->
        error(:unavailable)
    end
  end

  defp validate_directory(directory, owner_uid) do
    case File.lstat(directory) do
      {:ok, %File.Stat{type: :directory, mode: mode, uid: ^owner_uid}}
      when (mode &&& 0o777) == @directory_mode ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        error(:invalid_directory)

      {:ok, %File.Stat{type: :directory, uid: uid}} when uid != owner_uid ->
        error(:wrong_owner)

      {:ok, %File.Stat{type: :directory}} ->
        error(:wrong_mode)

      {:ok, _stat} ->
        error(:invalid_directory)

      {:error, :enoent} ->
        error(:missing_directory)

      {:error, _reason} ->
        error(:unavailable)
    end
  end

  defp refuse_existing(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> error(:already_provisioned)
      {:error, _reason} -> error(:unavailable)
    end
  end

  defp create_record(path, material, owner_uid) do
    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- chmod(path, @record_mode),
               {:ok, record} <- :file.read_file_info(file),
               :ok <- validate_created_stat(File.Stat.from_record(record), owner_uid),
               :ok <- write_record(file, material),
               :ok <- sync_record(file) do
            :ok
          end

        _ = :file.close(file)

        case result do
          :ok ->
            :ok

          {:error, %Error{} = reason} ->
            remove_temporary(path)
            {:error, reason}

          _other ->
            remove_temporary(path)
            error(:unavailable)
        end

      {:error, :eexist} ->
        error(:already_provisioned)

      {:error, _reason} ->
        error(:unavailable)
    end
  end

  defp validate_created_stat(
         %File.Stat{type: :regular, mode: mode, uid: owner_uid},
         owner_uid
       )
       when (mode &&& @record_mode_mask) == @record_mode,
       do: :ok

  defp validate_created_stat(%File.Stat{uid: uid}, owner_uid) when uid != owner_uid,
    do: error(:wrong_owner)

  defp validate_created_stat(_stat, _owner_uid), do: error(:invalid_material)

  defp write_record(file, material) do
    case :file.write(file, material) do
      :ok -> :ok
      {:error, _reason} -> error(:unavailable)
    end
  end

  defp sync_record(file) do
    case :file.sync(file) do
      :ok -> :ok
      {:error, _reason} -> error(:unavailable)
    end
  end

  defp sync_directory(directory) do
    case open_directory(directory) do
      {:ok, file} ->
        result = sync_record(file)
        _ = :file.close(file)
        result

      {:error, %Error{} = reason} ->
        {:error, reason}
    end
  end

  defp open_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      {:ok, file} -> {:ok, file}
      {:error, _reason} -> error(:unavailable)
    end
  end

  @doc false
  def read_record(_path, _owner_uid, 0), do: error(:unavailable)

  def read_record(path, owner_uid, attempts) do
    with {:ok, material, _identity} <- read_record_identity(path, owner_uid, attempts) do
      {:ok, material}
    end
  end

  @doc false
  def validate_current(record_path, owner_uid) do
    with :ok <- validate_directory(Path.dirname(record_path), owner_uid),
         {:ok, _material} <- read_record(record_path, owner_uid, @read_attempts) do
      :ok
    end
  end

  defp read_record_identity(_path, _owner_uid, 0), do: error(:unavailable)

  defp read_record_identity(path, owner_uid, attempts) do
    with {:ok, before_open} <- lstat_record(path),
         :ok <- validate_record_stat(before_open, owner_uid),
         {:ok, file} <- open_record(path) do
      result = read_open_record(file, path, owner_uid)
      _ = :file.close(file)

      case result do
        :retry -> read_record_identity(path, owner_uid, attempts - 1)
        other -> other
      end
    end
  end

  defp lstat_record(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> error(:missing_material)
      {:error, _reason} -> error(:unavailable)
    end
  end

  defp open_record(path) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, file} -> {:ok, file}
      {:error, :enoent} -> error(:missing_material)
      {:error, _reason} -> error(:unavailable)
    end
  end

  defp read_open_record(file, path, owner_uid) do
    with {:ok, record} <- :file.read_file_info(file),
         stat = File.Stat.from_record(record),
         :ok <- validate_record_stat(stat, owner_uid),
         :ok <- validate_record_size(stat),
         {:ok, material} <- read_material_bytes(file),
         {:ok, after_open} <- lstat_record(path),
         :ok <- validate_record_stat(after_open, owner_uid) do
      if same_record?(stat, after_open) do
        {:ok, material, record_identity(after_open)}
      else
        :retry
      end
    end
  end

  defp validate_record_stat(
         %File.Stat{type: :regular, mode: mode, uid: owner_uid},
         owner_uid
       )
       when (mode &&& @record_mode_mask) == @record_mode,
       do: :ok

  defp validate_record_stat(%File.Stat{type: :symlink}, _owner_uid), do: error(:invalid_material)

  defp validate_record_stat(%File.Stat{type: :regular, uid: uid}, owner_uid)
       when uid != owner_uid,
       do: error(:wrong_owner)

  defp validate_record_stat(%File.Stat{type: :regular}, _owner_uid), do: error(:wrong_mode)
  defp validate_record_stat(_stat, _owner_uid), do: error(:invalid_material)

  defp validate_record_size(%File.Stat{size: @material_bytes}), do: :ok
  defp validate_record_size(_stat), do: error(:invalid_material)

  defp read_material_bytes(file) do
    case :file.read(file, @material_bytes + 1) do
      {:ok, material} when byte_size(material) == @material_bytes -> {:ok, material}
      _other -> error(:invalid_material)
    end
  end

  defp same_record?(left, right) do
    left.inode == right.inode and
      left.major_device == right.major_device and
      left.minor_device == right.minor_device
  end

  defp record_identity(stat) do
    {stat.inode, stat.major_device, stat.minor_device, stat.size, stat.mtime, stat.ctime,
     stat.mode, stat.uid}
  end

  defp recover_canonical(record_path, owner_uid) do
    directory = Path.dirname(record_path)

    with :ok <- validate_directory(directory, owner_uid),
         {:ok, _material, identity} <-
           read_record_identity(record_path, owner_uid, @read_attempts),
         :ok <- sync_directory(directory),
         {:ok, after_sync} <- lstat_record(record_path),
         :ok <- validate_record_stat(after_sync, owner_uid),
         :ok <- validate_record_size(after_sync),
         true <- record_identity(after_sync) == identity do
      {:ok, :recovered}
    else
      _other -> error(:unavailable)
    end
  end

  defp provision_path(directory) do
    suffix = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    Path.join(directory, ".#{@record_name}.provision-#{suffix}")
  end

  defp rotation_path(directory) do
    suffix = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    Path.join(directory, ".#{@record_name}.rotate-#{suffix}")
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, _reason} -> error(:unavailable)
    end
  end

  defp effective_uid do
    case File.read("/proc/self/status") do
      {:ok, status} -> uid_from_proc(status)
      {:error, _reason} -> uid_from_id()
    end
  end

  defp uid_from_proc(status) do
    status
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line) do
        ["Uid:", _real, effective | _rest] -> parse_uid(effective)
        _other -> nil
      end
    end)
    |> case do
      nil -> error(:service_identity_unavailable)
      uid -> {:ok, uid}
    end
  end

  defp uid_from_id do
    executable = Enum.find(["/usr/bin/id", "/bin/id"], &File.regular?/1)

    case executable && System.cmd(executable, ["-u"], stderr_to_stdout: true) do
      {output, 0} ->
        case parse_uid(String.trim(output)) do
          nil -> error(:service_identity_unavailable)
          uid -> {:ok, uid}
        end

      _other ->
        error(:service_identity_unavailable)
    end
  end

  defp parse_uid(value) do
    case Integer.parse(value) do
      {uid, ""} when uid >= 0 -> uid
      _other -> nil
    end
  end
end
