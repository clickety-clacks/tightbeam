defmodule Tightbeam.LocalOpenAiRuntimeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.LocalOpenAi.Providers
  alias Tightbeam.Harness.Support
  alias Tightbeam.PiProvider
  alias Tightbeam.PiProvider.LocalOpenAi

  @models_body ~s({"data":[{"id":"qwen3.5-35b","max_model_len":131072}]})

  describe "parse_model_ids/1" do
    test "accepts strict nonblank data[*].id only" do
      assert LocalOpenAi.parse_model_ids(@models_body) == ["qwen3.5-35b"]
    end

    test "rejects empty ids, alternate shapes, and whitespace ids" do
      assert LocalOpenAi.parse_model_ids(~s({"data":[{"id":""}]})) == []
      assert LocalOpenAi.parse_model_ids(~s({"models":[{"id":"spark"}]})) == []
      assert LocalOpenAi.parse_model_ids(~s({"data":[{"name":"spark"}]})) == []
      assert LocalOpenAi.parse_model_ids(~s({"data":[{"id":"   "}]})) == []
      assert LocalOpenAi.parse_model_ids("not json") == []
    end
  end

  describe "Providers.validate_name/1" do
    test "accepts safe lowercase names" do
      assert Providers.validate_name("spark") == {:ok, "spark"}
      assert Providers.validate_name("spark-qwen") == {:ok, "spark-qwen"}
    end

    test "rejects blank, reserved, and invalid syntax" do
      assert {:error, _} = Providers.validate_name("")
      assert {:error, _} = Providers.validate_name("   ")
      assert {:error, reason} = Providers.validate_name("opencode-go")
      assert reason =~ "reserved"
      assert {:error, _} = Providers.validate_name("Spark")
      assert {:error, _} = Providers.validate_name("1spark")
    end
  end

  describe "Pi models.json materialization" do
    test "a keyless named provider uses Pi's non-secret local sentinel" do
      record = %{
        name: "spark",
        endpoint: "https://spark.example/v1",
        api_key: nil
      }

      {"spark", provider} = LocalOpenAi.pi_models_json_entry(record, @models_body)

      assert provider["apiKey"] == "local"
      assert provider["authHeader"] == false
    end

    test "an API-key provider materializes its banked key without the keyless marker" do
      record = %{
        name: "spark",
        endpoint: "https://spark.example/v1",
        api_key: "fixture-key"
      }

      {"spark", provider} = LocalOpenAi.pi_models_json_entry(record, @models_body)

      assert provider["apiKey"] == "fixture-key"
      refute Map.has_key?(provider, "authHeader")
    end
  end

  test "keyless liveness marks its curl response as a catalog trailer" do
    owner = self()

    transport = fn _target, request ->
      send(owner, {:request, request})
      {:ok, %{status: 200, headers: %{}, body: @models_body}}
    end

    target = %{
      host_config: %{ssh: nil},
      find_executable: fn
        "sh" -> "/bin/sh"
        "curl" -> "/usr/bin/curl"
      end
    }

    assert :live =
             LocalOpenAi.credential_live?(
               target,
               %{name: "spark", endpoint: "https://spark.example/v1", api_key: nil},
               transport: transport
             )

    assert_receive {:request, %{response: :catalog, command: ["/bin/sh", "-c", _script]}}
  end

  test "catalog credential transport decodes the trailing HTTP status" do
    target = %{
      host_config: %{ssh: nil},
      sh: fn ["/bin/sh", "-c", "probe"] -> {@models_body <> "\n200", 0} end
    }

    assert {:ok, %{status: 200, headers: %{}, body: @models_body}} =
             Support.credential_transport(target, %{
               command: ["/bin/sh", "-c", "probe"],
               response: :catalog
             })
  end

  describe "fetch_pi_catalog/1" do
    test "aggregates opencode-go and named locals independently" do
      base =
        Path.join(
          System.tmp_dir!(),
          "tb-local-openai-runtime-#{System.unique_integer([:positive])}"
        )

      providers_dir = Providers.providers_dir(base)
      File.mkdir_p!(providers_dir)

      File.write!(
        Providers.provider_path(base, "spark"),
        JSON.encode!(%{
          "name" => "spark",
          "type" => "local-openai",
          "endpoint" => "https://spark.example/v1"
        })
      )

      on_exit(fn -> File.rm_rf!(base) end)

      state = %{
        base_dir: base,
        credential_status: fn
          :opencode_go, _ -> :onboarded
          :local_openai, _ -> :onboarded
        end,
        options: %{
          find_executable: fn
            "sh" -> "/bin/sh"
            "curl" -> "/usr/bin/curl"
          end,
          sh: fn command ->
            script = Enum.join(command, " ")

            cond do
              String.contains?(script, "pi.dev/api/models/providers/opencode-go") ->
                {~s({"luna":{"id":"luna","name":"Luna","provider":"opencode-go","contextWindow":1000,"maxTokens":100,"thinkingLevelMap":{"medium":"medium"}}}) <>
                   "\n200", 0}

              String.contains?(script, "spark.example/v1/models") ->
                {@models_body <> "\n200", 0}

              String.contains?(script, "dead.example/v1/models") ->
                {~s({"error":"down"}) <> "\n503", 0}

              true ->
                flunk("unexpected catalog probe: #{script}")
            end
          end
        },
        host_config: %{ssh: nil}
      }

      assert {:ok, entries} = PiProvider.fetch_pi_catalog(state)
      families = Enum.map(entries, & &1.family)
      assert "opencode-go/luna" in families
      assert "spark/qwen3.5-35b" in families

      spark = Enum.find(entries, &(&1.family == "spark/qwen3.5-35b"))
      assert spark.max_input_tokens == 131_072
      assert get_in(spark.capabilities, ["tool_use"]) == true
      assert get_in(spark.capabilities, ["developer_role"]) == false
      assert get_in(spark.capabilities, ["reasoning_effort"]) == false
    end

    test "one dead named provider does not poison another catalog" do
      base =
        Path.join(System.tmp_dir!(), "tb-local-openai-dead-#{System.unique_integer([:positive])}")

      providers_dir = Providers.providers_dir(base)
      File.mkdir_p!(providers_dir)

      for {name, endpoint} <- [
            {"spark", "https://spark.example/v1"},
            {"dead", "https://dead.example/v1"}
          ] do
        File.write!(
          Providers.provider_path(base, name),
          JSON.encode!(%{"name" => name, "type" => "local-openai", "endpoint" => endpoint})
        )
      end

      on_exit(fn -> File.rm_rf!(base) end)

      state = %{
        base_dir: base,
        credential_status: fn
          :opencode_go, _ -> {:needs_onboarding, :missing}
          :local_openai, _ -> :onboarded
        end,
        options: %{
          find_executable: fn
            "sh" -> "/bin/sh"
            "curl" -> "/usr/bin/curl"
          end,
          sh: fn command ->
            script = Enum.join(command, " ")

            cond do
              String.contains?(script, "spark.example/v1/models") ->
                {@models_body <> "\n200", 0}

              String.contains?(script, "dead.example/v1/models") ->
                {~s({"error":"down"}) <> "\n503", 0}

              true ->
                flunk("unexpected catalog probe: #{script}")
            end
          end
        },
        host_config: %{ssh: nil}
      }

      assert {:ok, entries} = PiProvider.fetch_pi_catalog(state)
      assert Enum.map(entries, & &1.family) == ["spark/qwen3.5-35b"]
    end
  end
end
