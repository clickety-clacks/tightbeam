defmodule Tightbeam.CursorSigning do
  @moduledoc """
  Owns the server-held material used to authenticate opaque REST cursors.

  The active record stays on disk. A provider value contains only the location
  and the service identity that validated it. Every signing and verification
  operation opens and reads one complete current record, so atomic rotation is
  visible across request processes, BEAM instances, and restarts.

  Provisioning is an explicit local bootstrap operation. Normal application
  composition uses `load/1` and refuses to start when no valid record exists.
  """

  import Bitwise

  @material_bytes 32
  @domain_separator <<"tightbeam/rest-read-plane-d1/cursor/v1", 0>>
  @record_name "rest-cursor-signing.v1"
  @record_mode 0o600
  @record_mode_mask 0o7777
  @directory_mode 0o700
  @read_attempts 8
  @commit_sync_retry_ms 10

  defmodule Error do
    @moduledoc false
    defexception reason: :unavailable, message: "cursor signing is unavailable"

    @type t :: %__MODULE__{reason: atom(), message: String.t()}
  end

  @enforce_keys [:record_path, :owner_uid]
  @derive {Inspect, only: []}
  defstruct [:record_path, :owner_uid]

  @opaque t :: %__MODULE__{record_path: String.t(), owner_uid: non_neg_integer()}

  @doc """
  Creates the first material record without replacing any existing entry.

  This operation is for the local gateway bootstrap before a listener starts.
  Normal application startup must call `load/1` instead.
  """
  @spec provision(String.t()) :: :ok | {:error, Error.t()}
  def provision(base_dir) do
    with {:ok, owner_uid} <- effective_uid(),
         {:ok, directory, path} <- provision_location(base_dir, owner_uid),
         :ok <- refuse_existing(path),
         material <- :crypto.strong_rand_bytes(@material_bytes),
         :ok <- create_active_record(directory, path, material, owner_uid),
         {:ok, _material} <- read_record(path, owner_uid, @read_attempts) do
      :ok
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
      {:error, reason} -> raise reason
    end
  end

  @doc "Loads and validates an existing material record without retaining its bytes."
  @spec load(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def load(base_dir) do
    with {:ok, owner_uid} <- effective_uid(),
         {:ok, _directory, path} <- existing_location(base_dir, owner_uid),
         {:ok, _material} <- read_record(path, owner_uid, @read_attempts) do
      {:ok, %__MODULE__{record_path: path, owner_uid: owner_uid}}
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
      {:error, reason} -> raise reason
    end
  end

  @doc "Validates an injected provider and its current material record."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{record_path: path, owner_uid: owner_uid})
      when is_binary(path) and is_integer(owner_uid) and owner_uid >= 0 do
    provider = %__MODULE__{record_path: path, owner_uid: owner_uid}

    with {:ok, _directory} <- validate_parent(provider),
         {:ok, _material} <- read_record(path, owner_uid, @read_attempts) do
      :ok
    end
  rescue
    _error -> error(:invalid_injection)
  catch
    _kind, _reason -> error(:invalid_injection)
  end

  def validate(_provider), do: error(:invalid_injection)

  @doc "Same as `validate/1`, but raises a redacted typed error on refusal."
  @spec validate!(term()) :: t()
  def validate!(provider) do
    case validate(provider) do
      :ok -> provider
      {:error, reason} -> raise reason
    end
  end

  @doc "Computes one HMAC-SHA-256 value from one complete current record read."
  @spec sign(t(), iodata()) :: {:ok, <<_::256>>} | {:error, Error.t()}
  def sign(%__MODULE__{} = provider, input) do
    with {:ok, input} <- iodata(input),
         {:ok, material} <- provider_material(provider) do
      {:ok, :crypto.mac(:hmac, :sha256, material, [@domain_separator, input])}
    end
  rescue
    _error -> error(:operation_failed)
  catch
    _kind, _reason -> error(:operation_failed)
  end

  def sign(_provider, _input), do: error(:invalid_injection)

  @doc "Checks one HMAC-SHA-256 value against one complete current record read."
  @spec verify(t(), iodata(), binary()) :: {:ok, boolean()} | {:error, Error.t()}
  def verify(%__MODULE__{} = provider, input, signature) when is_binary(signature) do
    with {:ok, expected} <- sign(provider, input) do
      {:ok,
       byte_size(signature) == byte_size(expected) and
         Plug.Crypto.secure_compare(signature, expected)}
    end
  rescue
    _error -> error(:operation_failed)
  catch
    _kind, _reason -> error(:operation_failed)
  end

  def verify(%__MODULE__{}, _input, _signature), do: error(:invalid_signature)
  def verify(_provider, _input, _signature), do: error(:invalid_injection)

  @doc "Atomically replaces the active record with fresh material."
  @spec rotate(t()) :: :ok | {:error, Error.t()}
  def rotate(%__MODULE__{} = provider) do
    with :ok <- validate(provider),
         {:ok, directory} <- validate_parent(provider),
         material <- :crypto.strong_rand_bytes(@material_bytes),
         temporary <- rotation_path(directory),
         :ok <- create_record(temporary, material, provider.owner_uid),
         :ok <- replace_record(temporary, provider.record_path) do
      :ok
    else
      {:error, %Error{} = reason} -> {:error, reason}
      _other -> error(:rotation_failed)
    end
  rescue
    _error -> error(:rotation_failed)
  catch
    _kind, _reason -> error(:rotation_failed)
  end

  def rotate(_provider), do: error(:invalid_injection)

  defp provider_material(%__MODULE__{record_path: path, owner_uid: owner_uid}) do
    provider = %__MODULE__{record_path: path, owner_uid: owner_uid}

    with {:ok, _directory} <- validate_parent(provider) do
      read_record(path, owner_uid, @read_attempts)
    end
  end

  defp iodata(input) do
    {:ok, IO.iodata_to_binary(input)}
  rescue
    _error -> error(:invalid_input)
  end

  defp provision_location(base_dir, owner_uid) do
    with {:ok, base_dir} <- base_directory(base_dir),
         :ok <- mkdir_base(base_dir),
         directory = Path.join(base_dir, "secrets"),
         :ok <- ensure_private_directory(directory, owner_uid) do
      {:ok, directory, Path.join(directory, @record_name)}
    end
  end

  defp existing_location(base_dir, owner_uid) do
    with {:ok, base_dir} <- base_directory(base_dir),
         directory = Path.join(base_dir, "secrets"),
         :ok <- validate_directory(directory, owner_uid) do
      {:ok, directory, Path.join(directory, @record_name)}
    end
  end

  defp base_directory(base_dir) when is_binary(base_dir) and byte_size(base_dir) > 0,
    do: {:ok, base_dir}

  defp base_directory(_base_dir), do: error(:invalid_base_dir)

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

  defp validate_parent(%__MODULE__{record_path: path, owner_uid: owner_uid}) do
    directory = Path.dirname(path)

    case validate_directory(directory, owner_uid) do
      :ok -> {:ok, directory}
      {:error, %Error{} = reason} -> {:error, reason}
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
            _ = File.rm(path)
            {:error, reason}

          _other ->
            _ = File.rm(path)
            error(:unavailable)
        end

      {:error, :eexist} ->
        error(:already_provisioned)

      {:error, _reason} ->
        error(:unavailable)
    end
  end

  defp create_active_record(directory, path, material, owner_uid) do
    case open_directory(directory) do
      {:ok, directory_file} ->
        result =
          with :ok <- sync_record(directory_file),
               :ok <- create_record(path, material, owner_uid),
               :ok <- sync_committed_directory(directory_file) do
            :ok
          end

        _ = :file.close(directory_file)
        result

      {:error, %Error{} = reason} ->
        {:error, reason}
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

  # Creating or renaming the active record is the authority commit point. Once
  # that point is crossed, returning an ordinary failure would lie about which
  # generation is active. Keep listener admission or rotation completion
  # blocked until the containing directory confirms the committed namespace.
  defp sync_committed_directory(directory_file) do
    case :file.sync(directory_file) do
      :ok ->
        :ok

      {:error, _reason} ->
        Process.sleep(@commit_sync_retry_ms)
        sync_committed_directory(directory_file)
    end
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, _reason} -> error(:unavailable)
    end
  end

  defp read_record(_path, _owner_uid, 0), do: error(:unavailable)

  defp read_record(path, owner_uid, attempts) do
    with {:ok, before_open} <- lstat_record(path),
         :ok <- validate_record_stat(before_open, owner_uid),
         {:ok, file} <- open_record(path) do
      result = read_open_record(file, path, owner_uid)
      _ = :file.close(file)

      case result do
        :retry -> read_record(path, owner_uid, attempts - 1)
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
      if same_record?(stat, after_open), do: {:ok, material}, else: :retry
    end
  end

  defp validate_record_stat(
         %File.Stat{type: :regular, mode: mode, uid: owner_uid},
         owner_uid
       )
       when (mode &&& @record_mode_mask) == @record_mode,
       do: :ok

  defp validate_record_stat(%File.Stat{type: :symlink}, _owner_uid),
    do: error(:invalid_material)

  defp validate_record_stat(%File.Stat{type: :regular, uid: uid}, owner_uid)
       when uid != owner_uid,
       do: error(:wrong_owner)

  defp validate_record_stat(%File.Stat{type: :regular}, _owner_uid),
    do: error(:wrong_mode)

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

  defp rotation_path(directory) do
    suffix = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    Path.join(directory, ".#{@record_name}.rotate-#{suffix}")
  end

  defp replace_record(temporary, path) do
    directory = Path.dirname(path)

    case open_directory(directory) do
      {:ok, directory_file} ->
        result =
          case sync_record(directory_file) do
            :ok ->
              case File.rename(temporary, path) do
                :ok ->
                  sync_committed_directory(directory_file)

                {:error, _reason} ->
                  _ = File.rm(temporary)
                  error(:rotation_failed)
              end

            {:error, %Error{} = reason} ->
              _ = File.rm(temporary)
              {:error, reason}
          end

        _ = :file.close(directory_file)
        result

      {:error, %Error{}} ->
        _ = File.rm(temporary)
        error(:rotation_failed)
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

  defp error(reason), do: {:error, %Error{reason: reason}}
end
