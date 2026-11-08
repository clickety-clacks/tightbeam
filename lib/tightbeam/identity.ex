defmodule Tightbeam.Identity do
  @moduledoc """
  The served-identity seam.

  `identity/` is a git repository: `tightbeam/upstream` records the last
  published product snapshot, `tightbeam/product-baseline` records its
  attributable base, `main` carries local customization, and `tightbeam/live`
  is the only publication sessions read. Provisioning
  resolves `tightbeam/live` once, reads guidance and skills through that OID,
  materializes only the reserved `tightbeam__*` skill namespace at the
  session cwd, and returns the OID to stamp on the session row.
  """

  require Logger

  alias Tightbeam.{Archetypes, Credentials, Harness}
  alias Tightbeam.Harness.Support
  alias Tightbeam.Identity.Renderer

  @upstream "tightbeam/upstream"
  @live "tightbeam/live"
  @product_baseline "tightbeam/product-baseline"
  @product_incoming "tightbeam/product-incoming"
  @product_metadata_trailer "Tightbeam-Identity-Product-Metadata"
  @required_refs ["main", @upstream, @live]
  @reserved_prefix "tightbeam__"
  @seed_owned_paths [
    "archetypes/default.toml",
    "guidance/operating-model.md",
    "rules/harness-health-recovery.toml",
    "rules/harness-recovery-main-wake.toml"
  ]
  @product_path_overrides ["guidance/operating-manual.md"]
  @bundle_doc_paths ~w(capabilities.md intake.md preferred-models.md manifest.toml)
  @bundle_setup_path "setup.md"
  @sentinel_keys ~w(name command requires events)
  @sentinel_event_keys ~w(name description details)
  @sentinel_event_detail_keys ~w(name description)
  @env_name ~r/^[A-Z_][A-Z0-9_]*$/
  @render_contract "universal-root-render-v1"
  @universal_roots ["operating-model.md", "operating-manual.md"]

  @type harness :: atom()
  @type snapshot :: %{
          revision: String.t(),
          render_contract: String.t(),
          guidance_digest: String.t(),
          archetype: Archetypes.t(),
          guidance: String.t(),
          skills: %{optional(String.t()) => binary()}
        }

  @doc "The immutable served-guidance composition contract."
  def render_contract, do: @render_contract

  @doc "Names of shipped bundles and bundles in the published identity."
  def public_kungfu_names(base_dir) do
    dir = identity_dir(base_dir)

    installed =
      if File.dir?(Path.join(dir, ".git")) do
        git_output!(dir, ["ls-tree", "-r", "--name-only", @live, "--", "kungfu"])
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn path ->
          case String.split(path, "/") do
            ["kungfu", name, "manifest.toml"] -> [name]
            _ -> []
          end
        end)
      else
        []
      end

    Enum.sort(Enum.uniq(available_bundle_names() ++ installed))
  end

  @doc "Serve the three public document paths unchanged, with hashes of the served bytes."
  def public_kungfu(base_dir, name) do
    unless is_binary(name) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/, name),
      do: raise(ArgumentError, "invalid kungfu name")

    dir = identity_dir(base_dir)
    available = Enum.find(available_bundles(), &(&1.name == name))
    manifest_path = Path.join(["kungfu", name, "manifest.toml"])
    installed? = File.dir?(Path.join(dir, ".git")) and path_exists_at?(dir, @live, manifest_path)

    banked_secret_values =
      if installed? or not is_nil(available), do: banked_secret_values(base_dir), else: []

    cond do
      installed? ->
        revision = git_output!(dir, ["rev-parse", @live])
        manifest = bundle_manifest!(git_show!(dir, revision, manifest_path), manifest_path)

        documents =
          for path <- ~w(README.md capabilities.md preferred-models.md),
              relative = Path.join(["kungfu", name, path]),
              path_exists_at?(dir, revision, relative),
              do:
                public_document(
                  path,
                  git_show_bytes!(dir, revision, relative),
                  banked_secret_values
                )

        %{
          "name" => name,
          "purpose" => manifest.purpose,
          "phrases" => Enum.sort(manifest.phrases),
          "rootArchetype" => manifest.root_archetype,
          "installedRevision" => revision,
          "status" => "installed",
          "documents" => documents,
          "rowVersion" => 1
        }

      available ->
        documents =
          for path <- ~w(README.md capabilities.md preferred-models.md),
              full = Path.join(bundle_dir(name), path),
              File.regular?(full),
              do: public_document(path, File.read!(full), banked_secret_values)

        %{
          "name" => name,
          "purpose" => available.purpose,
          "phrases" => Enum.sort(available.phrases),
          "rootArchetype" => available.root_archetype,
          "installedRevision" => nil,
          "status" => "available",
          "documents" => documents,
          "rowVersion" => 1
        }

      true ->
        nil
    end
  end

  defp public_document(path, bytes, banked_secret_values) do
    bytes = replace_banked_secret_values(bytes, banked_secret_values)

    %{
      "path" => path,
      "content" => bytes,
      "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    }
  end

  defp banked_secret_values(base_dir) do
    base_dir
    |> Credentials.credential_secret_paths()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      if regular_banked_file?(base_dir, path) do
        bytes = File.read!(path)

        if bytes != "" and String.valid?(bytes) do
          [bytes, String.trim(bytes)]
        else
          []
        end
      else
        []
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp regular_banked_file?(base_dir, path) do
    base_dir = Path.expand(base_dir)
    path = Path.expand(path)
    relative = Path.relative_to(path, base_dir)
    parts = Path.split(relative)
    final_index = length(parts) - 1

    if relative == path or relative in ["", "."] or ".." in parts do
      false
    else
      parts
      |> Enum.with_index()
      |> Enum.reduce_while(base_dir, fn {part, index}, current ->
        candidate = Path.join(current, part)

        case File.lstat(candidate) do
          {:ok, %File.Stat{type: :directory}} when index < final_index ->
            {:cont, candidate}

          {:ok, %File.Stat{type: :regular}} when index == final_index ->
            {:halt, :regular}

          {:ok, %File.Stat{}} ->
            {:halt, :ignore}

          {:error, reason} ->
            raise File.Error, action: "inspect credential bank", path: candidate, reason: reason
        end
      end) == :regular
    end
  end

  defp replace_banked_secret_values(content, banked_secret_values) do
    Enum.reduce(banked_secret_values, content, fn value, sanitized ->
      String.replace(sanitized, value, "[redacted-secret]")
    end)
  end

  @doc false
  def init_after_admission!(base_dir, db) do
    :ok = Tightbeam.DB.assert_base_admitted!(db, base_dir)
    init!(base_dir)
  end

  @doc "Seed a new organization with the neutral identity substrate."
  @spec init!(String.t()) :: :initialized | :noop
  def init!(base_dir) do
    identity_dir = identity_dir(base_dir)

    lock = {{__MODULE__, :init, Path.expand(identity_dir)}, self()}

    :global.trans(lock, fn ->
      init_identity!(identity_dir)
    end)
  end

  defp init_identity!(identity_dir) do
    if File.dir?(Path.join(identity_dir, ".git")) do
      verify_required_refs!(identity_dir)

      if required_ref_exists?(identity_dir, "main"),
        do: maybe_mint_grandfather_receipt!(identity_dir)

      :noop
    else
      candidate =
        identity_dir <> ".candidate-" <> Integer.to_string(System.unique_integer([:positive]))

      try do
        File.mkdir_p!(candidate)
        git!(candidate, ["init", "-b", "main"])
        replace_with_entries!(candidate, seed_entries())
        validate_tree!(candidate)
        git!(candidate, ["add", "-A"])
        git!(candidate, ["commit", "-m", "seed: neutral-identity"], "tightbeam")
        revision = git_output!(candidate, ["rev-parse", "main"])
        validate_revision_dir!(candidate, revision)
        git!(candidate, ["branch", @upstream])
        git!(candidate, ["branch", @live])
        git!(candidate, ["branch", @product_baseline])
        File.rm_rf!(identity_dir)
        File.rename!(candidate, identity_dir)
        :initialized
      after
        File.rm_rf(candidate)
      end
    end
  end

  defp verify_required_refs!(identity_dir) do
    missing = Enum.reject(@required_refs, &required_ref_exists?(identity_dir, &1))

    Enum.each(missing -- [@live], fn ref ->
      Logger.warning("identity synchronization unavailable: missing ref #{ref}")
    end)

    missing = Enum.filter(missing, &(&1 == @live))

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

  @doc false
  def with_live_revision_lock(base_dir, fun) when is_function(fun, 1) do
    init!(base_dir)
    with_live_revision_lock_in_dir(identity_dir(base_dir), fun)
  end

  # Apply holds this lock for one target's materialization and durable stamp.
  # Live-ref writers take the same lock so an older projection cannot write
  # after a newer revision becomes live.
  defp with_live_revision_lock_in_dir(identity_dir, fun) do
    lock = {{__MODULE__, :live_revision, Path.expand(identity_dir)}, self()}

    :global.trans(lock, fn ->
      fun.(git_output!(identity_dir, ["rev-parse", @live]))
    end)
  end

  @doc false
  def with_recovery_law!(base_dir, load) do
    dir = identity_dir(base_dir)

    if merge_pending?(dir) do
      # Recovery needs the published law, never a partially merged working tree.
      # Export one pinned revision without touching the index or merge metadata.
      revision = git_output!(dir, ["rev-parse", @live])
      snapshot = Path.join(base_dir, ".identity-law-#{Tightbeam.Id.uuid4()}")
      tree = Path.join(snapshot, "identity")

      try do
        File.mkdir_p!(tree)
        File.chmod!(snapshot, 0o700)
        env = [{"GIT_INDEX_FILE", Path.join(snapshot, "index")}]
        export_law!(dir, ["read-tree", revision], env)
        export_law!(dir, ["checkout-index", "--all", "--prefix=#{tree}/"], env)
        load.(snapshot, revision)
      after
        File.rm_rf!(snapshot)
      end
    else
      load.(base_dir, nil)
    end
  end

  defp export_law!(dir, args, env) do
    case System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "published identity export failed (#{status}): #{output}"
    end
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
    catalog = revision_catalog!(identity_dir, revision)

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

    archetype_render = Archetypes.guidance_render(archetype, catalog)
    bundle_context = available_bundle_context(archetype_name)

    root_parts =
      Enum.flat_map(@universal_roots, fn name ->
        if MapSet.member?(archetype_render.reachable_roots, name) do
          []
        else
          entry = required_catalog_entry!(catalog, name, revision)
          [Renderer.render!(entry.bytes, entry.path, catalog, universal_root: name).bytes]
        end
      end)

    guidance =
      ([archetype_render.bytes, bundle_context] ++ root_parts)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
      |> then(&Harness.module!(harness).session_config(%{identity: true}, &1).guidance)

    case guidance
         |> String.split("\n")
         |> Enum.with_index(1)
         |> Enum.find(fn {line, _} -> String.starts_with?(line, "#include") end) do
      nil ->
        :ok

      {_line, line_number} ->
        raise Tightbeam.Identity.IncludeError,
          cause: :unrendered_directive,
          origin: "final-guidance:#{archetype_name}:#{harness}",
          path: "final-guidance",
          line: line_number,
          chain: []
    end

    %{
      revision: revision,
      render_contract: @render_contract,
      guidance_digest: sha256(guidance),
      archetype: archetype,
      guidance: guidance,
      skills: skills
    }
  end

  defp available_bundle_context("default") do
    bundles =
      available_bundles()
      |> Enum.map_join("\n\n", fn bundle ->
        phrases = Enum.map_join(bundle.phrases, "\n", &"- #{&1}")
        "### `#{bundle.name}`\nPurpose: #{bundle.purpose}\nPhrases:\n#{phrases}"
      end)

    """
    ## Available kungfu bundles in this Tightbeam build

    Use these facts, composed from the installed build's shipped bundle manifests, to match a
    user's stated goal before any tool call.

    #{bundles}
    """
    |> String.trim()
  end

  defp available_bundle_context(_archetype_name), do: nil

  # A fragment the SUBSTRATE requires, which an org's tree may predate.
  #
  # `operating-model.md` is composed into every archetype's guidance by name, from
  # here rather than from the org's manifests, so an org seeded before it shipped
  # has a tree that cannot serve a session — and `init!` is a no-op once the repo
  # exists, so nothing brings it in on its own. `Map.fetch!` raised a KeyError that
  # named the key and then printed the entire fragment map: tens of kilobytes of
  # guidance prose in a message whose actionable content is one filename and one
  # verb.
  defp required_catalog_entry!(catalog, name, revision) do
    case Map.fetch(catalog, name) do
      {:ok, entry} ->
        entry

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
        ) :: map()
  def edit!(base_dir, archetype, target, content, author) do
    init!(base_dir)
    dir = identity_dir(base_dir)
    require_clean_main!(dir)
    expected_prior = git_output!(dir, ["rev-parse", @live])
    path = edit_path(dir, archetype, target)
    previous = previous_target(path)

    fingerprint =
      try do
        apply_edit!(dir, path, target, content)
        validate_candidate_tree!(dir, expected_prior)
      rescue
        error ->
          restore_target!(path, previous)
          reraise error, __STACKTRACE__
      end

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-m", edit_message(archetype, target)], author)
    candidate_result(dir, expected_prior, fingerprint)
  end

  @doc "Create a complete kungfu scaffold as one main commit and publish it."
  @spec scaffold!(String.t(), String.t(), [{String.t(), binary()}], String.t()) :: map()
  def scaffold!(base_dir, name, entries, author) do
    manifest_relative = Path.join(["kungfu", name, "manifest.toml"])
    manifest = entries |> Map.new() |> Map.fetch!(manifest_relative)
    _purpose = bundle_manifest!(manifest, manifest_relative).purpose

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
    expected_prior = git_output!(dir, ["rev-parse", @live])

    paths =
      Enum.map(entries, fn {relative, content} ->
        path = Path.join(dir, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
        path
      end)

    fingerprint =
      try do
        validate_candidate_tree!(dir, expected_prior)
      rescue
        error ->
          Enum.each(paths, &File.rm/1)
          reraise error, __STACKTRACE__
      end

    git!(dir, ["add", "-A", "--" | Enum.map(entries, &elem(&1, 0))])
    git!(dir, ["commit", "-m", "kungfu-scaffold: #{name}"], author)
    candidate_result(dir, expected_prior, fingerprint) |> Map.put(:paths, paths)
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
        expected_prior = git_output!(dir, ["rev-parse", @live])
        upstream_prior = git_output!(dir, ["rev-parse", @upstream])
        product_base = product_base_info(dir, upstream_prior, expected_prior)
        learned = learned_bundle_names(dir)
        receipt = bundle_receipt(name, bundle)

        import_product_snapshot!(
          dir,
          learned ++ [name],
          "learn: #{name}",
          product_base,
          expected_prior,
          upstream_prior
        )

        case merge_upstream(dir, "learn: #{name}", author, expected_prior, fn ->
               missing =
                 Enum.reject(receipt.paths, &File.regular?(Path.join(dir, &1)))

               case missing do
                 [] ->
                   write_receipt!(dir, receipt)

                 paths ->
                   {:error,
                    "cannot learn #{name}: merged identity is missing shipped bundle paths: " <>
                      Enum.join(paths, ", ")}
               end
             end) do
          {:ok, revision} -> {:ok, revision}
          other -> other
        end
    end
  end

  @doc "Remove one learned kungfu bundle by its committed receipt."
  @spec unlearn!(String.t(), String.t(), String.t()) :: map()
  def unlearn!(base_dir, name, author) do
    init!(base_dir)
    dir = identity_dir(base_dir)
    receipt = read_receipt!(dir, "main", name)
    require_clean_main!(dir)
    expected_prior = git_output!(dir, ["rev-parse", @live])

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

    fingerprint =
      try do
        remove_empty_parent_dirs!(dir, [receipt_path | receipt.paths])
        validate_candidate_tree!(dir, expected_prior)
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
    candidate_result(dir, expected_prior, fingerprint)
  end

  @doc "Bundle-owned archetype names recorded by a learned receipt."
  @spec bundle_archetype_names!(String.t(), String.t()) :: [String.t()]
  def bundle_archetype_names!(base_dir, name) do
    bundle_archetype_names_at!(base_dir, "main", name)
  end

  @doc "Bundle-owned archetype names recorded by a learned receipt at `revision`."
  @spec bundle_archetype_names_at!(String.t(), String.t(), String.t()) :: [String.t()]
  def bundle_archetype_names_at!(base_dir, revision, name) do
    dir = identity_dir(base_dir)

    dir
    |> read_receipt!(revision, name)
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

  @doc "Kungfu bundles shipped with this Tightbeam build and their offer metadata."
  @spec available_bundles() :: [
          %{
            name: String.t(),
            purpose: String.t(),
            phrases: [String.t()],
            root_archetype: String.t()
          }
        ]
  def available_bundles do
    available_bundle_names()
    |> Enum.map(fn name ->
      manifest =
        name
        |> bundle_dir()
        |> Path.join("manifest.toml")
        |> then(&bundle_manifest!(File.read!(&1), &1))

      %{
        name: name,
        purpose: manifest.purpose,
        phrases: manifest.phrases,
        root_archetype: manifest.root_archetype
      }
    end)
  end

  defp bundle_manifest!(content, path) do
    manifest = Toml.decode!(content)
    purpose = Map.fetch!(manifest, "purpose")

    unless is_binary(purpose) and String.trim(purpose) != "" do
      raise ArgumentError, "kungfu manifest purpose must be non-empty prose: #{path}"
    end

    phrases =
      case Map.fetch(manifest, "phrases") do
        :error ->
          []

        {:ok, phrases} ->
          unless is_list(phrases) and phrases != [] and
                   Enum.all?(phrases, &(is_binary(&1) and String.trim(&1) != "")) do
            raise ArgumentError,
                  "kungfu manifest phrases must be a non-empty list of non-empty prose: #{path}"
          end

          phrases
      end

    %{
      purpose: purpose,
      phrases: phrases,
      root_archetype: Map.fetch!(manifest, "root_archetype"),
      sentinels: sentinel_declarations!(Map.get(manifest, "sentinels", []), path),
      events: outside_events!(Map.get(manifest, "events", []), path)
    }
  end

  defp outside_events!(entries, path) when is_list(entries) do
    entries
    |> Enum.map(&sentinel_event!(&1, path, nil))
    |> unique_events!()
  end

  defp outside_events!(_entries, path),
    do: raise(ArgumentError, "events must be an array of tables: #{path}")

  defp unique_events!(events) do
    names = Enum.map(events, & &1.qualified)

    case names -- Enum.uniq(names) do
      [] -> events
      [duplicate | _] -> raise ArgumentError, "duplicate event #{duplicate}"
    end
  end

  defp manifest_events(manifest, bundle) do
    manifest.events ++
      Enum.flat_map(manifest.sentinels, fn sentinel ->
        Enum.map(sentinel.events, fn event ->
          Map.put(event, :qualified, "#{bundle}/#{sentinel.name}/#{event.name}")
        end)
      end)
  end

  @doc "The single event catalog, including declarations from ordinary scripts."
  def learned_events(base_dir) do
    dir = identity_dir(base_dir)
    revision = git_output!(dir, ["rev-parse", @live])

    learned_bundle_names(dir, revision)
    |> Enum.flat_map(fn bundle ->
      path = Path.join(["kungfu", bundle, "manifest.toml"])
      manifest = bundle_manifest!(git_show!(dir, revision, path), path)
      manifest_events(manifest, bundle)
    end)
    |> unique_events!()
    |> Enum.sort_by(& &1.qualified)
  end

  defp sentinel_declarations!(entries, path) when is_list(entries) do
    declarations = Enum.map(entries, &sentinel_declaration!(&1, path))
    names = Enum.map(declarations, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        declarations

      duplicates ->
        raise ArgumentError, "kungfu manifest declares sentinel #{hd(duplicates)} twice: #{path}"
    end
  end

  defp sentinel_declarations!(_entries, path),
    do: raise(ArgumentError, "kungfu manifest sentinels must be an array of tables: #{path}")

  defp sentinel_declaration!(entry, path) when is_map(entry) do
    case Map.keys(entry) -- @sentinel_keys do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "kungfu manifest sentinel has unknown keys #{Enum.join(Enum.sort(keys), ", ")}: #{path}"
    end

    name = Map.get(entry, "name")
    command = Map.get(entry, "command")
    requires = Map.get(entry, "requires")
    bundle = Path.basename(Path.dirname(path))

    unless is_binary(name) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/, name) do
      raise ArgumentError,
            "kungfu manifest sentinel name must match [A-Za-z0-9][A-Za-z0-9_-]*: #{path}"
    end

    unless bundle_relative_file?(command) and
             command not in [@bundle_setup_path | @bundle_doc_paths] do
      raise ArgumentError,
            "kungfu manifest sentinel #{name} command must be a file path inside the bundle: #{path}"
    end

    unless is_list(requires) and
             Enum.all?(requires, &(is_binary(&1) and Regex.match?(@env_name, &1))) do
      raise ArgumentError,
            "kungfu manifest sentinel #{name} requires must be a list of names matching [A-Z_][A-Z0-9_]*: #{path}"
    end

    %{
      name: name,
      command: command,
      requires: Enum.uniq(requires),
      events: sentinel_events!(Map.get(entry, "events", []), path, bundle, name)
    }
  end

  defp sentinel_declaration!(_entry, path),
    do: raise(ArgumentError, "kungfu manifest sentinels must be an array of tables: #{path}")

  defp sentinel_events!(events, path, bundle, sentinel) when is_list(events) do
    prefix = "#{bundle}/#{sentinel}"
    declarations = Enum.map(events, &sentinel_event!(&1, path, prefix))
    names = Enum.map(declarations, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        declarations

      duplicates ->
        name = hd(duplicates)
        raise ArgumentError, "duplicate event #{prefix}/#{name} in sentinel #{prefix}: #{path}"
    end
  end

  defp sentinel_events!(_events, path, bundle, sentinel),
    do:
      raise(
        ArgumentError,
        "events for sentinel #{bundle}/#{sentinel} must be an array of tables: #{path}"
      )

  defp sentinel_event!(entry, path, prefix) when is_map(entry) do
    name = Map.get(entry, "name")

    event_ref =
      if is_nil(prefix), do: name || "<unnamed>", else: "#{prefix}/#{name || "<unnamed>"}"

    case Map.keys(entry) -- @sentinel_event_keys do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "event #{event_ref} has unknown keys #{Enum.join(Enum.sort(keys), ", ")}: #{path}"
    end

    unless is_binary(name) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.\/-]*$/, name) do
      raise ArgumentError,
            "event #{event_ref} name must contain letters, digits, dots, slashes, underscores or hyphens: #{path}"
    end

    description = Map.get(entry, "description")

    unless is_binary(description) and String.trim(description) != "" do
      raise ArgumentError, "event #{event_ref} description must be non-empty: #{path}"
    end

    details = sentinel_event_details!(Map.get(entry, "details"), path, event_ref)
    detail_names = Enum.map(details, & &1.name)

    case detail_names -- Enum.uniq(detail_names) do
      [] ->
        :ok

      duplicates ->
        duplicate = hd(duplicates)
        raise ArgumentError, "event #{event_ref} has duplicate detail #{duplicate}: #{path}"
    end

    %{name: name, qualified: event_ref, description: description, details: details}
  end

  defp sentinel_event!(entry, path, prefix),
    do: raise(ArgumentError, "event entry for sentinel #{prefix} must be a table: #{path}")

  defp sentinel_event_details!(details, path, event_ref)
       when is_list(details) and details != [] do
    Enum.map(details, fn detail -> sentinel_event_detail!(detail, path, event_ref) end)
  end

  defp sentinel_event_details!(_details, path, event_ref),
    do: raise(ArgumentError, "event #{event_ref} must declare one or more details: #{path}")

  defp sentinel_event_detail!(detail, path, event_ref) when is_map(detail) do
    name = Map.get(detail, "name")
    detail_ref = if is_binary(name), do: name, else: "<unnamed>"

    case Map.keys(detail) -- @sentinel_event_detail_keys do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "event #{event_ref} detail #{detail_ref} has unknown keys #{Enum.join(Enum.sort(keys), ", ")}: #{path}"
    end

    unless is_binary(name) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/, name) do
      raise ArgumentError,
            "event #{event_ref} detail name #{detail_ref} must match [A-Za-z0-9][A-Za-z0-9_-]*: #{path}"
    end

    description = Map.get(detail, "description")

    unless is_binary(description) and String.trim(description) != "" do
      raise ArgumentError,
            "event #{event_ref} detail #{name} description must be non-empty: #{path}"
    end

    %{name: name, description: description}
  end

  defp sentinel_event_detail!(_detail, path, event_ref),
    do: raise(ArgumentError, "event #{event_ref} detail must be a table: #{path}")

  defp bundle_relative_file?(relative) when is_binary(relative) do
    segments = String.split(relative, "/")

    Path.type(relative) == :relative and
      Enum.all?(
        segments,
        &(&1 not in ["", ".", ".."] and Regex.match?(~r/^[A-Za-z0-9_.-]+$/, &1))
      )
  end

  defp bundle_relative_file?(_relative), do: false

  @doc """
  Sentinels declared by the learned bundles of the published identity.

  Each command path is the bundle-namespaced file at `revision`; the supervisor
  runs exactly those bytes.
  """
  @spec learned_sentinels(String.t()) :: %{
          revision: String.t(),
          sentinels: [
            %{
              bundle: String.t(),
              name: String.t(),
              qualified: String.t(),
              command_path: String.t(),
              requires: [String.t()],
              events: [map()]
            }
          ]
        }
  def learned_sentinels(base_dir) do
    dir = identity_dir(base_dir)
    revision = git_output!(dir, ["rev-parse", @live])

    sentinels =
      Enum.flat_map(learned_bundle_names(dir, revision), fn bundle ->
        try do
          for sentinel <- live_bundle_sentinels(dir, revision, bundle) do
            %{
              bundle: bundle,
              name: sentinel.name,
              qualified: "#{bundle}/#{sentinel.name}",
              command_path: Path.join(["kungfu", bundle, sentinel.command]),
              requires: sentinel.requires,
              events:
                Enum.map(sentinel.events, fn event ->
                  Map.merge(event, %{qualified: "#{bundle}/#{sentinel.name}/#{event.name}"})
                end)
            }
          end
        rescue
          error ->
            Logger.warning("sentinel bundle #{bundle} unavailable: #{Exception.message(error)}")
            []
        end
      end)

    %{revision: revision, sentinels: sentinels}
  end

  @doc """
  One bundle's setup source: whether the published identity has it learned, its
  published `setup.md` text, and the sentinels the shipped bundle declares, so a
  bundle learned before it shipped a sentinel can say one awaits `identity relearn`.
  """
  @spec bundle_setup_source(String.t(), String.t()) :: %{
          learned: boolean(),
          setup_text: String.t() | nil,
          shipped_sentinels: [String.t()]
        }
  def bundle_setup_source(base_dir, name) do
    validate_name!(name)
    dir = identity_dir(base_dir)
    revision = git_output!(dir, ["rev-parse", @live])
    learned = name in learned_bundle_names(dir, revision)
    setup_path = Path.join(["kungfu", name, @bundle_setup_path])

    shipped =
      if name in available_bundle_names() do
        manifest_path = Path.join(bundle_dir(name), "manifest.toml")
        bundle_manifest!(File.read!(manifest_path), manifest_path).sentinels
      else
        []
      end

    %{
      learned: learned,
      setup_text:
        if(learned and path_exists_at?(dir, revision, setup_path),
          do: git_show_bytes!(dir, revision, setup_path)
        ),
      shipped_sentinels: Enum.map(shipped, & &1.name)
    }
  end

  @doc "Read a published file without initializing or changing the identity tree."
  def published_file_bytes!(base_dir, path),
    do: revision_file_bytes!(base_dir, @live, path)

  @doc "The exact bytes of a file in the published identity at `revision`."
  @spec revision_file_bytes!(String.t(), String.t(), String.t()) :: binary()
  def revision_file_bytes!(base_dir, revision, path),
    do: git_show_bytes!(identity_dir(base_dir), revision, path)

  defp live_bundle_sentinels(dir, revision, bundle) do
    manifest_path = Path.join(["kungfu", bundle, "manifest.toml"])

    if path_exists_at?(dir, revision, manifest_path) do
      bundle_manifest!(git_show!(dir, revision, manifest_path), manifest_path).sentinels
    else
      []
    end
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
    expected_prior = git_output!(dir, ["rev-parse", @live])
    upstream_prior = git_output!(dir, ["rev-parse", @upstream])
    product_base = product_base_info(dir, upstream_prior, expected_prior)
    learned = learned_bundle_names(dir)
    names = ["neutral-identity" | learned]
    message = "relearn: #{Enum.join(names, ", ")}"
    import_product_snapshot!(dir, learned, message, product_base, expected_prior, upstream_prior)

    merge_upstream(dir, message, author, expected_prior, fn ->
      refresh_receipts!(dir, learned)
    end)
  end

  @doc "Abort a conflicted re-learn without moving live."
  @spec abort_relearn!(String.t()) :: :ok
  def abort_relearn!(base_dir) do
    dir = identity_dir(base_dir)
    require_conflict!(dir)
    incoming = git_output!(dir, ["rev-parse", "MERGE_HEAD"])
    git!(dir, ["merge", "--abort"])
    delete_product_incoming!(dir, incoming)
    :ok
  end

  @doc "Commit operator-resolved conflicts and publish live."
  @spec resolve_relearn!(String.t(), String.t()) :: map()
  def resolve_relearn!(base_dir, author) do
    dir = identity_dir(base_dir)
    require_conflict!(dir)

    case conflict_paths(dir) do
      [] -> :ok
      paths -> raise ArgumentError, "unresolved identity conflicts: #{Enum.join(paths, ", ")}"
    end

    refresh_receipts_for_merge!(dir, merge_subject(dir))
    expected_prior = git_output!(dir, ["rev-parse", @live])
    fingerprint = validate_candidate_tree!(dir, expected_prior)

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--no-edit"], author)
    candidate_result(dir, expected_prior, fingerprint)
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
      conflicting_paths: conflicts,
      provenance_conflicts: provenance_conflicts_at_merge(dir)
    }
  end

  @doc "Explain relearn conflicts whose prior product base could not be proven."
  @spec provenance_conflicts(String.t()) :: [map()]
  def provenance_conflicts(base_dir), do: provenance_conflicts_at_merge(identity_dir(base_dir))

  defp identity_dir(base_dir), do: Path.join(base_dir, "identity")

  defp seed_dir do
    Application.get_env(
      :tightbeam,
      :identity_seed_dir,
      Application.app_dir(:tightbeam, "priv/seed")
    )
  end

  defp bundle_root_dir do
    Application.get_env(
      :tightbeam,
      :kungfu_bundle_root_dir,
      Application.app_dir(:tightbeam, "priv/kungfu")
    )
  end

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

  defp product_guidance_entries do
    manual =
      case Application.get_env(:tightbeam, :identity_product_guidance_dir) do
        nil -> Map.fetch!(Archetypes.builtin_fragments(), "operating-manual.md")
        guidance_dir -> File.read!(Path.join(guidance_dir, "operating-manual.md"))
      end

    [{"guidance/operating-manual.md", manual}]
  end

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
    commands = bundle_sentinel_commands!(name, bundle)
    namespaced = [@bundle_setup_path | @bundle_doc_paths] ++ commands

    bundle
    |> source_entries()
    |> Enum.map(fn {relative, bytes} ->
      if relative in namespaced,
        do: {Path.join(["kungfu", name, relative]), bytes},
        else: {relative, bytes}
    end)
  end

  # Declared sentinel commands, each checked to be a file the bundle ships.
  defp bundle_sentinel_commands!(name, bundle) do
    manifest_path = Path.join(bundle, "manifest.toml")
    manifest = bundle_manifest!(File.read!(manifest_path), manifest_path)

    Enum.map(manifest.sentinels, fn sentinel ->
      unless File.regular?(Path.join(bundle, sentinel.command)) do
        raise ArgumentError,
              "kungfu bundle #{name} declares sentinel #{sentinel.name} command " <>
                "#{sentinel.command}, which the bundle does not ship"
      end

      sentinel.command
    end)
  end

  defp bundle_receipt(name, bundle) do
    %{
      name: name,
      paths: bundle_entries(name, bundle) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    }
  end

  defp product_base_info(dir, upstream_prior, expected_live) do
    previous_baseline = optional_ref_oid(dir, @product_baseline)
    upstream_paths = tree_paths(dir, upstream_prior)

    baseline =
      if previous_baseline && ancestor?(dir, previous_baseline, expected_live),
        do: previous_baseline

    recovered =
      if baseline,
        do: {:baseline, baseline},
        else: recover_legacy_product_base(dir, upstream_prior, expected_live)

    {oid, source, unknown_paths} =
      case recovered do
        {:baseline, revision} ->
          unknown_product_paths =
            Enum.filter(@product_path_overrides, &is_nil(tree_entry(dir, revision, &1)))

          {revision, "product-baseline-ref", unknown_product_paths}

        {:legacy, revision, unknown_seed_paths} ->
          {revision, "legacy-upstream-history",
           Enum.uniq(unknown_seed_paths ++ @product_path_overrides)}

        nil ->
          {nil, "historical-base-unavailable",
           upstream_paths ++ @seed_owned_paths ++ @product_path_overrides}
      end

    product_paths =
      (if(oid, do: tree_paths(dir, oid), else: []) ++
         upstream_paths ++
         @seed_owned_paths ++
         @product_path_overrides)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      oid: oid,
      source: source,
      unknown_paths: Enum.uniq(unknown_paths),
      product_paths: product_paths,
      previous_baseline: previous_baseline
    }
  end

  defp recover_legacy_product_base(dir, upstream, live) do
    case latest_upstream_ancestor(dir, upstream, live) do
      nil ->
        nil

      revision ->
        roots =
          dir
          |> git_output!(["rev-list", "--max-parents=0", "--reverse", revision])
          |> String.split("\n", trim: true)

        seed_root =
          case roots do
            [root] ->
              if git_output!(dir, ["show", "-s", "--format=%s", root]) == "seed: neutral-identity",
                do: root

            _ ->
              nil
          end

        unknown_seed_paths =
          if seed_root do
            Enum.reject(@seed_owned_paths, fn path ->
              tree_entry(dir, revision, path) == tree_entry(dir, seed_root, path)
            end)
          else
            @seed_owned_paths
          end

        {:legacy, revision, unknown_seed_paths}
    end
  end

  defp latest_upstream_ancestor(dir, upstream, live) do
    latest_upstream_ancestor(dir, upstream, live, MapSet.new())
  end

  defp latest_upstream_ancestor(dir, revision, live, seen) do
    cond do
      MapSet.member?(seen, revision) ->
        nil

      ancestor?(dir, revision, live) ->
        revision

      true ->
        case System.cmd("git", ["rev-parse", "--verify", "#{revision}^1"],
               cd: dir,
               stderr_to_stdout: true
             ) do
          {parent, 0} ->
            latest_upstream_ancestor(dir, String.trim(parent), live, MapSet.put(seen, revision))

          {_output, _status} ->
            nil
        end
    end
  end

  defp ancestor?(dir, possible_ancestor, revision) do
    case System.cmd("git", ["merge-base", "--is-ancestor", possible_ancestor, revision], cd: dir) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp optional_ref_oid(dir, ref) do
    full_ref = "refs/heads/#{ref}"

    case System.cmd("git", ["rev-parse", "--verify", "--quiet", full_ref],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {oid, 0} -> String.trim(oid)
      {_output, 1} -> nil
      {output, status} -> raise "git rev-parse #{full_ref} failed (#{status}): #{output}"
    end
  end

  defp tree_paths(dir, revision) do
    git_output!(dir, ["ls-tree", "-r", "--name-only", revision])
    |> String.split("\n", trim: true)
  end

  defp tree_entry(dir, revision, path) do
    case System.cmd("git", ["ls-tree", "-r", "-z", revision, "--", ":(literal)#{path}"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.split(output, <<0>>, trim: true) do
          [entry | _] ->
            case String.split(entry, "\t", parts: 2) do
              [header, _path] ->
                case String.split(header, " ", trim: true) do
                  [mode, "blob", oid] -> {mode, oid}
                  [mode, "commit", oid] -> {mode, oid}
                  _ -> nil
                end

              _ ->
                nil
            end

          [] ->
            nil
        end

      {output, status} ->
        raise "git ls-tree failed (#{status}): #{output}"
    end
  end

  defp describe_tree_entry(nil), do: %{"present" => false}

  defp describe_tree_entry({mode, oid}),
    do: %{"present" => true, "mode" => mode, "oid" => oid}

  defp delete_product_incoming!(dir, expected) do
    case optional_ref_oid(dir, @product_incoming) do
      ^expected -> git!(dir, ["update-ref", "-d", "refs/heads/#{@product_incoming}", expected])
      _ -> :ok
    end
  end

  defp git_output_bytes!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  defp git_input!(dir, args, input) do
    # Port.command/2 only sends iodata; it cannot signal EOF to Git. Keep the
    # supported commands fixed and redirect a private file so Git reads the
    # complete transaction, observes EOF, and returns its real exit status.
    command =
      case args do
        ["update-index", "-z", "--index-info"] -> "git update-index -z --index-info"
        ["update-ref", "--stdin"] -> "git update-ref --stdin"
        _ -> raise ArgumentError, "unsupported git stdin command: #{inspect(args)}"
      end

    input_name = ".tightbeam-git-input-#{System.unique_integer([:positive, :monotonic])}"
    input_path = Path.join(dir, input_name)
    File.write!(input_path, input, [:binary, :exclusive])

    try do
      case System.shell("#{command} < #{input_name}",
             cd: dir,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          :ok

        {output, status} ->
          raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
      end
    after
      File.rm(input_path)
    end
  end

  defp import_product_snapshot!(
         dir,
         bundle_names,
         message,
         product_base,
         expected_live,
         upstream_prior
       ) do
    entries =
      seed_entries() ++
        Enum.flat_map(bundle_names, fn name ->
          bundle = bundle_dir(name)
          refuse_seed_owned_bundle_paths!(name, bundle)
          bundle_entries(name, bundle)
        end) ++ product_guidance_entries()

    executables =
      Enum.flat_map(bundle_names, fn name ->
        name
        |> bundle_sentinel_commands!(bundle_dir(name))
        |> Enum.map(&Path.join(["kungfu", name, &1]))
      end)

    case optional_ref_oid(dir, @product_incoming) do
      nil ->
        :ok

      pending ->
        if product_snapshot_metadata_if_present(dir, pending) && ancestor?(dir, pending, "main") do
          raise ArgumentError, "identity has an unpublished product relearn candidate"
        else
          git!(dir, ["update-ref", "-d", "refs/heads/#{@product_incoming}", pending])
        end
    end

    incoming_paths = Enum.map(entries, &elem(&1, 0))

    unknown_paths =
      if(is_nil(product_base.oid),
        do: product_base.unknown_paths ++ incoming_paths,
        else: product_base.unknown_paths
      )
      |> Enum.uniq()

    product_paths =
      (product_base.product_paths ++ incoming_paths ++ @seed_owned_paths)
      |> Enum.uniq()
      |> Enum.sort()

    metadata = %{
      "version" => 1,
      "base_oid" => product_base.oid,
      "base_source" => product_base.source,
      "previous_upstream" => upstream_prior,
      "previous_baseline" => product_base.previous_baseline,
      "expected_live" => expected_live,
      "product_paths" => product_paths,
      "provenance_conflicts" => []
    }

    try do
      if product_base.oid do
        git!(dir, ["switch", "-C", @product_incoming, product_base.oid])
      else
        git!(dir, ["switch", "--orphan", @product_incoming])
      end

      replace_with_entries!(dir, entries)
      Enum.each(executables, &File.chmod!(Path.join(dir, &1), 0o755))
      git!(dir, ["add", "-A"])
      incoming_tree = git_output!(dir, ["write-tree"])

      metadata =
        Map.put(
          metadata,
          "provenance_conflicts",
          provenance_conflict_details(
            dir,
            unknown_paths,
            "main",
            incoming_tree,
            product_base
          )
        )

      encoded_metadata =
        metadata
        |> :erlang.term_to_binary([:deterministic])
        |> Base.url_encode64(padding: false)

      product_commit_message =
        message <> "\n\n" <> @product_metadata_trailer <> ": " <> encoded_metadata

      git!(dir, ["commit", "--allow-empty", "-m", product_commit_message], "tightbeam")
      incoming = git_output!(dir, ["rev-parse", @product_incoming])
      git!(dir, ["switch", "main"])
      incoming
    rescue
      error ->
        if git_output!(dir, ["branch", "--show-current"]) == @product_incoming do
          git!(dir, ["switch", "main"])
        end

        if optional_ref_oid(dir, @product_incoming),
          do: git!(dir, ["update-ref", "-d", "refs/heads/#{@product_incoming}"])

        reraise error, __STACKTRACE__
    end
  end

  defp provenance_conflict_details(dir, unknown_paths, org_revision, incoming_tree, product_base) do
    Enum.flat_map(unknown_paths, fn path ->
      org_entry = tree_entry(dir, org_revision, path)
      incoming_entry = tree_entry(dir, incoming_tree, path)
      base_entry = if product_base.oid, do: tree_entry(dir, product_base.oid, path)

      if org_entry == incoming_entry or
           (is_nil(org_entry) and proven_new_product_path_absence?(dir, org_revision, path)) do
        []
      else
        [
          %{
            "path" => path,
            "base_source" =>
              if(is_nil(base_entry),
                do: "historical-base-unavailable",
                else: product_base.source
              ),
            "base" => describe_tree_entry(base_entry),
            "org" => describe_tree_entry(org_entry),
            "incoming" => describe_tree_entry(incoming_entry)
          }
        ]
      end
    end)
  end

  defp proven_new_product_path_absence?(dir, org_revision, path) do
    # A missing current entry alone can be a committed org deletion. Accept it as
    # fresh only when the identity has its neutral seed root and no path history.
    path in @product_path_overrides and
      neutral_seed_root?(dir, org_revision) and
      not path_in_history?(dir, org_revision, path)
  end

  defp neutral_seed_root?(dir, revision) do
    roots =
      dir
      |> git_output!(["rev-list", "--max-parents=0", revision])
      |> String.split("\n", trim: true)

    case roots do
      [root] ->
        git_output!(dir, ["show", "-s", "--format=%s", root]) == "seed: neutral-identity"

      _ ->
        false
    end
  end

  defp path_in_history?(dir, revision, path) do
    case System.cmd(
           "git",
           ["log", "--full-history", "--format=%H", revision, "--", ":(literal)#{path}"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {commits, 0} ->
        String.trim(commits) != ""

      {output, status} ->
        raise "git log for #{path} failed (#{status}): #{output}"
    end
  end

  defp merge_upstream(dir, message, author, expected_prior, before_commit) do
    incoming = git_output!(dir, ["rev-parse", @product_incoming])
    metadata = product_snapshot_metadata!(dir, incoming)

    try do
      merge_args = ["merge", "--no-ff", "--no-commit"]

      merge_args =
        if is_nil(metadata["base_oid"]),
          do: merge_args ++ ["--allow-unrelated-histories"],
          else: merge_args

      merge_args = merge_args ++ [@product_incoming, "-m", message]

      case System.cmd("git", merge_args,
             cd: dir,
             stderr_to_stdout: true,
             env: git_env(author)
           ) do
        {output, status} ->
          if status != 0 and conflict_paths(dir) == [] do
            cleanup_product_merge!(dir, incoming)
            {:error, String.trim(output)}
          else
            force_provenance_conflicts!(dir, metadata)

            case conflict_paths(dir) do
              paths when paths != [] ->
                {:conflict, paths}

              [] ->
                case run_pre_merge_hook(dir, author) do
                  {_hook_output, 0} ->
                    case run_before_commit(before_commit, dir, incoming, expected_prior) do
                      {:ok, fingerprint} ->
                        git!(dir, ["add", "-A"])
                        git!(dir, ["commit", "-m", message], author)
                        {:ok, candidate_result(dir, expected_prior, fingerprint)}

                      {:error, reason} ->
                        cleanup_product_merge!(dir, incoming)
                        {:error, reason}
                    end

                  {hook_output, _hook_status} ->
                    cleanup_product_merge!(dir, incoming)
                    {:error, String.trim(hook_output)}
                end
            end
          end
      end
    rescue
      error ->
        if merge_pending?(dir) do
          cleanup_product_merge!(dir, incoming)
        else
          delete_product_incoming!(dir, incoming)
        end

        reraise error, __STACKTRACE__
    end
  end

  defp run_before_commit(callback, dir, incoming, expected_prior) do
    case callback.() do
      :ok ->
        try do
          {:ok, validate_candidate_tree!(dir, expected_prior)}
        rescue
          error ->
            cleanup_product_merge!(dir, incoming)
            reraise error, __STACKTRACE__
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, "pre-commit identity callback returned #{inspect(other)}"}
    end
  rescue
    error ->
      cleanup_product_merge!(dir, incoming)
      reraise error, __STACKTRACE__
  end

  defp force_provenance_conflicts!(dir, metadata) do
    metadata
    |> Map.get("provenance_conflicts", [])
    |> Enum.each(fn conflict ->
      path = Map.fetch!(conflict, "path")
      org_entry = tree_entry(dir, "main", path)
      incoming_entry = tree_entry(dir, "MERGE_HEAD", path)

      git!(dir, ["update-index", "--force-remove", "--", path])

      stages =
        [{2, org_entry}, {3, incoming_entry}]
        |> Enum.flat_map(fn
          {_stage, nil} -> []
          {stage, entry} -> [index_info_line(entry, stage, path)]
        end)

      if stages != [],
        do: git_input!(dir, ["update-index", "-z", "--index-info"], IO.iodata_to_binary(stages))

      restore_tree_path!(dir, path, org_entry || incoming_entry)
    end)
  end

  defp index_info_line({mode, oid}, stage, path),
    do: [mode, " ", oid, " ", Integer.to_string(stage), "\t", path, <<0>>]

  defp restore_tree_path!(dir, path, nil), do: File.rm_rf!(Path.join(dir, path))

  defp restore_tree_path!(dir, path, {mode, oid}) do
    destination = Path.join(dir, path)
    File.rm_rf!(destination)
    File.mkdir_p!(Path.dirname(destination))
    bytes = git_output_bytes!(dir, ["cat-file", "blob", oid])

    case mode do
      "120000" ->
        File.ln_s!(bytes, destination)

      "160000" ->
        :ok

      _ ->
        File.write!(destination, bytes)
        if mode == "100755", do: File.chmod!(destination, 0o755)
    end
  end

  defp cleanup_product_merge!(dir, incoming) do
    if merge_pending?(dir), do: git!(dir, ["merge", "--abort"])
    delete_product_incoming!(dir, incoming)
  end

  defp product_snapshot_metadata_if_present(dir, revision) do
    message = git_output!(dir, ["show", "-s", "--format=%B", revision])

    encoded =
      message
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case String.split(line, ": ", parts: 2) do
          [@product_metadata_trailer, value] -> value
          _ -> nil
        end
      end)

    case encoded do
      nil ->
        nil

      value ->
        metadata =
          case Base.url_decode64(value, padding: false) do
            {:ok, payload} ->
              try do
                :erlang.binary_to_term(payload, [:safe])
              rescue
                _ -> :invalid
              end

            _ ->
              :invalid
          end

        case metadata do
          %{"version" => 1} = metadata ->
            metadata

          _ ->
            raise ArgumentError,
                  "identity product snapshot #{revision} has invalid provenance metadata"
        end
    end
  end

  defp product_snapshot_metadata!(dir, revision) do
    product_snapshot_metadata_if_present(dir, revision) ||
      raise ArgumentError, "identity product snapshot #{revision} has no provenance metadata"
  end

  defp provenance_conflicts_at_merge(dir) do
    if merge_pending?(dir) do
      incoming = git_output!(dir, ["rev-parse", "MERGE_HEAD"])

      case product_snapshot_metadata_if_present(dir, incoming) do
        nil -> []
        metadata -> Map.get(metadata, "provenance_conflicts", [])
      end
    else
      []
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

  defp learned_bundle_names(dir, revision \\ "main") do
    git_output!(dir, ["ls-tree", "-r", "--name-only", revision, "--", "kungfu"])
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

  defp remove_empty_parent_dirs!(dir, paths) do
    paths
    |> Enum.flat_map(&parent_dirs/1)
    |> Enum.uniq()
    |> Enum.sort_by(&(length(Path.split(&1)) * -1))
    |> Enum.each(fn relative ->
      case File.rmdir(Path.join(dir, relative)) do
        :ok ->
          :ok

        {:error, reason} when reason in [:enoent, :eexist, :enotempty] ->
          :ok

        {:error, reason} ->
          raise File.Error, action: "remove directory", path: relative, reason: reason
      end
    end)
  end

  defp parent_dirs(relative) do
    if Path.type(relative) == :relative and ".." not in Path.split(relative) do
      parent_dirs(Path.dirname(relative), [])
    else
      []
    end
  end

  defp parent_dirs(relative, parents) when relative in [".", ".."], do: parents

  defp parent_dirs(relative, parents) do
    parent_dirs(Path.dirname(relative), [relative | parents])
  end

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
    shipped = bundle_receipt(name, bundle_dir(name))

    previously_owned =
      case receipt_at(dir, "main", name) do
        {:ok, receipt} -> receipt.paths
        :error -> []
      end

    newly_installed =
      shipped.paths
      |> Enum.reject(&(&1 in previously_owned))
      |> Enum.filter(&index_matches_revision?(dir, "MERGE_HEAD", &1))

    paths =
      (previously_owned ++ newly_installed)
      |> Enum.uniq()
      |> Enum.filter(&File.regular?(Path.join(dir, &1)))
      |> Enum.sort()

    %{shipped | paths: paths}
  end

  defp index_matches_revision?(dir, revision, path) do
    case System.cmd("git", ["diff", "--cached", "--quiet", revision, "--", path], cd: dir) do
      {_output, 0} -> true
      {_output, 1} -> false
      {output, status} -> raise "git diff failed #{status}: #{output}"
    end
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
        publish_live_unmarked!(dir)
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

  defp revision_catalog!(dir, revision) do
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

    paths
    |> Enum.map(&{&1, git_show_bytes!(dir, revision, &1)})
    |> Renderer.catalog!()
    |> Map.put_new("operating-manual.md", %{
      path: "substrate:priv/guidance/operating-manual.md",
      bytes: Archetypes.builtin_fragments()["operating-manual.md"]
    })
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

  defp validate_candidate_tree!(dir, expected_prior) do
    fingerprint = tree_fingerprint!(dir)

    try do
      validate_tree!(dir)
      fingerprint
    rescue
      error in Tightbeam.Identity.IncludeError ->
        reraise Tightbeam.Identity.IncludeError.with_candidate(
                  error,
                  fingerprint,
                  expected_prior
                ),
                __STACKTRACE__
    end
  end

  defp validate_tree!(dir) do
    refuse_reserved_substrate_skills!(dir)

    dir
    |> Path.join("kungfu/*/manifest.toml")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      manifest = bundle_manifest!(File.read!(path), path)
      manifest_events(manifest, Path.basename(Path.dirname(path)))
    end)
    |> unique_events!()

    entries =
      dir
      |> Path.join("guidance/**/*.md")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&{Path.relative_to(&1, dir), File.read!(&1)})

    catalog =
      entries
      |> Renderer.catalog!()
      |> Map.put_new("operating-manual.md", %{
        path: "substrate:priv/guidance/operating-manual.md",
        bytes: Archetypes.builtin_fragments()["operating-manual.md"]
      })

    Enum.each(@universal_roots, fn name ->
      entry = required_catalog_entry!(catalog, name, "candidate-tree")
      Renderer.render!(entry.bytes, entry.path, catalog, universal_root: name)
    end)

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
      _ = Archetypes.guidance_render(archetype, catalog)
      missing = Enum.reject(archetype.skills, &MapSet.member?(skills, &1))

      if missing != [] do
        raise ArgumentError,
              "archetype #{archetype.name} elects unknown skills: #{Enum.join(missing, ", ")}"
      end
    end)
  end

  defp validate_revision_dir!(dir, revision) do
    catalog = revision_catalog!(dir, revision)

    Enum.each(@universal_roots, fn name ->
      entry = required_catalog_entry!(catalog, name, revision)
      Renderer.render!(entry.bytes, entry.path, catalog, universal_root: name)
    end)

    dir
    |> git_output!(["ls-tree", "-r", "--name-only", revision, "--", "archetypes"])
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.ends_with?(&1, ".toml"))
    |> Enum.each(fn path ->
      archetype = Archetypes.parse_manifest!(git_show!(dir, revision, path), path)
      _ = Archetypes.guidance_render(archetype, catalog)

      Enum.each(archetype.skills, fn skill ->
        unless skill in Tightbeam.Homes.baseline_skill_names() or
                 path_exists_at?(dir, revision, "skills/#{skill}/SKILL.md") do
          raise ArgumentError, "archetype #{archetype.name} elects unknown skill: #{skill}"
        end
      end)
    end)

    Enum.each(Tightbeam.Homes.baseline_skill_names(), fn name ->
      if path_exists_at?(dir, revision, "skills/#{name}/SKILL.md") do
        raise ArgumentError,
              "identity revision #{revision} contains reserved substrate skill #{name}"
      end
    end)

    :ok
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

  @doc "Revalidate an exact candidate commit and advance live from its expected prior OID."
  @spec publish_live!(String.t(), map()) :: {:ok, String.t()} | {:error, map()}
  def publish_live!(base_dir, candidate) do
    dir = identity_dir(base_dir)
    revision = Map.fetch!(candidate, :candidate_revision)
    expected = Map.fetch!(candidate, :expected_prior)
    validate_revision_dir!(dir, revision)

    with_live_revision_lock_in_dir(dir, fn actual ->
      cond do
        actual == revision ->
          {:ok, revision}

        actual != expected ->
          {:error, %{code: "identity_publication_conflict", expected: expected, actual: actual}}

        true ->
          case System.cmd("git", ["merge-base", "--is-ancestor", expected, revision], cd: dir) do
            {_output, 0} ->
              case product_snapshot_for_candidate(dir, revision) do
                nil ->
                  git!(dir, ["update-ref", "refs/heads/#{@live}", revision, expected])
                  {:ok, revision}

                {incoming, metadata} ->
                  if metadata["expected_live"] != expected do
                    {:error,
                     %{
                       code: "identity_publication_conflict",
                       expected: metadata["expected_live"],
                       actual: expected
                     }}
                  else
                    publish_product_snapshot!(dir, revision, expected, incoming, metadata)
                  end
              end

            _ ->
              {:error, %{code: "identity_publication_non_fast_forward", expected: expected}}
          end
      end
    end)
  end

  defp publish_live_unmarked!(dir) do
    with_live_revision_lock_in_dir(dir, fn live ->
      main = git_output!(dir, ["rev-parse", "main"])
      validate_revision_dir!(dir, main)

      case System.cmd("git", ["merge-base", "--is-ancestor", live, main], cd: dir) do
        {_output, 0} ->
          case product_snapshot_for_candidate(dir, main) do
            nil ->
              git!(dir, ["update-ref", "refs/heads/#{@live}", main, live])

            {incoming, metadata} ->
              case publish_product_snapshot!(dir, main, live, incoming, metadata) do
                {:ok, _revision} ->
                  :ok

                {:error, result} ->
                  raise "cannot publish pending identity product snapshot: #{inspect(result)}"
              end
          end

        _ ->
          raise ArgumentError, "tightbeam/live cannot fast-forward to main"
      end

      main
    end)
  end

  defp product_snapshot_for_candidate(dir, revision) do
    case optional_ref_oid(dir, @product_incoming) do
      nil ->
        nil

      incoming ->
        case product_snapshot_metadata_if_present(dir, incoming) do
          nil ->
            nil

          metadata ->
            if first_parent_contains_product_merge?(dir, revision, incoming),
              do: {incoming, metadata},
              else: nil
        end
    end
  end

  defp first_parent_contains_product_merge?(dir, revision, incoming) do
    dir
    |> git_output!(["rev-list", "--first-parent", "--merges", revision])
    |> String.split("\n", trim: true)
    |> Enum.any?(fn merge ->
      case String.split(git_output!(dir, ["rev-list", "--parents", "-n", "1", merge]), " ",
             trim: true
           ) do
        [_commit, _first_parent, ^incoming] -> true
        _ -> false
      end
    end)
  end

  defp publish_product_snapshot!(dir, revision, expected_live, incoming, metadata) do
    expected_upstream = metadata["previous_upstream"]
    expected_baseline = metadata["previous_baseline"]

    if metadata["expected_live"] != expected_live do
      raise ArgumentError,
            "identity product snapshot was prepared against a different live revision"
    end

    commands = [
      "start",
      "update refs/heads/#{@live} #{revision} #{expected_live}",
      "update refs/heads/#{@upstream} #{incoming} #{expected_upstream}",
      if(expected_baseline,
        do: "update refs/heads/#{@product_baseline} #{incoming} #{expected_baseline}",
        else: "create refs/heads/#{@product_baseline} #{incoming}"
      ),
      "delete refs/heads/#{@product_incoming} #{incoming}",
      "prepare",
      "commit",
      ""
    ]

    try do
      git_input!(dir, ["update-ref", "--stdin"], Enum.join(commands, "\n"))
      {:ok, revision}
    rescue
      error ->
        {:error,
         %{
           code: "identity_publication_conflict",
           expected: expected_live,
           actual: git_output!(dir, ["rev-parse", @live]),
           detail: Exception.message(error)
         }}
    end
  end

  defp candidate_result(dir, expected_prior, fingerprint) do
    %{
      candidate_revision: git_output!(dir, ["rev-parse", "main"]),
      expected_prior: expected_prior,
      tree_fingerprint: fingerprint
    }
  end

  defp tree_fingerprint!(dir) do
    dir
    |> candidate_tree_entries("")
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(:crypto.hash_init(:sha256), fn {path, bytes}, context ->
      :crypto.hash_update(context, [path, <<0>>, bytes])
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp candidate_tree_entries(root, relative) do
    root
    |> Path.join(relative)
    |> File.ls!()
    |> Enum.reject(&(&1 == ".git" and relative == ""))
    |> Enum.sort()
    |> Enum.flat_map(fn entry ->
      child_relative = if relative == "", do: entry, else: Path.join(relative, entry)
      child = Path.join(root, child_relative)

      if File.dir?(child) do
        candidate_tree_entries(root, child_relative)
      else
        [{child_relative, File.read!(child)}]
      end
    end)
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

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
