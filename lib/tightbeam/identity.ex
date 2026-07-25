defmodule Tightbeam.Identity do
  @moduledoc """
  The served-identity seam.

  `identity/` is a three-ref git repository: `tightbeam/upstream` records
  successive shipped kungfu snapshots, `main` carries local customization,
  and `tightbeam/live` is the only publication sessions read. Provisioning
  resolves `tightbeam/live` once, reads guidance and skills through that OID,
  materializes only the reserved `tightbeam__*` skill namespace at the
  session cwd, and returns the OID to stamp on the session row.
  """

  alias Tightbeam.{Archetypes, Harness}
  alias Tightbeam.Harness.Support

  @upstream "tightbeam/upstream"
  @live "tightbeam/live"
  @reserved_prefix "tightbeam__"

  @type harness :: atom()
  @type snapshot :: %{
          revision: String.t(),
          archetype: Archetypes.t(),
          guidance: String.t(),
          skills: %{optional(String.t()) => binary()}
        }

  @doc "First learn: import the shipped kungfu and publish it as main/live."
  @spec init!(String.t()) :: :initialized | :noop
  def init!(base_dir) do
    identity_dir = identity_dir(base_dir)

    if File.dir?(Path.join(identity_dir, ".git")) do
      :noop
    else
      File.mkdir_p!(identity_dir)
      git!(identity_dir, ["init", "-b", "main"])
      replace_with_source!(identity_dir)
      git!(identity_dir, ["add", "-A"])
      git!(identity_dir, ["commit", "-m", "learn: agentic-engineering"], "tightbeam")
      git!(identity_dir, ["branch", @upstream])
      git!(identity_dir, ["branch", @live])
      :initialized
    end
  end

  @doc "Resolve the sole publication pointer."
  @spec live_revision!(String.t()) :: String.t()
  def live_revision!(base_dir) do
    init!(base_dir)
    git_output!(identity_dir(base_dir), ["rev-parse", @live])
  end

  @doc "Read one archetype's complete immutable served snapshot."
  @spec snapshot!(String.t(), String.t(), harness()) :: snapshot()
  def snapshot!(base_dir, archetype_name, harness) do
    revision = live_revision!(base_dir)
    snapshot_at!(base_dir, revision, archetype_name, harness)
  end

  @doc "Read one archetype at an already-resolved publication OID."
  @spec snapshot_at!(String.t(), String.t(), String.t(), harness()) :: snapshot()
  def snapshot_at!(base_dir, revision, archetype_name, harness) do
    identity_dir = identity_dir(base_dir)
    fragments = revision_fragments!(identity_dir, revision)
    manifest_path = "archetypes/#{archetype_name}.toml"
    manifest = git_show!(identity_dir, revision, manifest_path)
    archetype = Archetypes.parse_manifest!(manifest, manifest_path)
    substrate_skills = MapSet.new(Tightbeam.Homes.baseline_skill_names())

    skills =
      archetype.skills
      |> Enum.reject(&MapSet.member?(substrate_skills, &1))
      |> Map.new(fn name ->
        {name, git_show!(identity_dir, revision, "skills/#{name}/SKILL.md")}
      end)

    guidance =
      [
        Archetypes.guidance(archetype, fragments),
        Map.fetch!(fragments, "operating-model.md")
      ]
      |> Enum.join("\n\n")
      |> then(&Harness.module!(harness).session_config(%{identity: true}, &1).guidance)

    %{revision: revision, archetype: archetype, guidance: guidance, skills: skills}
  end

  @doc """
  Materialize one immutable snapshot at the exact session cwd.

  Tight Beam owns only reserved `tightbeam__*` entries. Every provisioning
  reconciles that namespace and, only when cwd is itself a repo checkout,
  adds the single reserved exclusion to the repository's common git dir.
  """
  @spec materialize!(snapshot(), harness(), String.t()) :: snapshot()
  def materialize!(snapshot, harness, cwd) do
    Harness.module!(harness).materialize_skills(
      %{host_config: %{ssh: nil}, base_dir: cwd},
      cwd,
      snapshot
    )
  end

  @doc false
  def materialize_for_harness!(target, snapshot, cwd, relative_skills) do
    if Support.local?(target) do
      materialize_local!(snapshot, cwd, relative_skills)
    else
      stage_cwd =
        Path.join([
          target.base_dir,
          "staging",
          target.host_name,
          "session-identity",
          Map.fetch!(target, :session_key)
        ])

      try do
        materialize_local!(snapshot, stage_cwd, relative_skills)
        staged_skills = Path.join(stage_cwd, relative_skills)
        remote_skills = Path.join(cwd, relative_skills)
        exclude_pattern = Path.join(relative_skills, "#{@reserved_prefix}*")

        script =
          "mkdir -p #{Support.shell_quote(remote_skills)}; " <>
            "find #{Support.shell_quote(remote_skills)} -mindepth 1 -maxdepth 1 -name 'tightbeam__*' -exec rm -rf {} +; " <>
            "root=$(git -C #{Support.shell_quote(cwd)} rev-parse --show-toplevel 2>/dev/null || true); " <>
            "if [ \"$root\" = #{Support.shell_quote(cwd)} ]; then " <>
            "exclude=$(git -C #{Support.shell_quote(cwd)} rev-parse --git-path info/exclude); " <>
            "mkdir -p \"$(dirname \"$exclude\")\"; " <>
            "grep -qxF #{Support.shell_quote(exclude_pattern)} \"$exclude\" 2>/dev/null || " <>
            "printf '%s\\n' #{Support.shell_quote(exclude_pattern)} >> \"$exclude\"; fi"

        Support.run!(
          target,
          ["ssh" | Support.ssh_opts()] ++
            [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]
        )

        Support.run!(target, [
          "rsync",
          "-a",
          "-e",
          Enum.join(["ssh" | Support.ssh_opts()], " "),
          staged_skills <> "/",
          "#{target.host_config.ssh}:#{remote_skills}/"
        ])

        snapshot
      after
        File.rm_rf(stage_cwd)
      end
    end
  end

  defp materialize_local!(snapshot, cwd, relative_skills) do
    skills_root = Path.join(cwd, relative_skills)
    File.mkdir_p!(skills_root)

    elected =
      Map.new(snapshot.skills, fn {name, body} ->
        directory = @reserved_prefix <> name
        target = Path.join(skills_root, directory)
        File.rm_rf!(target)
        File.mkdir_p!(target)
        File.write!(Path.join(target, "SKILL.md"), body)
        {directory, true}
      end)

    skills_root
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, @reserved_prefix))
    |> Enum.reject(&Map.has_key?(elected, &1))
    |> Enum.each(fn entry -> File.rm_rf!(Path.join(skills_root, entry)) end)

    maybe_exclude_materialized_skills(cwd, relative_skills)
    snapshot
  end

  @doc "Resolve live once, compose guidance, materialize skills, and return the snapshot."
  @spec provision!(String.t(), String.t(), harness(), String.t()) :: snapshot()
  def provision!(base_dir, archetype_name, harness, cwd) do
    revision = live_revision!(base_dir)

    provision_at!(base_dir, revision, archetype_name, harness, cwd)
  end

  @doc "Provision an already-stamped immutable revision."
  @spec provision_at!(String.t(), String.t(), String.t(), harness(), String.t()) :: snapshot()
  def provision_at!(base_dir, revision, archetype_name, harness, cwd) do
    base_dir
    |> snapshot_at!(revision, archetype_name, harness)
    |> materialize!(harness, cwd)
  end

  @doc "Customize one guidance fragment, manifest, or shared skill and publish it."
  @spec edit!(
          String.t(),
          String.t(),
          {:guidance | :manifest | {:skill, String.t(), boolean()}},
          binary() | nil,
          String.t()
        ) :: String.t()
  def edit!(base_dir, archetype, target, content, author) do
    init!(base_dir)
    dir = identity_dir(base_dir)
    require_clean_main!(dir)
    path = edit_path(dir, archetype, target)
    previous = previous_target(path)

    try do
      apply_edit!(dir, path, target, content)
      validate_edit!(dir, target, path)
    rescue
      error ->
        restore_target!(path, previous)
        reraise error, __STACKTRACE__
    end

    git!(dir, ["add", "-A", "--", Path.relative_to(path, dir)])
    git!(dir, ["commit", "-m", edit_message(archetype, target)], author)
    publish_live!(dir)
  end

  @doc "Create a complete kungfu scaffold as one main commit and publish it."
  @spec scaffold!(String.t(), String.t(), [{String.t(), binary()}], String.t()) ::
          [String.t()]
  def scaffold!(base_dir, name, entries, author) do
    init!(base_dir)
    dir = identity_dir(base_dir)

    case Enum.find(entries, fn {relative, _content} ->
           File.exists?(Path.join(dir, relative))
         end) do
      {relative, _content} ->
        raise ArgumentError, "kungfu scaffold target already exists: identity/#{relative}"

      nil ->
        :ok
    end

    require_clean_main!(dir)

    paths =
      Enum.map(entries, fn {relative, content} ->
        path = Path.join(dir, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
        path
      end)

    try do
      validate_tree!(dir)
    rescue
      error ->
        Enum.each(paths, &File.rm/1)
        reraise error, __STACKTRACE__
    end

    git!(dir, ["add", "-A", "--" | Enum.map(entries, &elem(&1, 0))])
    git!(dir, ["commit", "-m", "kungfu-scaffold: #{name}"], author)
    _revision = publish_live!(dir)
    paths
  end

  @doc "Import the next source snapshot and merge it into main."
  @spec relearn!(String.t()) :: {:ok, String.t()} | {:conflict, [String.t()]}
  def relearn!(base_dir) do
    init!(base_dir)
    dir = identity_dir(base_dir)
    require_clean_main!(dir)

    git!(dir, ["switch", @upstream])
    replace_with_source!(dir)
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--allow-empty", "-m", "relearn: agentic-engineering"], "tightbeam")
    git!(dir, ["switch", "main"])

    case System.cmd(
           "git",
           ["merge", "--no-ff", @upstream, "-m", "merge: relearn agentic-engineering"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> {:ok, publish_live!(dir)}
      {_output, _status} -> {:conflict, conflict_paths(dir)}
    end
  end

  @doc "Abort a conflicted re-learn without moving live."
  @spec abort_relearn!(String.t()) :: :ok
  def abort_relearn!(base_dir) do
    dir = identity_dir(base_dir)
    require_conflict!(dir)
    git!(dir, ["merge", "--abort"])
    :ok
  end

  @doc "Commit operator-resolved conflicts and publish live."
  @spec resolve_relearn!(String.t(), String.t()) :: String.t()
  def resolve_relearn!(base_dir, author) do
    dir = identity_dir(base_dir)
    require_conflict!(dir)

    case conflict_paths(dir) do
      [] -> :ok
      paths -> raise ArgumentError, "unresolved identity conflicts: #{Enum.join(paths, ", ")}"
    end

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--no-edit"], author)
    publish_live!(dir)
  end

  @doc "Report publication and conflict truth without mutation."
  @spec status(String.t()) :: map()
  def status(base_dir) do
    dir = identity_dir(base_dir)
    live = live_revision!(base_dir)
    conflicts = conflict_paths(dir)

    %{
      live_revision: live,
      state: if(conflicts == [], do: :ready, else: :relearn_conflicted),
      conflicting_paths: conflicts
    }
  end

  defp identity_dir(base_dir), do: Path.join(base_dir, "identity")

  defp source_dir do
    Application.get_env(
      :tightbeam,
      :identity_source_dir,
      Application.app_dir(:tightbeam, "priv/kungfu/agentic-engineering")
    )
  end

  defp replace_with_source!(identity_dir) do
    identity_dir
    |> File.ls!()
    |> Enum.reject(&(&1 == ".git"))
    |> Enum.each(&File.rm_rf!(Path.join(identity_dir, &1)))

    source_dir()
    |> File.ls!()
    |> Enum.each(fn entry ->
      source = Path.join(source_dir(), entry)
      destination = Path.join(identity_dir, entry)
      File.cp_r!(source, destination)
    end)
  end

  defp revision_fragments!(dir, revision) do
    paths =
      git_output!(dir, [
        "ls-tree",
        "-r",
        "--name-only",
        revision,
        "--",
        "guidance"
      ])
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.ends_with?(&1, ".md"))

    Map.new(paths, fn path ->
      {Path.basename(path), git_show!(dir, revision, path)}
    end)
  end

  defp maybe_exclude_materialized_skills(cwd, relative_skills) do
    case repo_root(cwd) do
      {:ok, root} ->
        if same_directory?(cwd, root) do
          relative = Path.join(relative_skills, "#{@reserved_prefix}*")
          exclude = git_path!(cwd, "info/exclude")
          File.mkdir_p!(Path.dirname(exclude))
          append_line_once!(exclude, relative)
        end

      _ ->
        :ok
    end
  end

  defp same_directory?(left, right) do
    case {File.stat(left), File.stat(right)} do
      {{:ok, left_stat}, {:ok, right_stat}} ->
        left_stat.inode == right_stat.inode and
          left_stat.major_device == right_stat.major_device

      _ ->
        false
    end
  end

  defp repo_root(cwd) do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], cd: cwd, stderr_to_stdout: true) do
      {root, 0} -> {:ok, root |> String.trim() |> Path.expand()}
      _ -> :not_repo
    end
  end

  defp git_path!(cwd, relative) do
    path = git_output!(cwd, ["rev-parse", "--git-path", relative])
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, cwd)
  end

  defp append_line_once!(path, line) do
    existing =
      case File.read(path) do
        {:ok, bytes} -> bytes
        {:error, :enoent} -> ""
      end

    unless line in String.split(existing, "\n") do
      separator = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
      File.write!(path, existing <> separator <> line <> "\n")
    end
  end

  defp edit_path(dir, archetype, :guidance),
    do: Path.join([dir, "guidance", "#{archetype}.md"])

  defp edit_path(dir, archetype, :manifest),
    do: Path.join([dir, "archetypes", "#{archetype}.toml"])

  defp edit_path(dir, _archetype, {:skill, name, _remove?}) do
    validate_name!(name)
    Path.join([dir, "skills", name, "SKILL.md"])
  end

  defp apply_edit!(_dir, path, {:skill, name, true}, nil) do
    electors = skill_electors(Path.dirname(Path.dirname(Path.dirname(path))), name)

    if electors != [] do
      raise ArgumentError,
            "skill #{name} is still elected by: #{Enum.join(electors, ", ")}; de-elect first"
    end

    File.rm_rf!(Path.dirname(path))
  end

  defp apply_edit!(_dir, path, _target, content) when is_binary(content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp validate_edit!(dir, :manifest, _path), do: validate_tree!(dir)
  defp validate_edit!(dir, {:skill, _name, false}, _path), do: validate_tree!(dir)
  defp validate_edit!(_dir, {:skill, _name, true}, _path), do: :ok
  defp validate_edit!(_dir, :guidance, _path), do: :ok

  defp validate_tree!(dir) do
    refuse_reserved_substrate_skills!(dir)

    fragments =
      dir
      |> Path.join("guidance/*.md")
      |> Path.wildcard()
      |> Map.new(&{Path.basename(&1), File.read!(&1)})

    skills =
      dir
      |> Path.join("skills/*/SKILL.md")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
      |> MapSet.new()
      |> MapSet.union(MapSet.new(Tightbeam.Homes.baseline_skill_names()))

    dir
    |> Path.join("archetypes/*.toml")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      archetype = Archetypes.parse_manifest!(File.read!(path), Path.relative_to(path, dir))
      _ = Archetypes.guidance(archetype, fragments)
      missing = Enum.reject(archetype.skills, &MapSet.member?(skills, &1))

      if missing != [] do
        raise ArgumentError,
              "archetype #{archetype.name} elects unknown skills: #{Enum.join(missing, ", ")}"
      end
    end)
  end

  defp refuse_reserved_substrate_skills!(dir) do
    for name <- Tightbeam.Homes.baseline_skill_names() do
      path = Path.join([dir, "skills", name, "SKILL.md"])

      if File.regular?(path) do
        raise ArgumentError,
              "#{path}: rename or remove the org copy; substrate names are reserved"
      end
    end
  end

  defp skill_electors(dir, skill) do
    dir
    |> Path.join("archetypes/*.toml")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      archetype = Archetypes.parse_manifest!(File.read!(path), Path.relative_to(path, dir))
      if skill in archetype.skills, do: [archetype.name], else: []
    end)
    |> Enum.sort()
  end

  defp previous_target(path) do
    case File.read(path) do
      {:ok, bytes} -> {:present, bytes}
      {:error, :enoent} -> :absent
    end
  end

  defp restore_target!(path, {:present, bytes}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp restore_target!(path, :absent) do
    File.rm(path)
    File.rmdir(Path.dirname(path))
  end

  defp edit_message(archetype, :guidance), do: "identity: edit #{archetype} guidance"
  defp edit_message(archetype, :manifest), do: "identity: edit #{archetype} manifest"

  defp edit_message(_archetype, {:skill, name, true}),
    do: "identity: remove skill #{name}"

  defp edit_message(_archetype, {:skill, name, false}),
    do: "identity: edit skill #{name}"

  defp require_clean_main!(dir) do
    branch = git_output!(dir, ["branch", "--show-current"])

    if branch != "main" do
      raise ArgumentError, "identity working branch must be main (found #{branch})"
    end

    case git_output!(dir, ["status", "--porcelain"]) do
      "" -> :ok
      _ -> raise ArgumentError, "identity working tree is dirty; commit or discard it first"
    end
  end

  defp require_conflict!(dir) do
    unless File.exists?(Path.join([dir, ".git", "MERGE_HEAD"])) do
      raise ArgumentError, "identity is not in a conflicted re-learn"
    end
  end

  defp conflict_paths(dir) do
    git_output!(dir, ["diff", "--name-only", "--diff-filter=U"])
    |> String.split("\n", trim: true)
  end

  defp publish_live!(dir) do
    live = git_output!(dir, ["rev-parse", @live])
    main = git_output!(dir, ["rev-parse", "main"])

    case System.cmd("git", ["merge-base", "--is-ancestor", live, main], cd: dir) do
      {_output, 0} -> git!(dir, ["update-ref", "refs/heads/#{@live}", main, live])
      _ -> raise ArgumentError, "tightbeam/live cannot fast-forward to main"
    end

    main
  end

  defp validate_name!(name) do
    unless is_binary(name) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/, name) do
      raise ArgumentError, "invalid skill name: #{inspect(name)}"
    end
  end

  defp git_show!(dir, revision, path) do
    git_output!(dir, ["show", "#{revision}:#{path}"])
  rescue
    error ->
      raise ArgumentError,
            "identity revision #{revision} has no #{path}: #{Exception.message(error)}"
  end

  defp git_output!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> String.trim_trailing(output)
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  defp git!(dir, args, author \\ nil) do
    env =
      case author do
        nil ->
          []

        name ->
          local = String.replace(name, ~r/[^A-Za-z0-9_.+-]/, "-")

          [
            {"GIT_AUTHOR_NAME", name},
            {"GIT_AUTHOR_EMAIL", "#{local}@tightbeam.local"},
            {"GIT_COMMITTER_NAME", name},
            {"GIT_COMMITTER_EMAIL", "#{local}@tightbeam.local"}
          ]
      end

    case System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: env) do
      {_output, 0} -> :ok
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end
end
