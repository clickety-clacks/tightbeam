import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{config: config} ->
  for wake_tick <- [10, 900] do
    children =
      Gateway.children(
        config
        |> Map.put(:wake_tick_ms, wake_tick)
        |> Map.put(:supervision_interval_ms, 4_321)
      )

    {Tightbeam.Wakes, wake_opts} = Enum.find(children, &match?({Tightbeam.Wakes, _}, &1))

    {Tightbeam.Supervision, supervision_opts} =
      Enum.find(children, &match?({Tightbeam.Supervision, _}, &1))

    assert Keyword.fetch!(wake_opts, :tick_ms) == wake_tick
    assert Keyword.fetch!(supervision_opts, :sweep_ms) == 4_321
  end
end)

IO.puts("guarded-gateway-cadence: ok")
