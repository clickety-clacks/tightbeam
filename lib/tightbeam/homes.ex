defmodule Tightbeam.Homes do
  @moduledoc """
  Projects disposable harness homes from archetype guidance and extra files
  (TS reference: `src/homes/project.ts`). Credentials remain owned by
  `<base_dir>/auth/<harness>` and are only symlinked into generated homes.

  The auth store is written from exactly one place: the harvest-back that
  precedes a wipe. OAuth refresh tokens ROTATE on use, and the harness
  refreshes by write-temp-then-rename — which replaces our symlink with a
  regular file, leaving the home holding the only live credential lineage
  while the store's copy is silently dead. A wipe that discarded it would
  brick the login ("OAuth session expired and could not be refreshed" —
  this shipped once). So regeneration first copies any regular-file auth
  entry back over its store source, then wipes, then relinks.

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

  @typedoc """
  A structured harness-home projection input. `skills` is the archetype's
  election; every entry projects the same way — a symlink at
  `skills/<name>` pointing at `link_to`, the electing HOST's library
  replica (local library for local homes; the satellite's replica path for
  staged homes — dangling in staging by design, valid on arrival). One
  mode everywhere: content updates flow through the replica, never through
  home regeneration.
  """
  @type skill_ref :: %{name: String.t(), link_to: String.t()}
  @type spec :: %{
          required(:harness) => :claude | :codex,
          required(:archetype) => String.t(),
          required(:guidance) => String.t(),
          optional(:skills) => [skill_ref()],
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
  are topped up. A wipe harvests rotated credentials back to the auth store
  first (see moduledoc).
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
      harvest_auth_back(auth_dir, home_path)
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

    project_skills(home_path, Map.get(spec, :skills, []))

    %{
      home_path: home_path,
      instructions_file: instructions_path,
      linked_auth_files: link_auth(auth_dir, home_path)
    }
  end

  # Skills project OUTSIDE the hash gate on every call: idempotent symlinks
  # into the host's library replica (content lives there — editing a skill
  # updates every electing home live, which is exactly why content is not
  # in the manifest hash). A wrong-target or non-link entry is replaced —
  # the skills dir is substrate-managed, and re-pointing is how a home
  # follows a moved replica.
  defp project_skills(_home_path, []), do: :ok

  defp project_skills(home_path, skills) do
    skills_root = Path.join(home_path, "skills")
    File.mkdir_p!(skills_root)

    for %{name: name, link_to: link_to} <- skills do
      target = Path.join(skills_root, name)

      case File.read_link(target) do
        {:ok, ^link_to} ->
          :ok

        _ ->
          File.rm_rf!(target)
          File.ln_s!(link_to, target)
      end
    end

    :ok
  end

  # An auth entry that is a REGULAR file in the home (not our symlink) was
  # rotated in place by the harness and is the only live copy of that
  # credential — copy it back over its store source before the wipe (see
  # moduledoc). Symlinks and absent entries mean the store is still current.
  defp harvest_auth_back(auth_dir, home_path) do
    case File.ls(auth_dir) do
      {:ok, files} ->
        for file <- files do
          home_file = Path.join(home_path, file)

          with {:ok, %File.Stat{type: :regular}} <- File.lstat(home_file) do
            File.cp!(home_file, Path.join(auth_dir, file))
          end
        end

        :ok

      {:error, :enoent} ->
        :ok
    end
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

    # Election only — a skill's CONTENT is reachable through the projection
    # (symlink/copy) and updating it must never cost a home its nested
    # harness state.
    skills =
      spec
      |> Map.get(:skills, [])
      |> Enum.map(&[&1.name, 0])
      |> Enum.sort()

    :crypto.hash(:sha256, [Atom.to_string(spec.harness), 0, spec.guidance, 0, extra, 0, skills])
    |> Base.encode16(case: :lower)
  end
end
