defmodule Tightbeam.Visitor.Keyring do
  @moduledoc """
  Loads the durable visitor credential keyring through a closed, redacted seam.

  The loader compares path metadata with metadata from the opened descriptor.
  A symlink, replacement race, wrong owner or wrong mode therefore refuses
  before key material becomes available to the gateway.
  """

  import Bitwise

  alias __MODULE__.UnavailableError

  @schema "visitor-keyring-v1"
  @filename "visitor-keyring-v1.json"
  @derivation_purpose "credential-derivation"
  @digest_purpose "credential-digest"
  @maximum_bytes 1_048_576

  @enforce_keys [:path, :active_derivation_key_id, :active_digest_key_id, :keys]
  defstruct [:path, :active_derivation_key_id, :active_digest_key_id, :keys]

  @opaque t :: %__MODULE__{
            path: String.t(),
            active_derivation_key_id: String.t(),
            active_digest_key_id: String.t(),
            keys: %{required(String.t()) => %{purpose: String.t(), bytes: binary()}}
          }

  defmodule UnavailableError do
    @moduledoc false
    defexception [:class, :missing_key_id]

    @impl true
    def message(%{missing_key_id: key_id}) when is_binary(key_id),
      do: "visitor_keyring_unavailable (missing key id: #{key_id})"

    def message(%{class: class}) when is_binary(class),
      do: "visitor_keyring_unavailable (#{class})"

    def message(_), do: "visitor_keyring_unavailable"
  end

  @doc "Loads and validates a keyring without exposing a validation detail or key bytes."
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, UnavailableError.t()}
  def load(base_dir, opts \\ []) when is_binary(base_dir) and is_list(opts) do
    with {:ok, expected_uid} <- expected_uid(opts),
         path = Path.join([base_dir, "secrets", @filename]),
         :ok <- validate_directory(Path.dirname(path), expected_uid),
         {:ok, bytes} <- read_validated_file(path, expected_uid),
         {:ok, document} <- decode_strict(bytes),
         {:ok, keyring} <- validate_document(document, path),
         :ok <- validate_references(keyring, Keyword.get(opts, :referenced_key_ids, [])) do
      {:ok, keyring}
    else
      {:missing_key, key_id} -> {:error, unavailable("missing_key", key_id)}
      {:error, %UnavailableError{} = error} -> {:error, error}
      _ -> {:error, unavailable("validation")}
    end
  rescue
    _ -> {:error, unavailable("validation")}
  catch
    _, _ -> {:error, unavailable("validation")}
  end

  @doc "Loads a keyring or raises the single public boot-refusal exception."
  @spec load!(Path.t(), keyword()) :: t()
  def load!(base_dir, opts \\ []) do
    case load(base_dir, opts) do
      {:ok, keyring} -> keyring
      {:error, error} -> raise error
    end
  end

  @doc "Returns key ids only. Key bytes never cross this projection."
  @spec key_ids(t()) :: [String.t()]
  def key_ids(%__MODULE__{keys: keys}), do: keys |> Map.keys() |> Enum.sort()

  @doc "Derives the deterministic invitation bearer defined by visitor-principal-v3."
  @spec derive_invitation_credential(t(), String.t(), String.t() | integer(), String.t() | nil) ::
          String.t()
  def derive_invitation_credential(keyring, invitation_id, credential_version, key_id \\ nil) do
    derive(
      keyring,
      key_id || keyring.active_derivation_key_id,
      "tbi_",
      "tightbeam/visitor-invitation-credential/v1\0",
      invitation_id,
      credential_version
    )
  end

  @doc "Derives the deterministic access bearer defined by visitor-principal-v3."
  @spec derive_access_credential(t(), String.t(), String.t() | integer(), String.t() | nil) ::
          String.t()
  def derive_access_credential(keyring, access_session_id, credential_version, key_id \\ nil) do
    derive(
      keyring,
      key_id || keyring.active_derivation_key_id,
      "tbv_",
      "tightbeam/visitor-credential/v1\0",
      access_session_id,
      credential_version
    )
  end

  @doc "Computes the keyed digest stored for an exact credential byte string."
  @spec credential_digest(t(), binary(), String.t() | nil) :: binary()
  def credential_digest(keyring, credential, key_id \\ nil) when is_binary(credential) do
    key = fetch_key!(keyring, key_id || keyring.active_digest_key_id, @digest_purpose)
    :crypto.mac(:hmac, :sha256, key, credential)
  end

  defp derive(keyring, key_id, prefix, domain, identifier, version)
       when is_binary(identifier) and byte_size(identifier) > 0 do
    version = credential_version(version)
    key = fetch_key!(keyring, key_id, @derivation_purpose)
    mac = :crypto.mac(:hmac, :sha256, key, [domain, identifier, <<0>>, version])
    prefix <> Base.url_encode64(mac, padding: false)
  end

  defp credential_version(version) when is_binary(version) and byte_size(version) > 0, do: version

  defp credential_version(version) when is_integer(version) and version >= 0,
    do: Integer.to_string(version)

  defp credential_version(_), do: raise(ArgumentError, "invalid credential version")

  defp fetch_key!(%__MODULE__{keys: keys}, key_id, purpose) do
    case Map.fetch(keys, key_id) do
      {:ok, %{purpose: ^purpose, bytes: bytes}} -> bytes
      _ -> raise unavailable("missing_key", key_id)
    end
  end

  defp expected_uid(opts) do
    case Keyword.fetch(opts, :expected_uid) do
      {:ok, uid} when is_integer(uid) and uid >= 0 -> {:ok, uid}
      {:ok, _} -> {:error, :invalid_uid}
      :error -> gateway_uid()
    end
  end

  defp gateway_uid do
    executable = Enum.find(["/usr/bin/id", "/bin/id"], &File.regular?/1)

    with path when is_binary(path) <- executable,
         {encoded, 0} <- System.cmd(path, ["-u"], stderr_to_stdout: true),
         {uid, rest} <- Integer.parse(encoded),
         true <- String.trim(rest) == "" and uid >= 0 do
      {:ok, uid}
    else
      _ -> {:error, :uid_unavailable}
    end
  end

  defp validate_directory(path, expected_uid) do
    with {:ok, stat} <- File.lstat(path, time: :posix),
         true <- stat.type == :directory,
         true <- stat.uid == expected_uid,
         true <- permissions(stat) == 0o700 do
      :ok
    else
      _ -> {:error, :invalid_directory}
    end
  end

  defp read_validated_file(path, expected_uid) do
    with {:ok, path_stat} <- File.lstat(path, time: :posix),
         :ok <- validate_regular(path_stat, expected_uid),
         {:ok, io} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, before_record} <- :file.read_file_info(io, time: :posix),
             before = File.Stat.from_record(before_record),
             :ok <- validate_regular(before, expected_uid),
             true <- same_inode?(path_stat, before),
             {:ok, bytes} <- read_bounded(io),
             {:ok, after_record} <- :file.read_file_info(io, time: :posix),
             after_stat = File.Stat.from_record(after_record),
             true <- same_snapshot?(before, after_stat),
             true <- byte_size(bytes) == after_stat.size do
          {:ok, bytes}
        else
          _ -> {:error, :invalid_file}
        end
      after
        :file.close(io)
      end
    else
      _ -> {:error, :invalid_file}
    end
  end

  defp validate_regular(stat, expected_uid) do
    if stat.type == :regular and stat.uid == expected_uid and permissions(stat) == 0o600,
      do: :ok,
      else: {:error, :invalid_file}
  end

  defp permissions(stat), do: stat.mode &&& 0o7777

  defp same_inode?(left, right) do
    left.major_device == right.major_device and left.minor_device == right.minor_device and
      left.inode == right.inode
  end

  defp same_snapshot?(left, right) do
    same_inode?(left, right) and left.size == right.size and left.mode == right.mode and
      left.uid == right.uid and left.mtime == right.mtime and left.ctime == right.ctime
  end

  defp read_bounded(io) do
    case :file.read(io, @maximum_bytes + 1) do
      {:ok, bytes} when byte_size(bytes) <= @maximum_bytes ->
        case :file.read(io, 1) do
          :eof -> {:ok, bytes}
          _ -> {:error, :too_large}
        end

      :eof ->
        {:ok, <<>>}

      _ ->
        {:error, :read_failed}
    end
  end

  defp decode_strict(bytes) do
    decoders = [
      object_start: fn _old_acc -> [] end,
      object_push: fn key, value, pairs ->
        if List.keymember?(pairs, key, 0), do: throw(:duplicate_json_key)
        [{key, value} | pairs]
      end,
      object_finish: fn pairs, old_acc -> {Map.new(pairs), old_acc} end
    ]

    try do
      case JSON.decode(bytes, nil, decoders) do
        {document, nil, ""} -> {:ok, document}
        _ -> {:error, :malformed_json}
      end
    catch
      :duplicate_json_key -> {:error, :duplicate_json_key}
    end
  end

  defp validate_document(document, path) do
    with {:ok, root} <-
           exact_map(document, ~w(schema activeDerivationKeyId activeDigestKeyId keys)),
         @schema <- root["schema"],
         derivation_id when is_binary(derivation_id) and byte_size(derivation_id) > 0 <-
           root["activeDerivationKeyId"],
         digest_id when is_binary(digest_id) and byte_size(digest_id) > 0 <-
           root["activeDigestKeyId"],
         true <- derivation_id != digest_id,
         keys when is_map(keys) and map_size(keys) >= 2 <- root["keys"],
         {:ok, decoded_keys} <- decode_keys(keys),
         {:ok, %{purpose: @derivation_purpose, bytes: derivation_bytes}} <-
           Map.fetch(decoded_keys, derivation_id),
         {:ok, %{purpose: @digest_purpose, bytes: digest_bytes}} <-
           Map.fetch(decoded_keys, digest_id),
         true <- derivation_bytes != digest_bytes do
      {:ok,
       %__MODULE__{
         path: path,
         active_derivation_key_id: derivation_id,
         active_digest_key_id: digest_id,
         keys: decoded_keys
       }}
    else
      _ -> {:error, :invalid_schema}
    end
  end

  defp decode_keys(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn
      {id, value}, {:ok, decoded} when is_binary(id) and byte_size(id) > 0 ->
        with {:ok, key} <- exact_map(value, ~w(purpose bytesBase64)),
             purpose when purpose in [@derivation_purpose, @digest_purpose] <- key["purpose"],
             encoded when is_binary(encoded) <- key["bytesBase64"],
             {:ok, bytes} <- Base.decode64(encoded),
             true <- byte_size(bytes) == 32 do
          {:cont, {:ok, Map.put(decoded, id, %{purpose: purpose, bytes: bytes})}}
        else
          _ -> {:halt, {:error, :invalid_key}}
        end

      _, _ ->
        {:halt, {:error, :invalid_key}}
    end)
  end

  defp exact_map(value, keys) when is_map(value) do
    if value |> Map.keys() |> Enum.sort() == Enum.sort(keys),
      do: {:ok, value},
      else: {:error, :unexpected_keys}
  end

  defp exact_map(_, _), do: {:error, :not_an_object}

  defp validate_references(%__MODULE__{keys: keys}, references) when is_list(references) do
    case Enum.find(references, &(not is_binary(&1) or not Map.has_key?(keys, &1))) do
      nil -> :ok
      missing when is_binary(missing) -> {:missing_key, missing}
      _ -> {:error, :invalid_reference}
    end
  end

  defp validate_references(_, _), do: {:error, :invalid_reference}

  defp unavailable(class, missing_key_id \\ nil),
    do: %UnavailableError{class: class, missing_key_id: missing_key_id}
end

defimpl Inspect, for: Tightbeam.Visitor.Keyring do
  import Inspect.Algebra

  def inspect(keyring, _opts) do
    concat([
      "#Tightbeam.Visitor.Keyring<path=",
      keyring.path,
      " activeDerivationKeyId=",
      keyring.active_derivation_key_id,
      " activeDigestKeyId=",
      keyring.active_digest_key_id,
      " keys=[redacted]>"
    ])
  end
end
