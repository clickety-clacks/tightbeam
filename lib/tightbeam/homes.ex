defmodule Tightbeam.Homes do
  @moduledoc """
  Projects disposable harness homes from archetype guidance and extra files
  (TS reference: `src/homes/project.ts`). Credentials remain owned by
  `<base_dir>/auth/<harness>` and are only symlinked into generated homes;
  regeneration never writes to or deletes the auth source.

  Projection is IDEMPOTENT, gated on a manifest hash stamped into the home
  (spec: homes are regenerated on IDENTITY CHANGE, never on process restart).
  This gate is load-bearing: harnesses nest their session state (transcripts,
  session files) INSIDE the config dir we project, so an unconditional
  delete-and-rebuild would destroy every session's conversational memory on
  each adapter restart. Unchanged manifest → the home is left alone except
  for topping up missing auth symlinks; changed manifest → full delete +
  reassemble + relink (which forfeits nested harness state by design — an
  identity change is a new agent body).
  """

  @typedoc "A structured harness-home projection input."
  @type spec :: %{
          required(:harness) => :claude | :codex,
          required(:archetype) => String.t(),
          required(:guidance) => String.t(),
          optional(:extra_files) => %{optional(String.t()) => String.t()}
        }

  @typedoc "The generated home paths and auth entries linked into it."
  @type projected_home :: %{
          home_path: String.t(),
          instructions_file: String.t(),
          linked_auth_files: [String.t()]
        }

  @stamp_file ".tightbeam-manifest"

  @doc """
  Projects one home from its spec: the harness instruction file, extra files,
  and symlinks for every harness auth entry. Idempotent via the manifest-hash
  stamp (see moduledoc): an unchanged spec never deletes the home — nested
  harness session state survives restarts — and only missing auth symlinks
  are topped up. The auth source is never modified.
  """
  @spec project(String.t(), spec()) :: projected_home()
  def project(base_dir, spec) do
    harness = spec.harness
    home_path = Path.join([base_dir, "homes", spec.archetype, Atom.to_string(harness)])
    auth_dir = Path.join([base_dir, "auth", Atom.to_string(harness)])
    stamp_path = Path.join(home_path, @stamp_file)
    hash = manifest_hash(spec)

    instructions_file = if harness == :claude, do: "CLAUDE.md", else: "AGENTS.md"
    instructions_path = Path.join(home_path, instructions_file)

    unless File.exists?(stamp_path) and File.read!(stamp_path) == hash do
      File.rm_rf!(home_path)
      File.mkdir_p!(home_path)
      File.write!(instructions_path, spec.guidance)

      for {relative_path, content} <- Map.get(spec, :extra_files, %{}) do
        absolute_path = Path.join(home_path, relative_path)
        File.mkdir_p!(Path.dirname(absolute_path))
        File.write!(absolute_path, content)
      end

      File.write!(stamp_path, hash)
    end

    %{
      home_path: home_path,
      instructions_file: instructions_path,
      linked_auth_files: link_auth(auth_dir, home_path)
    }
  end

  # Top up symlinks for any auth entry not yet linked (idempotent; never
  # replaces an existing entry, never touches the auth source).
  defp link_auth(auth_dir, home_path) do
    case File.ls(auth_dir) do
      {:ok, files} ->
        for file <- files do
          link = Path.join(home_path, file)

          case File.lstat(link) do
            {:error, :enoent} -> File.ln_s!(Path.join(auth_dir, file), link)
            _ -> :ok
          end

          file
        end

      {:error, :enoent} ->
        []
    end
  end

  defp manifest_hash(spec) do
    extra =
      spec |> Map.get(:extra_files, %{}) |> Enum.sort() |> Enum.map(fn {k, v} -> [k, 0, v, 0] end)

    :crypto.hash(:sha256, [Atom.to_string(spec.harness), 0, spec.guidance, 0, extra])
    |> Base.encode16(case: :lower)
  end
end
