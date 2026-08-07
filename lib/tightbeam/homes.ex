defmodule Tightbeam.Homes do
  @moduledoc """
  Projects one generic shared home per `{harness, machine}`.

  Tight Beam owns exactly the credential entry, the harness rails artifact,
  `.tightbeam/`, and the substrate baseline skills. Regeneration is
  ownership-scoped: it never removes the home and therefore preserves
  harness-owned sessions, history, projects, transcripts, and memory
  byte-for-byte.

  IF YOU ADD A PATH THAT DOES REMOVE OR RECREATE A HOME, it must re-warm the
  harness afterwards. Some harnesses cache what the account is ENTITLED to in
  their own home -- claude keeps the extra models it may select there -- and
  Tightbeam fills that cache exactly once, when a credential is written
  (`Credentials.warm_home/3`). A home cleared without a credential write comes
  back with its credential relinked and that cache gone, and the model catalog
  silently narrows to the static floor: it reads as a smaller account, not as an
  emptied directory. Re-warm in the reset path; do not add cold-home detection
  here. Substrate baseline skills project separately from org
  identity and are never sourced from the org-editable skill library.

  Callers gate regeneration on a stopped runtime. Before replacing a
  credential entry, a regular file left by runtime rotation is harvested
  back to the Tight-Beam-owned store, then the fresh store link is restored.
  Homes never mint or otherwise write credential contents.
  """

  alias Tightbeam.Harness
  alias Tightbeam.Harness.Support

  @type harness :: atom()
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

    module.reconcile_home(
      %{
        base_dir: base_dir,
        host_name: spec.machine,
        host_config: %{ssh: nil, base_dir: base_dir},
        sh: &Support.system_cmd/1
      },
      home,
      %{
        harness: spec.harness,
        machine: spec.machine,
        rails: Map.get(spec, :rails),
        auth_dir: auth_dir(base_dir, module)
      }
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
    auth_dir = desired.auth_dir
    manifest_path = Path.join(home, @manifest_relative)
    manifest = manifest_bytes(desired)
    credential_names = Keyword.fetch!(mechanics, :credential_names)
    rails_filename = Keyword.fetch!(mechanics, :rails_filename)
    harvest_auth? = Map.get(desired, :harvest_auth, true)

    File.mkdir_p!(home)

    if harvest_auth?,
      do: harvest_auth_back(auth_dir, home, credential_names, provider_of(desired))

    Enum.each(credential_names, &File.rm(Path.join(home, &1)))

    unless File.read(manifest_path) == {:ok, manifest} do
      remove_owned_projection(home, rails_filename)
      write_rails(home, rails_filename, Map.get(desired, :rails))
      File.mkdir_p!(Path.dirname(manifest_path))
      File.write!(manifest_path, manifest)
    end

    project_baseline_skills(home)

    %{
      home_path: home,
      manifest_path: manifest_path,
      linked_auth_files: link_auth(auth_dir, home, credential_names)
    }
  end

  defp reconcile_remote(target, remote_home, desired, mechanics) do
    stage_base = Path.join([target.base_dir, "staging", target.host_name])
    staged_home = home_path(stage_base, desired.machine, desired.harness)

    staged =
      reconcile_local(
        staged_home,
        desired
        |> Map.put(
          :auth_dir,
          Path.join([stage_base, "auth", Atom.to_string(desired.harness)])
        )
        |> Map.put(:harvest_auth, false),
        mechanics
      )

    remote_manifest = Path.join(remote_home, @manifest_relative)

    {remote_stamp, stamp_exit} =
      target.sh.(["ssh" | Support.ssh_opts()] ++ [target.host_config.ssh, "cat", remote_manifest])

    if stamp_exit not in [0, 1], do: raise("remote stamp check failed with exit #{stamp_exit}")

    staged_stamp = File.read!(staged.manifest_path)

    credential = mechanics |> Keyword.fetch!(:credential_names) |> hd()
    rails_filename = Keyword.fetch!(mechanics, :rails_filename)
    entry = Path.join(remote_home, credential)
    store = Path.join(desired.auth_dir, credential)
    rails = Path.join(remote_home, rails_filename)
    manifest_dir = Path.join(remote_home, ".tightbeam")

    harvest =
      if Map.get(desired, :harvest_auth, true) do
        "if [ -f \"#{entry}\" ] && [ ! -L \"#{entry}\" ]; then " <>
          "cp \"#{entry}\" \"#{store}\" && chmod 600 \"#{store}\"; fi; "
      else
        ""
      end

    if remote_stamp != staged_stamp do
      script =
        "mkdir -p \"#{desired.auth_dir}\" \"#{remote_home}\"; " <>
          harvest <> "rm -f \"#{rails}\"; rm -rf \"#{manifest_dir}\"; "

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

    source = Path.join(desired.auth_dir, credential)
    destination = Path.join(remote_home, credential)

    link_script =
      "source=\"#{source}\"; target=\"#{destination}\"; " <>
        "[ ! -e \"$source\" ] || [ -e \"$target\" ] || [ -L \"$target\" ] || ln -s \"$source\" \"$target\""

    Support.run!(
      target,
      ["ssh" | Support.ssh_opts()] ++
        [target.host_config.ssh, "sh", "-c", Support.shell_quote(link_script)]
    )

    %{
      home_path: remote_home,
      manifest_path: remote_manifest,
      linked_auth_files: [credential]
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
    module = Harness.module!(harness)
    target = %{host_config: %{ssh: nil}, base_dir: base_dir}

    base_dir
    |> Path.join("homes/*/#{Atom.to_string(harness)}")
    |> Path.wildcard()
    |> Enum.each(fn home ->
      case module.harvest_credential(target, home) do
        nil ->
          :ok

        bytes ->
          Tightbeam.Credentials.store_harvested(
            base_dir,
            module.credential_provider(),
            bytes,
            "the #{module.id()} harness home #{home}"
          )
      end
    end)

    :ok
  end

  @doc "Canonical shared home path."
  @spec home_path(String.t(), String.t(), harness()) :: String.t()
  def home_path(base_dir, machine, harness),
    do: Path.join([base_dir, "homes", machine, Atom.to_string(harness)])

  defp auth_dir(base_dir, module),
    do: Tightbeam.Credentials.store_dir(base_dir, module.credential_provider())

  defp remove_owned_projection(home, rails_filename) do
    File.rm_rf!(Path.join(home, ".tightbeam"))
    File.rm_rf!(Path.join(home, rails_filename))
  end

  defp write_rails(_home, _filename, nil), do: :ok

  defp write_rails(home, filename, content) do
    File.write!(Path.join(home, filename), content)
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

  defp harvest_auth_back(auth_dir, home, credential_names, provider) do
    auth_dir
    |> credential_store_files(credential_names)
    |> Enum.each(fn file ->
      entry = Path.join(home, file)

      case File.lstat(entry) do
        {:ok, %File.Stat{type: :regular}} ->
          # The THIRD door onto the shared store, and it has to be guarded like the other
          # two: a copy is a bank.
          Tightbeam.Credentials.refuse_hollow!(
            provider,
            File.read!(entry),
            "the harness home #{home}"
          )

          File.cp!(entry, Path.join(auth_dir, file))
          File.chmod!(Path.join(auth_dir, file), 0o600)

        _ ->
          :ok
      end
    end)
  end

  # The harness owns the pairing, so it is ASKED rather than restated here. Mapping the
  # credential FILENAME to a provider in this module read fine and was wrong: it put harness
  # mechanic literals outside `Tightbeam.Harness.*`, which the seam scan and the provider
  # literal inventory both refuse -- and they caught it, which is the whole point of them.
  defp provider_of(%{harness: harness}),
    do: Harness.module!(harness).credential_provider()

  defp link_auth(auth_dir, home, credential_names) do
    auth_dir
    |> credential_store_files(credential_names)
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

  defp credential_store_files(auth_dir, credential_names) do
    case File.ls(auth_dir) do
      {:ok, files} -> files |> Enum.filter(&(&1 in credential_names)) |> Enum.sort()
      {:error, :enoent} -> []
    end
  end

  @doc false
  def credential_ready?(target, home, names) do
    if Support.local?(target) do
      Enum.any?(names, &File.exists?(Path.join(home, &1)))
    else
      script =
        Enum.map_join(names, " || ", &"test -f #{Support.shell_quote(Path.join(home, &1))}")

      {_output, status} =
        target.sh.(
          ["ssh" | Support.ssh_opts()] ++
            [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]
        )

      status == 0
    end
  end

  @doc false
  def harvest_credential(target, home, filename) do
    path = Path.join(home, filename)

    if Support.local?(target) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} -> File.read!(path)
        _ -> nil
      end
    else
      script = "[ -f \"#{path}\" ] && [ ! -L \"#{path}\" ] && cat \"#{path}\""

      case target.sh.(
             ["ssh" | Support.ssh_opts()] ++
               [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]
           ) do
        {bytes, 0} -> bytes
        {_bytes, _status} -> nil
      end
    end
  end

  defp digest(nil), do: nil

  defp digest(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
