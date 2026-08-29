defmodule Tightbeam.Harness.Support do
  @moduledoc false

  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
  @reserved_overlay_env_vars ~w(PATH CLAUDE_CONFIG_DIR CODEX_HOME TIGHTBEAM_URL)
  @bundle_path Application.app_dir(:tightbeam, "priv/harness_bundle.json")
  @external_resource @bundle_path
  @credential_live_timeout_ms @bundle_path
                              |> File.read!()
                              |> JSON.decode!()
                              |> get_in([
                                "vector_contract",
                                "credential_live?",
                                "default_timeout_ms"
                              ])

  def ssh_opts, do: @ssh_opts

  @doc false
  def reserved_overlay_env_vars, do: @reserved_overlay_env_vars

  def local?(target), do: target.host_config.ssh == nil

  def system_cmd([command | args]), do: System.cmd(command, args, stderr_to_stdout: true)

  # For probes whose STDOUT is the answer: ssh chatters on stderr even when it
  # succeeds, and a warning spliced into a JSON body is a malformed catalog. The
  # SCRIPT's own stderr is merged inside the script (`exec 2>&1`), so a failure
  # still carries its reason; only ssh's is kept out.
  def system_cmd_out([command | args]), do: System.cmd(command, args)

  # Generous enough for a slow model-list response, bounded because a probe runs
  # inside the catalog's refresh task: an unbounded one leaves the entry
  # `refreshing: true` forever, which is a liveness hole, not a slow answer.
  @catalog_probe_timeout_s 30

  @doc false
  def catalog_probe_timeout_s, do: @catalog_probe_timeout_s

  @doc """
  The argv for a catalog probe on `dest` (nil = this machine).

  A catalog is derived on the host that owns the credential, and for codex it
  also needs a fact only that host's binary can state, so the probe is a script
  either way — the only difference is whether ssh carries it. Non-login `sh -c`
  on purpose: a login shell's profile banner would land in the middle of the
  JSON body, and SATELLITE.md already requires the harness CLIs to be on a PATH
  a non-login ssh shell can see.
  """
  @spec catalog_probe_argv(String.t() | nil, String.t()) :: [String.t()]
  def catalog_probe_argv(nil, script), do: ["sh", "-c", script]

  def catalog_probe_argv(dest, script),
    do: ["ssh" | @ssh_opts] ++ [dest, "sh", "-c", shell_quote(script)]

  @doc """
  The curl line every catalog probe ends in.

  `-f` is deliberately absent: on 400 or 401 both vendors return a JSON body
  that names the actual problem — an outdated `client_version`, a grant that
  needs signing in again — and that sentence is the one the operator needs.
  curl has no way to hand back a status except to print it, so it rides in on a
  trailing line, followed by whatever else the probe learned ON the host.
  """
  @spec catalog_curl(String.t(), [String.t()], String.t()) :: String.t()
  def catalog_curl(url, headers, trailer \\ "") do
    header_args = Enum.map_join(headers, " ", &~s(-H "#{&1}"))

    ~s(curl -sS --max-time #{@catalog_probe_timeout_s} ) <>
      ~s(-w "\\n%{http_code}#{trailer}" ) <> header_args <> " " <> ~s("#{url}")
  end

  @doc """
  Run a catalog probe and split the body from its trailing status line.

  Returns the fields after the status untouched, for whatever the probe was
  asked to report back about the host it ran on.
  """
  @spec catalog_probe(fun(), [String.t()]) ::
          {:ok, String.t(), [String.t()]} | {:error, term()}
  def catalog_probe(sh, argv) do
    case sh.(argv) do
      {output, 0} ->
        {body, last_line} = split_trailing_line(output)

        case String.split(last_line, " ", trim: true) do
          [status | trailer] ->
            case Integer.parse(status) do
              {code, ""} when code in 200..299 -> {:ok, body, trailer}
              {code, ""} -> {:error, {:http_status, code, String.trim(body)}}
              _ -> {:error, {:probe_unrecognized, String.trim(output)}}
            end

          [] ->
            {:error, {:probe_unrecognized, String.trim(output)}}
        end

      {output, exit} ->
        {:error, {:probe_failed, exit, String.trim(output)}}
    end
  end

  defp split_trailing_line(output) do
    case output |> String.trim_trailing("\n") |> String.split("\n") |> Enum.split(-1) do
      {body, [last]} -> {Enum.join(body, "\n"), last}
      _ -> {output, ""}
    end
  end

  @doc false
  def owned_home_entries(credential_file, rails_file) do
    [
      ".tightbeam/manifest",
      credential_file,
      rails_file
      | Enum.map(Tightbeam.Homes.baseline_skill_names(), &"skills/#{&1}")
    ]
    |> Enum.sort()
  end

  def credential_transport(target, %{command: command}) do
    invocation =
      if local?(target) do
        command
      else
        ["ssh" | ssh_opts()] ++
          [
            target.host_config.ssh,
            "sh",
            "-lc",
            shell_quote(Enum.map_join(command, " ", &shell_quote/1))
          ]
      end

    case target.sh.(invocation) do
      {output, 0} ->
        case JSON.decode(output) do
          {:ok, decoded} ->
            {:ok,
             %{
               status: decoded["status"],
               headers: decoded["headers"],
               body: decoded["body"]
             }}

          {:error, reason} ->
            {:error, {:malformed_transport_response, reason}}
        end

      {output, exit} ->
        {:error, {:transport_exit, exit, String.trim(output)}}
    end
  end

  def credential_live_result(target, request, opts) do
    transport = Keyword.fetch!(opts, :transport)
    timeout_ms = Keyword.get(opts, :timeout_ms, @credential_live_timeout_ms)

    case bounded_call(fn -> transport.(target, request) end, timeout_ms) do
      {:ok, {:ok, %{status: status}}} when status in 200..299 ->
        :live

      {:ok, {:ok, %{status: status}}} when status in [401, 403] ->
        {:dead, {:http_status, status}}

      {:ok, {:ok, %{status: status}}} ->
        {:unknown, {:http_status, status}}

      {:ok, {:error, reason}} ->
        {:unknown, reason}

      :timeout ->
        {:unknown, :timeout}
    end
  end

  def run!(target, command) do
    case target.sh.(command) do
      {_output, 0} -> :ok
      {_output, exit} -> raise "command failed with exit #{exit}: #{Enum.join(command, " ")}"
    end
  end

  def shell_quote(script), do: "'" <> String.replace(script, "'", "'\\''") <> "'"

  def bounded_probe(binary, target) do
    run = Map.get(target, :run, &system_cmd/1)
    timeout = Map.get(target, :timeout, 2_000)

    with bin when is_binary(bin) <- binary,
         {:ok, {output, 0}} <- bounded_run(run, [bin, "--version"], timeout) do
      {:ok, %{bin: bin, version: String.trim(output)}}
    else
      nil ->
        {:error, :not_found}

      {:ok, {output, status}} ->
        {:error,
         {:exec_failed, "exit=#{status} output=#{inspect(String.trim(to_string(output)))}"}}

      {:error, detail} ->
        {:error, {:exec_failed, detail}}
    end
  end

  @doc false
  def conformance_vectors(module, profile) do
    %{
      "prepare_launch" => prepare_launch_vectors(module, profile),
      "ensure_adapter" => ensure_adapter_vectors(module, profile),
      "session_config" => session_config_vectors(module, profile),
      "owned_home_entries" => owned_home_entries_vectors(profile),
      "reconcile_home" => reconcile_home_vectors(module, profile),
      "materialize_skills" => materialize_skills_vectors(module, profile),
      "credential_ready?/harvest_credential" => credential_vectors(module, profile),
      "credential_live?" => credential_live_vectors(module, profile),
      "install_cli_projection" => install_cli_projection_vectors(module),
      "probe_cli" => probe_cli_vectors(module, profile),
      "classify_auth_event" => classification_vectors(module, profile.auth_events, :auth),
      "classify_subagent_event" =>
        classification_vectors(module, profile.subagent_events, :subagent),
      "fetch_catalog" => catalog_vectors(module, profile),
      "wire_projection" => wire_projection_vectors(module, profile)
    }
  end

  @doc false
  def observe_vector(module, "prepare_launch", %{input: input}),
    do: observe_launch(module, input.profile, input.locality, input.rails, input.kind)

  def observe_vector(module, "ensure_adapter", %{input: input}),
    do: observe_adapter(module, input.profile, input.locality, input.presence)

  def observe_vector(module, "session_config", %{input: input}),
    do: module.session_config(%{}, input.guidance).meta

  def observe_vector(module, "owned_home_entries", %{input: input}) do
    write_set = observe_reconcile_home(module, input.profile).write_set

    if module.owned_home_entries() == write_set,
      do: :matches_reconcile_write_set,
      else: {:mismatch, %{owned_entries: module.owned_home_entries(), write_set: write_set}}
  end

  def observe_vector(module, "reconcile_home", %{input: input}),
    do: observe_reconcile_home(module, input.profile)

  def observe_vector(module, "materialize_skills", %{input: input}),
    do: observe_materialize_skills(module, input.profile)

  def observe_vector(module, "credential_ready?/harvest_credential", %{input: input}),
    do: observe_credential(module, input.profile, input.case)

  def observe_vector(module, "credential_live?", %{input: input}),
    do: observe_credential_live(module, input.profile, input.case)

  def observe_vector(module, "install_cli_projection", %{input: input}),
    do: observe_cli_projection(module, input.case, input.effect)

  def observe_vector(module, "probe_cli", %{input: input}),
    do: observe_probe_cli(module, input.profile)

  def observe_vector(module, "classify_auth_event", %{input: input}),
    do: module.classify_auth_event(input.envelope)

  def observe_vector(module, "classify_subagent_event", %{input: input}),
    do: module.classify_subagent_event(input.envelope)

  def observe_vector(module, "fetch_catalog", %{input: input}),
    do: observe_catalog(module, input.profile, input.case)

  def observe_vector(module, "wire_projection", %{input: %{}}) do
    {:ok, decoded} = module.wire_projection() |> JSON.decode()
    Map.take(decoded, ~w(id wire_name install_package cli_binary process_markers))
  end

  # Eight cases, not four: a harness's launch plan is a function of locality,
  # rails AND the host's credential kind. For claude the kind decides which
  # environment variable carries the credential; for codex it decides nothing,
  # because codex reads its own auth.json — and running codex under both kinds
  # PINS that invariance instead of assuming it.
  defp prepare_launch_vectors(_module, profile) do
    for locality <- [:local, :remote],
        rails <- [:railed, :lawless],
        kind <- [:subscription, :api_key] do
      case_name = "#{locality}_#{rails}_#{kind}"

      vector(
        case_name,
        expected_launch(profile, locality, rails, kind),
        %{profile: profile, locality: locality, rails: rails, kind: kind}
      )
    end
  end

  defp observe_launch(module, profile, locality, rails, kind) do
    with_tmp("launch", fn base ->
      home = Path.join(base, "home")
      local? = locality == :local
      adapter = adapter_path(base, profile.adapter_bin, locality)
      token_path = Path.join([base, "auth", profile.home_scope, profile.credential_file])
      File.mkdir_p!(Path.dirname(token_path))
      File.write!(token_path, "vector-token\n")

      target = %{
        base_dir: base,
        host_name: "vector",
        host_config: %{base_dir: base, ssh: if(local?, do: nil, else: "vector@remote")},
        adapter_binary: adapter,
        sh: fn _command -> {"", 0} end,
        find_executable: fn _ -> Path.join([base, "2026.08.11-e8db854", "cursor-agent"]) end,
        realpath: fn path -> {:ok, path} end,
        sha256: &cursor_vector_sha256/1,
        verify_adapter_shim: fn _shim, _launcher -> :ok end
      }

      opts = [
        common_env: [{"COMMON", "1"}],
        remote_env: ["REMOTE=1"],
        lineage: "tb-vector",
        # The projected map is unconditional now — the substrate's own observation
        # entry rides in it — so the railed/lawless axis is org LAW, which is what
        # the probe follows.
        rails: %{"hooks" => %{"PreToolUse" => []}},
        statutes: rails == :railed,
        credential_kind: kind,
        cursor_api_key_loader: fn _ -> {:ok, "vector-token"} end,
        cursor_rails_sha256: String.duplicate("a", 64),
        ensure_workdir: fn _host, _cwd, _content, _opts -> :ok end,
        sh_out: nil
      ]

      with {:ok, checked} <- Tightbeam.Harness.preflight_launch(module, target, home, opts),
           {:ok, plan} <- Tightbeam.Harness.prepare_launch(module, target, home, checked) do
        plan
      end
      |> launch_observation()
      |> normalize_paths(base, home)
    end)
  end

  defp expected_launch(profile, locality, rails, kind) do
    if kind in Map.get(profile, :unsupported_launch_kinds, []) do
      {:error, %{code: "DIV-CURSOR-API-KEY-ONLY", message: "Cursor requires a banked API key"}}
    else
      expected_supported_launch(profile, locality, rails, kind)
    end
  end

  defp expected_supported_launch(profile, locality, rails, kind) do
    base = "<BASE>"
    home = "<HOME>"
    adapter = adapter_path(base, profile.adapter_bin, locality)
    local? = locality == :local
    railed? = rails == :railed

    plan =
      if profile.wire_name == "cursor" do
        if local? do
          [
            cmd: [Path.join(base, profile.pinned_cli_path), "acp"],
            env: [
              {"CURSOR_CONFIG_DIR", home},
              {"AGENT_CLI_CREDENTIAL_STORE", "memory"},
              {"CURSOR_API_KEY", "vector-token"},
              {"COMMON", "1"}
            ]
          ]
        else
          {:error,
           %{
             code: "DIV-CURSOR-LOCAL-ONLY",
             message:
               "Cursor shim harness is gateway-local only until remote zero-listener probe exists"
           }}
        end
      else
        expected_standard_launch(profile, locality, kind, base, home, adapter)
      end

    plan =
      if railed? and profile.railed_probe do
        Keyword.merge(plan,
          probe_cwd: Path.join(base, "work/gate-probe"),
          probe_model: Tightbeam.Model.new("gpt-5.6-sol", effort: "medium")
        )
      else
        plan
      end

    launch_observation(plan)
  end

  defp expected_standard_launch(profile, locality, kind, base, home, adapter) do
    if locality == :local do
      extra =
        Map.fetch!(profile.local_extra_env, kind) ++
          if(profile.rails_env, do: [profile.rails_env], else: [])

      # Most harnesses deliver their projected home through ONE env var (`home_env`). A harness
      # whose home projection needs several (OpenCode: XDG_DATA_HOME/XDG_CONFIG_HOME plus the
      # out-of-tree OPENCODE_CONFIG gate) supplies `local_home_env: fn base, home -> [{k, v}] end`.
      home_entries =
        case Map.get(profile, :local_home_env) do
          nil -> [{profile.home_env, home}]
          builder when is_function(builder, 2) -> builder.(base, home)
        end

      [
        cmd: [adapter],
        env: home_entries ++ [{"COMMON", "1"} | extra]
      ]
    else
      remote_env =
        profile.remote_prefix.(base, home, kind) ++
          ["REMOTE=1"] ++
          if(profile.remote_rails_env,
            do: [profile.remote_rails_env],
            else: []
          )

      [
        cmd:
          ["ssh" | ssh_opts()] ++
            ["vector@remote", "exec", "env" | remote_env] ++ [adapter],
        env: [{"TIGHTBEAM_LINEAGE", "tb-vector"}]
      ]
    end
  end

  defp launch_observation({:error, _refusal} = error), do: error

  defp launch_observation(plan) do
    argv = Keyword.fetch!(plan, :cmd)

    %{
      argv: argv,
      env: Keyword.fetch!(plan, :env),
      serialized_command: Enum.map_join(argv, " ", &shell_quote/1),
      probe_cwd: Keyword.get(plan, :probe_cwd),
      probe_model: Keyword.get(plan, :probe_model)
    }
  end

  defp ensure_adapter_vectors(_module, profile) do
    for locality <- [:local, :remote],
        presence <- [:present, :absent] do
      case_name = "#{locality}_#{presence}"

      vector(
        case_name,
        expected_adapter(profile, locality, presence),
        %{profile: profile, locality: locality, presence: presence}
      )
    end
  end

  defp observe_adapter(module, profile, locality, presence) do
    case Map.get(profile, :provisioning, :npm) do
      :npm -> observe_adapter_npm(module, profile, locality, presence)
      :shim -> observe_adapter_shim(module, profile, locality)
    end
  end

  # A binary-native (:shim) harness provisions its adapter by writing a shell shim over the
  # operator-installed CLI (`Spinup.ensure_shim_adapter`), never by npm-installing a package. The
  # vector asserts the shim FILE (content + mode) and the shared install line staying empty; it
  # deliberately does not assert any out-of-tree gate the harness also materializes, only the
  # shim. `find_executable` resolves the CLI locally; the remote `sh` mock resolves `command -v`
  # and executes the ssh-carried write script so the shim file actually lands.
  defp observe_adapter_shim(module, profile, locality) do
    with_tmp("adapter", fn base ->
      local? = locality == :local
      adapter = adapter_path(base, profile.adapter_bin, locality)

      cli_path =
        if module.id() == :cursor,
          do: Path.join([base, "2026.08.11-e8db854", "cursor-agent"]),
          else: Path.join(base, "#{profile.cli_name}-cli")

      File.mkdir_p!(Path.dirname(cli_path))
      File.write!(cli_path, "vector cli")

      ref = make_ref()

      sh = fn command ->
        send(self(), {ref, command})
        joined = Enum.join(command, " ")

        cond do
          # The shim resolves the operator CLI with `command -v`; hand back the fake path.
          String.contains?(joined, "command -v") ->
            {cli_path <> "\n", 0}

          # An ssh-carried `sh -c <script>`: emulate the remote shell exactly as ssh does —
          # join the args after the destination and run them through `sh -c` — so the shim (and
          # any gate) write EFFECT actually happens on disk and the shim file can be read back.
          match?(["ssh" | _], command) ->
            script_args = Enum.drop(command, 1 + length(@ssh_opts) + 1)
            System.cmd("sh", ["-c", Enum.join(script_args, " ")])

          true ->
            {"", 0}
        end
      end

      target = %{
        base_dir: base,
        host_name: "vector",
        host_config: %{base_dir: base, ssh: if(local?, do: nil, else: "vector@remote")},
        adapter_binary: adapter,
        find_executable: fn _ -> cli_path end,
        realpath: fn path -> {:ok, path} end,
        sha256: &cursor_vector_sha256/1,
        sh: sh
      }

      result = Tightbeam.Harness.ensure_adapter(module, target)
      commands = drain_commands(ref, [])
      stat = File.stat!(adapter)

      %{
        result: normalize_paths(result, base, nil),
        install_contribution:
          commands
          |> Enum.map(&Enum.join(&1, " "))
          |> Enum.find_value("", fn command ->
            if String.contains?(command, "npm install"), do: command, else: false
          end)
          |> normalize_paths(base, nil),
        shim: normalize_paths(File.read!(adapter), base, nil),
        mode: Bitwise.band(stat.mode, 0o777)
      }
    end)
  end

  defp cursor_vector_sha256(path) do
    if Path.basename(path) == "index.js",
      do: "6aceb24b7c7ecddb1993946ebb18a7dd4d025842e6efda955eb0c13255b1e5f0",
      else: "eed61c5224668c9236334c4c68936a16aecc37374b592f59e31eb50433817831"
  end

  defp observe_adapter_npm(module, profile, locality, presence) do
    with_tmp("adapter", fn base ->
      adapter = adapter_path(base, profile.adapter_bin, locality)
      bundle = install_fake_adapter!(adapter, profile)
      File.chmod!(bundle, 0o751)
      if presence == :absent, do: File.rm!(adapter)

      ref = make_ref()
      Process.put({ref, :checks}, 0)

      sh = fn command ->
        send(self(), {ref, command})
        joined = Enum.join(command, " ")

        cond do
          String.contains?(joined, "test -x") ->
            checks = Process.get({ref, :checks}, 0)
            Process.put({ref, :checks}, checks + 1)
            if presence == :absent and checks == 0, do: {"", 1}, else: {"", 0}

          String.contains?(joined, "npm install") ->
            # npm's whole job here is to leave an executable at the adapter path, and the
            # local branch confirms it with File.exists? rather than a shelled test. A
            # mock that returns 0 without producing the artifact would make the local
            # install look like it had failed, so the stand-in produces it.
            File.write!(adapter, "#!/bin/sh\n")
            File.chmod!(adapter, 0o755)
            {"", 0}

          true ->
            {"", 0}
        end
      end

      patch = fn _path, detail ->
        patch_fake_bundle!(bundle, profile)
        {:ok, detail <> profile.remote_patch_detail}
      end

      target = %{
        base_dir: base,
        host_name: "vector",
        host_config: %{
          base_dir: base,
          ssh: if(locality == :local, do: nil, else: "vector@remote")
        },
        adapter_binary: adapter,
        remote_patch: patch,
        sh: sh
      }

      result = Tightbeam.Harness.ensure_adapter(module, target)
      commands = drain_commands(ref, [])
      Process.delete({ref, :checks})
      stat = File.stat!(bundle)

      %{
        result: normalize_paths(result, base, nil),
        install_contribution:
          commands
          |> Enum.map(&Enum.join(&1, " "))
          |> Enum.find_value("", fn command ->
            if String.contains?(command, "npm install"), do: command, else: false
          end)
          |> normalize_paths(base, nil),
        bundle: File.read!(bundle),
        mode: Bitwise.band(stat.mode, 0o777)
      }
    end)
  end

  defp expected_adapter(profile, locality, presence) do
    case Map.get(profile, :provisioning, :npm) do
      :npm -> expected_adapter_npm(profile, locality, presence)
      :shim -> expected_adapter_shim(profile)
    end
  end

  # A :shim provision is presence- and locality-invariant in its RESULT: `ensure_shim_adapter`
  # rewrites the shim over the resolved CLI every time and returns the same `{:ok, detail}`; the
  # shared npm install line stays empty (a binary-native harness contributes no package). The
  # shim content is `exec "<cli>" <args> "$@"` at mode 0o755.
  defp expected_adapter_shim(profile) do
    # Parameterized per-harness by the profile's shim exec args (default ["acp"]) so a second
    # binary-native harness (e.g. cursor) reuses this vector by supplying its own values, with no
    # edit to the shared machinery — the same reuse contract as `Spinup.ensure_shim_adapter/4`.
    args = Enum.join(Map.get(profile, :shim_exec_args, ["acp"]), " ")

    cli_path =
      Map.get(profile, :pinned_cli_path, "#{profile.cli_name}-cli")

    %{
      result: {:ok, "shim adapter present"},
      install_contribution: "",
      shim: "#!/bin/sh\nexec \"<BASE>/#{cli_path}\" #{args} \"$@\"\n",
      mode: 0o755
    }
  end

  defp expected_adapter_npm(profile, locality, presence) do
    detail =
      case {locality, presence} do
        {:local, :present} -> "adapters present"
        {:local, :absent} -> "deployed adapters"
        {:remote, :present} -> "adapters present" <> profile.remote_patch_detail
        {:remote, :absent} -> "deployed adapters" <> profile.remote_patch_detail
      end

    %{
      result: {:ok, detail},
      install_contribution: expected_install_contribution(locality, presence),
      bundle: profile.patched,
      mode: 0o751
    }
  end

  # An absent adapter is provisioned on BOTH localities: the gateway host is no longer
  # the one machine that cannot supply its own. The two contribution strings differ only
  # in how the command reaches the host, which is the point — the script, and with it the
  # pinned package set, is shared.
  defp expected_install_contribution(_locality, :present), do: ""

  defp expected_install_contribution(locality, :absent) do
    # npm_provisioned/0, not all/0 — mirrors Spinup.install_command: a binary-native (:shim)
    # harness contributes no npm package to the shared install line, so it must be absent from the
    # EXPECTED contribution too, or every npm harness's ensure_adapter vector would mismatch.
    packages =
      Enum.map_join(
        Tightbeam.Harness.npm_provisioned(),
        " ",
        &"#{&1.install_package()}@#{&1.adapter_version()}"
      )

    script = "npm install --prefix '<BASE>/adapters' --no-save " <> packages

    case locality do
      :local ->
        Enum.join(["/bin/sh", "-c", script], " ")

      :remote ->
        (["ssh" | ssh_opts()] ++ ["vector@remote", "sh", "-c", shell_quote(script)])
        |> Enum.join(" ")
    end
  end

  defp session_config_vectors(_module, profile) do
    [
      vector("session", profile.session_meta, %{guidance: "vector guidance"})
    ]
  end

  defp reconcile_home_vectors(module, profile) do
    [
      vector(
        "sentinel_seeded_desired_set",
        %{write_set: module.owned_home_entries(), sentinels_preserved: true},
        %{profile: profile}
      )
    ]
  end

  defp owned_home_entries_vectors(profile) do
    [
      vector(
        "fresh_projection_write_set",
        :matches_reconcile_write_set,
        %{profile: profile}
      )
    ]
  end

  defp observe_reconcile_home(module, profile) do
    with_tmp("home", fn base ->
      home = Path.join(base, "home")
      auth_dir = Tightbeam.Credentials.store_dir(base, profile.provider)

      sentinels = %{
        "history/transcript" => "history-sentinel",
        "sessions/state" => "session-sentinel",
        "unowned" => "root-sentinel"
      }

      Enum.each(sentinels, fn {relative, bytes} ->
        path = Path.join(home, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
      end)

      File.mkdir_p!(auth_dir)
      File.write!(Path.join(auth_dir, profile.credential_file), "credential")
      before = leaf_snapshot(home)

      target = %{
        base_dir: base,
        host_name: "vector",
        host_config: %{base_dir: base, ssh: nil},
        sh: &system_cmd/1
      }

      module.reconcile_home(target, home, %{
        harness: module.id(),
        machine: "vector",
        rails: profile.rails,
        auth_dir: auth_dir
      })

      after_snapshot = leaf_snapshot(home)

      %{
        write_set:
          after_snapshot
          |> Map.keys()
          |> Enum.reject(&(Map.get(before, &1) == Map.get(after_snapshot, &1)))
          |> Enum.sort(),
        sentinels_preserved:
          Enum.all?(sentinels, fn {relative, bytes} ->
            File.read!(Path.join(home, relative)) == bytes
          end)
      }
    end)
  end

  defp materialize_skills_vectors(_module, profile) do
    expected = %{"tightbeam__alpha/SKILL.md" => "# Alpha\n"}

    [
      vector("snapshot", expected, %{profile: profile})
    ]
  end

  defp observe_materialize_skills(module, profile) do
    with_tmp("skills", fn cwd ->
      skills_root = Path.join(cwd, profile.skills_path)
      stale = Path.join(skills_root, "tightbeam__stale/SKILL.md")
      File.mkdir_p!(Path.dirname(stale))
      File.write!(stale, "stale")

      module.materialize_skills(
        %{host_config: %{ssh: nil}, base_dir: cwd},
        cwd,
        %{
          revision: "vector",
          archetype: "default",
          guidance: "",
          skills: %{"alpha" => "# Alpha\n"}
        }
      )

      skills_root
      |> leaf_snapshot()
      |> Map.new(fn {path, entry} -> {path, entry.bytes} end)
      |> Map.filter(fn {path, _entry} -> String.starts_with?(path, "tightbeam__") end)
    end)
  end

  defp credential_vectors(_module, profile) do
    for case_name <- ["present", "absent", "rotated"] do
      expected =
        case case_name do
          "present" -> %{ready?: true, harvested: nil}
          "absent" -> %{ready?: false, harvested: nil}
          "rotated" -> %{ready?: true, harvested: "rotated-bytes"}
        end

      vector(case_name, expected, %{profile: profile, case: case_name})
    end
  end

  defp observe_credential(module, profile, case_name) do
    with_tmp("credential", fn base ->
      store = Tightbeam.Credentials.store_dir(base, profile.provider)
      home = Path.join(base, "home")
      File.mkdir_p!(home)

      if case_name in ["present", "rotated"] do
        File.mkdir_p!(store)
        File.write!(Path.join(store, profile.credential_file), "stored-bytes")
      end

      if case_name == "rotated" do
        File.write!(Path.join(home, profile.credential_file), "rotated-bytes")
      end

      target = %{host_config: %{ssh: nil, base_dir: base}, base_dir: base}

      %{
        ready?: module.credential_ready?(target, home),
        harvested: module.harvest_credential(target, home)
      }
    end)
  end

  defp credential_live_vectors(_module, profile) do
    cases = [
      {"authenticated_success", :live},
      {"explicit_rejection", {:dead, {:http_status, 401}}},
      {"timeout", {:unknown, :timeout}},
      {"transient_transport_failure", {:unknown, :econnrefused}},
      {"no_probe_transport", {:unknown, :no_cheap_authenticated_probe}}
    ]

    Enum.map(cases, fn {case_name, supported_expected} ->
      {expected, support} =
        case profile.credential_live do
          :unsupported ->
            # The :unknown REASON and the divergence name are per-profile: fixture has no cheap
            # probe, opencode owns provider auth. A profile that omits them keeps fixture's
            # defaults, so the fixture vectors stay byte-identical.
            reason =
              Map.get(profile, :credential_live_unknown_reason, :no_cheap_authenticated_probe)

            divergence =
              Map.get(
                profile,
                :credential_live_divergence,
                "DIV-CREDENTIAL-LIVE-FIXTURE-NO-PROBE"
              )

            {{:unknown, reason}, {:unsupported, divergence}}

          _ ->
            {supported_expected, :supported}
        end

      vector(
        case_name,
        %{result: expected, bounded_elapsed: true, cleanup: true},
        %{profile: profile, case: case_name},
        support
      )
    end)
  end

  defp observe_credential_live(module, profile, case_name) do
    timeout_ms = 25
    parent = self()

    transport =
      if profile.credential_live == :unsupported do
        fn _target, _request -> {:error, :must_not_be_called} end
      else
        case case_name do
          "authenticated_success" ->
            raw_fixture_transport(profile.credential_live.live_fixture)

          "explicit_rejection" ->
            raw_fixture_transport(profile.credential_live.dead_fixture)

          "timeout" ->
            fn _target, _request ->
              send(parent, {:credential_transport_pid, self()})

              receive do
                :never -> {:error, :unexpected}
              end
            end

          "transient_transport_failure" ->
            fn _target, _request -> {:error, :econnrefused} end

          "no_probe_transport" ->
            fn _target, _request -> {:error, :no_cheap_authenticated_probe} end
        end
      end

    started = System.monotonic_time(:millisecond)

    result =
      module.credential_live?(
        %{host_config: %{ssh: nil}, sh: &system_cmd/1},
        "/vector/home",
        transport: transport,
        timeout_ms: timeout_ms,
        # The five liveness cases are about the RESULT MAPPING (live/dead/
        # unknown/bounded/cleaned-up), which is kind-independent, so they run on
        # one kind. The api-key routes are exercised where their oracle is a
        # recorded vendor response, in credential_kinds_test.exs.
        credential_kind: :subscription
      )

    elapsed = System.monotonic_time(:millisecond) - started

    transport_pid =
      receive do
        {:credential_transport_pid, pid} -> pid
      after
        0 -> nil
      end

    %{
      result: result,
      bounded_elapsed: elapsed <= timeout_ms + 250,
      cleanup: is_nil(transport_pid) or not Process.alive?(transport_pid)
    }
  end

  defp raw_fixture_transport(path) do
    recording =
      path
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("response")

    raw =
      {:ok,
       %{
         status: recording["status"],
         headers: recording["headers"],
         body: JSON.encode!(recording["body"])
       }}

    fn _target, _request -> raw end
  end

  defp install_cli_projection_vectors(module) do
    effect = if module.id() == :codex, do: :codex_projection, else: :no_op

    for case_name <- ["creates", "already-exists-skip", "self-resolved-skip"] do
      vector(
        case_name,
        expected_cli_projection(case_name, effect),
        %{case: case_name, effect: effect}
      )
    end
  end

  defp observe_cli_projection(module, case_name, effect) do
    with_tmp("cli-projection", fn base ->
      cli_bin = Path.join(base, "cli-bin")
      discovered_bin = Path.join(base, "discovered-bin")
      projection = Path.join(cli_bin, "codex")
      discovered = Path.join(discovered_bin, "codex")
      original_path = System.get_env("PATH")

      File.mkdir_p!(cli_bin)
      File.mkdir_p!(discovered_bin)

      case case_name do
        "creates" ->
          executable!(discovered, "discovered")
          System.put_env("PATH", discovered_bin)

        "already-exists-skip" ->
          executable!(discovered, "discovered")
          executable!(projection, "existing")
          System.put_env("PATH", discovered_bin)

        "self-resolved-skip" ->
          executable!(projection, "self-resolved")
          System.put_env("PATH", cli_bin)
      end

      before = filesystem_effect(cli_bin)

      try do
        :ok = module.install_cli_projection(cli_bin)

        %{effect: effect, before: before, after: filesystem_effect(cli_bin)}
        |> normalize_paths(base, nil)
      after
        restore_env("PATH", original_path)
      end
    end)
  end

  defp expected_cli_projection("creates", :no_op),
    do: %{effect: :no_op, before: %{}, after: %{}}

  defp expected_cli_projection(case_name, :no_op)
       when case_name in ["already-exists-skip", "self-resolved-skip"] do
    bytes = if case_name == "already-exists-skip", do: "existing", else: "self-resolved"
    snapshot = %{"codex" => %{bytes: bytes, mode: 0o755}}
    %{effect: :no_op, before: snapshot, after: snapshot}
  end

  defp expected_cli_projection("creates", :codex_projection) do
    %{
      effect: :codex_projection,
      before: %{},
      after: %{
        "codex" => %{
          bytes:
            "#!/bin/sh\nexec \"<BASE>/discovered-bin/codex\" --dangerously-bypass-hook-trust \"$@\"\n",
          mode: 0o755
        }
      }
    }
  end

  defp expected_cli_projection(case_name, :codex_projection)
       when case_name in ["already-exists-skip", "self-resolved-skip"] do
    bytes = if case_name == "already-exists-skip", do: "existing", else: "self-resolved"
    snapshot = %{"codex" => %{bytes: bytes, mode: 0o755}}
    %{effect: :codex_projection, before: snapshot, after: snapshot}
  end

  defp executable!(path, bytes) do
    File.write!(path, bytes)
    File.chmod!(path, 0o755)
  end

  defp filesystem_effect(root) do
    root
    |> leaf_snapshot()
    |> Map.new(fn {path, entry} ->
      stat = File.stat!(Path.join(root, path))
      {path, %{bytes: entry.bytes, mode: Bitwise.band(stat.mode, 0o777)}}
    end)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp probe_cli_vectors(_module, profile) do
    expected_path =
      if pinned = Map.get(profile, :pinned_cli_path) do
        "<BASE>/#{pinned}"
      else
        case profile.probe_path do
          :shim -> "<BASE>/bin/#{profile.cli_name}"
          :discovered -> "<BASE>/discovered/#{profile.cli_name}"
        end
      end

    [
      vector(
        "fake_cli",
        {:ok, %{bin: expected_path, version: profile.cli_version}},
        %{profile: profile}
      )
    ]
  end

  defp observe_probe_cli(module, profile) do
    with_tmp("cli", fn base ->
      cli_name = profile.cli_name

      discovered =
        if pinned = Map.get(profile, :pinned_cli_path),
          do: Path.join(base, pinned),
          else: Path.join([base, "discovered", profile.cli_name])

      File.mkdir_p!(Path.dirname(discovered))
      File.write!(discovered, "#!/bin/sh\n")

      Tightbeam.Harness.probe_cli(module, %{
        cli_bin: Path.join(base, "bin"),
        find_executable: fn ^cli_name -> discovered end,
        realpath: fn path -> {:ok, path} end,
        sha256: &cursor_vector_sha256/1,
        run: fn [_binary, "--version"] -> {"#{profile.cli_version}\n", 0} end
      })
      |> normalize_paths(base, nil)
    end)
  end

  defp classification_vectors(_module, events, _kind) do
    Enum.map(events, fn event ->
      support =
        if divergence = event[:divergence], do: {:unsupported, divergence}, else: :supported

      vector(event.case, event.expected, %{envelope: event.envelope}, support)
    end)
  end

  defp catalog_vectors(_module, profile) do
    for case_name <- ["valid", "valid_api_key", "malformed", "unavailable"] do
      vector(
        case_name,
        Map.fetch!(profile.catalog_expected, case_name),
        %{profile: profile, case: case_name}
      )
    end
  end

  defp observe_catalog(module, profile, case_name) do
    with_tmp("catalog", fn base ->
      state = profile.catalog_state.(case_name, base)
      module.fetch_catalog(state)
    end)
  end

  defp wire_projection_vectors(_module, profile) do
    [
      vector("round_trip", profile.wire_projection, %{})
    ]
  end

  defp vector(case_name, expected, input, support \\ :supported),
    do: %{case: case_name, expected: expected, input: input, support: support}

  # One shape for both localities (#46): the adapter lives under the host's own
  # base_dir. Local used to resolve to a sibling checkout of the retired
  # TypeScript project, which is the coupling this removed.
  defp adapter_path(base, adapter_bin, _locality),
    do: Path.join([base, "adapters", "node_modules", ".bin", adapter_bin])

  defp install_fake_adapter!(adapter, profile) do
    node_modules = adapter |> Path.dirname() |> Path.dirname()
    package_dir = Path.join([node_modules, "@agentclientprotocol", profile.adapter_package])
    bundle = Path.join([package_dir, "dist", profile.adapter_bundle])
    File.mkdir_p!(Path.dirname(adapter))
    File.mkdir_p!(Path.dirname(bundle))
    File.write!(adapter, "#!/bin/sh\n")

    File.write!(
      Path.join(package_dir, "package.json"),
      JSON.encode!(%{"version" => profile.adapter_version})
    )

    File.write!(bundle, profile.source)
    bundle
  end

  defp patch_fake_bundle!(bundle, profile) do
    %File.Stat{mode: mode} = File.stat!(bundle)
    File.write!(bundle, profile.patched)
    File.chmod!(bundle, mode)
  end

  defp drain_commands(ref, acc) do
    receive do
      {^ref, command} -> drain_commands(ref, [command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp leaf_snapshot(root) do
    if File.exists?(root) do
      walk_leaves(root, root, %{})
    else
      %{}
    end
  end

  defp walk_leaves(root, path, acc) do
    case File.lstat!(path) do
      %File.Stat{type: :directory} ->
        path
        |> File.ls!()
        |> Enum.sort()
        |> Enum.reduce(acc, fn child, entries ->
          walk_leaves(root, Path.join(path, child), entries)
        end)

      %File.Stat{type: :symlink} ->
        Map.put(acc, Path.relative_to(path, root), %{type: :symlink, bytes: File.read_link!(path)})

      %File.Stat{type: type} ->
        Map.put(acc, Path.relative_to(path, root), %{type: type, bytes: File.read!(path)})
    end
  end

  defp normalize_paths(value, base, home) do
    replace = fn string ->
      if home do
        string
        |> String.replace(home, "<HOME>")
        |> String.replace(base, "<BASE>")
      else
        String.replace(string, base, "<BASE>")
      end
    end

    normalize_term(value, replace)
  end

  defp normalize_term(value, replace) when is_binary(value), do: replace.(value)

  defp normalize_term(value, replace) when is_list(value),
    do: Enum.map(value, &normalize_term(&1, replace))

  defp normalize_term(value, replace) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&normalize_term(&1, replace)) |> List.to_tuple()

  # Structs are VALUES, not maps to walk into: a model identity normalizes as
  # itself. Rebuilding one field-by-field through Map.new would strip its type.
  defp normalize_term(%_{} = value, _replace), do: value

  defp normalize_term(value, replace) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, normalize_term(item, replace)} end)

  defp normalize_term(value, _replace), do: value

  defp with_tmp(label, fun) do
    root =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-conformance-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end

  @doc false
  def bounded_run(run, command, timeout) do
    case bounded_call(fn -> run.(command) end, timeout) do
      {:ok, result} -> {:ok, result}
      :timeout -> {:error, "timed out after #{timeout}ms"}
    end
  end

  defp bounded_call(fun, timeout) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          error -> {:error, {:transport_exception, Exception.message(error)}}
        catch
          kind, reason -> {:error, {:transport_exception, kind, reason}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:ok, {:error, {:transport_exit, reason}}}
      nil -> :timeout
    end
  end
end
