ExUnit.start(autorun: false)

defmodule GuardCredentialParkReceiver do
  use GenServer
  def start_link(fun), do: GenServer.start_link(__MODULE__, fun)
  def init(fun), do: {:ok, fun}

  def handle_call({:tightbeam_command, command}, _from, fun) do
    command = Tightbeam.CommandEdge.validate_command!(command)
    {:reply, fun.(command.provider), fun}
  end
end

defmodule GuardCredentialTransition do
  import ExUnit.Assertions
  alias Tightbeam.{ConnRegistry, Credentials, Gateway, Model, Org}
  alias Tightbeam.Firehose.Hub

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

      prove(db, credential_opts)
    end)
  end

  defp prove(db, credential_opts) do
    first =
      Org.create(db, %{
        session_key: "agent:credential-first",
        display_name: "Credential first",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: Model.new("gpt-5.6-sol", effort: "medium")
      })

    second =
      Org.create(db, %{
        session_key: "agent:credential-second",
        display_name: "Credential second",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: Model.new("gpt-5.6-sol", effort: "medium")
      })

    fixture_session =
      Org.create(db, %{
        session_key: "agent:credential-fixture",
        display_name: "Credential fixture",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture-model")
      })

    Org.create(db, %{
      session_key: "agent:credential-nonmatching",
      display_name: "Credential nonmatching",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })

    {:ok, _ref, nil} =
      ConnRegistry.register(Tightbeam.ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "credential-emission-device",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    parent = self()

    park = fn :openai ->
      Org.retire(db, first.session_key, "test:gateway", 1_000)

      Org.create(db, %{
        session_key: "agent:credential-late",
        display_name: "Credential late",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: Model.new("gpt-5.6-sol", effort: "medium")
      })

      send(parent, :parked)
      :ok
    end

    {:ok, park_receiver} = GuardCredentialParkReceiver.start_link(park)

    opts =
      credential_opts
      |> Keyword.put(:name, nil)
      |> Keyword.put(:park_edge, Tightbeam.CommandEdge.request_to(park_receiver))
      |> Keyword.put(:stop, fn _provider -> :ok end)
      |> Keyword.put(:start, fn _provider, _kind -> :ok end)
      |> Keyword.put(:resume, fn _provider -> :ok end)
      |> Keyword.put(:onboarders, %{
        openai: fn _state -> {:ok, %{bytes: ~S({"token":"replacement"}), expires_at: nil}} end
      })

    {:ok, hub} = Hub.start_link(name: Hub)

    :ok =
      Hub.register(hub, self(), %{
        mode: :filtered,
        db: db,
        user_id: "synthetic-observer",
        is_admin: true
      })

    :ok = Hub.subscribe(hub, self(), "credential-messages", %{"classes" => ["message.created"]})
    {:ok, server} = Credentials.start_link(opts)

    try do
      evidence = %{"authMode" => nil, "planType" => nil}

      assert :ok = Credentials.mark_terminal(:openai, evidence, server)
      assert_receive :parked

      terminal_frames = collect_pushes(4, [])
      assert_message_notices(hub, [first.session_key, second.session_key])

      assert Enum.frequencies_by(terminal_frames, & &1["type"]) == %{
               "message" => 2,
               "stream_updated" => 2
             }

      assert MapSet.new(
               for %{
                     "type" => "message",
                     "role" => "user",
                     "sessionKey" => key,
                     "sender" => "process:tightbeam",
                     "content" => content
                   } <- terminal_frames,
                   content =~ "credential" and content =~ "parked pending re-onboarding",
                   do: key
             ) == MapSet.new([first.session_key, second.session_key])

      assert MapSet.new(
               for %{"type" => "stream_updated", "stream" => %{"sessionKey" => key}} <-
                     terminal_frames,
                   do: key
             ) == MapSet.new([first.session_key, second.session_key])

      assert :ok = Credentials.mark_terminal(:openai, evidence, server)
      refute_receive :parked
      refute_receive {:push, _}
      refute_receive {:push_message, _, _, _}
      _barrier = Hub.sequence(hub, self())
      refute_received {:firehose_notice, _}

      assert :ok = Credentials.onboard(:openai, server)
      onboarded_frames = collect_pushes(4, [])
      assert_message_notices(hub, [second.session_key, "agent:credential-late"])

      assert Enum.frequencies_by(onboarded_frames, & &1["type"]) == %{
               "message" => 2,
               "stream_updated" => 2
             }

      assert MapSet.new(
               for %{
                     "type" => "message",
                     "role" => "user",
                     "sessionKey" => key,
                     "sender" => "process:tightbeam",
                     "content" => content
                   } <- onboarded_frames,
                   content =~ "re-onboarded" and content =~ "may resume",
                   do: key
             ) ==
               MapSet.new([
                 second.session_key,
                 "agent:credential-late"
               ])

      assert MapSet.new(
               for %{"type" => "stream_updated", "stream" => %{"sessionKey" => key}} <-
                     onboarded_frames,
                   do: key
             ) ==
               MapSet.new([
                 second.session_key,
                 "agent:credential-late"
               ])

      assert Org.get(db, fixture_session.session_key).provider == "fixture_provider"
    after
      GenServer.stop(server)
      GenServer.stop(hub)
      GenServer.stop(park_receiver)
    end
  end

  defp assert_message_notices(hub, expected_sessions) do
    notices =
      for _ <- expected_sessions do
        assert_receive {:firehose_notice, notice}
        assert notice["class"] == "message.created"
        assert notice["refs"]["messageId"] == notice["payload"]["id"]
        assert notice["refs"]["sessionKey"] == notice["payload"]["sessionKey"]
        assert notice["refs"]["ownerUserId"] == "flynn"
        assert notice["payload"]["sender"] == "process:tightbeam"
        refute JSON.encode!(notice) =~ "replacement"
        Hub.delivered(hub, self())
        notice
      end

    assert Enum.sort(Enum.map(notices, & &1["refs"]["sessionKey"])) ==
             Enum.sort(expected_sessions)

    _barrier = Hub.sequence(hub, self())
    refute_received {:firehose_notice, _}
  end

  defp collect_pushes(0, acc), do: Enum.reverse(acc)

  defp collect_pushes(n, acc) do
    receive do
      {:push, payload} -> collect_pushes(n - 1, [payload | acc])
      {:push_message, _key, _seq, payload} -> collect_pushes(n - 1, [payload | acc])
      {:ensure_lane, _key} -> collect_pushes(n, acc)
    after
      1_000 -> flunk("timed out collecting credential frames")
    end
  end
end

GuardCredentialTransition.run()
IO.puts("guarded-gateway-credential-transition: ok")
