defmodule Tightbeam.LiveBaseAdmission do
  @moduledoc false
  require Logger
  alias Tightbeam.{LiveBaseGuard, Schema}

  defmodule Refusal do
    defexception [:message]
  end

  # Reread before a handoff/write. This remains an observation, not a public
  # permission flag. The eventual DB owner retains its own context and must
  # also recheck inside migration.
  def revalidate!(previous) do
    current =
      prepare!(
        previous.base,
        [payload_root: previous.payload_root, transition: previous.transition],
        false
      )

    if current.files != previous.files and current.manifest_problem == :mismatch,
      do: refuse!("payload_manifest_mismatch before write")

    fields = [
      :base,
      :payload_root,
      :files,
      :marker,
      :stamp,
      :identity,
      :manifest_status,
      :manifest_observation,
      :manifest_problem,
      :decision
    ]

    unless Map.take(current, fields) == Map.take(previous, fields),
      do: refuse!("admission inputs changed before write")

    current
  end

  # DB-owner call after successful migrations. Schema rows come from that
  # owner's connection; file publication is not claimed atomic with SQLite.
  def publish_marker!(previous, rows) do
    :ok = validate_owned_files!(previous)

    unless rows == [[hd(Schema.guard_compatible_stamps())]],
      do: refuse!("schema migration did not reach the current target stamp")

    marker = %{"format" => "tightbeam-build-owner/v1", "buildIdentity" => previous.identity}
    path = Path.join(previous.base, "build-owner.json")

    unless previous.marker == marker do
      temporary = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      {:ok, :ok} =
        File.open(temporary, [:write, :exclusive, :binary], fn file ->
          :ok = IO.binwrite(file, JSON.encode!(marker))
          :file.sync(file)
        end)

      :ok = File.rename(temporary, path)
    end

    decision =
      checked!(
        LiveBaseGuard.admit_build(previous.base, previous.identity, marker, :existing, nil)
      )

    %{previous | marker: marker, stamp: rows, decision: decision, transition: nil}
  end

  def validate_owned_files!(previous) do
    unless canonical!(previous.base) == previous.base and
             canonical!(previous.payload_root) == previous.payload_root,
           do: refuse!("guard paths changed after admission")

    files = payload_files!(previous.payload_root)

    manifest = observed_manifest!(previous.payload_root, files)

    unless files == previous.files and manifest.identity == previous.identity and
             manifest.status == previous.manifest_status and
             manifest.observation == previous.manifest_observation and
             manifest.problem == previous.manifest_problem,
      do: refuse!("payload changed after admission")

    path = Path.join(previous.base, "build-owner.json")

    marker =
      case File.lstat(path) do
        {:error, :enoent} ->
          :absent

        {:ok, %{type: :regular}} ->
          path |> File.read!() |> LiveBaseGuard.decode_marker() |> checked!()

        other ->
          refuse!("invalid marker file: #{inspect(other)}")
      end

    unless marker == previous.marker, do: refuse!("marker changed after admission")
    :ok
  end

  # Options name immutable inputs, never a verified/admitted Boolean. The
  # manifest cannot choose the observed file set. No base writes occur here.
  def prepare!(base, options), do: prepare!(base, options, true)

  defp prepare!(base, options, warn_unverified?) do
    base = canonical!(Path.expand(base))
    payload = canonical!(Keyword.fetch!(options, :payload_root))
    files = payload_files!(payload)
    manifest = observed_manifest!(payload, files)

    # Reread the payload after the first observation: a set that changed under
    # us is dirt to report, not a race to serialize away.
    observed = payload_files!(payload)
    current_manifest = observed_manifest!(payload, observed)

    unless observed == files and current_manifest == manifest,
           do: refuse!("payload changed during admission")

    if warn_unverified? and manifest.status == :unverified do
      Logger.warning("build identity could not be verified from build-manifest.json")
    end

    identity = manifest.identity

    marker_path = Path.join(base, "build-owner.json")

    marker =
      case File.lstat(marker_path) do
        {:error, :enoent} ->
          :absent

        {:ok, %{type: :regular}} ->
          marker_path |> File.read!() |> LiveBaseGuard.decode_marker() |> checked!()

        other ->
          refuse!("invalid marker file: #{inspect(other)}")
      end

    state = observe_base!(base, marker)

    database = Path.join(base, "state.db")

    transition =
      case Keyword.get(options, :transition) do
        nil ->
          nil

        bytes when is_binary(bytes) ->
          bytes
          |> LiveBaseGuard.decode_transition()
          |> checked!()
          |> Map.update!("base", &canonical!/1)

        _ ->
          refuse!("transition must be exact serialized input")
      end

    source_marker =
      case marker do
        :absent ->
          :absent

        %{"buildIdentity" => source} when source != identity ->
          marker

        _ ->
          nil
      end

    transition =
      if transition == nil and state == :existing and source_marker != nil and
           manifest.status == :verified and
           (source_marker == :absent or
              Tightbeam.LiveBaseRelease.automatic_transition_candidate?(payload)) do
        stamp = read_schema_stamp!(database)

        case Tightbeam.LiveBaseRelease.automatic_transition(
               payload,
               base,
               identity,
               stamp,
               source_marker
             ) do
          {:ok, generated} -> generated
          :none -> nil
        end
      else
        transition
      end

    admission = checked!(LiveBaseGuard.admit_build(base, identity, marker, state, transition))
    stamp = qualify_readonly!(database, state, admission)

    %{
      base: base,
      transition: Keyword.get(options, :transition),
      decision: admission,
      stamp: stamp,
      identity: manifest.identity,
      payload_root: payload,
      files: files,
      marker: marker,
      manifest_status: manifest.status,
      manifest_observation: manifest.observation,
      manifest_problem: manifest.problem
    }
  end

  defp observed_manifest!(payload, files) do
    actual = checked!(LiveBaseGuard.generate_manifest(files))["buildIdentity"]
    path = Path.join(payload, "build-manifest.json")

    case File.lstat(path) do
      {:error, :enoent} ->
        unverified_manifest(actual, :missing, :missing)

      {:error, reason} ->
        unverified_manifest(actual, {:unreadable, reason}, :unreadable)

      {:ok, %{type: :regular}} ->
        read_manifest!(path, files, actual)

      {:ok, %{type: :symlink}} ->
        case File.stat(path) do
          {:ok, %{type: :regular}} -> read_manifest!(path, files, actual)

          {:error, reason} when reason in [:eacces, :eperm] ->
            unverified_manifest(actual, {:unreadable, reason}, :unreadable)

          other ->
            refuse!("invalid build manifest file: #{inspect(other)}")
        end

      {:ok, %{type: type}} ->
        refuse!("invalid build manifest file: #{inspect(type)}")
    end
  end

  defp read_manifest!(path, files, actual) do
    case File.read(path) do
      {:ok, bytes} ->
        observation = {:readable, digest(bytes)}

        case JSON.decode(bytes) do
          {:ok, manifest} ->
            case LiveBaseGuard.verify_manifest(manifest, files) do
              {:ok, identity} ->
                %{status: :verified, identity: identity, observation: observation, problem: nil}

              {:error, _reason} ->
                unverified_manifest(actual, observation, :mismatch)
            end

          {:error, _reason} ->
            unverified_manifest(actual, observation, :mismatch)
        end

      {:error, reason} ->
        unverified_manifest(actual, {:unreadable, reason}, :unreadable)
    end
  end

  defp unverified_manifest(identity, observation, problem) do
    %{status: :unverified, identity: identity, observation: observation, problem: problem}
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # Onboarding, CLI provisioning and launchers write neighboring files before
  # first boot. Only the DB and marker determine whether history already exists.
  # Do not inspect neighboring entries. Their validation belongs to their owners.
  # lstat keeps a dangling DB link from being mistaken for an absent database.
  defp observe_base!(base, marker) do
    case File.lstat(Path.join(base, "state.db")) do
      {:error, :enoent} when marker == :absent ->
        :new_empty

      {:error, :enoent} ->
        :existing

      {:ok, _} ->
        :existing

      other ->
        refuse!("invalid persistent database: #{inspect(other)}")
    end
  end

  defp qualify_readonly!(path, state, admission) do
    case File.lstat(path) do
      {:error, :enoent} when state == :new_empty ->
        :fresh

      {:ok, %{type: :regular}} ->
        rows = read_schema_stamp!(path)
        :ok = Schema.qualify_guard_stamp!(admission, rows)
        rows

      other ->
        refuse!("invalid persistent database: #{inspect(other)}")
    end
  end

  # A plain read-only observation of the stamp, nothing more. Every sidecar the
  # connection may touch must already be an ordinary file: a symlink here would
  # let an unadmitted base redirect the read at a target outside it, so refuse
  # rather than open. A read-only connection cannot checkpoint or write the main
  # database or committed WAL frames; it may create only the SHM.
  defp read_schema_stamp!(path) do
    alias Exqlite.Sqlite3

    for file <- [path, path <> "-wal", path <> "-shm", path <> "-journal"] do
      case File.lstat(file) do
        {:ok, %{type: :regular}} -> :ok
        {:error, :enoent} -> :ok
        other -> raise "schema inspection file refused: #{inspect(other)}"
      end
    end

    {:ok, conn} = Sqlite3.open(path, mode: :readonly)

    try do
      Tightbeam.DB.run_query(conn, "SELECT shape FROM schema_stamp", [])
    after
      :ok = Sqlite3.close(conn)
    end
  end

  def payload_files!(root) do
    Tightbeam.LiveBasePayload.files!(root)
  rescue
    error -> refuse!(Exception.message(error))
  end

  # Resolve existing ancestors, including aliases of a not-yet-created base.
  # Bound link traversal; do not create any missing component.
  def canonical!(path), do: canonical!(Path.expand(path), 40)
  defp canonical!(_path, 0), do: refuse!("excessive path links")
  defp canonical!("/", _remaining), do: "/"

  defp canonical!(path, remaining) do
    parent = canonical!(Path.dirname(path), remaining - 1)
    resolved = Path.join(parent, Path.basename(path))

    case File.lstat(resolved) do
      {:ok, %{type: :symlink}} ->
        target = File.read_link!(resolved)
        canonical!(Path.expand(target, parent), remaining - 1)

      {:ok, _} ->
        resolved

      {:error, :enoent} ->
        resolved

      other ->
        refuse!("unreadable path: #{inspect(other)}")
    end
  end

  defp checked!({:ok, value}), do: value
  defp checked!({:error, reason}), do: refuse!(inspect(reason))
  defp refuse!(message), do: raise(Refusal, message: message)
end
