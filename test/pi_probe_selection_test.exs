defmodule Tightbeam.PiProbeSelectionTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.Pi
  alias Tightbeam.Model
  alias Tightbeam.LocalOpenAi.Providers

  @spark_entry %{
    family: "spark/qwen3.5-35b",
    provider: :local_openai,
    capabilities: %{"tool_use" => true}
  }

  @opencode_entry %{family: "opencode-go/gpt-5.6-luna", provider: :opencode_go}

  @tag :tmp_dir
  test "probe discovery uses a Spark-only installation without OpenCode-Go credentials", %{
    tmp_dir: base
  } do
    File.mkdir_p!(Providers.providers_dir(base))

    File.write!(
      Providers.provider_path(base, "spark"),
      JSON.encode!(%{
        name: "spark",
        type: "local-openai",
        endpoint: "https://spark.example/v1"
      })
    )

    target = %{
      base_dir: base,
      host_name: "testhost",
      host_config: %{ssh: nil, base_dir: base},
      sh: fn argv ->
        command = Enum.join(argv, " ")
        assert command =~ "spark.example/v1/models"
        refute command =~ "opencode"
        {~s({"data":[{"id":"qwen3.5-35b","max_model_len":131072}]}) <> "\n200", 0}
      end
    }

    refute File.exists?(Tightbeam.Credentials.credential_path(base, "testhost", :opencode_go))
    assert Pi.gate_probe_model!(target) == Model.new("spark/qwen3.5-35b")
  end

  test "a Spark-only catalog selects its proven tool-capable model" do
    assert Pi.select_gate_probe_model([@spark_entry]) ==
             Model.new("spark/qwen3.5-35b")
  end

  test "a proven Spark entry wins over a public OpenCode-Go catalog" do
    assert Pi.select_gate_probe_model([@opencode_entry, @spark_entry]) ==
             Model.new("spark/qwen3.5-35b")
  end

  test "the established probe is retained when no proven local model exists" do
    assert Pi.select_gate_probe_model([@opencode_entry, %{family: "lab/mystery"}]) ==
             Model.new("opencode-go/gpt-5.6-luna")
  end

  test "an unproven local model cannot pass the permission probe" do
    assert_raise ArgumentError, fn ->
      Pi.select_gate_probe_model([
        %{family: "lab/mystery", provider: :local_openai, capabilities: %{}},
        %{family: "lab/other", provider: :local_openai, capabilities: %{"tool_use" => false}}
      ])
    end
  end

  @tag :tmp_dir
  test "prepare_launch chooses proven Spark when stale OpenCode auth is also present", %{
    tmp_dir: base
  } do
    File.mkdir_p!(Providers.providers_dir(base))

    File.write!(
      Providers.provider_path(base, "spark"),
      JSON.encode!(%{
        name: "spark",
        type: "local-openai",
        endpoint: "https://spark.example/v1"
      })
    )

    opencode_home = Tightbeam.Homes.home_path(base, "testhost", :pi)
    File.mkdir_p!(opencode_home)
    File.write!(Path.join(opencode_home, "auth.json"), ~s({"opencode-go":{"key":"stale"}}))

    target = %{
      base_dir: base,
      host_name: "testhost",
      host_config: %{ssh: nil, base_dir: base},
      sh: fn argv ->
        command = Enum.join(argv, " ")

        cond do
          String.contains?(command, "pi.dev/api/models/providers/opencode-go") ->
            {~s({"luna":{"id":"gpt-5.6-luna","name":"Luna","provider":"opencode-go","contextWindow":1000,"maxTokens":100,"thinkingLevelMap":{"medium":"medium"}}}) <>
               "\n200", 0}

          String.contains?(command, "spark.example/v1/models") ->
            {~s({"data":[{"id":"qwen3.5-35b","max_model_len":131072}]}) <> "\n200", 0}

          true ->
            flunk("unexpected Pi gate command: #{inspect(argv)}")
        end
      end
    }

    plan =
      Pi.prepare_launch(target, opencode_home,
        common_env: [],
        remote_env: [],
        lineage: "fixture",
        statutes: true,
        ensure_workdir: fn _host_config, _cwd, _guidance, _opts -> :ok end,
        sh_out: nil
      )

    assert plan[:probe_model] == Model.new("spark/qwen3.5-35b")
  end

  test "an empty catalog cannot silently fall back to OpenCode-Go" do
    assert_raise ArgumentError, fn -> Pi.select_gate_probe_model([]) end
  end
end
