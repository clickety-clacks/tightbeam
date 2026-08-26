defmodule Tightbeam.Harness.Cursor do
  @moduledoc """
  Cursor harness — gateway-local shim ACP adapter only.

  Remote zero-listener assertion is unimplemented (`HarnessProcess.assert_zero_listeners/3`
  refuses ssh rows), so launch planning refuses non-local targets until that probe exists.
  """
  @behaviour Tightbeam.Harness

  require Logger

  alias Tightbeam.Harness.{CursorRails, Support}
  alias Tightbeam.Model

  @adapter_version "2026.08.11-e8db854"
  @launcher_sha256 "eed61c5224668c9236334c4c68936a16aecc37374b592f59e31eb50433817831"
  @bundle_sha256 "6aceb24b7c7ecddb1993946ebb18a7dd4d025842e6efda955eb0c13255b1e5f0"
  @credential_file "cli-config.json"
  @api_key_file "api-key"
  @rails_file "hooks.json"

  # The catalog must not advertise what the adapter will refuse. `cursor-agent
  # --list-models` publishes ~200 refs; ACP `session/new` exposes a closed enum
  # of ~35 decorated wire values whose option `name` is the public ref. Re-probe
  # live against cursor-agent #{@adapter_version} before changing this pin.
  @adapter_selectable_models ~w(auto grok-4.6 composer-2.5 claude-opus-5 claude-opus-4-8
                                gpt-5.6-sol gpt-5.5 claude-fable-5 grok-4.5 gemini-3.7-flash
                                gpt-5.6-terra claude-sonnet-5 claude-sonnet-4-6 gpt-5.3-codex
                                claude-opus-4-7 gpt-5.4 claude-opus-4-6 claude-opus-4-5 gpt-5.2
                                gpt-5.6-luna gemini-3.6-flash gemini-3.1-pro gpt-5.4-mini
                                gpt-5.4-nano claude-haiku-4-5 claude-sonnet-4-5 gpt-5.1
                                gemini-3-flash gemini-3.5-flash claude-sonnet-4 gpt-5-mini
                                gemini-2.5-flash kimi-k3 kimi-k2.7-code glm-5.2)

  @doc """
  Model values this adapter version accepts at `session/set_config_option`.

  Narrower than `cursor-agent --list-models` — see the note above the attribute.
  """
  def adapter_selectable_models, do: @adapter_selectable_models

  @impl true
  def id, do: :cursor

  @impl true
  def wire_name, do: "cursor"

  @impl true
  def credential_provider, do: :cursor

  @impl true
  def credential_env_vars, do: ["CURSOR_API_KEY"]

  @impl true
  def default_model, do: Model.new("auto", effort: "medium")

  @impl true
  def install_package, do: "cursor-agent"

  @impl true
  def adapter_provisioning, do: :shim

  @impl true
  def cli_binary, do: "cursor-agent"

  @doc false
  def adapter_version, do: @adapter_version

  @impl true
  def wire_projection do
    JSON.encode!(%{
      "id" => "cursor",
      "wire_name" => wire_name(),
      "install_package" => install_package(),
      "cli_binary" => cli_binary(),
      "process_markers" => ["cursor-agent acp"]
    })
  end

  @impl true
  def ensure_adapter(target) do
    with {:ok, %{launcher: launcher}} <- verify_installed_cli(target) do
      Tightbeam.Spinup.ensure_shim_adapter(target, adapter_binary(target), launcher, ["acp"])
    end
  end

  @impl true
  def preflight_launch(target, _home, opts) do
    case Keyword.fetch(opts, :credential_kind) do
      {:ok, :api_key} -> load_api_key(target, opts)
      _ -> credential_refusal()
    end
  end

  @impl true
  def prepare_launch(target, home, opts) do
    with {:ok, %{launcher: launcher}} <- verify_installed_cli(target),
         :ok <- verify_adapter_shim(target, launcher) do
      if local?(target) do
        case Keyword.fetch(opts, :cursor_api_key) do
          {:ok, key} ->
            {:ok,
             [
               readiness_rendezvous: true,
               cmd: [adapter_binary(target)],
               env: [
                 {"CURSOR_CONFIG_DIR", home},
                 {"AGENT_CLI_CREDENTIAL_STORE", "memory"},
                 {"CURSOR_API_KEY", key}
                 | Keyword.fetch!(opts, :common_env)
               ]
             ]}

          :error ->
            credential_refusal()
        end
      else
        local_only_refusal()
      end
    end
  end

  @impl true
  def session_config(session, guidance) do
    prefix =
      "Your Tight Beam archetype identity arrives as this Cursor instruction. " <>
        "It is authoritative and outranks product AGENTS.md instructions on conflict."

    guidance =
      if Map.get(session, :identity) == true and not String.starts_with?(guidance, prefix),
        do: prefix <> "\n\n" <> guidance,
        else: guidance

    %{
      guidance: guidance,
      meta: %{instructions: guidance},
      permission_mode: "full",
      # Cursor folds its tuning into the opaque ACP model value. It exposes no
      # separate effort config option, unlike Claude/Codex.
      effort_config: nil,
      resident_model_switch: :in_place,
      # `cursor-agent --list-models` publishes `auto`, while ACP exposes this
      # exact value. Tightbeam keeps the stable public ref and translates only
      # at the adapter boundary, with config readback verification.
      model_option_aliases: %{"auto-smart[optimize_for=balanced]" => "auto"},
      # Cursor's ACP model enum is closed and decorated: every selectable model
      # is one exact wire value (`composer-2.5[fast=true]`) whose option `name`
      # is the public ref (`composer-2.5`). A bare ref is refused (-32602), so
      # the adapter resolves refs to wire values through the live option list
      # rather than a static table the server-side menu would drift past.
      model_wire_by_name: true,
      canonical_model_prefixes: []
    }
  end

  @impl true
  def owned_home_entries,
    do: Support.owned_home_entries(@credential_file, @rails_file)

  @impl true
  def reconcile_home(target, home, desired) do
    rails =
      desired.rails
      |> CursorRails.compile()
      |> JSON.encode!()

    Tightbeam.Homes.reconcile(target, home, %{desired | rails: rails},
      credential_names: [@credential_file],
      rails_filename: @rails_file
    )
  end

  @impl true
  def materialize_skills(target, cwd, snapshot) do
    Tightbeam.Identity.materialize_for_harness!(
      target,
      snapshot,
      cwd,
      Path.join([".cursor", "skills"])
    )
  end

  @impl true
  def credential_ready?(target, _home) do
    store = Tightbeam.Credentials.store_dir(target.host_config.base_dir, credential_provider())
    Tightbeam.Homes.credential_ready?(target, store, [@api_key_file])
  end

  @impl true
  def harvest_credential(_target, _home), do: nil

  @impl true
  def credential_live?(_target, _home, _opts),
    do: {:unknown, :no_captured_cursor_liveness_fixtures}

  @impl true
  def install_cli_projection(_cli_bin), do: :ok

  @impl true
  def probe_cli(target) do
    with {:ok, %{launcher: launcher}} <- verify_installed_cli(target) do
      Support.bounded_probe(launcher, target)
    end
  end

  @doc false
  def verify_installed_cli(target) do
    with launcher when is_binary(launcher) <- resolve_launcher(target),
         {:ok, canonical} <- canonical_path(target, launcher),
         true <- Path.basename(Path.dirname(canonical)) == @adapter_version,
         :ok <- verify_hash(target, canonical, @launcher_sha256),
         :ok <-
           verify_hash(target, Path.join(Path.dirname(canonical), "index.js"), @bundle_sha256) do
      {:ok, %{launcher: canonical, version: @adapter_version}}
    else
      nil -> integrity_refusal(:not_found)
      _ -> integrity_refusal()
    end
  end

  @impl true
  def classify_auth_event(_event), do: :unknown

  @impl true
  def classify_subagent_event(_event), do: :skip

  @impl true
  def fetch_catalog(state) do
    case get_in(state, [:options, :cursor_fetch]) do
      nil -> fetch_installed_catalog(state)
      fetch -> derive_catalog(fetch.())
    end
  end

  defp fetch_installed_catalog(state) do
    options = Map.get(state, :options, %{})
    sh = Map.get(options, :sh, &Support.system_cmd_out/1)
    host_config = Map.get(state, :host_config, %{base_dir: state.base_dir, ssh: nil})

    target =
      options
      |> Map.take([:find_executable, :realpath, :sha256])
      |> Map.merge(%{host_config: host_config, sh: sh})

    with {:ok, %{launcher: launcher}} <- verify_installed_cli(target),
         {output, 0} <- sh.(catalog_argv(host_config, launcher, state.base_dir)),
         {:ok, entries} <- parse_catalog(output),
         entries <- build_selectable_catalog(entries, selectable_models(state)),
         true <- entries != [] do
      {:ok, entries}
    else
      {output, exit} when is_binary(output) and is_integer(exit) ->
        {:error, {:cursor_catalog_probe_failed, exit, String.trim(output)}}

      false ->
        {:error, :empty_inventory}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :malformed_catalog}
    end
  end

  defp catalog_argv(host_config, launcher, base_dir) do
    key_path = api_key_path(base_dir)

    script =
      "test -r #{Support.shell_quote(key_path)} && " <>
        "exec env AGENT_CLI_CREDENTIAL_STORE=memory " <>
        "CURSOR_API_KEY=\"$(cat #{Support.shell_quote(key_path)})\" " <>
        "#{Support.shell_quote(launcher)} --list-models"

    Support.catalog_probe_argv(host_config.ssh, script)
  end

  defp parse_catalog(output) when is_binary(output) do
    entries =
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or &1 == "Available models" or String.starts_with?(&1, "Tip:")))
      |> Enum.map(&parse_catalog_line/1)

    if entries != [] and Enum.all?(entries, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(entries, fn {:ok, entry} -> entry end)}
    else
      {:error, :malformed_catalog}
    end
  end

  defp parse_catalog_line(line) do
    case String.split(line, " - ", parts: 2) do
      [family, display_name] when family != "" and display_name != "" ->
        name = String.replace_suffix(display_name, " (default)", "")

        {:ok,
         %{
           family: family,
           context: nil,
           display_name: name,
           name: name,
           efforts: [],
           max_input_tokens: nil,
           capabilities: %{},
           provider: credential_provider()
         }}

      _ ->
        :error
    end
  end

  defp derive_catalog({:ok, :valid}) do
    {:ok,
     [
       %{
         family: "auto",
         context: nil,
         display_name: "Auto",
         name: "Auto",
         efforts: [],
         max_input_tokens: nil,
         capabilities: %{},
         provider: credential_provider()
       }
     ]}
  end

  defp derive_catalog({:ok, _malformed}), do: {:error, :malformed_catalog}
  defp derive_catalog({:error, reason}), do: {:error, reason}

  @impl true
  def conformance_vectors do
    valid_entry = %{
      family: "auto",
      context: nil,
      display_name: "Auto",
      name: "Auto",
      efforts: [],
      max_input_tokens: nil,
      capabilities: %{},
      provider: credential_provider()
    }

    profile = %{
      wire_name: wire_name(),
      provider: credential_provider(),
      home_scope: wire_name(),
      home_env: "CURSOR_CONFIG_DIR",
      credential_file: @api_key_file,
      credential_live: :unsupported,
      credential_live_unknown_reason: :no_captured_cursor_liveness_fixtures,
      credential_live_divergence: "DIV-CREDENTIAL-LIVE-CURSOR-NO-FIXTURES",
      rails_file: @rails_file,
      rails: %{"hooks" => %{"PreToolUse" => []}},
      skills_path: Path.join([".cursor", "skills"]),
      local_extra_env: %{subscription: [], api_key: [{"CURSOR_API_KEY", "vector-token"}]},
      unsupported_launch_kinds: [:subscription],
      rails_env: nil,
      remote_prefix: fn base, home, kind ->
        case kind do
          :api_key ->
            [
              "CURSOR_API_KEY=$(cat #{base}/auth/cursor/api-key 2>/dev/null)",
              "CURSOR_CONFIG_DIR=#{home}"
            ]

          # Support builds a uniform registry matrix. Cursor retains the subscription
          # vectors as explicit unsupported cases, and this branch builds their oracles.
          :subscription ->
            ["CURSOR_CONFIG_DIR=#{home}"]
        end
      end,
      remote_rails_env: nil,
      railed_probe: false,
      provisioning: :shim,
      adapter_bin: "cursor-agent",
      cli_name: "cursor-agent",
      pinned_cli_path: Path.join([@adapter_version, "cursor-agent"]),
      shim_exec_args: ["acp"],
      session_meta: %{instructions: "vector guidance"},
      cli_version: "cursor-agent vector 1.0",
      probe_path: :discovered,
      auth_events: [
        %{
          case: "positive",
          envelope: %{"authMode" => nil},
          expected: :unknown,
          divergence: "DIV-AUTH-CURSOR-UNSUPPORTED"
        },
        %{case: "negative", envelope: %{"unrelated" => true}, expected: :unknown}
      ],
      subagent_events: [
        %{
          case: "positive_start",
          envelope: %{"cursor" => "start"},
          expected: :skip,
          divergence: "DIV-SUBAGENT-CURSOR-UNSUPPORTED"
        },
        %{
          case: "positive_stop",
          envelope: %{"cursor" => "stop"},
          expected: :skip,
          divergence: "DIV-SUBAGENT-CURSOR-UNSUPPORTED"
        },
        %{case: "negative", envelope: %{"unrelated" => true}, expected: :skip}
      ],
      catalog_expected: %{
        "valid" => {:ok, [valid_entry]},
        "valid_api_key" => {:ok, [valid_entry]},
        "malformed" => {:error, :malformed_catalog},
        "unavailable" => {:error, :cursor_unavailable}
      },
      catalog_state: fn case_name, _base ->
        fetch = fn ->
          case case_name do
            "valid" -> {:ok, :valid}
            "valid_api_key" -> {:ok, :valid}
            "malformed" -> {:ok, :malformed}
            "unavailable" -> {:error, :cursor_unavailable}
          end
        end

        %{credential_kind: :api_key, options: %{cursor_fetch: fetch}}
      end,
      wire_projection: %{
        "id" => "cursor",
        "wire_name" => "cursor",
        "install_package" => "cursor-agent",
        "cli_binary" => "cursor-agent",
        "process_markers" => ["cursor-agent acp"]
      }
    }

    vectors = Support.conformance_vectors(__MODULE__, profile)

    local_only_error =
      {:error,
       %{
         code: "DIV-CURSOR-LOCAL-ONLY",
         message:
           "Cursor shim harness is gateway-local only until remote zero-listener probe exists"
       }}

    launch_vectors =
      Enum.map(vectors["prepare_launch"], fn vector ->
        cond do
          String.ends_with?(vector.case, "_subscription") ->
            %{vector | support: {:unsupported, "DIV-CURSOR-API-KEY-ONLY"}}

          String.starts_with?(vector.case, "remote_") ->
            %{
              vector
              | support: {:unsupported, "DIV-CURSOR-LOCAL-ONLY"},
                expected: local_only_error
            }

          true ->
            vector
        end
      end)

    home_profile = %{profile | credential_file: @credential_file}

    home_vectors = fn callback ->
      Enum.map(vectors[callback], fn vector ->
        put_in(vector, [:input, :profile], home_profile)
      end)
    end

    credential_vectors =
      Enum.map(vectors["credential_ready?/harvest_credential"], fn vector ->
        vector
        |> Map.update!(:expected, &Map.put(&1, :harvested, nil))
      end)

    vectors
    |> Map.put("prepare_launch", launch_vectors)
    |> Map.put("owned_home_entries", home_vectors.("owned_home_entries"))
    |> Map.put("reconcile_home", home_vectors.("reconcile_home"))
    |> Map.put("credential_ready?/harvest_credential", credential_vectors)
  end

  defp api_key_path(base_dir),
    do: Path.join([base_dir, "auth", "cursor", @api_key_file])

  defp load_api_key(target, opts) do
    loader = Keyword.get(opts, :cursor_api_key_loader, &read_api_key(target, &1))

    case loader.(api_key_path(target.host_config.base_dir)) do
      {:ok, key} when is_binary(key) ->
        case String.trim(key) do
          "" -> credential_refusal()
          trimmed -> {:ok, Keyword.put(opts, :cursor_api_key, trimmed)}
        end

      _ ->
        credential_refusal()
    end
  end

  defp read_api_key(target, path) do
    if local?(target) do
      File.read(path)
    else
      script = "test -r #{Support.shell_quote(path)} && cat #{Support.shell_quote(path)}"

      case target.sh.(
             ["ssh" | Support.ssh_opts()] ++
               [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]
           ) do
        {output, 0} -> {:ok, output}
        _ -> {:error, :unreadable}
      end
    end
  end

  defp selectable_models(state),
    do: Map.get(state.options, :cursor_selectable_models, @adapter_selectable_models)

  defp build_selectable_catalog(entries, :all), do: entries

  defp build_selectable_catalog(entries, selectable) do
    {kept, dropped} = Enum.split_with(entries, &(vendor_ref(&1) in selectable))

    if dropped != [] do
      Logger.info(
        "cursor catalog: #{length(dropped)} model(s) from --list-models are not selectable by " <>
          "cursor-agent #{@adapter_version} ACP and were withheld — re-probe " <>
          "@adapter_selectable_models in harness/cursor.ex if this looks wrong"
      )
    end

    kept
  end

  defp vendor_ref(entry),
    do: Model.to_ref(Model.new(entry.family, context: entry.context))

  defp credential_refusal do
    {:error, %{code: "DIV-CURSOR-API-KEY-ONLY", message: "Cursor requires a banked API key"}}
  end

  defp local_only_refusal do
    {:error,
     %{
       code: "DIV-CURSOR-LOCAL-ONLY",
       message:
         "Cursor shim harness is gateway-local only until remote zero-listener probe exists"
     }}
  end

  defp integrity_refusal do
    {:error,
     %{code: "cursor_cli_integrity_mismatch", message: "Cursor CLI integrity check failed"}}
  end

  defp integrity_refusal(reason) do
    {:error,
     %{
       code: "cursor_cli_integrity_mismatch",
       message: "Cursor CLI integrity check failed",
       reason: reason
     }}
  end

  defp canonical_path(target, path) do
    realpath =
      Map.get_lazy(target, :realpath, fn ->
        if local?(target), do: &default_realpath/1, else: &remote_realpath(target, &1)
      end)

    case realpath.(path) do
      {:ok, canonical} when is_binary(canonical) -> {:ok, canonical}
      canonical when is_binary(canonical) -> {:ok, canonical}
      _ -> {:error, :canonical_path}
    end
  end

  defp default_realpath(path) do
    case System.cmd("/bin/realpath", [path], stderr_to_stdout: true) do
      {canonical, 0} -> {:ok, String.trim(canonical)}
      _ -> {:error, :canonical_path}
    end
  end

  defp verify_hash(target, path, expected) do
    hash =
      Map.get_lazy(target, :sha256, fn ->
        if local?(target), do: &local_sha256/1, else: &remote_sha256(target, &1)
      end)

    digest = hash.(path)
    if digest == expected or digest == {:ok, expected}, do: :ok, else: {:error, :hash}
  end

  defp resolve_launcher(%{find_executable: find}), do: find.(cli_binary())

  defp resolve_launcher(target) do
    if local?(target) do
      System.find_executable(cli_binary())
    else
      remote_value(target, "command -v #{Support.shell_quote(cli_binary())}")
    end
  end

  defp remote_realpath(target, path),
    do: remote_value(target, "realpath #{Support.shell_quote(path)}")

  defp remote_sha256(target, path),
    do: remote_value(target, "shasum -a 256 #{Support.shell_quote(path)} | cut -d' ' -f1")

  defp remote_value(target, script) do
    command =
      ["ssh" | Support.ssh_opts()] ++
        [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]

    case target.sh.(command) do
      {output, 0} -> output |> String.trim() |> String.split("\n") |> List.last()
      _ -> nil
    end
  end

  defp local_sha256(path) do
    with {:ok, bytes} <- File.read(path),
         do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  defp verify_adapter_shim(target, launcher) do
    case Map.get(target, :verify_adapter_shim) do
      verify when is_function(verify, 2) -> verify.(adapter_binary(target), launcher)
      nil -> verify_adapter_shim_on_target(target, launcher)
    end
  end

  defp verify_adapter_shim_on_target(target, launcher) do
    shim = adapter_binary(target)
    expected = "#!/bin/sh\nexec \"#{launcher}\" acp \"$@\"\n"

    if local?(target) do
      with {:ok, ^expected} <- File.read(shim),
           {:ok, stat} <- File.stat(shim),
           true <- Bitwise.band(stat.mode, 0o111) != 0 do
        :ok
      else
        _ -> integrity_refusal()
      end
    else
      expected_hash = Base.encode16(:crypto.hash(:sha256, expected), case: :lower)

      script =
        "test -x #{Support.shell_quote(shim)} && " <>
          "test \"$(shasum -a 256 #{Support.shell_quote(shim)} | cut -d' ' -f1)\" = " <>
          Support.shell_quote(expected_hash)

      command =
        ["ssh" | Support.ssh_opts()] ++
          [target.host_config.ssh, "sh", "-c", Support.shell_quote(script)]

      case target.sh.(command) do
        {_output, 0} -> :ok
        _ -> integrity_refusal()
      end
    end
  end

  defp adapter_binary(target) do
    Map.get(target, :adapter_binary) ||
      Path.join([
        target.host_config.base_dir,
        "adapters",
        "node_modules",
        ".bin",
        install_package()
      ])
  end

  defp local?(target), do: get_in(target, [:host_config, :ssh]) == nil
end
