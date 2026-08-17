defmodule Tightbeam.Harness.Cursor do
  @moduledoc false
  @behaviour Tightbeam.Harness

  alias Tightbeam.Harness.{CursorRails, Support}
  alias Tightbeam.Model

  @adapter_version "2026.08.11-e8db854"
  @credential_file "cli-config.json"
  @api_key_file "api-key"
  @rails_file "hooks.json"

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
    Tightbeam.Spinup.ensure_shim_adapter(
      target,
      adapter_binary(target),
      cli_binary(),
      ["acp"]
    )
  end

  @impl true
  def prepare_launch(target, home, opts) do
    binary = adapter_binary(target)
    key_path = api_key_path(target.host_config.base_dir)

    if Support.local?(target) do
      credential_env =
        case Keyword.fetch!(opts, :credential_kind) do
          :api_key ->
            case File.read(key_path) do
              {:ok, key} -> [{"CURSOR_API_KEY", String.trim(key)}]
              _ -> []
            end

          :subscription ->
            []
        end

      [
        cmd: [binary],
        env: [{"CURSOR_CONFIG_DIR", home} | Keyword.fetch!(opts, :common_env) ++ credential_env]
      ]
    else
      remote_env =
        case Keyword.fetch!(opts, :credential_kind) do
          :api_key ->
            [
              "CURSOR_API_KEY=$(cat #{key_path} 2>/dev/null)",
              "CURSOR_CONFIG_DIR=#{home}"
              | Keyword.fetch!(opts, :remote_env)
            ]

          :subscription ->
            ["CURSOR_CONFIG_DIR=#{home}" | Keyword.fetch!(opts, :remote_env)]
        end

      [
        cmd:
          ["ssh" | Support.ssh_opts()] ++
            [target.host_config.ssh, "exec", "env" | remote_env] ++ [binary],
        env: [{"TIGHTBEAM_LINEAGE", Keyword.fetch!(opts, :lineage)}]
      ]
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
      effort_config: "effort",
      resident_model_switch: :in_place,
      model_option_aliases: %{},
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
    find = Map.get(target, :find_executable, &System.find_executable/1)
    Support.bounded_probe(find.(cli_binary()), target)
  end

  @impl true
  def classify_auth_event(_event), do: :unknown

  @impl true
  def classify_subagent_event(_event), do: :skip

  @impl true
  def fetch_catalog(state) do
    case get_in(state, [:options, :cursor_fetch]) do
      nil -> {:error, :cursor_catalog_source_unwired}
      fetch -> derive_catalog(fetch.())
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

    launch_vectors =
      Enum.map(vectors["prepare_launch"], fn vector ->
        if String.ends_with?(vector.case, "_subscription") do
          %{vector | support: {:unsupported, "DIV-CURSOR-API-KEY-ONLY"}}
        else
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
end
