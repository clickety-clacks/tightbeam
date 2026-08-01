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

  require Logger

  alias Tightbeam.{Archetypes, Harness}
  alias Tightbeam.Harness.Support

  @upstream "tightbeam/upstream"
  @live "tightbeam/live"
  @required_refs ["main", @upstream, @live]
  @reserved_prefix "tightbeam__"
  @seed_owned_paths ["archetypes/default.toml", "guidance/operating-model.md"]
  @bundle_doc_paths ~w(capabilities.md intake.md preferred-models.md manifest.toml)

  @type harness :: atom()
  @type snapshot :: %{
          revision: String.t(),
          archetype: Archetypes.t(),
          guidance: String.t(),
          skills: %{optional(String.t()) => binary()}
        }

  @doc "Seed a new organization with the neutral identity substrate."
  @spec init!(String.t()) :: :initialized | :noop
  def init!(base_dir) do
    identity_dir = identity_dir(base_dir)

    if File.dir?(Path.join(identity_dir, ".git")) do
      verify_required_refs!(identity_dir)
      maybe_mint_grandfather_receipt!(identity_dir)
      :noop
    else
      File.mkdir_p!(identity_dir)
      git!(identity_dir, ["init", "-b", "main"])
      replace_with_entries!(identity_dir, seed_entries())
      git!(identity_dir, ["add", "-A"])
      git!(identity_dir, ["commit", "-m", "seed: neutral-identity"], "tightbeam")
      git!(identity_dir, ["branch", @upstream])
      git!(identity_dir, ["branch", @live])
      :initialized
    end
  end

  defp verify_required_refs!(identity_dir) do
    missing = Enum.reject(@required_refs, &required_ref_exists?(identity_dir, &1))

    if missing != [] do
      repair =
        if any_ref_exists?(identity_dir) do
          # Refs exist, so this is a repository that PREDATES something rather than a
          # broken one, and missing refs are only its first symptom: its tree can also
          # be too old to serve (see `required_fragment!`). Creating the refs alone
          # fixes the half that raised here and leaves the other half to fail at the
          # next session provisioning, so the repair names both steps.
          Enum.map_join(missing, "; ", fn
            "main" -> "restore main from a known-good identity backup"
            ref -> "git -C #{identity_dir} branch #{ref} main"
          end) <> "; then tightbeam identity relearn"
        else
          "remove #{identity_dir} and re-boot to re-learn"
        end

      raise ArgumentError,
            "identity repository is missing required refs: #{Enum.join(missing, ", ")}. Repair with: #{repair}"
    end
  end

  defp required_ref_exists?(identity_dir, ref) do
    full_ref = "refs/heads/#{ref}"

    case System.cmd("git", ["rev-parse", "--verify", "--quiet", full_ref],
           cd: identity_dir,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      {_output, 1} -> false
      {output, status} -> raise "git rev-parse failed (#{status}): #{String.trim(output)}"
    end
  end

  defp any_ref_exists?(identity_dir) do
    identity_dir
    |> git_output!(["for-each-ref", "--format=%(refname)"])
    |> String.trim()
    |> Kernel.!=("")
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

    # The operating manual is substrate-shipped (priv/guidance/operating-manual.md)
    # and served to every session, like operating-model.md below. An org tree that
    # carries its own operating-manual.md wins; otherwise the built-in fills the
    # name, so an explicit `#include "operating-manual.md"` resolves either way.
    # Absence of the shipped file is a broken install: File.read! raises.
    fragments =
      identity_dir
      |> revision_fragments!(revision)
      |> Map.put_new_lazy("operating-manual.md", fn ->
        String.trim_trailing(Archetypes.builtin_fragments()["operating-manual.md"])
      end)

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

    archetype_guidance = Archetypes.guidance(archetype, fragments)
    operating_manual = Map.fetch!(fragments, "operating-manual.md")

    # Appended once: an archetype whose guidance already includes the manual
    # (via `#include`) is not served it twice.
    manual_part =
      if String.contains?(archetype_guidance, operating_manual),
        do: [],
        else: [operating_manual]

    guidance =
      ([
         archetype_guidance,
         required_fragment!(fragments, "operating-model.md", revision)
       ] ++ manual_part)
      |> Enum.join("\n\n")
      |> then(&Harness.module!(harness).session_config(%{identity: true}, &1).guidance)

    %{revision: revision, archetype: archetype, guidance: guidance, skills: skills}
  end

  # A fragment the SUBSTRATE requires, which an org's tree may predate.
  #
  # `operating-model.md` is composed into every archetype's guidance by name, from
  # here rather than from the org's manifests, so an org seeded before it shipped
  # has a tree that cannot serve a session — and `init!` is a no-op once the repo
  # exists, so nothing brings it in on its own. `Map.fetch!` raised a KeyError that
  # named the key and then printed the entire fragment map: tens of kilobytes of
  # guidance prose in a message whose actionable content is one filename and one
  # verb.
  defp required_fragment!(fragments, name, revision) do
    case Map.fetch(fragments, name) do
      {:ok, body} ->
        body

      :error ->
        raise ArgumentError,
              "identity revision #{revision} has no guidance/#{name}, which every " <>
                "archetype's guidance is composed with. This org was seeded before that " <>
                "fragment shipped. Repair with: tightbeam identity relearn"
    end
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

    git!(dir, ["add", "-A"])
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

  @doc "Learn one shipped kungfu bundle and publish it."
  @spec learn!(String.t(), String.t(), String.t()) ::
          {:ok, String.t()}
          | {:noop, String.t()}
          | {:conflict, [String.t()]}
          | {:error, String.t()}
  def learn!(base_dir, name, author) do
    init!(base_dir)
    dir = identity_dir(base_dir)
    available = available_bundle_names()

    unless name in available do
      raise ArgumentError,
            "unknown kungfu bundle #{name}; available bundles: #{Enum.join(available, ", ")}"
    end

    bundle = bundle_dir(name)

    case receipt_at(dir, "main", name) do
      {:ok, _receipt} ->
        {:noop, git_output!(dir, ["rev-parse", @live])}

      :error ->
        refuse_seed_owned_bundle_paths!(name, bundle)
        require_clean_main!(dir)
        learned = learned_bundle_names(dir)
        receipt = bundle_receipt(name, bundle)
        import_upstream!(dir, learned ++ [name], "learn: #{name}")

        case merge_upstream(dir, "learn: #{name}", author, fn ->
               write_receipt!(dir, receipt)
             end) do
          {:ok, revision} -> {:ok, revision}
          other -> other
        end
    end
  end

  @doc "Remove one learned kungfu bundle by its committed receipt."
  @spec unlearn!(String.t(), String.t(), String.t()) :: String.t()
  def unlearn!(base_dir, name, author) do
    init!(base_dir)
    dir = identity_dir(base_dir)
    receipt = read_receipt!(dir, "main", name)
    require_clean_main!(dir)

    originals =
      receipt.paths
      |> Enum.filter(&File.regular?(Path.join(dir, &1)))
      |> Map.new(fn relative ->
        path = Path.join(dir, relative)
        {relative, File.read!(path)}
      end)

    Enum.each(receipt.paths, &File.rm(Path.join(dir, &1)))
    receipt_path = receipt_path(name)
    receipt_bytes = File.read!(Path.join(dir, receipt_path))
    File.rm!(Path.join(dir, receipt_path))

    try do
      validate_tree!(dir)
    rescue
      error ->
        Enum.each(Map.put(originals, receipt_path, receipt_bytes), fn {relative, bytes} ->
          path = Path.join(dir, relative)
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, bytes)
        end)

        reraise error, __STACKTRACE__
    end

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-m", "unlearn: #{name}"], author)
    publish_live!(dir)
  end

  @doc "Bundle-owned archetype names recorded by a learned receipt."
  @spec bundle_archetype_names!(String.t(), String.t()) :: [String.t()]
  def bundle_archetype_names!(base_dir, name) do
    dir = identity_dir(base_dir)

    dir
    |> read_receipt!("main", name)
    |> Map.fetch!(:paths)
    |> Enum.filter(&(Path.dirname(&1) == "archetypes" and String.ends_with?(&1, ".toml")))
    |> Enum.map(&(&1 |> Path.basename() |> Path.rootname()))
    |> Enum.sort()
  end

  @doc "Names of kungfu bundles shipped with this Tightbeam build."
  @spec available_bundle_names() :: [String.t()]
  def available_bundle_names do
    bundle_root_dir()
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(bundle_root_dir(), &1)))
    |> Enum.sort()
  end

  @doc "Import the current seed and learned bundle snapshots, then merge them into main."
  @spec relearn!(String.t(), String.t()) ::
          {:ok, String.t()} | {:conflict, [String.t()]} | {:error, String.t()}
  def relearn!(base_dir, author) do
    init!(base_dir)
    dir = identity_dir(base_dir)

    if grandfather_receipt_pending?(dir) do
      raise ArgumentError,
            "identity relearn is unavailable while the agentic-engineering grandfather receipt mint is pending"
    end

    require_clean_main!(dir)
    learned = learned_bundle_names(dir)
    names = ["neutral-identity" | learned]
    message = "relearn: #{Enum.join(names, ", ")}"
    import_upstream!(dir, learned, message)
    merge_upstream(dir, message, author, fn -> refresh_receipts!(dir, learned) end)
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

    refresh_receipts_for_merge!(dir, merge_subject(dir))

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

  defp seed_dir do
    Application.get_env(
      :tightbeam,
      :identity_seed_dir,
      Application.app_dir(:tightbeam, "priv/seed")
    )
  end

  defp bundle_root_dir, do: Application.app_dir(:tightbeam, "priv/kungfu")

  defp bundle_dir("agentic-engineering") do
    Application.get_env(
      :tightbeam,
      :identity_source_dir,
      Path.join(bundle_root_dir(), "agentic-engineering")
    )
  end

  defp bundle_dir(name), do: Path.join(bundle_root_dir(), name)

  defp replace_with_entries!(identity_dir, entries) do
    identity_dir
    |> File.ls!()
    |> Enum.reject(&(&1 == ".git"))
    |> Enum.each(&File.rm_rf!(Path.join(identity_dir, &1)))

    Enum.each(entries, fn {relative, bytes} ->
      destination = Path.join(identity_dir, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, bytes)
    end)
  end

  defp seed_entries, do: source_entries(seed_dir())

  defp source_entries(root), do: source_entries(root, "")

  defp source_entries(root, relative) do
    root
    |> Path.join(relative)
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn entry ->
      child_relative = if relative == "", do: entry, else: Path.join(relative, entry)
      child = Path.join(root, child_relative)

      if File.dir?(child) do
        source_entries(root, child_relative)
      else
        [{child_relative, File.read!(child)}]
      end
    end)
  end

  defp bundle_entries(name, bundle) do
    bundle
    |> source_entries()
    |> Enum.map(fn
      {relative, bytes}
      when relative in @bundle_doc_paths ->
        {Path.join(["kungfu", name, relative]), bytes}

      {relative, bytes} ->
        {relative, bytes}
    end)
  end

  defp bundle_receipt(name, bundle) do
    %{
      name: name,
      paths: bundle_entries(name, bundle) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    }
  end

  defp import_upstream!(dir, bundle_names, message) do
    entries =
      seed_entries_for_import(dir) ++
        Enum.flat_map(bundle_names, fn name ->
          bundle = bundle_dir(name)
          refuse_seed_owned_bundle_paths!(name, bundle)
          bundle_entries(name, bundle)
        end)

    git!(dir, ["switch", @upstream])
    replace_with_entries!(dir, entries)
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--allow-empty", "-m", message], "tightbeam")
    git!(dir, ["switch", "main"])
  end

  defp seed_entries_for_import(dir) do
    Enum.map(seed_entries(), fn {relative, shipped_bytes} ->
      bytes =
        if path_exists_at?(dir, "main", relative),
          do: git_show_bytes!(dir, "main", relative),
          else: shipped_bytes

      {relative, bytes}
    end)
  end

  defp merge_upstream(dir, message, author, before_commit) do
    case System.cmd(
           "git",
           ["merge", "--no-ff", "--no-commit", @upstream, "-m", message],
           cd: dir,
           stderr_to_stdout: true,
           env: git_env(author)
         ) do
      {_output, 0} ->
        case run_pre_merge_hook(dir, author) do
          {_output, 0} ->
            before_commit.()
            git!(dir, ["add", "-A"])
            git!(dir, ["commit", "-m", message], author)
            {:ok, publish_live!(dir)}

          {output, _status} ->
            git!(dir, ["merge", "--abort"])
            {:error, String.trim(output)}
        end

      {output, _status} ->
        case conflict_paths(dir) do
          [] -> {:error, String.trim(output)}
          paths -> {:conflict, paths}
        end
    end
  end

  defp run_pre_merge_hook(dir, author) do
    hook = Path.join([dir, ".git", "hooks", "pre-merge-commit"])

    if File.regular?(hook) do
      System.cmd("git", ["hook", "run", "pre-merge-commit"],
        cd: dir,
        stderr_to_stdout: true,
        env: git_env(author)
      )
    else
      {"", 0}
    end
  end

  defp refuse_seed_owned_bundle_paths!(name, bundle) do
    case Enum.find(@seed_owned_paths, &File.exists?(Path.join(bundle, &1))) do
      nil -> :ok
      path -> raise ArgumentError, "kungfu bundle #{name} claims seed-owned path #{path}"
    end
  end

  defp learned_bundle_names(dir) do
    git_output!(dir, ["ls-tree", "-r", "--name-only", "main", "--", "kungfu"])
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn path ->
      case String.split(path, "/") do
        ["kungfu", name, "installed.toml"] -> [name]
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  defp receipt_path(name), do: Path.join(["kungfu", name, "installed.toml"])

  defp receipt_at(dir, revision, name) do
    path = receipt_path(name)

    case System.cmd("git", ["show", "#{revision}:#{path}"], cd: dir, stderr_to_stdout: true) do
      {bytes, 0} -> {:ok, parse_receipt!(bytes, path)}
      {_output, _status} -> :error
    end
  end

  defp read_receipt!(dir, revision, name) do
    case receipt_at(dir, revision, name) do
      {:ok, receipt} -> receipt
      :error -> raise ArgumentError, "kungfu bundle #{name} is not learned"
    end
  end

  defp parse_receipt!(bytes, path) do
    receipt = Toml.decode!(bytes)
    %{name: Map.fetch!(receipt, "name"), paths: Map.fetch!(receipt, "paths")}
  rescue
    error -> raise ArgumentError, "#{path}: #{Exception.message(error)}"
  end

  defp write_receipt!(dir, receipt) do
    path = Path.join(dir, receipt_path(receipt.name))
    File.mkdir_p!(Path.dirname(path))

    paths = Enum.map_join(receipt.paths, ",\n", &"  #{inspect(&1)}")
    File.write!(path, "name = #{inspect(receipt.name)}\npaths = [\n#{paths}\n]\n")
  end

  defp refresh_receipts_for_merge!(dir, "learn: " <> name),
    do: write_receipt!(dir, current_bundle_receipt(dir, name))

  defp refresh_receipts_for_merge!(dir, "relearn: " <> _names),
    do: refresh_receipts!(dir, learned_bundle_names(dir))

  defp refresh_receipts_for_merge!(_dir, _subject), do: :ok

  defp refresh_receipts!(dir, names) do
    Enum.each(names, fn name ->
      write_receipt!(dir, current_bundle_receipt(dir, name))
    end)
  end

  defp current_bundle_receipt(dir, name) do
    receipt = bundle_receipt(name, bundle_dir(name))
    %{receipt | paths: Enum.filter(receipt.paths, &File.regular?(Path.join(dir, &1)))}
  end

  defp path_exists_at?(dir, revision, path) do
    case System.cmd("git", ["cat-file", "-e", "#{revision}:#{path}"], cd: dir) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp maybe_mint_grandfather_receipt!(dir) do
    if grandfather_receipt_pending?(dir) do
      if merge_pending?(dir) or git_output!(dir, ["status", "--porcelain"]) != "" do
        Logger.warning(
          "agentic-engineering grandfather receipt mint deferred: identity main is dirty or a merge is pending; retrying next boot"
        )
      else
        receipt = grandfather_receipt(dir)
        write_receipt!(dir, receipt)
        git!(dir, ["add", "-A", "--", receipt_path(receipt.name)])
        git!(dir, ["commit", "-m", "learn-receipt: agentic-engineering"], "tightbeam")
        publish_live!(dir)
      end
    end
  end

  defp grandfather_receipt_pending?(dir) do
    root =
      dir
      |> git_output!(["rev-list", "--max-parents=0", "--reverse", "main"])
      |> String.split("\n", trim: true)
      |> List.first()

    root != nil and
      git_output!(dir, ["show", "-s", "--format=%s", root]) ==
        "learn: agentic-engineering" and
      receipt_at(dir, "main", "agentic-engineering") == :error and
      not history_has_subject?(dir, "unlearn: agentic-engineering")
  end

  defp grandfather_receipt(dir) do
    paths =
      bundle_dir("agentic-engineering")
      |> source_entries()
      |> Enum.flat_map(fn {relative, _bytes} ->
        cond do
          relative in @seed_owned_paths ->
            []

          relative in @bundle_doc_paths and path_exists_at?(dir, "main", relative) ->
            [relative]

          relative in @bundle_doc_paths ->
            installed = Path.join(["kungfu", "agentic-engineering", relative])
            if path_exists_at?(dir, "main", installed), do: [installed], else: []

          path_exists_at?(dir, "main", relative) ->
            [relative]

          true ->
            []
        end
      end)
      |> Enum.sort()

    %{name: "agentic-engineering", paths: paths}
  end

  defp history_has_subject?(dir, subject) do
    dir
    |> git_output!(["log", "--format=%s", "main"])
    |> String.split("\n", trim: true)
    |> Enum.member?(subject)
  end

  defp merge_pending?(dir), do: File.exists?(Path.join([dir, ".git", "MERGE_HEAD"]))

  defp merge_subject(dir) do
    dir
    |> Path.join(".git/MERGE_MSG")
    |> File.read!()
    |> String.split("\n", parts: 2)
    |> hd()
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

  defp apply_edit!(dir, path, {:skill, name, true}, nil) do
    electors = skill_electors(Path.dirname(Path.dirname(Path.dirname(path))), name)

    if electors != [] do
      raise ArgumentError,
            "skill #{name} is still elected by: #{Enum.join(electors, ", ")}; de-elect first"
    end

    File.rm_rf!(Path.dirname(path))
    remove_path_from_receipts!(dir, Path.relative_to(path, dir))
  end

  defp apply_edit!(_dir, path, _target, content) when is_binary(content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp remove_path_from_receipts!(dir, removed_path) do
    Enum.each(learned_bundle_names(dir), fn name ->
      receipt = read_receipt!(dir, "main", name)

      if removed_path in receipt.paths do
        write_receipt!(dir, %{receipt | paths: List.delete(receipt.paths, removed_path)})
      end
    end)
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

  defp git_show_bytes!(dir, revision, path) do
    case System.cmd("git", ["show", "#{revision}:#{path}"], cd: dir, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git show #{revision}:#{path} failed (#{status}): #{output}"
    end
  end

  defp git_output!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> String.trim_trailing(output)
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  defp git!(dir, args, author \\ nil) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: git_env(author)) do
      {_output, 0} -> :ok
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  defp git_env(nil), do: []

  defp git_env(name) do
    local = String.replace(name, ~r/[^A-Za-z0-9_.+-]/, "-")

    [
      {"GIT_AUTHOR_NAME", name},
      {"GIT_AUTHOR_EMAIL", "#{local}@tightbeam.local"},
      {"GIT_COMMITTER_NAME", name},
      {"GIT_COMMITTER_EMAIL", "#{local}@tightbeam.local"}
    ]
  end
end
