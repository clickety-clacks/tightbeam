defmodule Tightbeam.Homes do
  @moduledoc """
  Projects one generic shared home per `{harness, machine}`.

  Tightbeam owns the harness rails artifact, its projection manifest, and the
  substrate baseline skills. The harness alone owns its credential file.
  Regeneration is
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
  contents. File absence in this exact home is the onboarding signal.
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
          manifest_path: String.t()
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
        rails: Map.get(spec, :rails)
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
    manifest_path = Path.join(home, @manifest_relative)
    manifest = manifest_bytes(desired)
    rails_filename = Keyword.fetch!(mechanics, :rails_filename)

    File.mkdir_p!(home)

    unless File.read(manifest_path) == {:ok, manifest} do
      remove_owned_projection(home, rails_filename)
      write_rails(home, rails_filename, Map.get(desired, :rails))
      File.mkdir_p!(Path.dirname(manifest_path))
      File.write!(manifest_path, manifest)
    end

    project_baseline_skills(home)

    %{home_path: home, manifest_path: manifest_path}
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

    rails_filename = Keyword.fetch!(mechanics, :rails_filename)
    rails = Path.join(remote_home, rails_filename)

    if remote_stamp != staged_stamp do
      script =
        "mkdir -p \"#{remote_home}\"; " <>
          "rm -f \"#{rails}\" \"#{remote_manifest}\"; "

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

  defp remove_owned_projection(home, rails_filename) do
    File.rm_rf!(Path.join(home, @manifest_relative))
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
