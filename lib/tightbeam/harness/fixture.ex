defmodule Tightbeam.Harness.Fixture do
  @moduledoc false
  @behaviour Tightbeam.Harness

  alias Tightbeam.Harness.Support

  @impl true
  def id, do: :fixture

  @impl true
  def wire_name, do: "fixture"

  @impl true
  def credential_provider, do: :openai

  @impl true
  def install_package, do: "@tightbeam/fixture-acp"

  @impl true
  def wire_projection do
    JSON.encode!(%{
      "id" => "fixture",
      "wire_name" => wire_name(),
      "install_package" => install_package(),
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
      |> Map.put_new(:patch_adapter, fn _path -> :ok end)
      |> Map.put(:remote_patch, fn _path, detail -> {:ok, detail} end)

    Tightbeam.Spinup.ensure_adapter(target, __MODULE__, adapter_binary(target))
  end

  @impl true
  def session_config(_session, guidance) do
    %{
      guidance: guidance,
      meta: %{instructions: guidance},
      permission_mode: "full",
      effort_config: "effort"
    }
  end

  @impl true
  def reconcile_home(target, home, desired) do
    rails = if is_map(desired.rails), do: JSON.encode!(desired.rails), else: desired.rails

    Tightbeam.Homes.reconcile(target, home, %{desired | rails: rails},
      credential_names: ["auth.json"],
      rails_filename: "fixture.rails"
    )
  end

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

    Tightbeam.Homes.credential_ready?(target, store, ["auth.json"])
  end

  @impl true
  def harvest_credential(target, home),
    do: Tightbeam.Homes.harvest_credential(target, home, "auth.json")

  @impl true
  def probe_cli(target) do
    find = Map.get(target, :find_executable, &System.find_executable/1)
    Support.bounded_probe(find.("fixture"), target)
  end

  @impl true
  def containment_additions, do: []

  @impl true
  def classify_auth_event(_event), do: :unknown

  @impl true
  def classify_subagent_event(_event), do: :skip

  @impl true
  def fetch_catalog(_state) do
    {:ok,
     [
       %{
         ref: "fixture-model",
         display_name: "Fixture Model",
         name: "Fixture Model",
         efforts: [],
         max_input_tokens: 1_024,
         capabilities: %{},
         provider: :openai
       }
     ]}
  end

  defp adapter_binary(target) do
    Path.join([
      target.host_config.base_dir,
      "adapters",
      "node_modules",
      ".bin",
      "fixture-acp"
    ])
  end
end
