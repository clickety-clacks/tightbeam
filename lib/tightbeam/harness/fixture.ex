defmodule Tightbeam.Harness.Fixture do
  @moduledoc false
  @behaviour Tightbeam.Harness

  alias Tightbeam.Harness.Support

  @adapter_version "1.0.0"
  @adapter_package "fixture-acp"
  @adapter_bundle "fixture.js"
  @adapter_replacements [{"fixture-anchor", "fixture-patched"}]

  @impl true
  def id, do: :fixture

  @impl true
  def wire_name, do: "fixture"

  @impl true
  def credential_provider, do: :fixture_provider

  @impl true
  def credential_env_vars, do: []

  @impl true
  def default_model, do: Tightbeam.Model.new("fixture-model", effort: "medium")

  @impl true
  def install_package, do: "@tightbeam/fixture-acp"

  @impl true
  def cli_binary, do: "fixture"

  @doc false
  def adapter_version, do: @adapter_version

  @impl true
  def wire_projection do
    JSON.encode!(%{
      "id" => "fixture",
      "wire_name" => wire_name(),
      "install_package" => install_package(),
      "cli_binary" => cli_binary(),
      "process_markers" => ["fixture-acp"]
    })
  end

  @impl true
  def prepare_launch(target, home, opts) do
    binary = adapter_binary(target)

    if Support.local?(target) do
      [cmd: [binary], env: [{"FIXTURE_HOME", home} | Keyword.fetch!(opts, :common_env)]]
    else
      remote_env = ["FIXTURE_HOME=#{home}" | Keyword.fetch!(opts, :remote_env)]

      [
        cmd:
          ["ssh" | Support.ssh_opts()] ++
            [target.host_config.ssh, "exec", "env" | remote_env] ++ [binary],
        env: [{"TIGHTBEAM_LINEAGE", Keyword.fetch!(opts, :lineage)}]
      ]
    end
  end

  @impl true
  def ensure_adapter(target) do
    target =
      target
      |> Map.put_new(:patch_adapter, &patch_local/1)
      |> Map.put_new(:remote_patch, fn _path, detail ->
        {:ok, detail <> "; fixture adapter patched"}
      end)

    Tightbeam.Spinup.ensure_adapter(target, __MODULE__, adapter_binary(target))
  end

  @impl true
  def session_config(_session, guidance) do
    %{
      guidance: guidance,
      meta: %{instructions: guidance},
      permission_mode: "full",
      effort_config: "effort",
      resident_model_switch: :in_place,
      model_option_aliases: %{},
      canonical_model_prefixes: ["fixture-"]
    }
  end

  @impl true
  def owned_home_entries,
    do: Support.owned_home_entries("fixture.json", "fixture.rails")

  @impl true
  def reconcile_home(target, home, desired) do
    # Mirror the claude harness: pin the desired model into the rails artifact so
    # the projected home tracks the session's selection. Binary rails pass
    # through opaque; a map takes the pin when a model is present. This keeps the
    # fixture a faithful double for the provisioning seam that pins per session.
    rails =
      case {desired.rails, Map.get(desired, :default_model)} do
        {bytes, _model} when is_binary(bytes) ->
          bytes

        {map_or_nil, nil} ->
          map_or_nil && JSON.encode!(map_or_nil)

        {map_or_nil, model} ->
          JSON.encode!(Map.put(map_or_nil || %{}, "model", packed_model(model)))
      end

    Tightbeam.Homes.reconcile(target, home, %{desired | rails: rails},
      credential_names: ["fixture.json"],
      rails_filename: "fixture.rails"
    )
  end

  defp packed_model(%Tightbeam.Model{family: family, context: nil}), do: family

  defp packed_model(%Tightbeam.Model{family: family, context: context}),
    do: "#{family}[#{context}]"

  @impl true
  def materialize_skills(target, cwd, snapshot) do
    Tightbeam.Identity.materialize_for_harness!(
      target,
      snapshot,
      cwd,
      Path.join([".fixture", "skills"])
    )
  end

  @impl true
  def credential_ready?(target, _home) do
    store =
      Tightbeam.Credentials.store_dir(
        target.host_config.base_dir,
        credential_provider()
      )

    Tightbeam.Homes.credential_ready?(target, store, ["fixture.json"])
  end

  @impl true
  def harvest_credential(target, home),
    do: Tightbeam.Homes.harvest_credential(target, home, "fixture.json")

  @impl true
  def credential_live?(_target, _home, _opts),
    do: {:unknown, :no_cheap_authenticated_probe}

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
    fetch = get_in(state, [:options, :fixture_fetch]) || fn -> {:ok, :valid} end

    case fetch.() do
      {:ok, :valid} ->
        {:ok,
         [
           %{
             family: "fixture-model",
             context: nil,
             display_name: "Fixture Model",
             name: "Fixture Model",
             efforts: [],
             max_input_tokens: 1_024,
             capabilities: %{},
             provider: credential_provider()
           }
         ]}

      {:ok, _malformed} ->
        {:error, :malformed_catalog}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def conformance_vectors do
    source = "fixture-anchor"

    valid_entry = %{
      family: "fixture-model",
      context: nil,
      display_name: "Fixture Model",
      name: "Fixture Model",
      efforts: [],
      max_input_tokens: 1_024,
      capabilities: %{},
      provider: credential_provider()
    }

    Support.conformance_vectors(__MODULE__, %{
      wire_name: wire_name(),
      provider: credential_provider(),
      home_scope: wire_name(),
      home_env: "FIXTURE_HOME",
      credential_file: "fixture.json",
      credential_live: :unsupported,
      rails_file: "fixture.rails",
      rails: %{"fixture" => true},
      skills_path: Path.join([".fixture", "skills"]),
      # Kind-invariant by construction: the fixture harness has no vendor and no
      # credential to carry, so both kinds render the same plan. Stated rather
      # than exempted, so the contract stays uniform across the registry.
      local_extra_env: %{subscription: [], api_key: []},
      rails_env: nil,
      remote_prefix: fn _base, home, _kind -> ["FIXTURE_HOME=#{home}"] end,
      remote_rails_env: nil,
      railed_probe: false,
      adapter_bin: "fixture-acp",
      adapter_package: @adapter_package,
      adapter_bundle: @adapter_bundle,
      adapter_version: @adapter_version,
      source: source,
      patched: patch_adapter_source(source),
      remote_patch_detail: "; fixture adapter patched",
      session_meta: %{instructions: "vector guidance"},
      cli_name: "fixture",
      cli_version: "fixture vector 1.0",
      probe_path: :discovered,
      auth_events: [
        %{
          case: "positive",
          envelope: %{"authMode" => nil, "planType" => nil},
          expected: :unknown,
          divergence: "DIV-AUTH-FIXTURE-UNSUPPORTED"
        },
        %{case: "negative", envelope: %{"unrelated" => true}, expected: :unknown}
      ],
      subagent_events: [
        %{
          case: "positive_start",
          envelope: %{"fixture" => "start"},
          expected: :skip,
          divergence: "DIV-SUBAGENT-FIXTURE-UNSUPPORTED"
        },
        %{
          case: "positive_stop",
          envelope: %{"fixture" => "stop"},
          expected: :skip,
          divergence: "DIV-SUBAGENT-FIXTURE-UNSUPPORTED"
        },
        %{case: "negative", envelope: %{"unrelated" => true}, expected: :skip}
      ],
      catalog_expected: %{
        "valid" => {:ok, [valid_entry]},
        # No vendor, so no per-kind route: the fixture answers identically.
        "valid_api_key" => {:ok, [valid_entry]},
        "malformed" => {:error, :malformed_catalog},
        "unavailable" => {:error, :fixture_unavailable}
      },
      catalog_state: fn case_name, _base ->
        fetch = fn ->
          case case_name do
            "valid" -> {:ok, :valid}
            "valid_api_key" -> {:ok, :valid}
            "malformed" -> {:ok, :malformed}
            "unavailable" -> {:error, :fixture_unavailable}
          end
        end

        %{credential_kind: :subscription, options: %{fixture_fetch: fetch}}
      end,
      wire_projection: %{
        "id" => "fixture",
        "wire_name" => "fixture",
        "install_package" => "@tightbeam/fixture-acp",
        "cli_binary" => "fixture",
        "process_markers" => ["fixture-acp"]
      }
    })
  end

  @doc false
  def patch_adapter_source(source) do
    Tightbeam.Harness.AdapterPatch.patch(
      source,
      @adapter_replacements,
      wire_name(),
      @adapter_version
    )
  end

  defp adapter_binary(target) do
    Map.get(target, :adapter_binary) ||
      Path.join([
        target.host_config.base_dir,
        "adapters",
        "node_modules",
        ".bin",
        "fixture-acp"
      ])
  end

  defp patch_local(path) do
    Tightbeam.Harness.AdapterPatch.ensure!(
      path,
      @adapter_package,
      @adapter_bundle,
      @adapter_version,
      @adapter_replacements,
      wire_name()
    )
  end
end
