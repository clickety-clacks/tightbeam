defmodule Tightbeam.LiveBaseAdmission do
  @moduledoc false
  alias Tightbeam.{LiveBaseGuard, LiveBaseLock, Schema}

  defmodule Refusal do
    defexception [:message]
  end

  # Options name immutable inputs, never a verified/admitted Boolean. The
  # manifest cannot choose the observed file set. No base writes occur here.
  def prepare!(base, options), do: prepare_locked!(base, options, nil)

  # Reread before a handoff/write, without releasing or reacquiring exclusion.
  # This remains an observation, not a public permission flag. The eventual
  # DB owner retains its own context and must also recheck inside migration.
  def revalidate!(previous) do
    current =
      prepare_locked!(
        previous.base,
        [
          payload_root: previous.payload_root,
          lock_dir: previous.lock_dir,
          transition: previous.transition
        ],
        previous.lock
      )

    fields = [:base, :payload_root, :files, :marker, :stamp, :identity, :decision]

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
             canonical!(previous.payload_root) == previous.payload_root and
             canonical!(previous.lock_dir) == previous.lock_dir,
           do: refuse!("guard paths changed after admission")

    key = :crypto.hash(:sha256, previous.base) |> Base.encode16(case: :lower)

    case LiveBaseLock.assert_path(previous.lock, Path.join(previous.lock_dir, key <> ".lock")) do
      :ok -> :ok
      {:error, reason} -> refuse!(inspect(reason))
    end

    files = payload_files!(previous.payload_root)

    manifest =
      previous.payload_root |> Path.join("build-manifest.json") |> File.read!() |> JSON.decode!()

    identity = checked!(LiveBaseGuard.verify_manifest(manifest, files))

    unless files == previous.files and identity == previous.identity,
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

  defp prepare_locked!(base, options, held_lock) do
    base = canonical!(Path.expand(base))
    payload = canonical!(Keyword.fetch!(options, :payload_root))
    files = payload_files!(payload)
    manifest = payload |> Path.join("build-manifest.json") |> File.read!() |> JSON.decode!()
    identity = checked!(LiveBaseGuard.verify_manifest(manifest, files))
    lock_dir = canonical!(Keyword.fetch!(options, :lock_dir))

    if lock_dir == base or String.starts_with?(lock_dir, base <> "/"),
      do: refuse!("lock directory inside base")

    stat = File.lstat!(lock_dir)

    if stat.type != :directory or Bitwise.band(stat.mode, 0o777) != 0o700,
      do: refuse!("lock directory must already be private mode0700")

    key = :crypto.hash(:sha256, base) |> Base.encode16(case: :lower)
    lock_path = Path.join(lock_dir, key <> ".lock")

    lock =
      if held_lock do
        case LiveBaseLock.assert_path(held_lock, lock_path) do
          :ok -> held_lock
          {:error, reason} -> refuse!(inspect(reason))
        end
      else
        checked!(LiveBaseLock.acquire(lock_path))
      end

    try do
      # Payload checks also run under exclusion, not only before acquisition.
      observed = payload_files!(payload)

      current_manifest =
        payload |> Path.join("build-manifest.json") |> File.read!() |> JSON.decode!()

      unless observed == files and
               checked!(LiveBaseGuard.verify_manifest(current_manifest, observed)) == identity,
             do: refuse!("payload changed during admission")

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

      state =
        case File.ls(base) do
          {:error, :enoent} -> :new_empty
          {:ok, []} -> :new_empty
          {:ok, _} -> :existing
          other -> refuse!("invalid base: #{inspect(other)}")
        end

      transition =
        case Keyword.get(options, :transition) do
          nil -> nil
          bytes when is_binary(bytes) -> checked!(LiveBaseGuard.decode_transition(bytes))
          _ -> refuse!("transition must be exact serialized input")
        end

      admission = checked!(LiveBaseGuard.admit_build(base, identity, marker, state, transition))
      database = Path.join(base, "state.db")
      stamp = qualify_readonly!(database, state, admission, lock)

      %{
        base: base,
        lock: lock,
        lock_dir: lock_dir,
        transition: Keyword.get(options, :transition),
        decision: admission,
        stamp: stamp,
        identity: identity,
        payload_root: payload,
        files: files,
        marker: marker
      }
    rescue
      error ->
        if is_nil(held_lock), do: :ok = LiveBaseLock.release(lock)
        reraise error, __STACKTRACE__
    end
  end

  defp qualify_readonly!(path, state, admission, lock) do
    case File.lstat(path) do
      {:error, :enoent} when state == :new_empty ->
        :fresh

      {:ok, %{type: :regular}} ->
        rows = LiveBaseLock.inspect_schema!(lock, path)
        :ok = Schema.qualify_guard_stamp!(admission, rows)
        rows

      other ->
        refuse!("invalid persistent database: #{inspect(other)}")
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
