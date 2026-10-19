defmodule Tightbeam.Homes do
  @moduledoc """
  Projects one generic shared home per `{harness, machine}`.

  Tight Beam owns the harness rails artifact, projection manifest,
  and substrate baseline skills, not credential contents. Regeneration is
  ownership-scoped: it never removes the home and therefore preserves
  harness-owned sessions, history, projects, transcripts, and memory
  byte-for-byte.

  IF YOU ADD A PATH THAT DOES REMOVE OR RECREATE A HOME, it must re-warm the
  harness afterwards. Some harnesses cache what the account is ENTITLED to in
  their own home -- claude keeps the extra models it may select there -- and
  Tightbeam fills that cache exactly once, when a credential is written
  (`Credentials.warm_home/3`). A home cleared without a credential write loses
  both its credential and that cache, and the model catalog
  silently narrows to the static floor: it reads as a smaller account, not as an
  emptied directory. Re-warm in the reset path; do not add cold-home detection
  here. Substrate baseline skills project separately from org
  identity and are never sourced from the org-editable skill library.

  Home reconciliation never reads, removes, copies, links, or writes credential
  contents. Before regular-file readiness is checked, the explicit legacy-link
  migration may copy one supported 0.1.8 home link from this installation's
  auth store. It keeps the auth referent and every other home intact.
  """

  alias Tightbeam.Harness
  alias Tightbeam.Harness.Support
  import Bitwise, only: [band: 2]

  @type harness :: atom()
  @type spec :: %{
          required(:harness) => harness(),
          required(:machine) => String.t(),
          optional(:rails) => binary() | nil
        }

  @type projected_home :: %{
          home_path: String.t(),
          manifest_path: String.t()
        }

  @manifest_relative Path.join(".tightbeam", "manifest")
  @legacy_auth_migration_prefix ".tightbeam-auth-migration-"
  @legacy_auth_migration_previous "previous-home-entry"
  @baseline_skill_names [
    "tightbeam-operating-manual",
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

  @doc "Harness-registry-owned leaf entries for a projected home."
  @spec owned_entries(harness()) :: [String.t()]
  def owned_entries(harness) do
    harness
    |> Harness.module!()
    |> then(& &1.owned_home_entries())
  end

  @doc "Project or ownership-scope-regenerate a shared home."
  @spec project(String.t(), spec()) :: projected_home()
  def project(base_dir, spec) do
    home = home_path(base_dir, spec.machine, spec.harness)
    module = Harness.module!(spec.harness)

    desired = %{
      harness: spec.harness,
      machine: spec.machine,
      rails: Map.get(spec, :rails)
    }

    desired =
      if module.id() == :cursor,
        do: Map.put(desired, :auth_dir, auth_dir(base_dir, module)),
        else: desired

    module.reconcile_home(
      %{
        base_dir: base_dir,
        host_name: spec.machine,
        host_config: %{ssh: nil, base_dir: base_dir},
        sh: &Support.system_cmd/1
      },
      home,
      desired
    )
  end

  @doc false
  def reconcile(target, home, desired, mechanics) do
    if Support.local?(target) do
      reconcile_local(home, desired, mechanics)
    else
      reconcile_remote(target, home, desired, mechanics)
    end
  end

  defp reconcile_local(home, desired, mechanics) do
    manifest_path = Path.join(home, @manifest_relative)
    manifest = manifest_bytes(desired)
    rails_filename = Keyword.get(mechanics, :rails_filename)

    File.mkdir_p!(home)

    unless File.read(manifest_path) == {:ok, manifest} do
      remove_owned_projection(
        home,
        rails_filename,
        Keyword.get(mechanics, :preserve_manifest_dir, false)
      )

      write_rails(home, rails_filename, Map.get(desired, :rails))
      File.mkdir_p!(Path.dirname(manifest_path))
      File.write!(manifest_path, manifest)
    end

    project_baseline_skills(home)

    case Keyword.fetch(mechanics, :credential_names) do
      {:ok, credential_names} ->
        %{
          home_path: home,
          manifest_path: manifest_path,
          linked_auth_files:
            project_auth(
              Map.fetch!(desired, :auth_dir),
              home,
              credential_names,
              Keyword.get(mechanics, :credential_projection, :link),
              Keyword.get(mechanics, :before_credential_projection_promote, fn _target -> :ok end)
            )
        }

      :error ->
        %{home_path: home, manifest_path: manifest_path}
    end
  end

  defp reconcile_remote(target, remote_home, desired, mechanics) do
    stage_base = Path.join([target.base_dir, "staging", target.host_name])
    staged_home = home_path(stage_base, desired.machine, desired.harness)
    File.rm_rf!(staged_home)

    staged =
      reconcile_local(
        staged_home,
        desired,
        mechanics
      )

    remote_manifest = Path.join(remote_home, @manifest_relative)

    {remote_stamp, stamp_exit} =
      target.sh.(["ssh" | Support.ssh_opts()] ++ [target.host_config.ssh, "cat", remote_manifest])

    if stamp_exit not in [0, 1], do: raise("remote stamp check failed with exit #{stamp_exit}")

    staged_stamp = File.read!(staged.manifest_path)

    rails_filename = Keyword.get(mechanics, :rails_filename)
    rails = rails_filename && Path.join(remote_home, rails_filename)

    if remote_stamp != staged_stamp do
      rails_removal = if rails, do: "rm -f \"#{rails}\"; ", else: ""

      script =
        "mkdir -p \"#{remote_home}\"; " <>
          rails_removal <>
          "rm -f \"#{remote_manifest}\"; "

      Support.run!(
        target,
        ["ssh" | Support.ssh_opts()] ++
          [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]
      )
    end

    Support.run!(target, [
      "rsync",
      "-a",
      "-e",
      Enum.join(["ssh" | Support.ssh_opts()], " "),
      staged_home <> "/",
      "#{target.host_config.ssh}:#{remote_home}/"
    ])

    %{home_path: remote_home, manifest_path: remote_manifest}
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

  @doc "Canonical shared home path."
  @spec home_path(String.t(), String.t(), harness()) :: String.t()
  def home_path(base_dir, machine, harness),
    do: Path.join([base_dir, "homes", machine, Atom.to_string(harness)])

  @doc false
  def materialize_legacy_auth_link(target, home, source) do
    path = Path.join(home, Path.basename(source))
    base_dir = target.host_config.base_dir

    result =
      if Support.local?(target) do
        materialize_local_auth_link(target, home, path, source)
      else
        materialize_remote_auth_link(target, base_dir, home, path, source)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, %{path: path, source: source, reason: reason}}
    end
  end

  @doc false
  def promote_staged_legacy_credential(staged, path) do
    case File.ln(staged, path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.lstat(path) do
          {:ok, %{type: :regular}} -> :ok
          _ -> {:error, :destination_changed}
        end

      {:error, _reason} ->
        {:error, :promotion_failed}
    end
  end

  defp materialize_local_auth_link(target, home, path, source) do
    with :ok <- recover_interrupted_local_migration(target, home, path, source) do
      case File.lstat(path) do
        {:error, :enoent} ->
          :ok

        {:ok, %{type: :regular}} ->
          :ok

        {:ok, %{type: :symlink}} ->
          case materialize_local_symlink(target, home, path, source) do
            :ok ->
              :ok

            {:error, _reason} = error ->
              case File.lstat(path) do
                {:ok, %{type: :regular}} ->
                  :ok

                _ ->
                  error
              end
          end

        {:ok, _stat} ->
          {:error, :unsupported_destination}

        {:error, _reason} ->
          {:error, :destination_unreadable}
      end
    end
  end

  defp recover_interrupted_local_migration(target, home, path, source) do
    case File.lstat(path) do
      {:error, :enoent} ->
        recover_missing_local_entry(target, home, path, source)

      {:ok, %{type: :regular}} ->
        :ok

      _ ->
        :ok
    end
  end

  defp recover_missing_local_entry(target, home, path, source) do
    case local_migration_recovery_stages(home) do
      {:ok, []} ->
        :ok

      {:ok, [stage_dir]} ->
        case recover_local_migration_stage(target, home, path, source, stage_dir) do
          :recovered -> :ok
          {:error, _reason} = error -> error
        end

      {:ok, _stages} ->
        {:error, :ambiguous_migration_recovery}

      {:error, _reason} = error ->
        error
    end
  end

  defp local_migration_recovery_stages(home) do
    case File.ls(home) do
      {:ok, names} ->
        Enum.reduce_while(names, {:ok, []}, fn name, {:ok, stages} ->
          if String.starts_with?(name, @legacy_auth_migration_prefix) do
            stage_dir = Path.join(home, name)
            displaced = Path.join(stage_dir, @legacy_auth_migration_previous)

            case File.lstat(displaced) do
              {:ok, _stat} ->
                if private_migration_stage?(stage_dir) do
                  {:cont, {:ok, [stage_dir | stages]}}
                else
                  {:halt, {:error, :ambiguous_migration_recovery}}
                end

              {:error, :enoent} ->
                {:cont, {:ok, stages}}

              {:error, _reason} ->
                {:halt, {:error, :destination_unreadable}}
            end
          else
            {:cont, {:ok, stages}}
          end
        end)

      {:error, :enoent} ->
        {:ok, []}

      {:error, _reason} ->
        {:error, :destination_unreadable}
    end
  end

  defp recover_local_migration_stage(target, home, path, source, stage_dir) do
    displaced = Path.join(stage_dir, @legacy_auth_migration_previous)

    with true <- private_migration_stage?(stage_dir),
         {:ok, displaced_stat} <- File.lstat(displaced) do
      case displaced_stat.type do
        :symlink ->
          recover_displaced_local_link(target, home, path, source, stage_dir, displaced)

        :regular ->
          case promote_staged_legacy_credential(displaced, path) do
            :ok ->
              if same_file?(displaced, path), do: remove_local_migration_stage(stage_dir, source)
              :recovered

            {:error, reason} ->
              {:error, reason}
          end

        _ ->
          {:error, :ambiguous_migration_recovery}
      end
    else
      false -> {:error, :ambiguous_migration_recovery}
      {:error, :enoent} -> {:error, :destination_changed}
      {:error, _reason} -> {:error, :destination_unreadable}
    end
  end

  defp recover_displaced_local_link(target, home, path, source, stage_dir, displaced) do
    with {:ok, link_text} <- File.read_link(displaced),
         true <- valid_interrupted_local_link?(target, home, path, source, link_text) do
      staged = Path.join(stage_dir, Path.basename(source))

      case {private_legacy_stage_file?(staged), File.lstat(source)} do
        {true, {:error, :enoent}} ->
          case promote_staged_legacy_credential(staged, path) do
            :ok ->
              if same_file?(staged, path), do: remove_local_migration_stage(stage_dir, source)
              :recovered

            {:error, _reason} ->
              restore_interrupted_local_link(displaced, path, link_text)
          end

        _ ->
          case restore_interrupted_local_link(displaced, path, link_text) do
            :recovered = recovered ->
              if staged_link_recovery_is_redundant?(staged, source) do
                remove_local_migration_stage(stage_dir, source)
              end

              recovered

            {:error, _reason} = error ->
              error
          end
      end
    else
      {:error, _reason} -> {:error, :unsafe_or_unreadable_link}
      false -> {:error, :unsafe_or_unreadable_link}
    end
  end

  defp valid_interrupted_local_link?(target, home, path, source, link_text) do
    case validate_local_legacy_link(target, home, path, source, link_text) do
      :ok ->
        true

      _ ->
        Path.expand(link_text, Path.dirname(path)) == Path.expand(source)
    end
  end

  defp restore_interrupted_local_link(displaced, path, link_text) do
    case File.lstat(path) do
      {:error, :enoent} ->
        case File.ln_s(link_text, path) do
          :ok -> :recovered
          {:error, :eexist} -> restore_interrupted_local_link(displaced, path, link_text)
          {:error, _reason} -> {:error, :destination_changed}
        end

      {:ok, %{type: :regular}} ->
        :recovered

      {:ok, %{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, ^link_text} -> :recovered
          _ -> {:error, :destination_changed}
        end

      _ ->
        {:error, :destination_changed}
    end
  end

  defp private_migration_stage?(stage_dir) do
    case File.lstat(stage_dir) do
      {:ok, %{type: :directory, mode: mode}} -> band(mode, 0o077) == 0
      _ -> false
    end
  end

  defp private_legacy_stage_file?(staged) do
    case File.lstat(staged) do
      {:ok, %{type: :regular, mode: mode}} -> band(mode, 0o077) == 0
      _ -> false
    end
  end

  defp staged_link_recovery_is_redundant?(staged, source) do
    case File.lstat(staged) do
      {:error, :enoent} ->
        true

      {:ok, %{type: :regular}} ->
        with true <- private_legacy_stage_file?(staged),
             {:ok, staged_bytes} <- File.read(staged),
             {:ok, source_bytes} <- File.read(source) do
          staged_bytes == source_bytes
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp same_file?(left, right) do
    with {:ok, left_stat} <- File.stat(left),
         {:ok, right_stat} <- File.stat(right) do
      left_stat.inode == right_stat.inode and
        left_stat.major_device == right_stat.major_device and
        left_stat.minor_device == right_stat.minor_device
    else
      _ -> false
    end
  end

  defp remove_local_migration_stage(stage_dir, source) do
    File.rm(Path.join(stage_dir, Path.basename(source)))
    File.rm(Path.join(stage_dir, @legacy_auth_migration_previous))
    File.rmdir(stage_dir)
    :ok
  end

  defp materialize_local_symlink(target, home, path, source) do
    with {:ok, link_text} <- local_link_text(path),
         {:ok, source_stat} <- local_regular_source(source),
         :ok <- validate_local_legacy_link(target, home, path, source, link_text),
         {:ok, bytes} <- read_local_source(source),
         {:ok, stat_after_read} <- File.lstat(source),
         true <- same_credential_stat?(source_stat, stat_after_read) do
      materialize_local_copy(target, home, path, source, link_text, source_stat, bytes)
    else
      {:error, reason}
      when reason in [:source_missing, :source_not_regular, :source_unreadable] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :unsafe_or_unreadable_link}

      false ->
        {:error, :source_changed}
    end
  end

  defp local_link_text(path) do
    case File.read_link(path) do
      {:ok, link_text} -> {:ok, link_text}
      {:error, _reason} -> {:error, :unsafe_or_unreadable_link}
    end
  end

  defp local_regular_source(source) do
    case File.lstat(source) do
      {:ok, %{type: :regular} = stat} -> {:ok, stat}
      {:ok, _stat} -> {:error, :source_not_regular}
      {:error, :enoent} -> {:error, :source_missing}
      {:error, _reason} -> {:error, :source_unreadable}
    end
  end

  defp read_local_source(source) do
    case File.read(source) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, :source_missing}
      {:error, _reason} -> {:error, :source_unreadable}
    end
  end

  defp validate_local_legacy_link(target, home, path, source, link_text) do
    base_dir = target.host_config.base_dir
    expected_home = Path.join([base_dir, "homes", target.host_name, Path.basename(home)])

    with {:ok, base_real} <- canonical_existing(base_dir),
         {:ok, auth_real} <- canonical_existing(Path.join(base_dir, "auth")),
         true <- auth_real == Path.join(base_real, "auth"),
         {:ok, homes_real} <- canonical_existing(Path.join(base_dir, "homes")),
         true <- homes_real == Path.join(base_real, "homes"),
         {:ok, home_real} <- canonical_existing(home),
         true <-
           home_real == Path.join(base_real, Path.relative_to(expected_home, base_dir)),
         {:ok, target_parent_real} <- canonical_existing(Path.dirname(path)),
         true <- target_parent_real == home_real,
         {:ok, source_real} <- canonical_existing(source),
         true <- path_within?(source_real, auth_real),
         link_real <- Path.expand(link_text, Path.dirname(path)),
         {:ok, link_real} <- canonical_existing(link_real),
         true <- link_real == source_real do
      :ok
    else
      _ -> {:error, :unsafe_or_unreadable_link}
    end
  end

  defp canonical_existing(path, remaining \\ 40)

  defp canonical_existing(_path, 0), do: {:error, :excessive_links}
  defp canonical_existing("/", _remaining), do: {:ok, "/"}

  defp canonical_existing(path, remaining) do
    expanded = Path.expand(path)

    with {:ok, parent} <- canonical_existing(Path.dirname(expanded), remaining - 1) do
      candidate = Path.join(parent, Path.basename(expanded))

      case File.lstat(candidate) do
        {:ok, %{type: :symlink}} ->
          with {:ok, link_text} <- File.read_link(candidate) do
            canonical_existing(Path.expand(link_text, parent), remaining - 1)
          end

        {:ok, _stat} ->
          {:ok, candidate}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp path_within?(path, root) do
    relative = Path.relative_to(path, root)

    relative != path and relative not in ["", ".", ".."] and
      not String.starts_with?(relative, "../") and Path.type(relative) == :relative
  end

  defp materialize_local_copy(target, home, path, source, link_text, source_stat, bytes) do
    nonce = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    stage_dir = Path.join(home, "#{@legacy_auth_migration_prefix}#{nonce}")
    staged = Path.join(stage_dir, Path.basename(source))
    displaced = Path.join(stage_dir, "previous-home-entry")

    case File.mkdir(stage_dir) do
      :ok ->
        try do
          stage_and_promote_local(
            target,
            home,
            path,
            source,
            link_text,
            source_stat,
            bytes,
            stage_dir,
            staged,
            displaced
          )
        after
          cleanup_local_migration_stage(stage_dir, staged, displaced, path)
        end

      {:error, _reason} ->
        {:error, :staging_failed}
    end
  end

  defp stage_and_promote_local(
         target,
         home,
         path,
         source,
         link_text,
         source_stat,
         bytes,
         stage_dir,
         staged,
         displaced
       ) do
    with :ok <- File.chmod(stage_dir, 0o700),
         :ok <- copy_to_stage(source, staged),
         :ok <- preserve_metadata(staged, source_stat),
         {:ok, ^bytes} <- File.read(staged),
         :ok <- unchanged_source?(source, source_stat, bytes) do
      promote_local_copy(target, home, path, source, link_text, staged, displaced)
    else
      {:error, :source_missing} -> {:error, :source_missing}
      {:error, :source_not_regular} -> {:error, :source_not_regular}
      {:error, :unsafe_access_mode} -> {:error, :unsafe_access_mode}
      {:error, _reason} -> {:error, :staging_failed}
      _ -> {:error, :source_changed}
    end
  end

  defp promote_local_copy(target, home, path, source, link_text, staged, displaced) do
    case unchanged_destination?(target, home, path, source, link_text) do
      :already_materialized ->
        :ok

      :ok ->
        case File.rename(path, displaced) do
          :ok ->
            promote_displaced_local_entry(staged, path, displaced, link_text)

          {:error, _reason} ->
            {:error, :destination_changed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp promote_displaced_local_entry(staged, path, displaced, expected_link) do
    case File.lstat(displaced) do
      {:ok, %{type: :symlink}} ->
        case File.read_link(displaced) do
          {:ok, ^expected_link} ->
            case promote_staged_legacy_credential(staged, path) do
              :ok ->
                File.rm(displaced)
                :ok

              {:error, reason} ->
                restore_symlink_if_missing(displaced, path, expected_link)
                {:error, reason}
            end

          _ ->
            restore_symlink_if_missing(displaced, path, nil)
            {:error, :destination_changed}
        end

      {:ok, %{type: :regular}} ->
        case promote_staged_legacy_credential(displaced, path) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :destination_changed}
    end
  end

  defp restore_symlink_if_missing(displaced, path, expected_link) do
    case File.lstat(path) do
      {:error, :enoent} ->
        with {:ok, link_text} <- displaced_link_text(displaced, expected_link) do
          File.ln_s(link_text, path)
        end

      _ ->
        :ok
    end
  end

  defp displaced_link_text(displaced, nil), do: File.read_link(displaced)

  defp displaced_link_text(displaced, expected_link) do
    case File.read_link(displaced) do
      {:ok, ^expected_link} -> {:ok, expected_link}
      _ -> {:error, :destination_changed}
    end
  end

  defp cleanup_local_migration_stage(stage_dir, staged, displaced, path) do
    File.rm(staged)

    case File.lstat(displaced) do
      {:ok, %{type: :symlink}} ->
        case restore_symlink_if_missing(displaced, path, nil) do
          :ok -> File.rm(displaced)
          _ -> :preserve
        end

      {:ok, %{type: :regular}} ->
        case promote_staged_legacy_credential(displaced, path) do
          :ok -> File.rm(displaced)
          {:error, _reason} -> :preserve
        end

      _ ->
        :preserve
    end

    File.rmdir(stage_dir)
  end

  defp copy_to_stage(source, staged) do
    case File.cp(source, staged) do
      :ok -> :ok
      {:error, _reason} -> {:error, :staging_failed}
    end
  end

  defp preserve_metadata(staged, source_stat) do
    safe_mode = band(source_stat.mode, 0o600)

    if band(safe_mode, 0o400) == 0 do
      {:error, :unsafe_access_mode}
    else
      with {:ok, staged_stat} <- File.stat(staged),
           :ok <- maybe_chown(staged, staged_stat.uid, source_stat.uid),
           {:ok, staged_stat} <- File.stat(staged),
           :ok <- maybe_chgrp(staged, staged_stat.gid, source_stat.gid),
           :ok <- File.chmod(staged, safe_mode),
           {:ok, final_stat} <- File.stat(staged),
           true <- same_owner_and_access?(source_stat, final_stat, safe_mode) do
        :ok
      else
        _ -> {:error, :metadata_failed}
      end
    end
  end

  defp maybe_chown(_path, uid, uid), do: :ok
  defp maybe_chown(path, _current_uid, uid), do: File.chown(path, uid)
  defp maybe_chgrp(_path, gid, gid), do: :ok
  defp maybe_chgrp(path, _current_gid, gid), do: File.chgrp(path, gid)

  defp same_owner_and_access?(left, right, mode) do
    left.uid == right.uid and left.gid == right.gid and
      band(right.mode, 0o7777) == mode
  end

  defp same_credential_stat?(left, right) do
    left.type == right.type and left.size == right.size and left.uid == right.uid and
      left.gid == right.gid and left.inode == right.inode and left.mtime == right.mtime and
      band(left.mode, 0o7777) == band(right.mode, 0o7777)
  end

  defp unchanged_source?(source, source_stat, bytes) do
    with {:ok, current_stat} <- File.lstat(source),
         {:ok, current_bytes} <- File.read(source),
         true <- same_credential_stat?(source_stat, current_stat),
         true <- current_bytes == bytes do
      :ok
    else
      _ -> {:error, :source_changed}
    end
  end

  defp unchanged_destination?(target, home, path, source, link_text) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        :already_materialized

      {:ok, %{type: :symlink}} ->
        with {:ok, ^link_text} <- File.read_link(path),
             :ok <- validate_local_legacy_link(target, home, path, source, link_text) do
          :ok
        else
          _ -> {:error, :destination_changed}
        end

      _ ->
        {:error, :destination_changed}
    end
  end

  defp materialize_remote_auth_link(target, base_dir, home, path, source) do
    nonce = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    stage_dir = Path.join(home, ".tightbeam-auth-migration-#{nonce}")

    script =
      remote_auth_migration_script(
        base_dir,
        target.host_name,
        home,
        path,
        source,
        stage_dir
      )

    command =
      ["ssh" | Support.ssh_opts()] ++
        [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]

    case target.sh.(command) do
      {_output, 0} -> :ok
      {_output, 70} -> {:error, :unsupported_destination}
      {_output, 71} -> {:error, :unsafe_or_unreadable_link}
      {_output, 72} -> {:error, :source_missing}
      {_output, 73} -> {:error, :source_not_regular}
      {_output, 74} -> {:error, :source_changed}
      {_output, 75} -> {:error, :destination_changed}
      {_output, 76} -> {:error, :staging_failed}
      {_output, 77} -> {:error, :promotion_failed}
      {_output, 78} -> {:error, :unsafe_access_mode}
      {_output, 79} -> {:error, :ambiguous_migration_recovery}
      {_output, _status} -> {:error, :remote_migration_failed}
    end
  end

  defp remote_auth_migration_script(base_dir, host_name, home, path, source, stage_dir) do
    base = Support.shell_quote(base_dir)
    host = Support.shell_quote(host_name)
    home = Support.shell_quote(home)
    entry = Support.shell_quote(path)
    source = Support.shell_quote(source)
    stage = Support.shell_quote(stage_dir)

    """
    base=#{base}
    host=#{host}
    home=#{home}
    entry=#{entry}
    source=#{source}
    stage=#{stage}

    private_dir() {
      [ -d "$1" ] && [ ! -L "$1" ] || return 1
      mode=$(stat -c '%a' "$1" 2>/dev/null) || mode=$(stat -f '%Lp' "$1" 2>/dev/null) || return 1
      case "$mode" in ''|*[!0-7]*) return 1 ;; esac
      [ $((0$mode & 077)) -eq 0 ]
    }
    private_file() {
      [ -f "$1" ] && [ ! -L "$1" ] || return 1
      mode=$(stat -c '%a' "$1" 2>/dev/null) || mode=$(stat -f '%Lp' "$1" 2>/dev/null) || return 1
      case "$mode" in ''|*[!0-7]*) return 1 ;; esac
      [ $((0$mode & 077)) -eq 0 ]
    }
    if [ -L "$entry" ]; then
      link=$(readlink "$entry" 2>/dev/null) || exit 71
      entry_state=link
    elif [ -f "$entry" ]; then
      exit 0
    elif [ -e "$entry" ]; then
      exit 70
    else
      entry_state=missing
    fi

    canonical() {
      candidate=$1
      depth=${2:-0}
      [ "$depth" -lt 40 ] || return 1
      parent=${candidate%/*}
      leaf=${candidate##*/}
      [ -n "$parent" ] || parent=/
      physical_parent=$(CDPATH= cd -P "$parent" 2>/dev/null && pwd -P) || return 1
      resolved="$physical_parent/$leaf"
      if [ -L "$resolved" ]; then
        next=$(readlink "$resolved" 2>/dev/null) || return 1
        case "$next" in
          /*) canonical "$next" "$((depth + 1))" ;;
          *) canonical "$physical_parent/$next" "$((depth + 1))" ;;
        esac
      else
        [ -e "$resolved" ] || return 1
        printf '%s' "$resolved"
      fi
    }

    base_real=$(CDPATH= cd -P "$base" 2>/dev/null && pwd -P) || exit 71
    auth_real=$(CDPATH= cd -P "$base/auth" 2>/dev/null && pwd -P) || exit 71
    homes_real=$(CDPATH= cd -P "$base/homes" 2>/dev/null && pwd -P) || exit 71
    [ "$auth_real" = "$base_real/auth" ] || exit 71
    [ "$homes_real" = "$base_real/homes" ] || exit 71

    home_real=$(CDPATH= cd -P "$home" 2>/dev/null && pwd -P) || exit 71
    expected_home="$homes_real/$host/${home##*/}"
    [ "$home_real" = "$expected_home" ] || exit 71
    entry_parent=$(CDPATH= cd -P "${entry%/*}" 2>/dev/null && pwd -P) || exit 71
    [ "$entry_parent" = "$home_real" ] || exit 71

    source_parent_real=$(CDPATH= cd -P "${source%/*}" 2>/dev/null && pwd -P) || exit 72
    source_expected="$source_parent_real/${source##*/}"
    case "$source_expected" in "$auth_real"/*) ;; *) exit 71 ;; esac

    if [ "$entry_state" = missing ]; then
      recovery_count=0
      recovery_previous=
      for candidate_previous in "$home_real"/.tightbeam-auth-migration-*/previous-home-entry; do
        [ -e "$candidate_previous" ] || [ -L "$candidate_previous" ] || continue
        candidate_dir=${candidate_previous%/*}
        [ -d "$candidate_dir" ] && [ ! -L "$candidate_dir" ] || exit 79
        private_dir "$candidate_dir" || exit 79
        recovery_count=$((recovery_count + 1))
        [ "$recovery_count" -le 1 ] || exit 79
        recovery_previous=$candidate_previous
      done

      if [ "$recovery_count" -eq 1 ]; then
        previous=$recovery_previous
        recover_dir=${previous%/*}

        if [ -L "$previous" ]; then
          previous_link=$(readlink "$previous" 2>/dev/null) || exit 75
          case "$previous_link" in
            /*) previous_candidate=$previous_link ;;
            *) previous_candidate="$home_real/$previous_link" ;;
          esac
          previous_parent=$(CDPATH= cd -P "${previous_candidate%/*}" 2>/dev/null && pwd -P) || exit 75
          previous_expected="$previous_parent/${previous_candidate##*/}"
          [ "$previous_expected" = "$source_expected" ] || exit 75

          recovered_credential="$recover_dir/${source##*/}"
          if [ ! -e "$recovered_credential" ] && [ ! -L "$recovered_credential" ]; then
            recovered_credential="$recover_dir/credential"
          fi

          if [ ! -e "$source" ] && [ ! -L "$source" ] && private_file "$recovered_credential"; then
            if ln "$recovered_credential" "$entry" >/dev/null 2>&1; then
              rm -f "$previous" "$recovered_credential" 2>/dev/null
              rmdir "$recover_dir" 2>/dev/null
              entry_state=regular
            elif [ -f "$entry" ] && [ ! -L "$entry" ]; then
              if [ "$recovered_credential" -ef "$entry" ]; then
                rm -f "$previous" "$recovered_credential" 2>/dev/null
                rmdir "$recover_dir" 2>/dev/null
              fi
              entry_state=regular
            fi
          fi

          if [ "$entry_state" != regular ]; then
            if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
              ln -s "$previous_link" "$entry" >/dev/null 2>&1 || exit 75
            fi
            if [ -L "$entry" ]; then
              current_link=$(readlink "$entry" 2>/dev/null) || exit 75
              [ "$current_link" = "$previous_link" ] || exit 75
              link=$current_link
              if [ -e "$source" ] && [ -f "$source" ] && private_file "$recovered_credential" &&
                 cmp -s "$source" "$recovered_credential"; then
                rm -f "$previous" "$recovered_credential" 2>/dev/null
                rmdir "$recover_dir" 2>/dev/null
              elif [ ! -e "$recovered_credential" ] && [ ! -L "$recovered_credential" ]; then
                rm -f "$previous" 2>/dev/null
                rmdir "$recover_dir" 2>/dev/null
              fi
              entry_state=link
            elif [ -f "$entry" ] && [ ! -L "$entry" ]; then
              entry_state=regular
            else
              exit 75
            fi
          fi
        elif [ -f "$previous" ] && [ ! -L "$previous" ]; then
          if ln "$previous" "$entry" >/dev/null 2>&1; then
            rm -f "$previous" "$recover_dir/${source##*/}" "$recover_dir/credential" 2>/dev/null
            rmdir "$recover_dir" 2>/dev/null
            entry_state=regular
          elif [ -f "$entry" ] && [ ! -L "$entry" ]; then
            if [ "$previous" -ef "$entry" ]; then
              rm -f "$previous" "$recover_dir/${source##*/}" "$recover_dir/credential" 2>/dev/null
              rmdir "$recover_dir" 2>/dev/null
            fi
            entry_state=regular
          elif [ -L "$entry" ]; then
            link=$(readlink "$entry" 2>/dev/null) || exit 75
            entry_state=link
          else
            exit 75
          fi
        else
          exit 79
        fi
      fi
    fi

    if [ "$entry_state" = regular ]; then
      exit 0
    fi
    if [ -L "$entry" ]; then
      link=$(readlink "$entry" 2>/dev/null) || exit 71
      entry_state=link
    fi
    if [ -e "$entry" ] && [ "$entry_state" != link ]; then exit 70; fi
    if [ "$entry_state" != link ]; then exit 0; fi

    source_real=$(canonical "$source") || exit 72
    case "$source_real" in "$auth_real"/*) ;; *) exit 71 ;; esac
    if [ ! -e "$source" ] && [ ! -L "$source" ]; then exit 72; fi
    [ -f "$source" ] && [ ! -L "$source" ] || exit 73
    case "$link" in
      /*) link_candidate=$link ;;
      *) link_candidate="$home_real/$link" ;;
    esac
    link_real=$(canonical "$link_candidate") || exit 71
    [ "$link_real" = "$source_real" ] || exit 71

    umask 077
    mkdir "$stage" 2>/dev/null || exit 76
    chmod 700 "$stage" 2>/dev/null || exit 76
    cleanup() {
      rm -f "$stage/credential" 2>/dev/null
      if [ -L "$stage/previous-home-entry" ]; then
        if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
          if previous_link=$(readlink "$stage/previous-home-entry" 2>/dev/null) &&
             ln -s "$previous_link" "$entry" >/dev/null 2>&1; then
            rm -f "$stage/previous-home-entry" 2>/dev/null
          fi
        else
          rm -f "$stage/previous-home-entry" 2>/dev/null
        fi
      elif [ -f "$stage/previous-home-entry" ]; then
        if ln "$stage/previous-home-entry" "$entry" >/dev/null 2>&1; then
          rm -f "$stage/previous-home-entry" 2>/dev/null
        elif [ -f "$entry" ] && [ ! -L "$entry" ] &&
             [ "$stage/previous-home-entry" -ef "$entry" ]; then
          rm -f "$stage/previous-home-entry" 2>/dev/null
        fi
      fi
      rmdir "$stage" 2>/dev/null
    }
    trap cleanup 0
    trap 'cleanup; exit 1' HUP INT TERM
    cp -p "$source" "$stage/credential" >/dev/null 2>&1 || exit 76
    chmod go-rwx,u-x,u-s,g-s,o-t "$stage/credential" >/dev/null 2>&1 || exit 76
    [ -r "$stage/credential" ] || exit 78
    cmp -s "$source" "$stage/credential" || exit 74
    [ -f "$source" ] && [ ! -L "$source" ] || exit 73

    if [ -f "$entry" ] && [ ! -L "$entry" ]; then
      exit 0
    fi
    [ -L "$entry" ] || exit 75
    link_after=$(readlink "$entry" 2>/dev/null) || exit 75
    [ "$link_after" = "$link" ] || exit 75
    cmp -s "$source" "$stage/credential" || exit 74
    mv "$entry" "$stage/previous-home-entry" >/dev/null 2>&1 || exit 75
    if [ -f "$stage/previous-home-entry" ] && [ ! -L "$stage/previous-home-entry" ]; then
      if ln "$stage/previous-home-entry" "$entry" >/dev/null 2>&1; then
        rm -f "$stage/previous-home-entry"
        exit 0
      fi
      if [ -f "$entry" ] && [ ! -L "$entry" ]; then exit 0; fi
      exit 75
    fi
    if [ ! -L "$stage/previous-home-entry" ]; then exit 75; fi
    previous_link=$(readlink "$stage/previous-home-entry" 2>/dev/null) || exit 75
    if [ "$previous_link" != "$link" ]; then
      if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
        ln -s "$previous_link" "$entry" >/dev/null 2>&1 || exit 75
      fi
      exit 75
    fi
    if ln "$stage/credential" "$entry" >/dev/null 2>&1; then
      exit 0
    fi
    if [ -f "$entry" ] && [ ! -L "$entry" ]; then
      exit 0
    fi
    if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
      ln -s "$link" "$entry" >/dev/null 2>&1 || exit 77
    fi
    exit 77
    """
  end

  defp auth_dir(base_dir, module),
    do: Tightbeam.Credentials.store_dir(base_dir, module.credential_provider())

  defp remove_owned_projection(home, rails_filename, preserve_manifest_dir?) do
    unless preserve_manifest_dir?, do: File.rm_rf!(Path.join(home, @manifest_relative))
    if rails_filename, do: File.rm_rf!(Path.join(home, rails_filename))
  end

  defp write_rails(_home, nil, _content), do: :ok
  defp write_rails(_home, _filename, nil), do: :ok

  defp write_rails(home, filename, content) do
    path = Path.join(home, filename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp project_baseline_skills(home) do
    skills_root = Path.join(home, "skills")
    File.mkdir_p!(skills_root)

    for name <- @baseline_skill_names do
      source = Application.app_dir(:tightbeam, "priv/skills/#{name}")
      target = Path.join(skills_root, name)

      case File.read_link(target) do
        {:ok, ^source} ->
          :ok

        _ ->
          File.rm_rf!(target)
          File.ln_s!(source, target)
      end
    end
  end

  defp project_auth(auth_dir, home, credential_names, projection, before_projection_promote) do
    auth_dir
    |> credential_store_files(credential_names)
    |> Enum.map(fn file ->
      source = Path.join(auth_dir, file)
      target = Path.join(home, file)

      case projection do
        :link ->
          case File.lstat(target) do
            {:error, :enoent} -> File.ln_s!(source, target)
            _ -> :ok
          end

        :copy_readable ->
          bytes = File.read!(source)

          temporary =
            Path.join(
              auth_dir,
              ".#{file}.tightbeam-projection-#{System.unique_integer([:positive])}"
            )

          case :file.open(temporary, [:write, :exclusive, :binary]) do
            {:ok, io} ->
              try do
                :ok = :file.write(io, bytes)
              after
                :ok = :file.close(io)
              end

              try do
                # Cursor's credential store is operator-only. Preserve the
                # projection's shared group while the copy is still private;
                # rename keeps this inode's group instead of inheriting the
                # destination directory's setgid group. Then atomically
                # replace a planted symlink instead of following it.
                File.chgrp!(temporary, File.stat!(home).gid)
                File.chmod!(temporary, 0o640)
                before_projection_promote.(target)
                File.rename!(temporary, target)
              after
                case File.rm(temporary) do
                  :ok ->
                    :ok

                  {:error, :enoent} ->
                    :ok

                  {:error, reason} ->
                    raise File.Error, reason: reason, action: "remove", path: temporary
                end
              end

            {:error, reason} ->
              raise File.Error, reason: reason, action: "create exclusively", path: temporary
          end
      end

      file
    end)
  end

  defp credential_store_files(auth_dir, credential_names) do
    case File.ls(auth_dir) do
      {:ok, files} -> files |> Enum.filter(&(&1 in credential_names)) |> Enum.sort()
      {:error, :enoent} -> []
    end
  end

  @doc false
  def credential_ready?(target, home, names) do
    if Support.local?(target) do
      Enum.any?(names, fn name ->
        case File.lstat(Path.join(home, name)) do
          {:ok, %File.Stat{type: :regular}} -> true
          _ -> false
        end
      end)
    else
      script =
        Enum.map_join(names, " || ", fn name ->
          path = Support.shell_quote(Path.join(home, name))
          "test -f #{path} && test ! -L #{path}"
        end)

      {_output, status} =
        target.sh.(
          ["ssh" | Support.ssh_opts()] ++
            [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]
        )

      status == 0
    end
  end

  defp digest(nil), do: nil

  defp digest(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
