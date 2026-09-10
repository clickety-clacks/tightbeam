ExUnit.start(autorun: false)

defmodule GuardCredentialRuntime do
  import ExUnit.Assertions
  alias Tightbeam.{Credentials, Gateway, Model, Org}
  alias Tightbeam.GatewayTurnFixture.CoordinatorStub

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config} ->
      Org.create(db, %{
        session_key: "k1",
        display_name: "Main",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("claude-fable-5")
      })

      config =
        Map.merge(config, %{
          port: 0,
          sh: fn _ -> flunk("unexpected credential shell or warm") end,
          sh_out: fn _ -> flunk("unexpected credential byte probe") end
        })

      children = Gateway.children(config)

      %{start: {Credentials, :start_link, [credential_opts]}} =
        Enum.find(children, &match?(%{id: {Credentials, "testhost"}}, &1))

      prove(credential_opts)
    end)
  end

  defp prove(credential_opts) do
    parent = self()

    start_result = fn
      {:codex, "shared", "testhost"} = key ->
        send(parent, {:runtime_start, key})
        {:error, :codex_failed}

      {:fixture, "shared", "testhost"} = key ->
        send(parent, {:runtime_start, key})
        {:ok, parent, 1}
    end

    {:ok, coordinator} = CoordinatorStub.start_link(start_result)

    opts =
      credential_opts
      |> Keyword.put(:name, nil)
      |> Keyword.put(:stop, fn _provider -> :ok end)
      |> Keyword.put(:resume, fn _provider -> :ok end)
      |> Keyword.put(:onboarders, %{
        openai: fn _state -> {:ok, %{bytes: ~S({"token":"replacement"}), expires_at: nil}} end
      })

    {:ok, server} = Credentials.start_link(opts)

    try do
      assert {:error,
              {:provider_runtime_start_failed,
               %{
                 started: [],
                 failed: [%{harness: "codex", reason: :codex_failed}]
               }}} = Credentials.onboard(:openai, server)

      assert_receive {:runtime_start, {:codex, "shared", "testhost"}}
      refute_receive {:runtime_start, {:fixture, "shared", "testhost"}}
      refute Credentials.status(:openai, server) == :onboarded

      fixture_opts =
        credential_opts
        |> Keyword.put(:name, nil)
        |> Keyword.put(:stop, fn _provider -> :ok end)
        |> Keyword.put(:resume, fn _provider -> :ok end)
        |> Keyword.put(:onboarders, %{
          fixture_provider: fn _state ->
            {:ok, %{bytes: "fixture-provider-credential", expires_at: nil}}
          end
        })

      {:ok, fixture_server} = Credentials.start_link(fixture_opts)

      try do
        assert :ok = Credentials.onboard(:fixture_provider, fixture_server)
        assert_receive {:runtime_start, {:fixture, "shared", "testhost"}}
      after
        GenServer.stop(fixture_server)
      end
    after
      GenServer.stop(server)
      GenServer.stop(coordinator)
    end
  end
end

GuardCredentialRuntime.run()
IO.puts("guarded-gateway-credential-runtime: ok")
