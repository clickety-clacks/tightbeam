defmodule Tightbeam.Harness.Codex do
  @moduledoc false
  @behaviour Tightbeam.Harness

  require Logger

  alias Tightbeam.Harness.Support
  alias Tightbeam.{Model, Placement}

  @adapter_version "1.12.0"
  @adapter_package "codex-acp"
  # Two routes, one per credential kind, because they are two different accounts'
  # worth of entitlement expressed two different ways.
  #
  # SUBSCRIPTION — recorded live 2026-07-28 against codex-cli 0.145.0. The
  # platform route is CLOSED to a ChatGPT token: 403, missing scope
  # `api.model.read`. Do not "fix" this to the obvious URL.
  @models_url "https://chatgpt.com/backend-api/codex/models"

  # API KEY — the platform route, which the subscription token was refused for by
  # name. Recorded 2026-07-28 with a deliberately invalid key: 401
  # `invalid_api_key`, an AUTHENTICATION failure, not the subscription token's
  # 403 authorization failure. That contrast is the evidence the route treats API
  # keys as first-class.
  #
  # VERIFIED WITH A VALID KEY 2026-07-28 (the #89 api-key exercise, throwaway
  # org): the route answered 200 with 125 bare ids in the platform shape
  # `derive_platform_entries/1` decodes, and codex-acp ran a real turn on
  # api-key auth (gpt-5.6-sol[medium]). What the exercise DISPROVED is that the
  # adapter accepts everything this route lists — see
  # `@adapter_selectable_models` below.
  @api_models_url "https://api.openai.com/v1/models"

  # Candidate values for the API-key catalog. The platform route lists the
  # account's whole model universe; the stock adapter accepts only models its
  # selected Codex engine returns from ordinary `model/list`. Astra is checked
  # against that exact executable at discovery time before it is advertised.
  #
  # RECORDED LIVE 2026-07-28 (the #89 api-key exercise, throwaway org,
  # codex-acp 1.1.4): GET /v1/models answered 125 bare ids; the adapter REFUSED
  # the platform id `gpt-5.1-codex` with -32602 Invalid params, and ACCEPTED
  # `gpt-5.6-sol`, which ran a real turn (effort medium) on the same adapter and
  # auth. `gpt-5.1-codex` is spelled exactly like a codex slug and was refused
  # anyway, so a platform id is NOT translatable into the adapter's vocabulary
  # by any mapping this repo can compute from spelling — substituting a
  # near-miss would be the silent-downgrade `harness/claude.ex` refuses. Hence a
  # FILTER to the bounded candidate set for the platform route.
  #
  # Injectable (`codex_selectable_models` in the catalog's options, `:all` to
  # disable) for the existing catalog tests. This is a scope filter, not a claim
  # that every selected engine offers both values.
  @adapter_selectable_models ~w(gpt-5.6-sol gpt-6-astra)

  # The gate probe's own model, as fields — it crosses the adapter seam like any
  # other selection.
  @probe_model %Tightbeam.Model{family: "gpt-5.6-sol", effort: "medium", context: nil}

  @adapter_bundle "index.js"

  @doc false
  def adapter_version, do: @adapter_version

  @doc """
  Bounded API-key candidates. Astra still needs a matching selected-engine
  `model/list` result before `fetch_catalog/1` admits it.
  """
  def adapter_selectable_models, do: @adapter_selectable_models

  @impl true
  def id, do: :codex

  @impl true
  def wire_name, do: "codex"

  @impl true
  def credential_provider, do: :openai

  @impl true
  def credential_env_vars, do: []

  @impl true
  def default_model, do: Tightbeam.Model.new("gpt-5.6-sol", effort: "medium")

  @impl true
  def install_package, do: "@agentclientprotocol/codex-acp"

  @impl true
  def cli_binary, do: "codex"

  @impl true
  def wire_projection do
    JSON.encode!(%{
      "id" => "codex",
      "wire_name" => wire_name(),
      "install_package" => install_package(),
      "cli_binary" => cli_binary(),
      "process_markers" => ["codex-acp"]
    })
  end

  @impl true
  def prepare_launch(target, home, opts) do
    binary = adapter_binary(target)
    # The SessionStart identity carrier is required even in an org with no
    # statutes, so the existing gate must witness it before any Codex session
    # is admitted. The reserved probe hook is projected in either case.
    probe_cwd = Path.join(target.host_config.base_dir, "work/gate-probe")

    if Support.local?(target) do
      File.rm_rf!(probe_cwd)
    else
      Support.run!(
        target,
        ["ssh" | Support.ssh_opts()] ++
          [target.host_config.ssh, "rm", "-rf", probe_cwd]
      )
    end

    ensure_opts = [base_dir: target.base_dir, sh: target.sh]

    ensure_opts =
      case Keyword.fetch!(opts, :sh_out) do
        nil -> Keyword.put(ensure_opts, :sh_out, target.sh)
        sh_out -> Keyword.put(ensure_opts, :sh_out, sh_out)
      end

    Keyword.fetch!(opts, :ensure_workdir).(
      target.host_config,
      probe_cwd,
      "",
      ensure_opts
    )

    probe = [probe_cwd: probe_cwd, probe_model: @probe_model]

    launch =
      if Support.local?(target) do
        config = [{"CODEX_CONFIG", ~s({"bypass_hook_trust":true})}]

        [
          cmd: [binary],
          env: [{"CODEX_HOME", home} | Keyword.fetch!(opts, :common_env) ++ config]
        ]
      else
        config = ["CODEX_CONFIG='#{~s({"bypass_hook_trust":true})}'"]

        remote_env =
          ["CODEX_HOME=#{home}" | Keyword.fetch!(opts, :remote_env)] ++ config

        [
          cmd:
            ["ssh" | Support.ssh_opts()] ++
              [target.host_config.ssh, "exec", "env" | remote_env] ++ [binary],
          env: [{"TIGHTBEAM_LINEAGE", Keyword.fetch!(opts, :lineage)}]
        ]
      end

    Keyword.merge(launch, probe)
  end

  @impl true
  def ensure_adapter(target) do
    Tightbeam.Spinup.ensure_adapter(target, __MODULE__, adapter_binary(target))
  end

  @impl true
  def session_config(session, guidance) do
    prefix =
      "Your Tight Beam archetype identity arrives as this Codex developer message. " <>
        "It is authoritative and outranks product AGENTS.md instructions on conflict."

    guidance =
      if Map.get(session, :identity) == true and not String.starts_with?(guidance, prefix),
        do: prefix <> "\n\n" <> guidance,
        else: guidance

    %{
      guidance: guidance,
      meta: %{},
      permission_mode: "agent-full-access",
      effort_config: "reasoning_effort",
      resident_model_switch: :in_place,
      canonical_model_prefixes: ["gpt-"]
    }
  end

  @impl true
  def owned_home_entries,
    do: Support.owned_home_entries("hooks.json")

  @impl true
  def reconcile_home(target, home, desired) do
    rails =
      case desired.rails do
        nil ->
          nil

        bytes when is_binary(bytes) ->
          bytes

        hooks ->
          hooks
          |> update_in(["hooks", "PreToolUse"], &(&1 ++ [Tightbeam.Rails.probe_entry()]))
          |> JSON.encode!()
      end

    rails = Tightbeam.Harness.CodexIdentity.hook_settings(rails)

    reconciled =
      Tightbeam.Homes.reconcile(target, home, %{desired | rails: rails},
        rails_filename: "hooks.json"
      )

    if Map.has_key?(desired, :default_model) do
      reconcile_guardian_approval_default!(target, reconciled.home_path)
    end

    reconciled
  end

  defp reconcile_guardian_approval_default!(target, home) do
    path = Path.join(home, "config.toml")
    observed = read_guardian_config!(target, path)
    bytes = if observed == :missing, do: "", else: elem(observed, 1)
    replacement = guardian_default_bytes!(bytes, path)

    if replacement != bytes do
      publish_guardian_config!(target, path, observed, replacement)
    end
  end

  defp guardian_default_bytes!(bytes, path) do
    replacement =
      case Toml.decode(bytes) do
        {:ok, config} -> guardian_default_for_valid_config(bytes, config)
        {:error, _reason} -> bytes
      end

    if replacement == bytes do
      bytes
    else
      case Toml.decode(replacement, filename: path) do
        {:ok, %{"features" => %{"guardian_approval" => false}}} -> replacement
        _ -> bytes
      end
    end
  end

  defp guardian_default_for_valid_config(bytes, config) do
    case Map.fetch(config, "features") do
      :error ->
        append_guardian_table(bytes)

      {:ok, features} when is_map(features) ->
        if Map.has_key?(features, "guardian_approval") do
          bytes
        else
          insert_guardian_lines(bytes, guardian_table_headers(bytes))
        end

      {:ok, _incompatible} ->
        bytes
    end
  end

  defp append_guardian_table("") do
    "[features]\nguardian_approval = false\n"
  end

  defp append_guardian_table(bytes) do
    separator = if String.ends_with?(bytes, "\n"), do: "", else: "\n"
    bytes <> separator <> "[features]\nguardian_approval = false\n"
  end

  defp guardian_table_headers(bytes) do
    Regex.scan(~r/^[ \t]*\[\[?[^\r\n]+\]?\][ \t]*(?:#[^\r\n]*)?(?:\r\n|\n|$)/m, bytes,
      return: :index
    )
    |> Enum.reduce(%{features: nil, first: nil}, fn [{offset, length}], headers ->
      line = binary_part(bytes, offset, length)
      first = headers.first || offset

      features =
        if features_table_header?(line) do
          {offset, length, String.ends_with?(line, "\n")}
        else
          headers.features
        end

      %{features: features, first: first}
    end)
  end

  defp features_table_header?(line) do
    case Toml.decode(line <> "\n__tightbeam_guardian_marker__ = true") do
      {:ok, %{"features" => %{"__tightbeam_guardian_marker__" => true}}} -> true
      _ -> false
    end
  end

  defp insert_guardian_lines(bytes, %{features: {offset, length, newline?}}) do
    insertion = if(newline?, do: "", else: "\n") <> "guardian_approval = false\n"
    split = offset + length

    binary_part(bytes, 0, split) <>
      insertion <> binary_part(bytes, split, byte_size(bytes) - split)
  end

  defp insert_guardian_lines(bytes, %{first: first}) when is_integer(first) do
    binary_part(bytes, 0, first) <>
      "features.guardian_approval = false\n" <>
      binary_part(bytes, first, byte_size(bytes) - first)
  end

  defp insert_guardian_lines(bytes, _headers) do
    separator = if bytes == "" or String.ends_with?(bytes, "\n"), do: "", else: "\n"
    bytes <> separator <> "features.guardian_approval = false\n"
  end

  defp read_guardian_config!(target, path) do
    if Support.local?(target) do
      read_local_guardian_config!(path)
    else
      read_remote_guardian_config!(target, path)
    end
  end

  defp read_local_guardian_config!(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> {:present, File.read!(path)}
      {:error, :enoent} -> :missing
      {:ok, %{type: type}} -> raise "Codex config #{path} is not a regular file (#{type})"
      {:error, reason} -> raise "could not inspect Codex config #{path}: #{inspect(reason)}"
    end
  end

  defp read_remote_guardian_config!(target, path) do
    quoted = Support.shell_quote(path)

    script =
      "if [ -L #{quoted} ]; then exit 45; " <>
        "elif [ -f #{quoted} ]; then cat #{quoted}; " <>
        "elif [ -e #{quoted} ]; then exit 45; else exit 44; fi"

    command =
      ["ssh" | Support.ssh_opts()] ++
        [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]

    case target.sh.(command) do
      {bytes, 0} -> {:present, bytes}
      {_output, 44} -> :missing
      {_output, 45} -> raise "Codex config #{path} is not a regular file"
      {_output, exit} -> raise "remote Codex config check failed with exit #{exit}"
    end
  end

  defp publish_guardian_config!(target, path, observed, replacement) do
    if Support.local?(target) do
      publish_local_guardian_config!(path, observed, replacement)
    else
      publish_remote_guardian_config!(target, path, observed, replacement)
    end
  end

  defp publish_local_guardian_config!(path, observed, replacement) do
    temporary = path <> ".tightbeam-guardian-#{guardian_publication_id()}"

    try do
      File.write!(temporary, replacement, [:exclusive])

      case observed do
        {:present, _bytes} -> File.chmod!(temporary, File.stat!(path).mode)
        :missing -> File.chmod!(temporary, 0o600)
      end

      if read_local_guardian_config!(path) != observed do
        raise "Codex config changed during Guardian default publication: #{path}"
      end

      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp publish_remote_guardian_config!(target, path, observed, replacement) do
    nonce = guardian_publication_id()
    staging = Path.join([target.base_dir, "staging", target.host_name, "codex-guardian"])
    action = Path.join(staging, "action-#{nonce}")
    remote_replacement = path <> ".tightbeam-guardian-#{nonce}"
    remote_expected = path <> ".tightbeam-guardian-expected-#{nonce}"
    local_replacement = Path.join(action, Path.basename(remote_replacement))
    local_expected = Path.join(action, Path.basename(remote_expected))

    File.mkdir_p!(action)

    try do
      File.write!(local_replacement, replacement)

      case observed do
        {:present, bytes} ->
          File.write!(local_expected, bytes)

        :missing ->
          :ok
      end

      upload_guardian_stage!(target, action, Path.dirname(path))

      publish_remote_guardian_stage!(
        target,
        path,
        observed,
        remote_expected,
        remote_replacement
      )
    after
      cleanup_remote_guardian_stage(target, remote_expected, remote_replacement)
      File.rm_rf(action)
    end
  end

  defp upload_guardian_stage!(target, local_dir, remote_dir) do
    Support.run!(target, [
      "rsync",
      "-a",
      "-e",
      Enum.join(["ssh" | Support.ssh_opts()], " "),
      local_dir <> "/",
      "#{target.host_config.ssh}:#{remote_dir}/"
    ])
  end

  defp publish_remote_guardian_stage!(target, path, observed, expected, replacement) do
    path = Support.shell_quote(path)
    expected = Support.shell_quote(expected)
    replacement = Support.shell_quote(replacement)

    unchanged =
      case observed do
        {:present, _bytes} ->
          "[ ! -L #{path} ] && [ -f #{path} ] && cmp -s #{path} #{expected}"

        :missing ->
          "[ ! -e #{path} ] && [ ! -L #{path} ]"
      end

    mode =
      case observed do
        {:present, _bytes} ->
          "mode=$(stat -f %Lp #{path} 2>/dev/null) || " <>
            "mode=$(stat -c %a #{path} 2>/dev/null) || exit 76; " <>
            "chmod \"$mode\" #{replacement}"

        :missing -> "chmod 600 #{replacement}"
      end

    script =
      "trap \"rm -f #{expected} #{replacement}\" EXIT; " <>
        unchanged <> " || exit 75; " <> mode <> " && mv -f #{replacement} #{path}"

    command =
      ["ssh" | Support.ssh_opts()] ++
        [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]

    case target.sh.(command) do
      {_output, 0} -> :ok
      {_output, 75} -> raise "Codex config changed during Guardian default publication: #{path}"
      {output, exit} ->
        detail = String.trim(output)
        detail = if detail == "", do: "", else: ": #{detail}"
        raise "remote Codex config publication failed with exit #{exit}#{detail}"
    end
  end

  defp cleanup_remote_guardian_stage(target, expected, replacement) do
    script =
      "rm -f #{Support.shell_quote(expected)} #{Support.shell_quote(replacement)}"

    command =
      ["ssh" | Support.ssh_opts()] ++
        [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]

    target.sh.(command)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp guardian_publication_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  @doc false
  @impl true
  def project_session_identity(target, session_id, guidance),
    do: Tightbeam.Harness.CodexIdentity.project(target, session_id, guidance)

  @doc false
  @impl true
  def verify_session_identity_hook(target, session_id),
    do: Tightbeam.Harness.CodexIdentity.verify_hook(target, session_id)

  @impl true
  def materialize_skills(target, cwd, snapshot) do
    Tightbeam.Identity.materialize_for_harness!(
      target,
      snapshot,
      cwd,
      Path.join([".codex", "skills"])
    )
  end

  @impl true
  def credential_ready?(target, home) do
    Tightbeam.Homes.credential_ready?(target, home, ["auth.json"])
  end

  @impl true
  def credential_live?(target, home, opts) do
    script = liveness_script(Keyword.fetch!(opts, :credential_kind))
    request = %{command: ["node", "--no-warnings", "-e", script, Path.join(home, "auth.json")]}
    Support.credential_live_result(target, request, opts)
  end

  # The cheapest authenticated call each kind CAN make. A subscription cannot
  # reach the platform route (403, missing `api.model.read`) and an API key
  # cannot reach the ChatGPT account route, so there is no single probe that
  # serves both — liveness is kind-shaped all the way down. This is what
  # docs/SMOKE.md P2 promises; the two must move together.
  defp liveness_script(:subscription) do
    """
    const fs = require("node:fs");
    const auth = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    fetch("https://chatgpt.com/backend-api/wham/accounts/check", {
      headers: {
        "Authorization": `Bearer ${auth.tokens.access_token}`,
        "ChatGPT-Account-ID": auth.tokens.account_id,
        "User-Agent": "codex_cli_rs/0.145.0"
      }
    })#{liveness_tail()}
    """
  end

  defp liveness_script(:api_key) do
    """
    const fs = require("node:fs");
    const auth = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    fetch("#{@api_models_url}", {
      headers: {
        "Authorization": `Bearer ${auth.OPENAI_API_KEY}`,
        "User-Agent": "codex_cli_rs/0.145.0"
      }
    })#{liveness_tail()}
    """
  end

  defp liveness_tail do
    """
    .then(async response => {
      process.stdout.write(JSON.stringify({
        status: response.status,
        headers: {"content-type": response.headers.get("content-type")},
        body: await response.text()
      }));
    }).catch(error => {
      // Same defect as claude.ex's probe, fixed the same way: undici leaves `code`
      // undefined on a fetch rejection and puts the real reason in `error.cause`, so
      // `error.code || error.message` reported "fetch failed" for every transport
      // failure and named none of them.
      const cause = error.cause;
      process.stderr.write(
        [cause && cause.code, cause && cause.message, error.code, error.message]
          .filter(Boolean)
          .join(": ") || "unknown transport failure"
      );
      process.exitCode = 70;
    });
    """
  end

  @impl true
  def install_cli_projection(cli_bin) do
    shim = Path.join(cli_bin, cli_binary())
    discovered = System.find_executable(cli_binary())

    if not File.exists?(shim) and is_binary(discovered) and
         Path.dirname(discovered) != Path.dirname(shim) do
      File.write!(
        shim,
        "#!/bin/sh\nexec \"#{discovered}\" --dangerously-bypass-hook-trust \"$@\"\n"
      )

      File.chmod!(shim, 0o755)
    end

    :ok
  end

  @impl true
  def probe_cli(target) do
    find = Map.get(target, :find_executable, &System.find_executable/1)
    shim = Path.join(Map.get(target, :cli_bin, ""), cli_binary())
    binary = if File.exists?(shim), do: shim, else: find.(cli_binary())
    Support.bounded_probe(binary, target)
  end

  @impl true
  def classify_auth_event(%{"authStatus" => %{"kind" => "none"}}), do: :terminal

  def classify_auth_event(%{"authStatus" => %{"kind" => kind}})
      when kind in ["account", "api_key", "gateway", "external"],
      do: :transient

  # Keep the public account/updated payload compatible for older ACP peers; the
  # current adapters use authStatus above and no longer need a source rewrite.
  def classify_auth_event(%{"authMode" => nil, "planType" => nil}), do: :terminal

  def classify_auth_event(%{"authMode" => mode})
      when mode in ["apiKey", "chatgpt", "chatgptAuthTokens"],
      do: :transient

  def classify_auth_event(_event), do: :unknown

  @impl true
  def classify_subagent_event(%{
        "sessionUpdate" => "subagent_spawned",
        "subagentSessionId" => subagent
      }) do
    {:subagent_start, %{source_event_ref: subagent, subagent_ref: subagent}}
  end

  def classify_subagent_event(%{
        "sessionUpdate" => "subagent_state_update",
        "subagentSessionId" => subagent,
        "state" => state
      })
      when state in ["completed", "failed", "cancelled", "disconnected"] do
    {:subagent_stop, %{source_event_ref: subagent, subagent_ref: subagent}}
  end

  def classify_subagent_event(_update), do: :skip

  # The catalog is the ACCOUNT's, so it is derived on the host that holds the
  # account — one HTTPS call made BY that host. This replaced reading codex's
  # `models_cache.json`, which was only ever a copy of this answer, and only on a
  # host where codex had already run (#67). Nothing reads that file now.
  #
  # Two facts the probe needs exist only on the owning host, and both are taken
  # there: the access token out of `auth.json`, and the version of the `codex`
  # binary. Neither is interpolated into a command line by us — the remote shell
  # expands both — so no credential transits and none appears in a process table.
  @impl true
  def fetch_catalog(state) do
    kind = Map.fetch!(state, :credential_kind)

    case probe(state, kind) do
      {:ok, body, trailer} ->
        with {:ok, models} <- decode_catalog(kind, body),
             {:ok, entries} <- derive_catalog_entries(kind, models),
             entries <- keep_selectable(entries, selectable_models(state, kind)),
             {:ok, entries} <- qualify_api_key_astra(state, kind, entries),
             entries when entries != [] <- entries do
          {:ok, entries}
        else
          {:error, reason} -> {:error, reason}
          [] -> {:error, empty_catalog_reason(kind, trailer)}
          _ -> {:error, :malformed_catalog}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An empty answer means two different things on the two routes, and saying the
  # wrong one sends the operator after the wrong fix. Only the account route
  # filters by client version (see `probe_script/2`); the platform route has no
  # such filter, so blaming a version there would be a fabricated diagnosis.
  defp empty_catalog_reason(:subscription, trailer),
    do: {:empty_catalog_for_client_version, client_version(trailer)}

  defp empty_catalog_reason(:api_key, _trailer), do: :empty_inventory

  defp probe(state, kind) do
    sh = Map.get(state.options, :sh, &Support.system_cmd_out/1)
    executable = catalog_executable(state, kind)

    auth =
      Tightbeam.Credentials.credential_path(
        state.base_dir,
        Map.get(state, :host_name, Tightbeam.Placement.local_host_name()),
        credential_provider()
      )

    sh
    |> Support.catalog_probe(
      Support.catalog_probe_argv(
        Map.get(state, :host_config, %{ssh: nil}).ssh,
        probe_script(kind, auth, executable)
      )
    )
    |> classify_extraction(kind, auth, executable)
  end

  # codex-acp receives this same host/harness CODEX_PATH overlay when it
  # launches. The account route uses its version for `client_version`; the API
  # route uses it for a separate native model/list capability check. Without an
  # overlay both use the adapter's host-local PATH selection.
  defp catalog_executable(state, _kind) do
    with {:ok, db} <- Map.fetch(state.options, :db),
         host <- Map.get(state, :host_name, Placement.local_host_name()),
         %{value: path} <-
           Enum.find(Placement.env_overlays(db, host, wire_name()), &("CODEX_PATH" == &1.name)) do
      {:bound, path}
    else
      _ -> :bare_path
    end
  end

  # Query the same native model/list visibility that stock codex-acp 1.12.0
  # queries. It does not pass includeHidden, and its set_config_option rejects
  # any model absent from that result. The provider's /v1/models IDs establish
  # entitlement separately; they cannot establish this client capability.
  @engine_model_list_js ~S"""
  const {spawn} = require("node:child_process");
  const binary = process.argv[1];
  const home = process.argv[2];
  const child = spawn(binary, ["app-server"], {
    env: {...process.env, CODEX_HOME: home},
    stdio: ["pipe", "pipe", "ignore"]
  });
  let done = false, buffer = "", requestId = 2, version = "unknown";
  let pages = 0;
  const cursors = new Set();
  const models = [];
  const timer = setTimeout(() => finish({error: "timeout"}), 30000);
  function finish(result) {
    if (done) return;
    done = true;
    clearTimeout(timer);
    child.kill();
    process.stdout.write(JSON.stringify(result), () => process.exit(0));
  }
  function send(message) { child.stdin.write(JSON.stringify(message) + "\n"); }
  function list(cursor) {
    send({id: requestId, method: "model/list", params: {cursor, limit: null}});
  }
  child.on("error", () => finish({error: "spawn_failed"}));
  child.on("exit", () => finish({error: "engine_exited"}));
  child.stdout.on("data", chunk => {
    buffer += chunk;
    if (buffer.length > 2000000) return finish({error: "response_too_large"});
    let end;
    while ((end = buffer.indexOf("\n")) >= 0 && !done) {
      const line = buffer.slice(0, end);
      buffer = buffer.slice(end + 1);
      let reply;
      try { reply = JSON.parse(line); }
      catch { return finish({error: "malformed_response"}); }
      if (reply.id === 1) {
        if (!reply.result) return finish({error: "initialize_failed"});
        const match = String(reply.result.userAgent || "").match(/\/([0-9]+\.[0-9]+\.[0-9]+)/);
        if (match) version = match[1];
        send({method: "initialized"});
        list(null);
      } else if (reply.id === requestId) {
        if (!reply.result || !Array.isArray(reply.result.data))
          return finish({error: "model_list_failed"});
        models.push(...reply.result.data.filter(model =>
          model && (model.id === "gpt-6-astra" || model.id === "gpt-5.6-sol")));
        const cursor = reply.result.nextCursor;
        if (cursor === null || cursor === undefined)
          return finish({models, engineVersion: version});
        if (typeof cursor !== "string" || cursors.has(cursor) || ++pages > 100)
          return finish({error: "invalid_cursor"});
        cursors.add(cursor);
        requestId++;
        list(cursor);
      }
    }
  });
  send({id: 1, method: "initialize", params: {
    clientInfo: {name: "tightbeam-catalog", title: "Tightbeam Catalog", version: "1"}
  }});
  """

  defp probe_engine_models(state) do
    sh = Map.get(state.options, :sh, &Support.system_cmd_out/1)
    executable = catalog_executable(state, :api_key)
    host = Map.get(state, :host_name, Placement.local_host_name())
    home = Tightbeam.Homes.home_path(state.base_dir, host, :codex)

    path =
      case Map.fetch(state.options, :db) do
        {:ok, db} ->
          Placement.toolchain_path_preview(%{base_dir: state.base_dir, db: db}, host)

        :error ->
          System.get_env("PATH") || ""
      end

    path_assignment =
      if String.ends_with?(path, ":$PATH") do
        "PATH=#{Support.shell_quote(String.trim_trailing(path, ":$PATH"))}:$PATH"
      else
        "PATH=#{Support.shell_quote(path)}"
      end

    binary = if match?({:bound, _}, executable), do: elem(executable, 1), else: "codex"

    script =
      "#{path_assignment} exec node -e #{Support.shell_quote(@engine_model_list_js)} " <>
        "#{Support.shell_quote(binary)} #{Support.shell_quote(home)}"

    argv = Support.catalog_probe_argv(Map.get(state, :host_config, %{ssh: nil}).ssh, script)

    case sh.(argv) do
      {output, 0} ->
        case JSON.decode(output) do
          {:ok, %{"models" => models, "engineVersion" => version}} when is_list(models) ->
            {:ok, models, version}

          {:ok, %{"error" => reason}} when is_binary(reason) ->
            {:error, {:selected_engine_model_list_failed, reason}}

          _ ->
            {:error, :malformed_selected_engine_model_list}
        end

      {_output, exit} ->
        {:error, {:selected_engine_model_list_failed, {:exit, exit}}}
    end
  end

  # Codex owns `auth.json` and rewrites it IN PLACE as it rotates (established
  # empirically 2026-07-28: the inode survives a forced rotation, so the store's
  # symlink stays coherent). This probe is a second, read-only reader of that
  # file, so a read can land mid-rewrite and see torn JSON. That is a RETRYABLE
  # accident of timing, not a verdict on the grant — the next refresh reads a
  # whole file — and it must never be reported as a bad credential, because the
  # repair it would imply (re-onboard) is both wrong and destructive of a working
  # login. The extraction step exits on a distinct code per state so the three
  # cannot collapse into one opaque failure.
  defp classify_extraction(
         {:error, {:probe_failed, 69, _output}},
         :subscription,
         _auth,
         {:bound, path}
       ),
       do: {:error, {:codex_path_unusable, path}}

  defp classify_extraction({:error, {:probe_failed, 66, _output}}, _kind, auth, _executable),
    do: {:error, {:missing_credential, auth}}

  # 75 is structurally near-impossible on an api-key host, and the branch stays
  # anyway. A torn read needs a concurrent in-place REWRITER, and an API key has
  # none: it is static, with no refresh and no single-writer constraint — the
  # same fact that removes codex's shared-runtime anchor on such a host. A
  # hand-run `codex login` is still a writer, so the state stays reachable and
  # stays retryable.
  defp classify_extraction(
         {:error, {:probe_failed, 75, _output}},
         _kind,
         _auth,
         _executable
       ),
       do: {:error, {:credential_read_torn, :retry_next_refresh}}

  # The 67 reason names the field the host was supposed to hold. An api-key host
  # has no `access_token` to be missing, and saying it did would send the
  # operator hunting the wrong key in the right file.
  defp classify_extraction(
         {:error, {:probe_failed, 67, _output}},
         :subscription,
         auth,
         _executable
       ),
       do: {:error, {:credential_missing_access_token, auth}}

  defp classify_extraction(
         {:error, {:probe_failed, 67, _output}},
         :api_key,
         auth,
         _executable
       ),
       do: {:error, {:credential_missing_api_key, auth}}

  defp classify_extraction(result, _kind, _auth, _executable), do: result

  # `client_version` is a SILENT filter ON THIS BRANCH ONLY: every model carries
  # a `minimal_client_version` and the account route drops the ones the caller is
  # too old for — returning 200 with an EMPTY list, not an error. So the version
  # must be the one the `codex` binary on THAT host reports (it is an operator
  # prerequisite there, #76). A constant in our source would filter the catalog
  # to nothing and blame the account. It rides back on the status line so the
  # refusal can name the version that produced an empty answer. The platform
  # route has no such filter — see the api-key clause below.
  defp probe_script(:subscription, auth_path, executable) do
    # Exit codes are sysexits: 66 EX_NOINPUT (no readable auth.json — a real
    # "this host holds no grant"), 75 EX_TEMPFAIL (present but unparseable — a
    # torn read, transient), 67 EX_NOUSER (parsed, but carries no access token —
    # a real credential-shape problem). `set -e` propagates the substitution's
    # status, so the script exits with whichever one node chose.
    node_program =
      ~s|const fs=require("fs");let raw;| <>
        ~s|try{raw=fs.readFileSync("#{auth_path}","utf8")}catch(e){process.exit(66)}| <>
        ~s|let d;try{d=JSON.parse(raw)}catch(e){process.exit(75)}| <>
        ~s|const t=d&&d.tokens?d.tokens.access_token:undefined;| <>
        ~s|if(!(typeof t==="string"&&t.length)){process.exit(67)}process.stdout.write(t)|

    curl =
      Support.catalog_curl(
        "#{@models_url}?client_version=${raw##* }",
        [~s|authorization: Bearer $token|],
        " ${raw##* }"
      )

    version =
      case executable do
        :bare_path ->
          "raw=$(codex --version)"

        {:bound, path} ->
          """
          codex_path=#{Support.shell_quote(path)}
          case "$codex_path" in
            /*) ;;
            *) exit 69 ;;
          esac
          if [ ! -f "$codex_path" ] || [ ! -x "$codex_path" ]; then exit 69; fi
          raw=$("$codex_path" --version)
          """
      end

    """
    exec 2>&1
    set -eu
    token=$(node -e '#{node_program}')
    #{version}
    exec #{curl}
    """
  end

  # No `codex --version` here, and no trailer: `client_version` is the ACCOUNT
  # route's silent filter and the platform route does not have it. Asking the
  # host for a version it will not use would turn "codex is not on this PATH"
  # into a catalog failure.
  #
  # The key comes from `auth.json`'s own `OPENAI_API_KEY` — the native field
  # codex writes and reads in api-key mode, null under a subscription. Same
  # sysexits contract as the subscription branch (66 no readable file, 75 torn,
  # 67 parsed but no usable key), so the three states stay apart here too; an
  # api-key host must not be the one place a torn read reports as a bad
  # credential. As on the other branch the credential is expanded by the REMOTE
  # shell and never appears in a command line on either machine.
  defp probe_script(:api_key, auth_path, _executable) do
    node_program =
      ~s|const fs=require("fs");let raw;| <>
        ~s|try{raw=fs.readFileSync("#{auth_path}","utf8")}catch(e){process.exit(66)}| <>
        ~s|let d;try{d=JSON.parse(raw)}catch(e){process.exit(75)}| <>
        ~s|const k=d?d.OPENAI_API_KEY:undefined;| <>
        ~s|if(!(typeof k==="string"&&k.length)){process.exit(67)}process.stdout.write(k)|

    curl = Support.catalog_curl(@api_models_url, [~s|authorization: Bearer $token|])

    """
    exec 2>&1
    set -eu
    token=$(node -e '#{node_program}')
    exec #{curl}
    """
  end

  defp client_version([version | _]), do: version
  defp client_version(_), do: :unknown

  @impl true
  def conformance_vectors do
    source = "stock codex adapter fixture"
    levels = [%{"effort" => "medium"}]

    valid_entry = %{
      family: "codex-vector",
      context: nil,
      display_name: "Codex Vector",
      name: "Codex Vector",
      efforts: ["medium"],
      max_input_tokens: 2_000,
      capabilities: %{"supported_reasoning_levels" => levels},
      provider: :openai
    }

    Support.conformance_vectors(__MODULE__, %{
      wire_name: wire_name(),
      provider: credential_provider(),
      home_scope: wire_name(),
      home_env: "CODEX_HOME",
      credential_file: "auth.json",
      credential_live: %{
        live_fixture: Application.app_dir(:tightbeam, "priv/credential_live/codex-live.json"),
        dead_fixture: Application.app_dir(:tightbeam, "priv/credential_live/codex-dead.json")
      },
      rails_file: "hooks.json",
      rails: %{"hooks" => %{"PreToolUse" => []}},
      skills_path: Path.join([".codex", "skills"]),
      # Identical under both kinds on purpose: codex reads its credential out of
      # auth.json itself, so its launch plan does not vary by kind. The vector
      # exists to keep that true.
      local_extra_env: %{subscription: [], api_key: []},
      rails_env: {"CODEX_CONFIG", ~s({"bypass_hook_trust":true})},
      remote_prefix: fn _base, home, _kind -> ["CODEX_HOME=#{home}"] end,
      remote_rails_env: "CODEX_CONFIG='#{~s({"bypass_hook_trust":true})}'",
      railed_probe: true,
      always_probe: true,
      adapter_bin: "codex-acp",
      adapter_package: @adapter_package,
      adapter_bundle: @adapter_bundle,
      adapter_version: @adapter_version,
      source: source,
      patched: source,
      remote_patch_detail: "",
      stock_adapter: true,
      session_meta: %{},
      cli_name: "codex",
      cli_version: "codex vector 1.0",
      probe_path: :discovered,
      auth_events: [
        %{
          case: "positive",
          envelope: %{"authStatus" => %{"kind" => "none"}},
          expected: :terminal
        },
        %{case: "negative", envelope: %{"unrelated" => true}, expected: :unknown}
      ],
      subagent_events: [
        %{
          case: "positive_start",
          envelope: %{"sessionUpdate" => "subagent_spawned", "subagentSessionId" => "codex-child"},
          expected:
            {:subagent_start, %{source_event_ref: "codex-child", subagent_ref: "codex-child"}}
        },
        %{
          case: "positive_stop",
          envelope: %{
            "sessionUpdate" => "subagent_state_update",
            "subagentSessionId" => "codex-child",
            "state" => "completed"
          },
          expected:
            {:subagent_stop, %{source_event_ref: "codex-child", subagent_ref: "codex-child"}}
        },
        %{case: "negative", envelope: %{"toolCallId" => "codex-call"}, expected: :skip}
      ],
      catalog_expected: %{
        "valid" => {:ok, [valid_entry]},
        # A DIFFERENT route answering in a DIFFERENT shape, so a different
        # derivation: bare id, no effort tiers, no context window — everything
        # the platform route does not tell us. See `derive_platform_entries/1`.
        "valid_api_key" =>
          {:ok,
           [
             %{
               family: "codex-vector",
               context: nil,
               display_name: "codex-vector",
               name: "codex-vector",
               efforts: [],
               max_input_tokens: nil,
               capabilities: %{},
               provider: :openai
             }
           ]},
        "malformed" => {:error, :malformed_catalog},
        # The vendor's own sentence for a grant that needs signing in again — the
        # probe carries the 401 BODY, not just the code, because that is what the
        # operator acts on.
        "unavailable" =>
          {:error,
           {:http_status, 401,
            ~s({"detail":"Could not parse your authentication token. Please try signing in again."})}}
      },
      catalog_state: fn case_name, base ->
        body =
          JSON.encode!(%{
            "models" => [
              %{
                "slug" => "codex-vector",
                "display_name" => "Codex Vector",
                "supported_reasoning_levels" => levels,
                "max_input_tokens" => 2_000
              }
            ]
          })

        # One HTTPS call made BY the owning host, so the seam is the runner and
        # the vector is a RESPONSE: body, then curl's status on a trailing line,
        # then the `codex --version` that decided what the server would list.
        sh = fn command ->
          script = Enum.join(command, " ")

          case case_name do
            "valid" ->
              {body <> "\n200 0.145.0", 0}

            # Asserting the SCRIPT, not just the parse: this case exists to pin
            # the route and the credential field, and a stand-in that answered
            # regardless would pass while the probe called the wrong endpoint.
            "valid_api_key" ->
              unless String.contains?(script, "api.openai.com/v1/models") do
                raise "codex api-key probe did not call the platform route: #{script}"
              end

              unless String.contains?(script, "OPENAI_API_KEY") do
                raise "codex api-key probe did not read the native api-key field: #{script}"
              end

              if String.contains?(script, "codex --version") do
                raise "codex api-key probe asked for a client_version the route ignores"
              end

              {~s({"data":[{"id":"codex-vector","object":"model"}]}) <> "\n200", 0}

            "malformed" ->
              {"{}\n200 0.145.0", 0}

            "unavailable" ->
              {~s({"detail":"Could not parse your authentication token. Please try signing in again."}) <>
                 "\n401 0.145.0", 0}
          end
        end

        # The vector's subject is catalog DERIVATION — route, credential field,
        # shape — using a synthetic model id. The selectable pin is a separate
        # concern with its own tests, so it is disabled here; leaving it on
        # would filter the synthetic id out and fail the case for the wrong
        # reason.
        %{
          base_dir: base,
          host_name: "vector",
          credential_kind: if(case_name == "valid_api_key", do: :api_key, else: :subscription),
          options: %{sh: sh, codex_selectable_models: :all}
        }
      end,
      wire_projection: %{
        "id" => "codex",
        "wire_name" => "codex",
        "install_package" => "@agentclientprotocol/codex-acp",
        "cli_binary" => "codex",
        "process_markers" => ["codex-acp"]
      }
    })
  end

  defp decode_catalog(kind, body) when is_binary(body) do
    envelope = catalog_envelope(kind)

    case JSON.decode(body) do
      {:ok, %{^envelope => models}} when is_list(models) -> {:ok, models}
      {:ok, _} -> {:error, :malformed_catalog}
      {:error, _} -> {:error, :malformed_json}
    end
  end

  defp decode_catalog(_kind, _body), do: {:error, :malformed_catalog}

  defp catalog_envelope(:subscription), do: "models"
  defp catalog_envelope(:api_key), do: "data"

  defp derive_catalog_entries(:subscription, models), do: derive_account_entries(models)
  defp derive_catalog_entries(:api_key, models), do: derive_platform_entries(models)

  defp derive_account_entries(models) do
    Enum.reduce_while(models, {:ok, []}, fn
      %{
        "slug" => slug,
        "display_name" => display_name,
        "supported_reasoning_levels" => levels
      } = model,
      {:ok, entries}
      when is_binary(slug) and is_binary(display_name) and is_list(levels) ->
        capabilities = model["capabilities"] || %{}
        max_input_tokens = model["max_input_tokens"] || model["context_window"]

        if is_map(capabilities) and
             (is_nil(max_input_tokens) or
                (is_integer(max_input_tokens) and max_input_tokens >= 0)) and
             Enum.all?(levels, &match?(%{"effort" => effort} when is_binary(effort), &1)) do
          efforts = Enum.map(levels, & &1["effort"])
          capabilities = Map.put(capabilities, "supported_reasoning_levels", levels)
          {:cont, {:ok, entries ++ [entry_for(model, slug, efforts, capabilities)]}}
        else
          {:halt, {:error, :malformed_catalog}}
        end

      _, _ ->
        {:halt, {:error, :malformed_catalog}}
    end)
  end

  # ONE entry per vendor model, carrying the efforts it offers.
  defp entry_for(model, id, efforts, capabilities) do
    identity = Model.parse_ref(id)
    display_name = model["display_name"] || id

    %{
      family: identity.family,
      context: identity.context,
      display_name: display_name,
      name: display_name,
      efforts: efforts,
      max_input_tokens: model["max_input_tokens"] || model["context_window"],
      capabilities: capabilities,
      provider: :openai
    }
  end

  # The platform route answers in the PLATFORM's shape, not the codex account
  # route's: `{"data": [{"id": …, "object": "model", …}]}`. No display name, no
  # `supported_reasoning_levels`, no context window. So this is a SECOND
  # derivation, not a second decoder feeding one, and the catalog it produces is
  # honestly thinner: bare ids, no effort tiers, no token ceiling. A session on
  # such a catalog reports `canChangeReasoning: false`, which is correct —
  # nothing here knows what efforts the model offers, and inventing tiers would
  # advertise a control that does not work.
  #
  # OBSERVED LIVE 2026-07-28 (the #89 api-key exercise): 125 entries in exactly
  # this shape, bare ids under "data".
  defp derive_platform_entries(models) do
    Enum.reduce_while(models, {:ok, []}, fn
      %{"id" => id}, {:ok, entries} when is_binary(id) and id != "" ->
        {:cont,
         {:ok,
          entries ++
            [
              %{
                family: id,
                context: nil,
                display_name: id,
                name: id,
                efforts: [],
                max_input_tokens: nil,
                capabilities: %{},
                provider: :openai
              }
            ]}}

      _model, _entries ->
        {:halt, {:error, :malformed_catalog}}
    end)
  end

  defp qualify_api_key_astra(_state, :subscription, entries), do: {:ok, entries}

  defp qualify_api_key_astra(state, :api_key, entries) do
    if Enum.any?(entries, &(&1.family == "gpt-6-astra")) do
      with {:ok, models, version} <- probe_engine_models(state),
           {:ok, levels} <- selected_astra_efforts(models, version) do
        efforts = Enum.map(levels, & &1["reasoningEffort"])

        {:ok,
         Enum.map(entries, fn
           %{family: "gpt-6-astra"} = entry ->
             %{entry | efforts: efforts, capabilities: %{"supported_reasoning_levels" => levels}}

           entry ->
             entry
         end)}
      else
        {:error, {:astra_not_selectable_on_selected_engine, _version} = reason} ->
          # A provider entitlement is not a stock ACP option when the selected
          # engine omits Astra from ordinary model/list. Preserve existing Sol
          # if it remains available, but make the rejected Astra fact explicit.
          Logger.warning("codex catalog: provider lists gpt-6-astra but #{inspect(reason)}")
          remaining = Enum.reject(entries, &(&1.family == "gpt-6-astra"))
          if remaining == [], do: {:error, reason}, else: {:ok, remaining}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, entries}
    end
  end

  defp selected_astra_efforts(models, version) do
    case Enum.filter(models, &(is_map(&1) and &1["id"] == "gpt-6-astra")) do
      [] ->
        {:error, {:astra_not_selectable_on_selected_engine, version}}

      [%{"hidden" => false, "supportedReasoningEfforts" => levels}] when is_list(levels) ->
        efforts =
          Enum.map(levels, fn
            %{"reasoningEffort" => effort} when is_binary(effort) and effort != "" ->
              effort

            _ ->
              nil
          end)

        if efforts != [] and Enum.all?(efforts, &is_binary/1) and
             length(efforts) == length(Enum.uniq(efforts)) do
          {:ok, levels}
        else
          {:error, :malformed_selected_engine_model_list}
        end

      [%{"hidden" => true}] ->
        {:error, {:astra_not_selectable_on_selected_engine, version}}

      _ ->
        {:error, :malformed_selected_engine_model_list}
    end
  end

  # The platform route lists the account's full model universe, most of which
  # stock ACP refuses. This bounded filter preserves Sol and considers Astra;
  # qualify_api_key_astra/3 additionally requires a selected-engine model/list
  # result with exact ID and effort metadata before admitting Astra.
  #
  # The SUBSCRIPTION kind stays unfiltered: its catalog comes from the account
  # route the CLI itself consults, so the two vocabularies share one source
  # there. That claim is now kind-scoped — it was once believed to cover codex
  # wholesale, and the api-key exercise disproved it for the platform route.
  #
  # Injectable through `state.options` (`:all` disables): the accepted set is
  # the adapter version's, and a test
  # must be able to exercise derivation without coupling to the table.
  defp selectable_models(state, :subscription),
    do: Map.get(state.options, :codex_selectable_models, :all)

  defp selectable_models(state, :api_key),
    do: Map.get(state.options, :codex_selectable_models, @adapter_selectable_models)

  defp keep_selectable(entries, :all), do: entries

  defp keep_selectable(entries, selectable) do
    {kept, dropped} =
      Enum.split_with(entries, &(vendor_ref(&1) in selectable))

    if dropped != [] do
      Logger.info(
        "codex catalog: #{length(dropped)} model(s) the platform lists are not selectable by " <>
          "codex-acp #{@adapter_version} and were withheld: " <>
          Enum.map_join(dropped, ", ", &vendor_ref/1) <>
          " — re-probe @adapter_selectable_models in harness/codex.ex if this looks wrong"
      )
    end

    kept
  end

  defp vendor_ref(entry),
    do: Model.to_ref(Model.new(entry.family, context: entry.context))

  defp adapter_binary(target) do
    # One path for both localities, as fixture.ex already does: the adapter lives
    # under the host's own base_dir. The local branch used to point at a sibling
    # checkout of the RETIRED TypeScript project, so the gateway's turn path
    # depended on a directory nothing in this repo owns or installs.
    Map.get(target, :adapter_binary) ||
      Path.join([
        target.host_config.base_dir,
        "adapters",
        "node_modules",
        ".bin",
        "codex-acp"
      ])
  end
end
