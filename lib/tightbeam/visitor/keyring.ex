defmodule Tightbeam.Visitor.Keyring do
  @moduledoc """
  Loads the durable visitor credential keyring through a closed, redacted seam.

  The loader compares path metadata with metadata from the opened descriptor.
  A symlink, replacement race, wrong owner or wrong mode therefore refuses
  before key material becomes available to the gateway.
  """

  alias __MODULE__.UnavailableError
  alias __MODULE__.Native
  alias Tightbeam.DB

  @schema "visitor-keyring-v1"
  @visitor_schema "visitor-principal-v3-v1"
  @current_previsitor_schema "coordination-fabric-v1-phase1-v17"
  @filename "visitor-keyring-v1.json"
  @derivation_purpose "credential-derivation"
  @digest_purpose "credential-digest"
  @boot_key {__MODULE__, :loaded}

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
         {:ok, bytes} <- read_validated_file(path, expected_uid),
         {:ok, document} <- decode_strict(bytes),
         {:ok, keyring} <- validate_document(document, path),
         :ok <-
           validate_references(
             keyring,
             Keyword.get(opts, :referenced_derivation_key_ids, []),
             Keyword.get(opts, :referenced_digest_key_ids, [])
           ) do
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

  @doc false
  @spec load_for_boot(Path.t(), DB.server(), keyword()) ::
          :not_required | {:ok, t()} | {:error, UnavailableError.t()}
  def load_for_boot(base_dir, db \\ DB, opts \\ []) do
    :persistent_term.erase(@boot_key)
    phase = Keyword.get(opts, :phase, :after_schema)

    with {:ok, references} <- database_references(db, phase) do
      path = Path.join([base_dir, "secrets", @filename])

      if references.required or path_entry_exists?(path) do
        case load(base_dir,
               referenced_derivation_key_ids: references.derivation,
               referenced_digest_key_ids: references.digest
             ) do
          {:ok, keyring} ->
            :persistent_term.put(@boot_key, keyring)
            {:ok, keyring}

          {:error, error} ->
            {:error, error}
        end
      else
        :not_required
      end
    else
      _ -> {:error, unavailable("database_references")}
    end
  rescue
    _ -> {:error, unavailable("database_references")}
  catch
    _, _ -> {:error, unavailable("database_references")}
  end

  @doc "Returns the keyring locked into the current gateway boot."
  @spec current!() :: t()
  def current! do
    case :persistent_term.get(@boot_key, nil) do
      %__MODULE__{} = keyring -> keyring
      _ -> raise unavailable("not_loaded")
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

  defp read_validated_file(path, expected_uid) do
    case Native.read(Path.dirname(path), expected_uid) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      _ -> {:error, :invalid_file}
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

  defp validate_references(%__MODULE__{keys: keys}, derivation_ids, digest_ids)
       when is_list(derivation_ids) and is_list(digest_ids) do
    with :ok <- validate_reference_group(keys, derivation_ids, @derivation_purpose),
         :ok <- validate_reference_group(keys, digest_ids, @digest_purpose) do
      :ok
    end
  end

  defp validate_references(_, _, _), do: {:error, :invalid_reference}

  defp validate_reference_group(keys, ids, purpose) do
    case Enum.find(ids, fn id ->
           not is_binary(id) or not match?(%{purpose: ^purpose}, Map.get(keys, id))
         end) do
      nil -> :ok
      missing when is_binary(missing) -> {:missing_key, missing}
      _ -> {:error, :invalid_reference}
    end
  end

  defp database_references(db, phase) when phase in [:before_schema, :after_schema] do
    case DB.query(db, "SELECT shape FROM schema_stamp") do
      {:ok, [[@visitor_schema]]} ->
        referenced_rows(db)

      {:ok, [[@current_previsitor_schema]]} ->
        {:ok, empty_references()}

      {:error, _} when phase == :before_schema ->
        {:ok, empty_references()}

      _ ->
        {:error, :invalid_schema_stamp}
    end
  end

  defp database_references(_, _), do: {:error, :invalid_phase}

  defp referenced_rows(db) do
    sql = """
    SELECT derivationKeyId, digestKeyId FROM visitor_invitations
    UNION ALL
    SELECT derivationKeyId, digestKeyId FROM visitor_access_sessions
    """

    case DB.query(db, sql) do
      {:ok, rows} ->
        Enum.reduce_while(rows, {:ok, %{required: true, derivation: [], digest: []}}, fn
          [derivation_id, digest_id], {:ok, references}
          when is_binary(derivation_id) and is_binary(digest_id) ->
            {:cont,
             {:ok,
              %{
                references
                | derivation: [derivation_id | references.derivation],
                  digest: [digest_id | references.digest]
              }}}

          _, _ ->
            {:halt, {:error, :invalid_database_reference}}
        end)

      _ ->
        {:error, :database_reference_query_failed}
    end
  end

  defp empty_references, do: %{required: false, derivation: [], digest: []}

  defp path_entry_exists?(path) do
    match?({:ok, _}, File.lstat(path, time: :posix))
  end

  defp unavailable(class, missing_key_id \\ nil),
    do: %UnavailableError{class: class, missing_key_id: missing_key_id}

  defimpl Inspect, for: __MODULE__ do
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
end
