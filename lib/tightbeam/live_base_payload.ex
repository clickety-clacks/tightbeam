defmodule Tightbeam.LiveBasePayload do
  @moduledoc false
  alias Tightbeam.LiveBaseGuard

  # Layout comes from the actual application directory, never RELEASE_ROOT or
  # a manifest-supplied path list. Packaged closure includes every shipped file.
  def files!(app) do
    app = Path.expand(app)
    directory_chain!(app)
    lib = Path.dirname(app)
    release = Path.dirname(lib)

    if Path.basename(lib) == "lib" and Path.basename(release) == "release" do
      root = Path.dirname(release)
      required!(root, "package.json", :regular)
      required!(root, "bin/tightbeam", :regular)
      required!(root, "bin/tightbeam-gateway", :regular)
      required!(root, "release", :directory)
      required!(app, "ebin", :directory)
      required!(app, "priv", :directory)
      excluded = Path.relative_to(Path.join(app, "build-manifest.json"), root)
      enumerate!(root, "", excluded)
    else
      Enum.flat_map(["ebin", "priv", "config"], fn name ->
        case File.lstat(Path.join(app, name)) do
          {:error, :enoent} when name == "config" -> []
          {:ok, %{type: :directory}} -> enumerate!(app, name, "build-manifest.json")
          other -> raise "invalid application payload root #{name}: #{inspect(other)}"
        end
      end)
    end
  end

  def application!(root) do
    root = Path.expand(root)
    directory_chain!(root)
    apps = Path.wildcard(Path.join(root, "release/lib/tightbeam-*/ebin/tightbeam.app"))

    case apps do
      [app] ->
        path = app |> Path.dirname() |> Path.dirname()
        required!(root, Path.relative_to(path, root), :directory)
        path

      _ ->
        raise "package requires exactly one Tightbeam application"
    end
  end

  def generate!(root) do
    app = application!(root)
    {:ok, manifest} = LiveBaseGuard.generate_manifest(files!(app))
    path = Path.join(app, "build-manifest.json")

    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular}} -> :ok
      other -> raise "invalid manifest output: #{inspect(other)}"
    end

    temporary = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    try do
      File.write!(temporary, JSON.encode!(manifest), [:exclusive])
      File.rename!(temporary, path)
    after
      if File.regular?(temporary), do: File.rm!(temporary)
    end

    verify!(root)
  end

  def verify!(root) do
    app = application!(root)
    required!(app, "build-manifest.json", :regular)
    manifest = app |> Path.join("build-manifest.json") |> File.read!() |> JSON.decode!()

    case LiveBaseGuard.verify_manifest(manifest, files!(app)) do
      {:ok, identity} -> identity
      {:error, reason} -> raise "package manifest refused: #{inspect(reason)}"
    end
  end

  defp required!(root, relative, type) do
    # Check each component, not only the final path.
    Enum.reduce(Path.split(relative), root, fn part, parent ->
      path = Path.join(parent, part)
      expected = if path == Path.join(root, relative), do: type, else: :directory
      unless File.lstat!(path).type == expected, do: raise("invalid payload path: #{path}")
      path
    end)
  end

  defp directory_chain!("/"), do: :ok

  defp directory_chain!(path) do
    directory_chain!(Path.dirname(path))
    unless File.lstat!(path).type == :directory, do: raise("invalid payload ancestor: #{path}")
  end

  defp enumerate!(root, relative, relative) do
    unless File.lstat!(Path.join(root, relative)).type == :regular,
      do: raise("invalid manifest file")

    []
  end

  defp enumerate!(root, relative, excluded) do
    path = Path.join(root, relative)

    case File.lstat!(path).type do
      :directory ->
        path
        |> File.ls!()
        |> Enum.sort()
        |> Enum.flat_map(&enumerate!(root, Path.join(relative, &1), excluded))

      :regular ->
        [{relative, File.read!(path)}]

      other ->
        raise "nonregular payload file #{relative}: #{inspect(other)}"
    end
  end
end
