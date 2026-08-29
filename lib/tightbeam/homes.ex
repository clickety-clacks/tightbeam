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

  require Logger

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
  @remote_credential_absent_exit 42

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

    if remote_stamp != staged_stamp do
      if Map.get(desired, :harvest_auth, true) do
        harvest_remote_auth_back(
          target,
          remote_home,
          entry,
          store,
          provider_of(desired)
        )
      end

      script =
        "mkdir -p \"#{desired.auth_dir}\" \"#{remote_home}\"; " <>
          "rm -f \"#{rails}\"; rm -rf \"#{manifest_dir}\"; "

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

  # Freeze first, judge the exact frozen bytes on the gateway, promote last.
  #
  # A plain remote `cat`, followed by a validated `cp`, has a TOCTOU hole: the harness may
  # rotate the regular file between those commands and the copy can bank bytes the gateway
  # never judged. The private stage makes the bytes read back and the bytes promoted the
  # same file. It is outside the authoritative auth store, mode 0600, and its pathname --
  # never its contents -- is all that crosses a command or a log line.
  defp harvest_remote_auth_back(target, remote_home, entry, store, provider) do
    nonce = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

    stage =
      Path.join([
        target.host_config.base_dir,
        "staging",
        "credential-harvest",
        "#{provider}-#{nonce}"
      ])

    entry_q = Support.shell_quote(entry)
    stage_q = Support.shell_quote(stage)
    stage_dir_q = stage |> Path.dirname() |> Support.shell_quote()

    read_script =
      "if [ -f #{entry_q} ] && [ ! -L #{entry_q} ]; then " <>
        "mkdir -p #{stage_dir_q} && cp #{entry_q} #{stage_q} && " <>
        "chmod 600 #{stage_q} && cat #{stage_q}; " <>
        "else exit #{@remote_credential_absent_exit}; fi"

    read_command = remote_script(target, read_script)

    # SSH diagnostic chatter must not be spliced into the credential body: a warning prefix
    # would make a hollow JSON record undecodable and therefore appear healthy. Production
    # targets provide the stdout-only runner; injected test targets fall back to `:sh`.
    case Map.get(target, :sh_out, target.sh).(read_command) do
      {bytes, 0} ->
        try do
          Tightbeam.Credentials.refuse_hollow!(
            provider,
            bytes,
            "the harness home #{remote_home}"
          )

          promote_script =
            "mkdir -p #{store |> Path.dirname() |> Support.shell_quote()} && " <>
              "mv -f #{stage_q} #{Support.shell_quote(store)}"

          Support.run!(target, remote_script(target, promote_script))
        after
          remove_remote_harvest_stage(target, stage)
        end

      {_output, @remote_credential_absent_exit} ->
        :ok

      {_output, status} ->
        remove_remote_harvest_stage(target, stage)
        raise "remote credential read failed with exit #{status}"
    end
  end

  defp remove_remote_harvest_stage(target, stage) do
    case target.sh.(remote_script(target, "rm -f #{Support.shell_quote(stage)}")) do
      {_output, 0} ->
        :ok

      {_output, status} ->
        Logger.error("remote credential harvest cleanup failed with exit #{status}")
        :ok
    end
  rescue
    _error ->
      Logger.error("remote credential harvest cleanup could not run")
      :ok
  end

  defp remote_script(target, script) do
    ["ssh" | Support.ssh_opts()] ++
      [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]
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

  This runs during stopped-runtime lifecycle reconciliation and during a live
  local model-catalog recovery after a subscription 401. The live call is
  bounded to managed homes under `base_dir`, and harvested store writes are
  atomic. It never discovers or imports credentials from a user's personal
  harness installation.
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
          harvest_one(base_dir, module, home, bytes)
      end
    end)

    :ok
  end

  # ONE BAD HOME MUST NOT TAKE THE GATEWAY WITH IT.
  #
  # This runs on the BOOT path -- gateway.ex calls `sweep_auth/2` for every harness inside
  # `children_after_preflight`, which `Application.start/2` invokes with no rescue around it
  # (it catches only `{:no_harness_cli, _}`). So a raise here is not a refusal an operator
  # reads; in a release it is `Kernel pid terminated` and an `erl_crash.dump`, and the
  # gateway does not boot. The sweep also globs `homes/*/<harness>`, so the raise would
  # abort the `Enum.each` over every OTHER home and harness too.
  #
  # That would defeat the very invariant the refusal exists to protect. `refuse_hollow!/3`
  # keeps a good store credential alive; a dead gateway makes that credential unreachable
  # and leaves the box crash-looping every boot until someone hand-deletes a file the VENDOR
  # wrote. Silent poisoning was the bug; an outage is not the fix for it.
  #
  # The distinction against `reload_law!` two lines above, which does stop the boot: law is
  # org-AUTHORED, global by nature, and has no prior-good value to fall back on -- the author
  # fixes their own manifest. A harness credential is EXTERNAL data the vendor rotates in
  # place, scoped to one provider on one home, and there is a known-good value already
  # banked. Same mechanism, different category.
  #
  # So the refusal still REFUSES -- nothing hollow is banked, the good credential stands --
  # and it still NAMES itself, at :error where an operator and the log both see it. What it
  # no longer does is take the org down to say so.
  #
  # The provider's STATUS IS UNCHANGED BY THIS, deliberately. The store credential still
  # authenticates, so `Credentials.status/2` keeps answering `:onboarded` -- which is true.
  # Reporting `needs_onboarding` here would tell an operator to re-onboard a credential that
  # works, and writing a false status into the org's own state is the same class of mistake
  # as banking a hollow one.
  #
  # What IS degraded is the one home, and it does NOT heal itself. `reconcile_local/3` calls
  # `harvest_auth_back/4` BEFORE the `File.rm` that would clear the vendor's file, so
  # reconciling that home raises there and never reaches the relink -- session placement into
  # it fails, by name, until someone deletes the file. That is the right failure: a session
  # started against a hollow credential dies with `authentication_failed` an hour later and
  # points at nothing, while this refuses at the door and says which home. But it is manual
  # to clear, not transient. A health surface that can be QUERIED for it belongs to the
  # doctor check (wi_8b89e50c), not here.
  defp harvest_one(base_dir, module, home, bytes) do
    Tightbeam.Credentials.store_harvested(
      base_dir,
      module.credential_provider(),
      bytes,
      "the #{module.id()} harness home #{home}"
    )
  rescue
    error in RuntimeError ->
      Logger.error(
        "#{module.id()} credential in #{home} was NOT harvested: #{Exception.message(error)}"
      )

      :ok
  end

  @doc "Canonical shared home path."
  @spec home_path(String.t(), String.t(), harness()) :: String.t()
  def home_path(base_dir, machine, harness),
    do: Path.join([base_dir, "homes", machine, Atom.to_string(harness)])

  defp auth_dir(base_dir, module),
    do: Tightbeam.Credentials.store_dir(base_dir, module.credential_provider())

  defp remove_owned_projection(home, rails_filename, preserve_manifest_dir?) do
    unless preserve_manifest_dir?, do: File.rm_rf!(Path.join(home, ".tightbeam"))
    File.rm_rf!(Path.join(home, rails_filename))
  end

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
