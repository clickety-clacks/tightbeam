ExUnit.start(autorun: false)

defmodule OnboardWireRuntime do
  import ExUnit.Assertions
  alias Tightbeam.{CliCompatibility, Credentials, DB, Devices, Gateway, Rules}
  alias Tightbeam.Wire.Router

  def run do
    for app <- [:bandit, :inets], do: {:ok, _} = Application.ensure_all_started(app)

    Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config, base: base} ->
      Devices.add_user(db, "synthetic-admin", true)
      Devices.add_user(db, "synthetic-member", false)
      handlers = Gateway.handlers(config)
      Rules.load!(Path.join(base, "no-rules"), Map.keys(handlers))

      opts =
        Router.init(db: db, base_dir: base, handlers: handlers, cli_token: "synthetic-wire-token")

      {:ok, listener} =
        Bandit.start_link(plug: {Router, opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false)

      try do
        {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

        # The payload's real Router/Dispatch/Gateway sees JSON strings; the command
        # renderer keeps its existing atom API and required CLI flags.
        for {wire, atom, command} <- [
              {"anthropic", :anthropic, "tightbeam onboard anthropic --as-user <userId>"},
              {"openai", :openai, "tightbeam onboard openai --as-user <userId>"},
              {"cursor", :cursor, "tightbeam onboard cursor --api-key --as-user <userId>"},
              {"opencode-go", :opencode_go,
               "tightbeam onboard opencode-go --api-key --as-user <userId>"},
              {"local-openai", :local_openai,
               "tightbeam onboard local-openai --endpoint <endpoint-url> --name <provider-name> --as-user <userId>"}
            ] do
          assert Credentials.onboard_command(atom) == command

          assert {400, %{"error" => %{"code" => "interactive_required", "message" => message}}} =
                   request(port, wire)

          assert message == "run #{command} from a terminal on this machine"
        end

        unknown = "untrusted-provider-#{System.unique_integer([:positive])}"
        assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

        for provider <- [
              unknown,
              "Anthropic",
              "local_openai",
              "opencode_go",
              "github",
              "",
              nil,
              7
            ] do
          assert {400,
                  %{
                    "error" => %{
                      "code" => "invalid_message",
                      "message" => "unsupported onboarding provider"
                    }
                  }} =
                   request(port, provider)
        end

        assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

        for provider <- ["anthropic", unknown] do
          assert {403, %{"error" => %{"code" => "forbidden", "message" => "admin required"}}} =
                   request(port, provider, "synthetic-member")
        end

        # No ceremony phase was requested: no credential server, auth directory,
        # provider process or turn may be created by merely rendering a hint.
        assert Process.whereis(Credentials) == nil
        refute File.exists?(Path.join(base, "auth"))
        refute File.exists?(Path.join(base, "homes"))
        assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM turns")
      after
        Supervisor.stop(listener)
      end
    end)
  end

  defp request(port, provider, actor \\ "synthetic-admin") do
    body = JSON.encode!(%{verb: "onboard", asUser: actor, params: %{provider: provider}})

    headers = [
      {~c"authorization", ~c"Bearer synthetic-wire-token"},
      {~c"x-tightbeam-cli-version", String.to_charlist(CliCompatibility.required_version())}
    ]

    assert {:ok, {{_, status, _}, _, response}} =
             :httpc.request(
               :post,
               {~c"http://127.0.0.1:#{port}/agent/dispatch", headers, ~c"application/json", body},
               [timeout: 5_000],
               body_format: :binary
             )

    {status, JSON.decode!(response)}
  end
end

OnboardWireRuntime.run()
IO.puts("onboard-wire-supported-unsupported-actor: ok")
