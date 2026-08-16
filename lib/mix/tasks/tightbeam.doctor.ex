defmodule Mix.Tasks.Tightbeam.Doctor do
  use Mix.Task

  alias Mix.Tasks.Tightbeam.Catalog.Diff
  alias Tightbeam.Model
  alias Tightbeam.ModelCatalog
  alias Tightbeam.Placement

  @shortdoc "Check inference-free Tightbeam bootstrap readiness"

  @default_model Tightbeam.Model.new("claude-sonnet-5", effort: "medium")

  @impl Mix.Task
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [base_dir: :string, json: :boolean], aliases: [])

    if positional != [] or invalid != [] do
      Mix.raise("usage: mix tightbeam.doctor [--base-dir DIR] [--json]")
    end

    base_dir = options[:base_dir] || Diff.base_dir()
    catalog = Diff.fetch_live(base_dir)

    # Invariant: resolve bootstrap config from ENV first (mirroring runtime.exs)
    # because a standalone mix task does not evaluate runtime.exs.
    inputs = [
      base_dir: base_dir,
      default_model: default_model_setting(),
      default_harness:
        System.get_env("TIGHTBEAM_DEFAULT_HARNESS") ||
          Tightbeam.Harness.default().wire_name(),
      advertised_url:
        System.get_env("TIGHTBEAM_ADVERTISED_URL") ||
          Application.get_env(:tightbeam, :advertised_url),
      hosts: org_hosts(base_dir),
      github_remote_url: github_remote_url(),
      local_host_name: Placement.local_host_name(),
      credential_state: &local_credential_state(base_dir, &1),
      cli_bin: Path.join(base_dir, "bin")
    ]

    {status, report} = evaluate(catalog, inputs)
    Mix.shell().info(format(report, if(options[:json], do: :json, else: :human)))

    if status != 0 do
      Mix.raise(
        "bootstrap_not_ready: one or more checks above did not pass. Read the " <>
          "fix-if-failed column for each FAIL row; rows that say they could not " <>
          "verify are not failures of the thing they name."
      )
    end
  end

  @doc false
  def evaluate(catalog, inputs) do
    base_dir = Keyword.fetch!(inputs, :base_dir)
    default_harness = inputs |> Keyword.fetch!(:default_harness) |> to_string()
    default_model = Keyword.get(inputs, :default_model)
    advertised_url = Keyword.get(inputs, :advertised_url)
    hosts = Keyword.fetch!(inputs, :hosts)
    local_host_name = Keyword.fetch!(inputs, :local_host_name)
    cli_bin = Keyword.get(inputs, :cli_bin, Path.join(base_dir, "bin"))
    binary_probe = Keyword.get(inputs, :harness_binary_probe, &Placement.harness_binary_probe/2)
    credential_probe = Keyword.get(inputs, :credential_state, fn _provider -> :unknown end)
    github_probe =
      Keyword.get(inputs, :github_probe, fn hostname, remote_url ->
        github_probe(base_dir, hostname, remote_url)
      end)
    github_remote_url = Keyword.get(inputs, :github_remote_url)
    harnesses = Enum.map(Tightbeam.Harness.all(), & &1.wire_name())

    credential_states =
      Map.new(harnesses, fn harness ->
        provider = Tightbeam.Harness.parse!(harness).credential_provider()
        {harness, credential_probe.(provider)}
      end)

    harness_checks =
      Map.new(harnesses, fn harness ->
        {harness,
         [
           harness_binary_check(
             binary_probe.(Tightbeam.Harness.parse!(harness).id(), cli_bin),
             harness
           ),
           harness_auth_check(
             catalog,
             harness,
             Map.fetch!(credential_states, harness),
             base_dir,
             local_host_name
           )
         ]}
      end)

    ready_harnesses =
      Enum.filter(harnesses, fn harness ->
        Enum.all?(Map.fetch!(harness_checks, harness), &(&1.ok or &1.unverifiable))
      end)

    harness_checks =
      Enum.flat_map(harnesses, fn harness ->
        Enum.map(Map.fetch!(harness_checks, harness), fn check ->
          cond do
            check.ok -> check
            check.unverifiable -> check
            ready_harnesses != [] -> %{check | level: :warn}
            harness != default_harness -> %{check | level: :warn}
            true -> check
          end
        end)
      end)

    non_harness_checks =
      [
        default_model_check(
          catalog,
          default_harness,
          default_model,
          Map.fetch!(credential_states, default_harness),
          base_dir,
          local_host_name
        ),
        identity_check(base_dir),
        advertised_url_check(advertised_url),
        hosts_check(hosts, local_host_name),
        github_check(github_remote_url, github_probe)
      ]
      |> Enum.reject(&is_nil/1)

    checks = [hd(non_harness_checks)] ++ harness_checks ++ tl(non_harness_checks)

    ready =
      ready_harnesses != [] and
        Enum.all?(non_harness_checks, &(&1.ok or &1.unverifiable))

    {if(ready, do: 0, else: 1), %{checks: checks, ready: ready}}
  end

  @doc false
  def format(report, :json), do: JSON.encode!(report)

  def format(report, :human) do
    rows =
      Enum.map(report.checks, fn check ->
        [check.name, check.level |> Atom.to_string() |> String.upcase(), check.detail, check.fix]
      end)

    headings = ["check", "status", "detail", "fix-if-failed"]
    widths = column_widths([headings | rows])
    divider = Enum.map_join(widths, "-+-", &String.duplicate("-", &1))

    ([format_row(headings, widths), divider] ++ Enum.map(rows, &format_row(&1, widths)))
    |> Enum.join("\n")
  end

  defp default_model_check(catalog, harness, model, credential_state, base_dir, host) do
    fix =
      "Set TIGHTBEAM_DEFAULT_MODEL to a live model and TIGHTBEAM_DEFAULT_EFFORT to one of " <>
        "its effort levels; see mix tightbeam.catalog.diff."

    cond do
      is_nil(model) ->
        check("default_model", false, "default model is not set", fix)

      credential_state == :missing ->
        module = Tightbeam.Harness.parse!(harness)

        check(
          "default_model",
          false,
          "#{Model.describe(model)} cannot be verified because " <>
            missing_credential_message(
              module.credential_provider(),
              harness,
              host,
              base_dir
            ),
          onboard_command(module.credential_provider(), host)
        )

      true ->
        case catalog do
          {:ok, inventories} ->
            default_model_inventory_check(inventories, harness, model, fix)

          {:ok, inventories, degraded} ->
            default_model_inventory_check(inventories, harness, model, fix, degraded)

          {:error, degraded} ->
            check(
              "default_model",
              false,
              "catalog_unavailable: #{catalog_error(degraded)}",
              fix
            )
        end
    end
  end

  defp default_model_inventory_check(inventories, harness, model, fix, degraded \\ %{}) do
    # The ENTRY decides whether an effort is required: a model with tiers needs
    # one, a model without tiers must not carry one. `nil` is a legal selection
    # for an untiered model, and rejecting it out of hand failed a default that
    # the gateway and the catalog both accept.
    entry =
      Enum.find(Map.get(inventories, harness, []), &ModelCatalog.names_same_model?(&1, model))

    live? = not is_nil(entry) and ModelCatalog.offers_effort?(entry, model.effort)
    reason = Map.get(degraded, harness)

    cond do
      live? ->
        check("default_model", true, "#{Model.describe(model)} is live for #{harness}", "")

      # An inventory that is empty BECAUSE the credential server could not be
      # reached says nothing about the model. Concluding "not live" from it sent
      # the operator to change a default model that was fine. An inventory empty
      # for any other reason still fails.
      unverifiable_credential?(reason) ->
        unverifiable(
          "default_model",
          "not verified here: #{harness} inventory is empty because the credential " <>
            "server is unreachable from a bare mix task, so #{Model.describe(model)} " <>
            "liveness is UNKNOWN",
          "Not a model verdict — do not repoint TIGHTBEAM_DEFAULT_MODEL on the " <>
            "strength of this row. Check the running gateway's catalog."
        )

      # The model IS offered here and only the level is wrong, so say which
      # levels it has rather than sending the operator to re-pick a model that
      # was never the problem.
      not is_nil(entry) ->
        check("default_model", false, effort_mismatch(model, entry, harness), fix)

      true ->
        check("default_model", false, "#{Model.describe(model)} is not live for #{harness}", fix)
    end
  end

  defp effort_mismatch(model, %{efforts: []}, harness) do
    "#{model.family} on #{harness} has no effort tiers, so TIGHTBEAM_DEFAULT_EFFORT " <>
      "must be unset (it names #{inspect(model.effort)})"
  end

  defp effort_mismatch(%{effort: nil} = model, entry, harness) do
    "#{model.family} on #{harness} offers #{Enum.join(entry.efforts, "|")} — " <>
      "set TIGHTBEAM_DEFAULT_EFFORT to one of them"
  end

  defp effort_mismatch(model, entry, harness) do
    "#{model.family} on #{harness} does not offer effort #{inspect(model.effort)}; " <>
      "it offers #{Enum.join(entry.efforts, "|")}"
  end

  defp harness_auth_check(_catalog, harness, :missing, base_dir, host) do
    auth_check(harness, false, :missing, 0, base_dir, host)
  end

  defp harness_auth_check({:ok, inventories}, harness, _credential_state, base_dir, host) do
    harness_auth_inventory_check(inventories, %{}, harness, base_dir, host)
  end

  defp harness_auth_check(
         {:ok, inventories, degraded},
         harness,
         _credential_state,
         base_dir,
         host
       ) do
    harness_auth_inventory_check(inventories, degraded, harness, base_dir, host)
  end

  defp harness_auth_check({:error, degraded}, harness, _credential_state, base_dir, host) do
    reason = Map.get(degraded, harness, {:catalog_fetch_aborted, degraded})

    auth_check(harness, false, reason, 0, base_dir, host)
  end

  defp harness_auth_inventory_check(inventories, degraded, harness, base_dir, host) do
    entries = Map.get(inventories, harness, [])
    ok = entries != []

    reason = Map.get(degraded, harness, :empty_inventory)

    auth_check(harness, ok, reason, length(entries), base_dir, host)
  end

  defp auth_check(harness, ok, reason, live_refs, base_dir, host) do
    cond do
      ok ->
        check("harness_auth:#{harness}", true, "#{harness} fetched #{live_refs} live refs", "")

      unverifiable_credential?(reason) ->
        unverifiable(
          "harness_auth:#{harness}",
          auth_detail(harness, reason, base_dir, host),
          auth_fix(harness, reason, host)
        )

      true ->
        check(
          "harness_auth:#{harness}",
          false,
          auth_detail(harness, reason, base_dir, host),
          auth_fix(harness, reason, host)
        )
    end
  end

  # `credential_server_unavailable` is NOT a credential fault — it is this task
  # being unable to look. The Credentials server does not run inside a bare mix
  # task, so a healthy org and a never-onboarded one produce the same reason here.
  # Reporting `dead_sign_in` and "Re-onboard the credential" for it is false twice
  # over: it asserts a dead sign-in nobody observed, and it sends the operator to
  # re-onboard a credential that may be perfectly live. Say what happened instead.
  # Matched on the TERM, not on its inspect text. Both producers emit
  # `{:needs_onboarding, :credential_server_unavailable}` (gateway.ex,
  # model_catalog.ex) and the catalog wraps it as `{:unavailable, reason}`, so the
  # wrapper is peeled rather than pattern-matched at every depth. This decides an
  # EXIT CODE now, so a renamed atom must break the match loudly instead of
  # sliding past a substring test.
  defp unverifiable_credential?({:unavailable, reason}), do: unverifiable_credential?(reason)
  defp unverifiable_credential?({:needs_onboarding, reason}), do: unverifiable_credential?(reason)
  defp unverifiable_credential?(:credential_server_unavailable), do: true
  defp unverifiable_credential?(_reason), do: false

  defp auth_detail(harness, reason, base_dir, host) do
    cond do
      missing_credential?(reason) ->
        module = Tightbeam.Harness.parse!(harness)

        missing_credential_message(module.credential_provider(), harness, host, base_dir)

      unverifiable_credential?(reason) ->
        "not verified here: the credential server does not run inside a bare mix " <>
          "task, so #{harness} credential state is UNKNOWN from this command"

      true ->
        "dead_sign_in: harness=#{harness} reason=#{inspect(reason)}"
    end
  end

  defp auth_fix(harness, reason, host) do
    cond do
      missing_credential?(reason) ->
        onboard_command(Tightbeam.Harness.parse!(harness).credential_provider(), host)

      unverifiable_credential?(reason) ->
        "Not a credential verdict — do not re-onboard on the strength of this row. " <>
          "Verify for real with Tightbeam.ClientE2E.preflight/2 for #{harness} " <>
          "against this base_dir, or read the running gateway's catalog."

      true ->
        "Re-onboard the #{harness} harness credential."
    end
  end

  defp missing_credential?({:unavailable, reason}), do: missing_credential?(reason)
  defp missing_credential?({:needs_onboarding, reason}), do: missing_credential?(reason)
  defp missing_credential?(:missing), do: true
  defp missing_credential?(_reason), do: false

  defp missing_credential_message(provider, harness, host, base_dir) do
    "Tightbeam has no credential for #{provider} on #{host}. It does not use or import " <>
      "your normal #{harness} CLI login; Tightbeam keeps its own credential under " <>
      "#{Path.join(base_dir, "auth")}. Run on #{host}: #{onboard_command(provider, host)}"
  end

  defp onboard_command(provider, _host),
    do: "tightbeam onboard #{provider} --as-user <userId>"

  defp github_check(nil, _github_probe), do: nil

  defp github_check(remote_url, github_probe) do
    case github_hostname(remote_url) do
      nil ->
        nil

      hostname ->
        case github_probe.(hostname, remote_url) do
          {:ok, %{account: account, git_protocol: protocol}} ->
            detail =
              "GitHub #{hostname} is live for #{account || "active account"}" <>
                if(protocol, do: " via #{protocol}", else: "")

            check("github_auth:#{hostname}", true, detail, "")

          {:error, state, detail} ->
            check(
              "github_auth:#{hostname}",
              false,
              "#{state}: #{scrub_github_detail(detail)}",
              "Run on this host: tightbeam onboard github --hostname #{hostname}. " <>
                "Do not paste a PAT into an agent."
            )
        end
    end
  end

  defp github_hostname(remote_url) when is_binary(remote_url) do
    cond do
      String.starts_with?(remote_url, "https://") or String.starts_with?(remote_url, "http://") ->
        remote_url
        |> URI.parse()
        |> Map.get(:host)
        |> github_host()

      String.starts_with?(remote_url, "ssh://") ->
        remote_url
        |> URI.parse()
        |> Map.get(:host)
        |> github_host()

      String.starts_with?(remote_url, "git@") ->
        case String.split(remote_url, ["@", ":"], parts: 3) do
          ["git", host, _path] -> github_host(host)
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp github_hostname(_remote_url), do: nil

  defp github_host(nil), do: nil

  defp github_host(host) do
    cond do
      host == "github.com" -> host
      String.ends_with?(host, ".github.com") -> host
      true -> nil
    end
  end

  defp github_remote_url do
    case System.cmd("git", ["config", "--get", "remote.origin.url"], stderr_to_stdout: true) do
      {url, 0} ->
        url = String.trim(url)
        if url == "", do: nil, else: url

      _ ->
        nil
    end
  rescue
    ErlangError -> nil
  end

  # The probe must judge the store agents actually read: with a banked
  # file-backed credential present, gh and git run with GH_CONFIG_DIR pointing
  # at it, so doctor's "live" cannot be satisfied by a login-keychain entry
  # that daemon-descended project environments cannot read.
  defp github_probe(base_dir, hostname, remote_url) do
    env = github_probe_env(base_dir)

    with {:gh, path} when is_binary(path) <- {:gh, System.find_executable("gh")},
         {:auth, {_out, 0}} <-
           {:auth,
            System.cmd("gh", ["auth", "status", "--active", "--hostname", hostname],
              stderr_to_stdout: true,
              env: env
            )},
         {:api, {account, 0}} <-
           {:api,
            System.cmd("gh", ["api", "--hostname", hostname, "user", "--jq", ".login"], env: env)},
         {:git, {_out, 0}} <-
           {:git,
            System.cmd("git", ["ls-remote", remote_url, "HEAD"],
              stderr_to_stdout: true,
              env: env
            )} do
      {:ok, %{account: String.trim(account), git_protocol: github_git_protocol(hostname, env)}}
    else
      {:gh, nil} ->
        {:error, :missing_cli, "gh is missing from PATH"}

      {:auth, {detail, _status}} ->
        {:error, :needs_onboarding, scrub_github_detail(detail)}

      {:api, {detail, _status}} ->
        {:error, classify_github_api_failure(detail), scrub_github_detail(detail)}

      {:git, {detail, _status}} ->
        {:error, :git_unready, scrub_github_detail(detail)}
    end
  rescue
    ErlangError ->
      {:error, :unknown, "GitHub readiness probe could not run"}
  end

  # Unconditional: an absent banked dir must probe as needs_onboarding, never
  # as whatever the operator shell's ambient gh config can reach.
  defp github_probe_env(base_dir) do
    [{"GH_CONFIG_DIR", Placement.github_config_dir(base_dir)}]
  end

  defp github_git_protocol(hostname, env) do
    _ = hostname

    case System.cmd("gh", ["config", "get", "git_protocol"], env: env) do
      {protocol, 0} ->
        protocol = String.trim(protocol)
        if protocol == "", do: nil, else: protocol

      _ ->
        nil
    end
  rescue
    ErlangError -> nil
  end

  defp classify_github_api_failure(detail) do
    down = String.downcase(to_string(detail))

    cond do
      String.contains?(down, "scope") or String.contains?(down, "forbidden") or
          String.contains?(down, "403") ->
        :insufficient_scope

      String.contains?(down, "auth") or String.contains?(down, "401") ->
        :needs_onboarding

      true ->
        :unknown
    end
  end

  defp scrub_github_detail(detail) do
    detail
    |> to_string()
    |> String.replace(~r/github_pat_[A-Za-z0-9_]+/, "[redacted]")
    |> String.replace(~r/gh[opusr]_[A-Za-z0-9_]+/, "[redacted]")
    |> String.replace(~r{https://[^/\s:]+:[^@\s]+@}, "https://[redacted]@")
    |> String.trim()
  end

  defp local_credential_state(base_dir, provider) do
    host = Placement.local_host_name()
    host_config = %{ssh: nil, base_dir: base_dir, cli_bin: nil}
    target = %{base_dir: base_dir, host_name: host, host_config: host_config}

    present? =
      Tightbeam.Credentials.kind_at(base_dir, provider) != :none and
        Tightbeam.Harness.all()
        |> Enum.filter(&(&1.credential_provider() == provider))
        |> Enum.any?(fn module ->
          home = Tightbeam.Homes.home_path(base_dir, host, module.id())
          module.credential_ready?(target, home)
        end)

    if present?, do: :present, else: :missing
  end

  defp harness_binary_check({:ok, %{version: version}}, harness) do
    check("harness_binary:#{harness}", true, version, "")
  end

  defp harness_binary_check({:error, reason}, harness) do
    check(
      "harness_binary:#{harness}",
      false,
      inspect(reason),
      "Install the #{harness} CLI and ensure it is on PATH."
    )
  end

  defp identity_check(base_dir) do
    identity_dir = Path.join(base_dir, "identity")

    populated? =
      File.dir?(base_dir) and File.dir?(identity_dir) and
        File.dir?(Path.join(identity_dir, ".git")) and populated_identity?(identity_dir)

    detail =
      if populated?,
        do: "#{identity_dir} is a populated identity repo",
        else: "#{base_dir} or its populated identity repo is missing"

    check("base_dir_identity", populated?, detail, "Run mix tightbeam.init.")
  end

  defp advertised_url_check(url) when is_binary(url) do
    ok = String.trim(url) != ""
    detail = if ok, do: url, else: "advertised URL is empty"
    check("advertised_url", ok, detail, "Set TIGHTBEAM_ADVERTISED_URL.")
  end

  defp advertised_url_check(_missing) do
    check(
      "advertised_url",
      false,
      "advertised URL is not set",
      "Set TIGHTBEAM_ADVERTISED_URL."
    )
  end

  # RULED: doctor never creates org state. The registry lives in the org DB now
  # (host-registry-v1), so it is opened READ-ONLY, and only when the file already
  # exists — an org that has not booted yet has no DB, which is a fact for the
  # table, not a failure of anything this task checks.
  @doc false
  def org_hosts(base_dir) do
    db_path = Path.join(base_dir, "state.db")

    if File.exists?(db_path) do
      {:ok, conn} = Exqlite.Sqlite3.open(db_path, mode: :readonly)

      try do
        {:ok, stmt} =
          Exqlite.Sqlite3.prepare(conn, "SELECT name, ssh, baseDir, cliBin FROM hosts")

        {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
        :ok = Exqlite.Sqlite3.release(conn, stmt)

        rows
        |> Map.new(fn [name, ssh, host_base, cli_bin] ->
          {name, %{ssh: ssh, base_dir: host_base, cli_bin: cli_bin}}
        end)
        |> Map.put(Placement.local_host_name(), %{ssh: nil, base_dir: base_dir, cli_bin: nil})
      after
        Exqlite.Sqlite3.close(conn)
      end
    else
      :absent
    end
  end

  defp hosts_check(:absent, _local_host_name) do
    unverifiable(
      "hosts_registered",
      "org database absent — there is no host registry to read yet",
      "Not a registration verdict — the org DB is created when the gateway boots."
    )
  end

  defp hosts_check(hosts, local_host_name) do
    ok = Map.has_key?(hosts, local_host_name)

    detail =
      if ok,
        do: "local host #{local_host_name} resolves",
        else: "local host #{local_host_name} is not registered"

    check("hosts_registered", ok, detail, "Register a host.")
  end

  # The default selection reaches this task as fields — three env vars, or the
  # configured struct, or the built-in default. Nothing here parses a ref.
  defp default_model_setting do
    case System.get_env("TIGHTBEAM_DEFAULT_MODEL") do
      family when is_binary(family) ->
        Model.new(family,
          effort: System.get_env("TIGHTBEAM_DEFAULT_EFFORT"),
          context: System.get_env("TIGHTBEAM_DEFAULT_CONTEXT")
        )

      nil ->
        Application.get_env(:tightbeam, :default_model) || @default_model
    end
  end

  defp populated_identity?(identity_dir) do
    case File.ls(identity_dir) do
      {:ok, entries} ->
        File.regular?(Path.join([identity_dir, ".git", "HEAD"])) and
          Enum.any?(entries, &(&1 != ".git"))

      {:error, _reason} ->
        false
    end
  end

  defp check(name, ok, detail, fix) do
    level = if(ok, do: :pass, else: :fail)

    %{
      name: name,
      ok: ok,
      unverifiable: false,
      level: level,
      detail: detail,
      fix: if(ok, do: "", else: fix)
    }
  end

  # A check that could not be PERFORMED is not a check that FAILED. It stays in
  # the table — the operator must still see the gap — but it cannot decide the
  # exit status. Before this, `mix tightbeam.doctor` exited non-zero against a
  # fully healthy org, so any deploy script gating on it was broken by a limit of
  # the diagnostic rather than by anything wrong with the installation.
  defp unverifiable(name, detail, fix) do
    %{name: name, ok: false, unverifiable: true, level: :info, detail: detail, fix: fix}
  end

  defp catalog_error(degraded) do
    degraded
    |> Enum.sort()
    |> Enum.map_join(", ", fn {harness, reason} -> "#{harness}=#{inspect(reason)}" end)
  end

  defp column_widths(rows) do
    rows
    |> Enum.zip()
    |> Enum.map(fn column ->
      column |> Tuple.to_list() |> Enum.map(&String.length/1) |> Enum.max()
    end)
  end

  defp format_row(values, widths) do
    values
    |> Enum.zip(widths)
    |> Enum.map_join(" | ", fn {value, width} -> String.pad_trailing(value, width) end)
  end
end
