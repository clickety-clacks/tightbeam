defmodule Tightbeam.Homes do
  @moduledoc """
  Projects one generic shared home per `{harness, machine}`.

  Tight Beam owns exactly the credential entry, the harness rails artifact,
  and `.tightbeam/`. Regeneration is ownership-scoped: it never removes the
  home and therefore preserves harness-owned sessions, history, projects,
  transcripts, and memory byte-for-byte.

  Callers gate regeneration on a stopped runtime. Before replacing a
  credential entry, a regular file left by runtime rotation is harvested
  back to the Tight-Beam-owned store, then the fresh store link is restored.
  Homes never mint or otherwise write credential contents.
  """

  @type harness :: :claude | :codex
  @type spec :: %{
          required(:harness) => harness(),
          required(:machine) => String.t(),
          optional(:rails) => binary() | nil
        }

  @type projected_home :: %{
          home_path: String.t(),
          manifest_path: String.t(),
          linked_auth_files: [String.t()]
        }

  @manifest_relative Path.join(".tightbeam", "manifest")

  @doc "The old home-skill baseline no longer projects into shared homes."
  @spec baseline_skill_names() :: [String.t()]
  def baseline_skill_names, do: []

  @doc "Project or ownership-scope-regenerate a shared home."
  @spec project(String.t(), spec()) :: projected_home()
  def project(base_dir, spec) do
    home = home_path(base_dir, spec.machine, spec.harness)
    auth_dir = auth_dir(base_dir, spec.harness)
    manifest_path = Path.join(home, @manifest_relative)
    manifest = manifest_bytes(spec)

    File.mkdir_p!(home)

    unless File.read(manifest_path) == {:ok, manifest} do
      harvest_auth_back(auth_dir, home, spec.harness)
      remove_owned_projection(home, spec.harness)
      write_rails(home, spec.harness, Map.get(spec, :rails))
      File.mkdir_p!(Path.dirname(manifest_path))
      File.write!(manifest_path, manifest)
    end

    %{
      home_path: home,
      manifest_path: manifest_path,
      linked_auth_files: link_auth(auth_dir, home, spec.harness)
    }
  end

  @doc "Canonical manifest bytes for the owned projection."
  @spec manifest_bytes(spec()) :: binary()
  def manifest_bytes(spec) do
    JSON.encode!(%{
      "harness" => Atom.to_string(spec.harness),
      "machine" => spec.machine,
      "rails_sha256" => digest(Map.get(spec, :rails))
    })
  end

  @doc """
  Harvest a runtime-rotated regular credential into the backing store.

  This is a stopped-runtime lifecycle operation. It never discovers or
  imports credentials from a user's personal harness installation.
  """
  @spec sweep_auth(String.t(), harness()) :: :ok
  def sweep_auth(base_dir, harness) do
    auth_dir = auth_dir(base_dir, harness)
    File.mkdir_p!(auth_dir)

    base_dir
    |> Path.join("homes/*/#{Atom.to_string(harness)}")
    |> Path.wildcard()
    |> Enum.each(&harvest_auth_back(auth_dir, &1, harness))

    :ok
  end

  @doc "Canonical shared home path."
  @spec home_path(String.t(), String.t(), harness()) :: String.t()
  def home_path(base_dir, machine, harness),
    do: Path.join([base_dir, "homes", machine, Atom.to_string(harness)])

  defp auth_dir(base_dir, harness),
    do: Path.join([base_dir, "auth", Atom.to_string(harness)])

  defp remove_owned_projection(home, harness) do
    File.rm_rf!(Path.join(home, ".tightbeam"))
    File.rm_rf!(Path.join(home, rails_filename(harness)))

    credential_names(harness)
    |> Enum.each(&File.rm(Path.join(home, &1)))
  end

  defp write_rails(_home, _harness, nil), do: :ok

  defp write_rails(home, harness, content) do
    File.write!(Path.join(home, rails_filename(harness)), content)
  end

  defp harvest_auth_back(auth_dir, home, harness) do
    auth_dir
    |> credential_store_files(harness)
    |> Enum.each(fn file ->
      entry = Path.join(home, file)

      case File.lstat(entry) do
        {:ok, %File.Stat{type: :regular}} ->
          File.cp!(entry, Path.join(auth_dir, file))
          File.chmod!(Path.join(auth_dir, file), 0o600)

        _ ->
          :ok
      end
    end)
  end

  defp link_auth(auth_dir, home, harness) do
    auth_dir
    |> credential_store_files(harness)
    |> Enum.map(fn file ->
      source = Path.join(auth_dir, file)
      target = Path.join(home, file)

      case File.lstat(target) do
        {:error, :enoent} -> File.ln_s!(source, target)
        _ -> :ok
      end

      file
    end)
  end

  defp credential_store_files(auth_dir, harness) do
    case File.ls(auth_dir) do
      {:ok, files} -> files |> Enum.filter(&(&1 in credential_names(harness))) |> Enum.sort()
      {:error, :enoent} -> []
    end
  end

  defp credential_names(:codex), do: ["auth.json"]
  defp credential_names(:claude), do: ["oauth-token"]

  defp rails_filename(:codex), do: "hooks.json"
  defp rails_filename(:claude), do: "settings.json"

  defp digest(nil), do: nil

  defp digest(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
