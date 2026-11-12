import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{config: config} ->
  for wake_tick <- [10, 900] do
    children =
      Gateway.children(
        config
        |> Map.put(:wake_tick_ms, wake_tick)
      )

    {Tightbeam.Wakes, wake_opts} = Enum.find(children, &match?({Tightbeam.Wakes, _}, &1))

    assert Keyword.fetch!(wake_opts, :tick_ms) == wake_tick
  end
end)

IO.puts("guarded-gateway-cadence: ok")
