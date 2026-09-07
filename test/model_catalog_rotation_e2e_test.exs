defmodule Tightbeam.ModelCatalogRotationE2ETest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Model, ModelCatalog, Placement}

  @host "manifest-e2e"

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "model-manifest-e2e-#{System.unique_integer([:positive])}")

    db = String.to_atom("model_manifest_e2e_db_#{System.unique_integer([:positive])}")
    start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    :ok = Placement.ensure_schema(db)
    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{base_dir: base_dir, db: db}
  end

  test "E2E: the public route uses the manifest and never calls the retired offered-set fetch",
       ctx do
    owner = self()

    start_supervised!(
      {ModelCatalog,
       name: ModelCatalog,
       base_dir: ctx.base_dir,
       db: ctx.db,
       hosts: fn -> %{@host => %{base_dir: ctx.base_dir, ssh: nil}} end,
       credential_status: fn _provider -> :onboarded end,
       credential_kind: fn _provider -> :subscription end,
       model_manifest: fn ->
         %{
           document:
             :tightbeam
             |> Application.app_dir("priv/model-manifest.json")
             |> File.read!()
             |> JSON.decode!(),
           source: :bundled,
           health: :fresh
         }
       end,
       claude_code_version: "2.1.257",
       claude_fetch: fn _path, _headers ->
         send(owner, :retired_offered_set_fetch)
         {:error, :must_not_fetch}
       end,
       sh: fn _command -> {"unavailable", 1} end}
    )

    await(fn ->
      match?(
        {:ok, %{health: :fresh}},
        ModelCatalog.route(
          @host,
          "claude",
          Model.new("claude-sonnet-5", effort: "medium")
        )
      )
    end)

    refute_receive :retired_offered_set_fetch

    assert {:ok, %{harness: "claude", provider: "anthropic", health: :fresh}} =
             ModelCatalog.route(
               @host,
               "claude",
               Model.new("claude-sonnet-5", effort: "medium")
             )
  end

  defp await(fun, attempts \\ 200)

  defp await(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      await(fun, attempts - 1)
    end
  end

  defp await(_fun, 0), do: flunk("catalog route did not become fresh")
end
