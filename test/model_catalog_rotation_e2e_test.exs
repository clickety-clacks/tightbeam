defmodule Tightbeam.ModelCatalogRotationE2ETest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Credentials, DB, Model, ModelCatalog, Placement}

  @host "rotation-e2e"
  @fixtures Path.join(__DIR__, "fixtures/model_catalog")

  setup do
    previous_host = Application.get_env(:tightbeam, :local_host_name)
    Application.put_env(:tightbeam, :local_host_name, @host)

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "model-catalog-rotation-e2e-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf!(base_dir)

      case previous_host do
        nil -> Application.delete_env(:tightbeam, :local_host_name)
        host -> Application.put_env(:tightbeam, :local_host_name, host)
      end
    end)

    start_supervised!({DB, path: ":memory:", name: DB})
    :ok = Placement.ensure_schema(DB)

    {:ok, _host} =
      Placement.register_host(DB, @host, %{ssh: nil, base_dir: base_dir, cli_bin: nil})

    %{base_dir: base_dir}
  end

  test "E2E: a public catalog route uses only the local harness-home credential", ctx do
    rotated = ~s({"claudeAiOauth":{"accessToken":"fixture-token-ROTATED"}})

    home = Path.join([ctx.base_dir, "homes", @host, "claude", ".credentials.json"])

    metadata =
      Path.join([ctx.base_dir, "homes", @host, "claude", ".tightbeam", "credential.json"])

    File.mkdir_p!(Path.dirname(metadata))

    File.write!(
      metadata,
      JSON.encode!(%{
        provider: "anthropic",
        kind: "subscription",
        onboarded: true,
        terminal: false,
        expires_at: System.system_time(:second) + 3_600
      })
    )

    File.mkdir_p!(Path.dirname(home))
    File.write!(home, rotated)

    start_supervised!({Credentials, base_dir: ctx.base_dir, machine: @host})

    owner = self()
    model_list = fixture_body("claude_models.jsonc")
    model_detail = fixture_body("claude_model_detail.jsonc")

    fetch = fn
      "/v1/models?limit=100", headers ->
        token = bearer(headers)
        send(owner, {:catalog_token, token})

        case token do
          "fixture-token-ROTATED" ->
            {:ok, model_list}

          other ->
            flunk("catalog read unexpected credential #{inspect(other)}")
        end

      "/v1/models/claude-haiku-4-5-20251001", _headers ->
        {:ok, model_detail}
    end

    start_supervised!(
      {ModelCatalog,
       name: ModelCatalog,
       base_dir: ctx.base_dir,
       db: DB,
       claude_fetch: fetch,
       claude_selectable_models: :all}
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

    assert_receive {:catalog_token, "fixture-token-ROTATED"}
    refute_receive {:catalog_token, _}

    assert File.read!(home) == rotated
    refute File.exists?(Path.join([ctx.base_dir, "auth", "claude", ".credentials.json"]))

    assert {:ok, %{harness: "claude", provider: "anthropic", health: :fresh}} =
             ModelCatalog.route(
               @host,
               "claude",
               Model.new("claude-sonnet-5", effort: "medium")
             )
  end

  defp bearer(headers) do
    {~c"authorization", raw} = List.keyfind(headers, ~c"authorization", 0)
    raw |> to_string() |> String.replace_prefix("Bearer ", "")
  end

  defp fixture_body(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&String.starts_with?(&1, "//"))
    |> Enum.join("\n")
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
