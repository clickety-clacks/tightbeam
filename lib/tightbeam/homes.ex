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

  Projection is IDEMPOTENT, gated on a readable projection manifest stamped into the home
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
  election. The substrate baseline is prepended to that election, and every
  entry projects the same way — a symlink at `skills/<name>` pointing at
  `link_to`. Baseline links point into the substrate's shipped `priv`; elected
  links point into the electing HOST's library replica (local library for
  local homes; the satellite's replica path for staged homes — dangling in
  staging by design, valid on arrival). One mode everywhere: content updates
  flow through the linked source, never through home regeneration.
  """
  @type skill_ref :: %{
          name: String.t(),
          link_to: String.t(),
          provenance: String.t(),
          linkage: String.t()
        }
  @type spec :: %{
          required(:harness) => :claude | :codex,
          required(:archetype) => String.t(),
          required(:base_archetype) => String.t(),
          required(:parent_source) => %{file: String.t(), sha256: String.t()} | nil,
          required(:guidance) => String.t(),
          optional(:identity_sha256) => String.t(),
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
  @known_credential_files [".credentials.json", "oauth-token", "auth.json"]

  # Namespace invariant: this ordered set is the one substrate baseline truth.
  # It projects before org elections, and its names are reserved from org skill
  # libraries; when an election overlaps, the substrate entry wins the one slot.
  @baseline_skill_names [
    "tightbeam-dispatching",
    "tightbeam-assimilate",
    "tightbeam-harnesses",
    "tightbeam-skills",
    "tightbeam-onboarding",
    "tightbeam-guidance-authoring",
    "tightbeam-law-minting",
    "tightbeam-archetype-cultivation",
    "tightbeam-kungfu-crafting"
  ]

  @doc "Ordered names reserved for the substrate skills baseline."
  @spec baseline_skill_names() :: [String.t()]
  def baseline_skill_names, do: @baseline_skill_names

  @doc """
  Projects one home from its spec: the harness instruction file, extra files,
  and symlinks for every harness auth entry. Idempotent via the projection manifest
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
    extra_files = projected_extra_files(base_dir, spec)
    manifest = manifest_bytes(Map.put(spec, :extra_files, extra_files))
    guard_identity_collision!(stamp_path, spec.archetype, Map.get(spec, :identity_sha256))

    instructions_file = if harness == :claude, do: "CLAUDE.md", else: "AGENTS.md"
    instructions_path = Path.join(home_path, instructions_file)

    unless File.read(stamp_path) == {:ok, manifest} do
      harvest_auth_back(auth_dir, home_path)
      File.rm_rf!(home_path)
      File.mkdir_p!(home_path)
      File.write!(instructions_path, spec.guidance)

      for {relative_path, content} <- extra_files do
        absolute_path = Path.join(home_path, relative_path)
        File.mkdir_p!(Path.dirname(absolute_path))
        File.write!(absolute_path, content)
      end

      File.write!(stamp_path, manifest)
    end

    project_skills(home_path, projected_skills(spec))

    %{
      home_path: home_path,
      instructions_file: instructions_path,
      linked_auth_files: link_auth(auth_dir, home_path)
    }
  end

  @doc "Canonical projection-manifest bytes. Pure for a given projection spec."
  @spec manifest_bytes(spec()) :: binary()
  def manifest_bytes(spec) do
    parent =
      case spec.parent_source do
        nil -> %{"file" => nil, "sha256" => nil}
        source -> %{"file" => source.file, "sha256" => source.sha256}
      end

    skills =
      spec
      |> projected_skills()
      |> Enum.map(fn skill ->
        %{
          "name" => skill.name,
          "provenance" => skill.provenance,
          "linkage" => skill.linkage
        }
      end)
      |> Enum.sort_by(&{&1["name"], &1["provenance"], &1["linkage"]})

    extra_files =
      spec
      |> Map.get(:extra_files, %{})
      |> Map.new(fn {path, content} -> {path, sha256(content)} end)

    manifest = %{
      "base_archetype" => spec.base_archetype,
      "parent_manifest" => parent,
      "harness" => Atom.to_string(spec.harness),
      "guidance_sha256" => sha256(spec.guidance),
      "skills" => skills,
      "extra_files" => extra_files
    }

    manifest
    |> maybe_put_identity_sha256(Map.get(spec, :identity_sha256))
    |> canonical_json()
  end

  @doc "Harness-independent digest used to derive an overridden identity name."
  @spec identity_fingerprint(spec()) :: String.t()
  def identity_fingerprint(spec) do
    skill_names =
      spec
      |> Map.get(:skills, [])
      |> Enum.map(& &1.name)
      |> Enum.sort()
      |> Enum.intersperse(<<0>>)

    sha256([spec.guidance, <<0>>, skill_names])
  end

  @doc "Recover newer regular-file credentials from every projected home for one harness."
  @spec sweep_auth(String.t(), :claude | :codex) :: :ok
  def sweep_auth(base_dir, harness) do
    auth_dir = Path.join([base_dir, "auth", Atom.to_string(harness)])
    home_dirs = Path.wildcard(Path.join([base_dir, "homes", "*", Atom.to_string(harness)]))
    instruction_file = if harness == :claude, do: "CLAUDE.md", else: "AGENTS.md"
    File.mkdir_p!(auth_dir)

    store_files =
      auth_dir
      |> File.ls!()
      |> MapSet.new()

    home_dirs
    |> Enum.flat_map(fn home_dir ->
      home_dir
      |> File.ls!()
      |> Enum.reject(&(&1 in [@stamp_file, instruction_file]))
      |> Enum.filter(&(MapSet.member?(store_files, &1) or &1 in @known_credential_files))
      |> Enum.flat_map(fn file ->
        path = Path.join(home_dir, file)

        case regular_mtime(path) do
          nil -> []
          mtime -> [{file, mtime, path}]
        end
      end)
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.each(fn {file, entries} ->
      {^file, mtime, path} = Enum.max_by(entries, &elem(&1, 1))
      store_path = Path.join(auth_dir, file)

      if is_nil(regular_mtime(store_path)) or mtime > regular_mtime(store_path) do
        File.cp!(path, store_path)
      end
    end)

    :ok
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

  defp projected_skills(spec) do
    baseline =
      Enum.map(@baseline_skill_names, fn name ->
        %{
          name: name,
          link_to: Application.app_dir(:tightbeam, "priv/skills/#{name}"),
          provenance: "substrate",
          linkage: "linked"
        }
      end)

    reserved = MapSet.new(@baseline_skill_names)
    baseline ++ Enum.reject(Map.get(spec, :skills, []), &MapSet.member?(reserved, &1.name))
  end

  defp projected_extra_files(base_dir, spec) do
    direct_identity = Path.join(base_dir, "identity")

    identity_dir =
      if File.dir?(direct_identity) do
        direct_identity
      else
        base_dir
        |> Path.dirname()
        |> Path.dirname()
        |> Path.join("identity")
      end

    capability_files =
      identity_dir
      |> Path.join("kungfu/*/capabilities.md")
      |> Path.wildcard()
      |> Map.new(fn path ->
        bundle = path |> Path.dirname() |> Path.basename()
        {Path.join(["kungfu", bundle, "capabilities.md"]), File.read!(path)}
      end)

    session_readable_files =
      case File.read(Path.join(identity_dir, "tentpoles.md")) do
        {:ok, tentpoles} -> Map.put(capability_files, "tentpoles.md", tentpoles)
        {:error, :enoent} -> capability_files
      end

    Map.merge(Map.get(spec, :extra_files, %{}), session_readable_files)
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

  defp regular_mtime(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp guard_identity_collision!(_stamp_path, _identity_name, nil), do: :ok

  defp guard_identity_collision!(stamp_path, identity_name, identity_sha256) do
    suffix = identity_name |> String.split("--") |> List.last()

    with {:ok, bytes} <- File.read(stamp_path),
         {:ok, manifest} <- JSON.decode(bytes),
         existing when is_binary(existing) <- manifest["identity_sha256"],
         false <- existing == identity_sha256,
         ^suffix <- binary_part(existing, 0, 16),
         ^suffix <- binary_part(identity_sha256, 0, 16) do
      raise ArgumentError,
            "identity name collision: existing fingerprint #{existing} differs from #{identity_sha256}"
    else
      _ -> :ok
    end
  end

  defp maybe_put_identity_sha256(manifest, nil), do: manifest

  defp maybe_put_identity_sha256(manifest, identity_sha256),
    do: Map.put(manifest, "identity_sha256", identity_sha256)

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(value) when is_map(value) do
    members =
      value
      |> Enum.map(fn {key, item} -> {to_string(key), item} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, item} -> [JSON.encode!(key), ?:, canonical_json(item)] end)
      |> Enum.intersperse(?,)

    IO.iodata_to_binary([?{, members, ?}])
  end

  defp canonical_json(value) when is_list(value) do
    items = value |> Enum.map(&canonical_json/1) |> Enum.intersperse(?,)
    IO.iodata_to_binary([?[, items, ?]])
  end

  defp canonical_json(value), do: JSON.encode!(value)
end
