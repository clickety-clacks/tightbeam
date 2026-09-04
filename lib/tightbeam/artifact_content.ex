defmodule Tightbeam.ArtifactContent do
  @moduledoc """
  Immutable released-artifact content custody.

  The tables in this module are the durable registry for verified CAS bytes,
  authenticated replay keys, and the one 0.1.9 legacy-promotion census. File
  capture and release are deliberately added at this seam rather than to the
  artifact pointer registry.
  """

  alias Tightbeam.{Artifacts, DB, EventLog}

  defmodule CaptureError do
    @moduledoc false
    defexception [:code, :message]
  end

  defmodule CaptureReuseError do
    @moduledoc false
    defexception [:digest, :failure, :principal, message: "capture reuse failed"]
  end

  @migration_id "0.1.9/artifact-content-v1"
  @max_object_bytes 32 * 1024 * 1024

  @ddl """
  CREATE TABLE IF NOT EXISTS artifact_blobs (
    digest          TEXT PRIMARY KEY,
    size            INTEGER NOT NULL CHECK (size >= 0),
    storageVersion  INTEGER NOT NULL CHECK (storageVersion = 1),
    status          TEXT NOT NULL CHECK (status IN ('verified','corrupt')),
    createdAt       INTEGER NOT NULL,
    verifiedAt      INTEGER NOT NULL,
    corruptAt       INTEGER,
    corruptReason   TEXT,
    CHECK (
      (status = 'verified' AND corruptAt IS NULL AND corruptReason IS NULL)
      OR
      (status = 'corrupt' AND corruptAt IS NOT NULL AND corruptReason IS NOT NULL)
    )
  );

  CREATE TABLE IF NOT EXISTS artifact_content_requests (
    principalKind   TEXT NOT NULL,
    principalId     TEXT NOT NULL,
    operation       TEXT NOT NULL CHECK (operation IN ('record','recover','fetch-complete')),
    idempotencyKey  TEXT NOT NULL,
    requestHash     TEXT NOT NULL,
    artifactId      TEXT NOT NULL REFERENCES artifacts(artifactId),
    createdAt       INTEGER NOT NULL,
    PRIMARY KEY (principalKind, principalId, operation, idempotencyKey)
  );

  CREATE TABLE IF NOT EXISTS artifact_content_migrations (
    migrationId     TEXT NOT NULL CHECK (migrationId = '#{@migration_id}'),
    artifactId      TEXT NOT NULL REFERENCES artifacts(artifactId),
    sourceState     TEXT NOT NULL CHECK (sourceState IN ('in-workspace','archived','released')),
    outcome         TEXT NOT NULL CHECK (outcome IN ('pending','released','unavailable')),
    contentSha256   TEXT,
    contentSize     INTEGER CHECK (contentSize >= 0),
    reason          TEXT,
    updatedAt       INTEGER NOT NULL,
    cause           TEXT NOT NULL,
    principal       TEXT NOT NULL,
    PRIMARY KEY (migrationId, artifactId),
    CHECK ((contentSha256 IS NULL) = (contentSize IS NULL))
  );
  """

  @doc "Create the artifact-content registry schema."
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc false
  def ddl, do: @ddl

  @doc false
  def migration_id, do: @migration_id

  @doc """
  Capture one regular file below a trusted root and release its artifact row.

  The source pathname is never opened by the BEAM. The gateway executes only
  `<base_dir>/bin/tightbeam`; that helper opens the source under descriptor
  custody and stdout carries bytes from that same descriptor.
  """
  @spec capture(DB.server(), map()) :: {:ok, map()} | {:error, map()}
  def capture(db \\ Tightbeam.DB, opts) do
    with :ok <- validate_capture_options(opts),
         :miss <- request_replay(db, opts),
         {:ok, quota} <- configured_bytes(opts, :quota_bytes),
         {:ok, reserved} <- configured_bytes(opts, :reserved_free_bytes),
         :ok <- filesystem_preflight(opts, reserved),
         {:ok, staged} <- stage_from_custody(opts) do
      try do
        with :ok <- validate_declared(staged, opts),
             :ok <- validate_expected(staged, opts),
             {:ok, blob, row} <- publish_and_persist_release(db, staged, quota, opts),
             :ok <- verify_after_release(db, blob, opts) do
          {:ok, row}
        end
      after
        File.rm(staged.path)
      end
    else
      {:replay, row} -> {:ok, row}
      {:error, %{code: _} = refusal} -> {:error, refusal}
      {:error, reason} -> {:error, refusal("content_capture_failed", inspect(reason))}
    end
  end

  @doc """
  Prepare every retirement source before releasing any row.

  All sources are staged before one serialized quota/publication/release
  transaction. A failed batch can retain only objects that fit the physical
  quota, and it can never leave a partial set of released rows.
  """
  @spec capture_many(DB.server(), [map()], map()) :: {:ok, [map()]} | {:error, map()}
  def capture_many(db \\ Tightbeam.DB, captures, common_opts)
      when is_list(captures) and is_map(common_opts) do
    with {:ok, quota} <- configured_bytes(common_opts, :quota_bytes),
         {:ok, reserved} <- configured_bytes(common_opts, :reserved_free_bytes),
         :ok <- filesystem_preflight(common_opts, reserved),
         {:ok, prepared} <- prepare_all(captures, common_opts) do
      try do
        with {:ok, blobs, rows} <- persist_releases(db, prepared, quota),
             :ok <- verify_many_after_release(db, blobs) do
          {:ok, rows}
        end
      after
        Enum.each(prepared, &File.rm(&1.blob.path))
      end
    else
      {:error, %{code: _} = refusal} -> {:error, refusal}
      {:error, reason} -> {:error, refusal("content_capture_failed", inspect(reason))}
    end
  end

  @doc """
  Verify released content completely before returning an unlinked descriptor.

  The returned descriptor owns a private copy. Its pathname has already been
  removed and its position is zero, so a router can stream it without trusting
  the CAS pathname again.
  """
  @spec fetch(DB.server(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, map()}
  def fetch(db \\ Tightbeam.DB, base_dir, artifact_id, principal) do
    case Artifacts.get(db, artifact_id) do
      nil ->
        {:error, refusal("not_found", "artifact not found")}

      %{state: "in-workspace"} ->
        {:error, refusal("content_not_released", "artifact content is not released")}

      %{state: "archived"} ->
        {:error, refusal("content_not_released", "artifact content is not released")}

      %{state: "legacy-unavailable"} ->
        {:error, refusal("content_unavailable", "artifact content is unavailable")}

      %{state: "corrupt-unavailable"} ->
        {:error, refusal("content_corrupt", "artifact content is corrupt")}

      %{state: "released"} = artifact ->
        fetch_released(db, base_dir, artifact, principal, "fetch")
    end
  end

  @doc "Remove incomplete capture, fetch, and authenticated-import staging."
  @spec cleanup_temps(String.t()) :: :ok
  def cleanup_temps(base_dir) do
    for staging <- ~w(tmp import) do
      staging_dir = Path.join([base_dir, "artifact-content", staging])

      case File.ls(staging_dir) do
        {:ok, names} ->
          Enum.each(names, fn name -> File.rm_rf!(Path.join(staging_dir, name)) end)

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          raise "artifact content #{staging} inventory failed: #{reason}"
      end
    end

    :ok
  end

  @doc "Verify every released digest before the gateway accepts traffic."
  @spec boot_scrub!(DB.server(), String.t()) :: :ok
  def boot_scrub!(db \\ Tightbeam.DB, base_dir) do
    failures =
      Artifacts.list(db)
      |> Enum.filter(&(&1.state == "released"))
      |> Enum.reduce([], fn artifact, failures ->
        case fetch_released(db, base_dir, artifact, "process:tightbeam", "boot-scrub") do
          {:ok, %{descriptor: descriptor}} ->
            File.close(descriptor)
            failures

          {:error, refusal} ->
            [{artifact.artifact_id, refusal.code} | failures]
        end
      end)

    if failures == [] do
      :ok
    else
      failures = failures |> Enum.reverse() |> inspect()
      raise "artifact content boot scrub refused: #{failures}"
    end
  end

  @doc "Record an authenticated completion only after the CLI installs output."
  @spec complete_fetch(DB.server(), map()) :: map()
  def complete_fetch(db \\ Tightbeam.DB, call) do
    with {:ok, principal_kind, principal_id} <- replay_principal(call[:principal]),
         artifact when not is_nil(artifact) <- Artifacts.get(db, call.params[:artifact_id]),
         true <- artifact.state == "released",
         true <- artifact.content_sha256 == call.params[:content_sha256],
         true <- artifact.content_size == call.params[:content_size],
         fetch_id when is_binary(fetch_id) and fetch_id != "" <- call.params[:fetch_id] do
      request_hash =
        :crypto.hash(
          :sha256,
          Enum.join(
            [artifact.artifact_id, fetch_id, artifact.content_sha256, artifact.content_size],
            "\0"
          )
        )
        |> Base.encode16(case: :lower)

      request = %{
        principal_kind: principal_kind,
        principal_id: principal_id,
        operation: "fetch-complete",
        idempotency_key: fetch_id,
        request_hash: request_hash
      }

      opts = %{artifact_id: artifact.artifact_id, request: request}

      case DB.transaction(db, fn txn -> ensure_request_in_txn!(txn, opts) end) do
        {:ok, :ok} ->
          %{
            artifact_id: artifact.artifact_id,
            fetch_id: fetch_id,
            content_sha256: artifact.content_sha256,
            content_size: artifact.content_size,
            completed: true
          }

        {:error, %{__struct__: CaptureError} = error} ->
          refusal(error.code, error.message)

        {:error, error} ->
          refusal("content_completion_failed", Exception.message(error))
      end
    else
      nil -> refusal("not_found", "artifact not found")
      false -> refusal("content_completion_mismatch", "fetch completion does not match release")
      _ -> refusal("principal_required", "fetch completion requires an authenticated principal")
    end
  end

  @doc false
  def lookup_request(db \\ Tightbeam.DB, request) do
    case DB.query(
           db,
           """
           SELECT requestHash, artifactId FROM artifact_content_requests
           WHERE principalKind = ?1 AND principalId = ?2 AND operation = ?3
             AND idempotencyKey = ?4
           """,
           [
             request.principal_kind,
             request.principal_id,
             request.operation,
             request.idempotency_key
           ]
         ) do
      {:ok, []} ->
        :miss

      {:ok, [[hash, artifact_id]]} when hash == request.request_hash ->
        {:replay, Artifacts.get(db, artifact_id)}

      {:ok, [_]} ->
        {:error, refusal("idempotency_conflict", "idempotency key was used for another request")}
    end
  end

  defp replay_principal({:session, id}) when is_binary(id), do: {:ok, "session", id}
  defp replay_principal({:user, id}) when is_binary(id), do: {:ok, "user", id}
  defp replay_principal(_principal), do: :error

  @doc false
  def cas_path(base_dir, digest)
      when is_binary(base_dir) and is_binary(digest) and byte_size(digest) == 64 do
    Path.join([base_dir, "artifact-content", "sha256", binary_part(digest, 0, 2), digest])
  end

  defp validate_capture_options(opts) do
    required = [:artifact_id, :base_dir, :source_root, :relative_path, :principal]

    if Enum.all?(required, &(is_binary(opts[&1]) and opts[&1] != "")) do
      :ok
    else
      {:error, refusal("invalid", "artifact capture options are incomplete")}
    end
  end

  defp prepare_all(captures, common_opts) do
    Enum.reduce_while(captures, {:ok, []}, fn capture, {:ok, prepared} ->
      opts = Map.merge(common_opts, capture)

      result =
        with :ok <- validate_capture_options(opts),
             {:ok, staged} <- stage_from_custody(opts) do
          validation =
            with :ok <- validate_declared(staged, opts),
                 :ok <- validate_expected(staged, opts) do
              {:ok, %{blob: staged, opts: opts}}
            end

          case validation do
            {:ok, _item} = success ->
              success

            {:error, _refusal} = error ->
              File.rm(staged.path)
              error
          end
        end

      case result do
        {:ok, item} ->
          {:cont, {:ok, prepared ++ [item]}}

        {:error, refusal} ->
          Enum.each(prepared, &File.rm(&1.blob.path))
          {:halt, {:error, refusal}}
      end
    end)
  end

  defp configured_bytes(opts, key) do
    env_key =
      case key do
        :quota_bytes -> "TIGHTBEAM_ARTIFACT_CONTENT_QUOTA_BYTES"
        :reserved_free_bytes -> "TIGHTBEAM_ARTIFACT_CONTENT_RESERVED_FREE_BYTES"
      end

    value =
      case Map.fetch(opts, key) do
        {:ok, configured} ->
          configured

        :error ->
          application_key =
            case key do
              :quota_bytes -> :artifact_content_quota_bytes
              :reserved_free_bytes -> :artifact_content_reserved_free_bytes
            end

          Application.get_env(:tightbeam, application_key)
      end

    case value do
      integer when is_integer(integer) and integer >= 0 ->
        {:ok, integer}

      binary when is_binary(binary) ->
        case Integer.parse(binary) do
          {integer, ""} when integer >= 0 -> {:ok, integer}
          _ -> {:error, refusal("capture_preflight", "invalid #{env_key}")}
        end

      _ ->
        {:error, refusal("capture_preflight", "missing #{env_key}")}
    end
  end

  defp filesystem_preflight(_opts, 0), do: :ok

  defp filesystem_preflight(opts, reserved) do
    temp_dir = Path.join([opts.base_dir, "artifact-content", "tmp"])
    File.mkdir_p!(temp_dir)
    executable = Path.join([opts.base_dir, "bin", "tightbeam"])

    with {:ok, base} <- filesystem_stat(executable, opts.base_dir),
         {:ok, temp} <- filesystem_stat(executable, temp_dir),
         true <- base.device == temp.device,
         true <- temp.free_bytes >= reserved do
      :ok
    else
      false ->
        {:error, refusal("capture_preflight", "artifact content filesystem safety refused")}

      {:error, reason} ->
        {:error, refusal("capture_preflight", reason)}
    end
  end

  defp filesystem_stat(executable, path) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:args, ["artifact-content-stat", "--path", path]}
      ])

    receive_stat(port, [])
  rescue
    error in [ArgumentError, ErlangError] -> {:error, Exception.message(error)}
  end

  defp receive_stat(port, output) do
    receive do
      {^port, {:data, bytes}} ->
        receive_stat(port, [bytes | output])

      {^port, {:exit_status, 0}} ->
        encoded = output |> Enum.reverse() |> IO.iodata_to_binary()

        case JSON.decode(encoded) do
          {:ok, %{"device" => device, "freeBytes" => free_bytes}}
          when is_integer(device) and is_integer(free_bytes) ->
            {:ok, %{device: device, free_bytes: free_bytes}}

          _ ->
            {:error, "artifact content filesystem probe returned invalid data"}
        end

      {^port, {:exit_status, _status}} ->
        {:error, "artifact content filesystem probe failed"}
    after
      10_000 ->
        Port.close(port)
        {:error, "artifact content filesystem probe timed out"}
    end
  end

  defp stage_from_custody(opts) do
    temp_dir = Path.join([opts.base_dir, "artifact-content", "tmp"])
    File.mkdir_p!(temp_dir)
    temp_path = Path.join(temp_dir, "capture-" <> random_token())

    case File.open(temp_path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        try do
          with :ok <- File.chmod(temp_path, 0o600),
               {:ok, digest, size} <- stream_helper(opts, io),
               :ok <- :file.sync(io) do
            {:ok, %{path: temp_path, digest: digest, size: size}}
          else
            {:error, %{code: _} = refusal} -> {:error, refusal}
            {:error, reason} -> {:error, refusal("content_capture_failed", inspect(reason))}
          end
        after
          File.close(io)
        end
        |> case do
          {:ok, staged} ->
            {:ok, staged}

          error ->
            File.rm(temp_path)
            error
        end

      {:error, reason} ->
        {:error, refusal("content_capture_failed", "temporary file: #{reason}")}
    end
  end

  defp stream_helper(opts, io) do
    executable = Path.join([opts.base_dir, "bin", "tightbeam"])

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:args,
         [
           "artifact-custody-read",
           "--root",
           opts.source_root,
           "--path",
           opts.relative_path
         ]}
      ])

    receive_helper(port, io, :crypto.hash_init(:sha256), 0)
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, refusal("source_unavailable", Exception.message(error))}
  end

  defp receive_helper(port, io, hash, size) do
    receive do
      {^port, {:data, bytes}} ->
        next_size = size + byte_size(bytes)

        if next_size > @max_object_bytes do
          Port.close(port)
          {:error, refusal("content_too_large", "artifact exceeds 32 MiB")}
        else
          case :file.write(io, bytes) do
            :ok ->
              receive_helper(port, io, :crypto.hash_update(hash, bytes), next_size)

            {:error, reason} ->
              Port.close(port)
              {:error, refusal("content_capture_failed", "temporary write: #{reason}")}
          end
        end

      {^port, {:exit_status, 0}} ->
        {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower), size}

      {^port, {:exit_status, _status}} ->
        {:error, refusal("source_unavailable", "custody helper refused source")}
    after
      30_000 ->
        Port.close(port)
        {:error, refusal("source_unavailable", "custody helper timed out")}
    end
  end

  defp validate_declared(staged, %{declared_length: expected})
       when is_integer(expected) and expected >= 0 do
    if staged.size == expected,
      do: :ok,
      else: {:error, refusal("content_size_mismatch", "declared content length differs")}
  end

  defp validate_declared(_staged, _opts), do: :ok

  defp validate_expected(staged, %{expected_digest: expected}) when is_binary(expected) do
    if staged.digest == String.downcase(expected),
      do: :ok,
      else: {:error, refusal("content_digest_mismatch", "expected digest differs")}
  end

  defp validate_expected(_staged, _opts), do: :ok

  defp publish_staged_in_txn!(_txn, staged, opts) do
    target = cas_path(opts.base_dir, staged.digest)
    parent = Path.dirname(target)
    File.mkdir_p!(parent)

    case File.chmod(staged.path, 0o400) do
      :ok -> :ok
      {:error, reason} -> fail!("content_capture_failed", "CAS mode: #{reason}")
    end

    case File.ln(staged.path, target) do
      :ok ->
        File.rm!(staged.path)

        case sync_directory(parent) do
          :ok -> Map.put(staged, :path, target)
          {:error, reason} -> fail!("content_capture_failed", "CAS sync: #{reason}")
        end

      {:error, :eexist} ->
        File.rm!(staged.path)

        case verify_path(target, staged.digest, staged.size) do
          :ok ->
            Map.put(staged, :path, target)

          {:error, failure} ->
            raise CaptureReuseError,
              digest: staged.digest,
              failure: failure,
              principal: opts.principal
        end

      {:error, reason} ->
        File.rm(staged.path)
        fail!("content_capture_failed", "CAS publish: #{reason}")
    end
  end

  defp sync_directory(path) do
    with {:ok, io} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      try do
        :file.sync(io)
      after
        :file.close(io)
      end
    end
  end

  defp publish_and_persist_release(db, staged, quota, opts) do
    case DB.transaction(db, fn txn ->
           ensure_physical_quota!(staged, quota, opts.base_dir)
           blob = publish_staged_in_txn!(txn, staged, opts)
           ensure_blob_in_txn!(txn, blob)
           ensure_request_in_txn!(txn, opts)
           release_in_txn(txn, blob, opts)
           blob
         end) do
      {:ok, blob} ->
        {:ok, blob, Artifacts.get(db, opts.artifact_id)}

      {:error, error} when is_struct(error, CaptureReuseError) ->
        capture_reuse_refusal(db, error)

      {:error, error} when is_struct(error, CaptureError) ->
        {:error, refusal(error.code, error.message)}

      {:error, error} ->
        {:error, refusal("content_capture_failed", Exception.message(error))}
    end
  end

  defp persist_releases(db, prepared, quota) do
    case DB.transaction(db, fn txn ->
           Enum.map(prepared, fn %{blob: staged, opts: opts} ->
             ensure_physical_quota!(staged, quota, opts.base_dir)
             blob = publish_staged_in_txn!(txn, staged, opts)
             ensure_blob_in_txn!(txn, blob)
             release_in_txn(txn, blob, opts)
             %{blob: blob, opts: opts}
           end)
         end) do
      {:ok, blobs} ->
        {:ok, blobs, Enum.map(blobs, &Artifacts.get(db, &1.opts.artifact_id))}

      {:error, error} when is_struct(error, CaptureReuseError) ->
        capture_reuse_refusal(db, error)

      {:error, error} when is_struct(error, CaptureError) ->
        {:error, refusal(error.code, error.message)}

      {:error, error} ->
        {:error, refusal("content_capture_failed", Exception.message(error))}
    end
  end

  defp ensure_physical_quota!(blob, quota, base_dir) do
    target = cas_path(base_dir, blob.digest)

    already_present =
      case File.lstat(target) do
        {:ok, _stat} -> true
        {:error, :enoent} -> false
        {:error, reason} -> fail!("capture_preflight", "CAS target inventory: #{reason}")
      end

    used = physical_cas_bytes!(base_dir)

    if not already_present and used + blob.size > quota,
      do: fail!("content_quota_exceeded", "artifact content quota exceeded")
  end

  defp physical_cas_bytes!(base_dir) do
    root = Path.join([base_dir, "artifact-content", "sha256"])

    case File.ls(root) do
      {:ok, prefixes} ->
        Enum.reduce(prefixes, 0, fn prefix, total ->
          directory = Path.join(root, prefix)

          case File.lstat(directory) do
            {:ok, %File.Stat{type: :directory}} ->
              total + physical_cas_directory_bytes!(directory)

            {:ok, _stat} ->
              fail!("capture_preflight", "CAS inventory contains a non-directory prefix")

            {:error, reason} ->
              fail!("capture_preflight", "CAS prefix inventory: #{reason}")
          end
        end)

      {:error, :enoent} ->
        0

      {:error, reason} ->
        fail!("capture_preflight", "CAS inventory: #{reason}")
    end
  end

  defp physical_cas_directory_bytes!(directory) do
    case File.ls(directory) do
      {:ok, names} ->
        Enum.reduce(names, 0, fn name, total ->
          case File.lstat(Path.join(directory, name)) do
            {:ok, %File.Stat{type: :regular, size: size}} ->
              total + size

            {:ok, _stat} ->
              fail!("capture_preflight", "CAS inventory contains a non-regular object")

            {:error, reason} ->
              fail!("capture_preflight", "CAS object inventory: #{reason}")
          end
        end)

      {:error, reason} ->
        fail!("capture_preflight", "CAS directory inventory: #{reason}")
    end
  end

  defp capture_reuse_refusal(db, error) do
    case corrupt_shared(
           db,
           error.digest,
           error.failure,
           "capture-reuse",
           error.principal
         ) do
      :ok ->
        {:error,
         refusal(
           "content_corrupt",
           "existing CAS object failed #{error.failure} verification"
         )}

      {:error, _reason} ->
        {:error, refusal("corruption_transition_failed", "corruption transition failed")}
    end
  end

  defp ensure_blob_in_txn!(txn, blob) do
    now = now()

    DB.Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO artifact_blobs
        (digest, size, storageVersion, status, createdAt, verifiedAt)
      VALUES (?1, ?2, 1, 'verified', ?3, ?3)
      """,
      [blob.digest, blob.size, now]
    )

    case DB.Txn.q(
           txn,
           "SELECT size, status FROM artifact_blobs WHERE digest = ?1",
           [blob.digest]
         ) do
      [[size, "verified"]] when size == blob.size -> :ok
      [[_size, "corrupt"]] -> fail!("content_corrupt", "CAS digest is marked corrupt")
      _ -> fail!("content_conflict", "CAS digest metadata conflicts")
    end
  end

  defp ensure_request_in_txn!(_txn, %{request: nil}), do: :ok
  defp ensure_request_in_txn!(_txn, opts) when not is_map_key(opts, :request), do: :ok

  defp ensure_request_in_txn!(txn, opts) do
    request = opts.request

    case DB.Txn.q(
           txn,
           """
           SELECT requestHash, artifactId FROM artifact_content_requests
           WHERE principalKind = ?1 AND principalId = ?2 AND operation = ?3
             AND idempotencyKey = ?4
           """,
           [
             request.principal_kind,
             request.principal_id,
             request.operation,
             request.idempotency_key
           ]
         ) do
      [] ->
        DB.Txn.q(
          txn,
          """
          INSERT INTO artifact_content_requests
            (principalKind, principalId, operation, idempotencyKey, requestHash,
             artifactId, createdAt)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
          """,
          [
            request.principal_kind,
            request.principal_id,
            request.operation,
            request.idempotency_key,
            request.request_hash,
            opts.artifact_id,
            now()
          ]
        )

        :ok

      [[hash, artifact_id]]
      when hash == request.request_hash and artifact_id == opts.artifact_id ->
        :ok

      _ ->
        fail!("idempotency_conflict", "idempotency key was used for another request")
    end
  end

  # Sole released-state writer. No caller-supplied digest reaches this function;
  # it receives only the blob built from helper-streamed bytes above.
  defp release_in_txn(txn, blob, opts) do
    case DB.Txn.q(
           txn,
           """
           SELECT state, contentSha256, contentRecoverySha256
           FROM artifacts WHERE artifactId = ?1
           """,
           [opts.artifact_id]
         ) do
      [] ->
        fail!("not_found", "artifact not found")

      [["released", digest, _recovery]] when digest == blob.digest ->
        :ok

      [["released", _digest, _recovery]] ->
        fail!("content_conflict", "artifact already released with different bytes")

      [["corrupt-unavailable", _digest, recovery]] when recovery != blob.digest ->
        fail!("content_digest_mismatch", "recovery bytes differ from failed digest")

      [[state, _digest, _recovery]]
      when state in ["in-workspace", "archived", "legacy-unavailable", "corrupt-unavailable"] ->
        DB.Txn.q(
          txn,
          """
          UPDATE artifacts
          SET state = 'released', contentSha256 = ?2, contentSize = ?3,
              contentRecoverySha256 = NULL, unavailableReason = NULL,
              home = NULL, updatedAt = ?4
          WHERE artifactId = ?1 AND state = ?5
          """,
          [opts.artifact_id, blob.digest, blob.size, now(), state]
        )

        if DB.Txn.changes(txn) != 1,
          do: fail!("content_conflict", "artifact state changed during capture")

        EventLog.lifecycle_in_txn(
          txn,
          "artifact_content_released",
          opts.artifact_id,
          "digest=#{blob.digest} size=#{blob.size} principal=#{opts.principal}"
        )

        :ok
    end
  end

  defp request_replay(_db, %{request: nil}), do: :miss
  defp request_replay(_db, opts) when not is_map_key(opts, :request), do: :miss

  defp request_replay(db, opts) do
    request = opts.request

    case DB.query(
           db,
           """
           SELECT requestHash, artifactId FROM artifact_content_requests
           WHERE principalKind = ?1 AND principalId = ?2 AND operation = ?3
             AND idempotencyKey = ?4
           """,
           [
             request.principal_kind,
             request.principal_id,
             request.operation,
             request.idempotency_key
           ]
         ) do
      {:ok, []} ->
        :miss

      {:ok, [[hash, artifact_id]]}
      when hash == request.request_hash and artifact_id == opts.artifact_id ->
        {:replay, Artifacts.get(db, artifact_id)}

      {:ok, [_]} ->
        {:error, refusal("idempotency_conflict", "idempotency key was used for another request")}
    end
  end

  defp verify_after_release(db, blob, opts) do
    case verify_path(blob.path, blob.digest, blob.size) do
      :ok ->
        :ok

      {:error, failure} ->
        case corrupt_shared(db, blob.digest, failure, "post-release", opts.principal) do
          :ok ->
            {:error, refusal("content_corrupt", "released content failed verification")}

          {:error, _} ->
            {:error, refusal("corruption_transition_failed", "corruption transition failed")}
        end
    end
  end

  defp fetch_released(db, base_dir, artifact, principal, operation) do
    path = cas_path(base_dir, artifact.content_sha256)

    case File.open(path, [:read, :binary]) do
      {:ok, source} ->
        try do
          verify_to_private_descriptor(base_dir, source, artifact)
        after
          File.close(source)
        end
        |> case do
          {:ok, descriptor} ->
            {:ok,
             %{
               artifact_id: artifact.artifact_id,
               digest: artifact.content_sha256,
               size: artifact.content_size,
               fetch_id: "fetch_" <> random_token(),
               descriptor: descriptor
             }}

          {:error, failure} when failure in ~w(read size digest) ->
            fetch_corruption(db, artifact.content_sha256, failure, principal, operation)

          {:error, reason} ->
            {:error, refusal("content_fetch_failed", reason)}
        end

      {:error, :enoent} ->
        fetch_corruption(db, artifact.content_sha256, "missing", principal, operation)

      {:error, reason} when reason in [:eacces, :eperm] ->
        fetch_corruption(db, artifact.content_sha256, "permission", principal, operation)

      {:error, _reason} ->
        fetch_corruption(db, artifact.content_sha256, "open", principal, operation)
    end
  end

  defp verify_to_private_descriptor(base_dir, source, artifact) do
    temp_dir = Path.join([base_dir, "artifact-content", "tmp"])
    File.mkdir_p!(temp_dir)
    path = Path.join(temp_dir, "fetch-" <> random_token())

    case File.open(path, [:read, :write, :binary, :exclusive]) do
      {:ok, verification} ->
        result =
          with :ok <- File.chmod(path, 0o600),
               {:ok, digest, size} <-
                 copy_and_hash(source, verification, :crypto.hash_init(:sha256), 0),
               :ok <- verify_pair(digest, size, artifact),
               :ok <- File.rm(path),
               {:ok, 0} <- :file.position(verification, 0) do
            {:ok, verification}
          else
            {:error, failure} when failure in ~w(read size digest) -> {:error, failure}
            {:error, reason} -> {:error, "verification file: #{inspect(reason)}"}
          end

        case result do
          {:ok, descriptor} ->
            {:ok, descriptor}

          error ->
            File.close(verification)
            File.rm(path)
            error
        end

      {:error, reason} ->
        {:error, "verification file: #{reason}"}
    end
  end

  defp copy_and_hash(source, destination, hash, size) do
    case IO.binread(source, 64 * 1024) do
      :eof ->
        {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower), size}

      {:error, _reason} ->
        {:error, "read"}

      bytes ->
        case IO.binwrite(destination, bytes) do
          :ok ->
            copy_and_hash(
              source,
              destination,
              :crypto.hash_update(hash, bytes),
              size + byte_size(bytes)
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp verify_pair(_digest, size, %{content_size: expected}) when size != expected,
    do: {:error, "size"}

  defp verify_pair(digest, _size, %{content_sha256: expected}) when digest != expected,
    do: {:error, "digest"}

  defp verify_pair(_digest, _size, _artifact), do: :ok

  defp fetch_corruption(db, digest, failure, principal, operation) do
    case corrupt_shared(db, digest, failure, operation, principal) do
      :ok ->
        {:error, refusal("content_corrupt", "artifact content is corrupt")}

      {:error, _} ->
        {:error, refusal("corruption_transition_failed", "corruption transition failed")}
    end
  end

  defp verify_many_after_release(db, blobs) do
    Enum.reduce_while(blobs, :ok, fn %{blob: blob, opts: opts}, :ok ->
      case verify_after_release(db, blob, opts) do
        :ok -> {:cont, :ok}
        {:error, refusal} -> {:halt, {:error, refusal}}
      end
    end)
  end

  defp verify_path(path, expected_digest, expected_size) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case hash_io(io, :crypto.hash_init(:sha256), 0) do
            {:ok, _digest, size} when size != expected_size -> {:error, "size"}
            {:ok, digest, _size} when digest != expected_digest -> {:error, "digest"}
            {:ok, _digest, _size} -> :ok
            {:error, _reason} -> {:error, "read"}
          end
        after
          File.close(io)
        end

      {:error, :enoent} ->
        {:error, "missing"}

      {:error, reason} when reason in [:eacces, :eperm] ->
        {:error, "permission"}

      {:error, _reason} ->
        {:error, "open"}
    end
  end

  defp hash_io(io, hash, size) do
    case IO.binread(io, 64 * 1024) do
      :eof -> {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower), size}
      {:error, reason} -> {:error, reason}
      bytes -> hash_io(io, :crypto.hash_update(hash, bytes), size + byte_size(bytes))
    end
  end

  defp corrupt_shared(db, digest, failure, operation, principal) do
    case DB.transaction(db, fn txn ->
           corrupt_shared_in_txn!(txn, digest, failure, operation, principal)
           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp corrupt_shared_in_txn!(txn, digest, failure, operation, principal) do
    now = now()

    DB.Txn.q(
      txn,
      """
      UPDATE artifact_blobs
      SET status = 'corrupt', corruptAt = ?2, corruptReason = ?3
      WHERE digest = ?1 AND status = 'verified'
      """,
      [digest, now, "cas-" <> failure]
    )

    if DB.Txn.changes(txn) == 1 do
      ids =
        DB.Txn.q(
          txn,
          "SELECT artifactId FROM artifacts WHERE contentSha256 = ?1 ORDER BY artifactId",
          [digest]
        )
        |> List.flatten()

      DB.Txn.q(
        txn,
        """
        UPDATE artifacts
        SET state = 'corrupt-unavailable', contentRecoverySha256 = ?1,
            contentSha256 = NULL, contentSize = NULL,
            unavailableReason = ?2, home = NULL, updatedAt = ?3
        WHERE contentSha256 = ?1
        """,
        [digest, "cas-" <> failure, now]
      )

      EventLog.lifecycle_in_txn(
        txn,
        "artifact_content_corrupt",
        digest,
        "ids=#{Enum.join(ids, ",")} cause=cas-verification-failed " <>
          "failure=#{failure} operation=#{operation} principal=#{principal}"
      )
    end

    :ok
  end

  defp fail!(code, message), do: raise(CaptureError, code: code, message: message)
  defp refusal(code, message), do: %{code: code, message: message}
  defp random_token, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp now, do: System.system_time(:millisecond)
end
