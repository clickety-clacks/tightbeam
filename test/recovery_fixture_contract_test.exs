defmodule Tightbeam.RecoveryFixtureContractTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Model, RecoveryFixture}
  alias Tightbeam.Acp.Adapter

  @tag timeout: 60_000
  test "the arena fixture exchanges the real Adapter session and turn contract" do
    arena =
      Path.join(System.tmp_dir!(), "recovery-contract-#{System.unique_integer([:positive])}")

    File.mkdir_p!(arena)
    File.write!(Path.join(arena, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
    fixture = RecoveryFixture.place_adapter!(arena)
    on_exit(fn -> File.rm_rf!(arena) end)

    # The existing fixture package checker must accept these preplaced bytes.
    # No missing binary is passed to the npm provisioning branch.
    for module <- Tightbeam.Harness.all() do
      assert {:ok, "adapters present"} =
               module.ensure_adapter(%{
                 base_dir: arena,
                 host_name: "testhost",
                 host_config: %{base_dir: arena, ssh: nil}
               })
    end

    for placeholder <- fixture.placeholders do
      assert {"recovery arena: non-fixture adapter invocation forbidden\n", 64} =
               System.cmd(placeholder.binary, [], stderr_to_stdout: true)
    end

    refute File.exists?(Path.join(arena, "auth/claude"))
    refute File.exists?(Path.join(arena, "auth/codex"))

    adapter =
      start_supervised!(%{
        id: :recovery_contract_adapter,
        start:
          {Adapter, :start_link,
           [
             [
               harness: :fixture,
               cmd: [System.find_executable("node"), fixture.bundle],
               env: fixture.env,
               home: arena,
               cwd: arena,
               stderr_path: Path.join(arena, "adapter.stderr")
             ]
           ]},
        restart: :temporary
      })

    model = Model.new("fixture-model", effort: "medium")
    assert {:ok, session_id} = Adapter.new_session(adapter, model, arena, [], "recovery fixture")
    assert {:ok, ^model} = Adapter.current_model(adapter, session_id)

    assert {:ok, %{stop_reason: "end_turn", text: "recovery fixture delivered"}} =
             Adapter.prompt(adapter, session_id, "RECOVERY_CONTRACT_ONLY")

    frames =
      fixture.transcript
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    requests = for %{"direction" => "request", "frame" => frame} <- frames, do: frame
    replies = for %{"direction" => "reply", "frame" => frame} <- frames, do: frame

    assert Enum.any?(
             requests,
             &match?(%{"method" => "initialize", "params" => %{"protocolVersion" => 1}}, &1)
           )

    assert Enum.any?(
             requests,
             &match?(
               %{"method" => "session/new", "params" => %{"cwd" => ^arena, "mcpServers" => []}},
               &1
             )
           )

    assert Enum.any?(
             requests,
             &match?(%{"method" => "session/set_mode", "params" => %{"modeId" => "full"}}, &1)
           )

    assert [
             %{
               "params" => %{
                 "sessionId" => ^session_id,
                 "prompt" => [%{"type" => "text", "text" => "RECOVERY_CONTRACT_ONLY"}]
               }
             }
           ] =
             Enum.filter(requests, &(&1["method"] == "session/prompt"))

    assert Enum.any?(replies, &match?(%{"result" => %{"stopReason" => "end_turn"}}, &1))

    assert Enum.any?(
             replies,
             &match?(
               %{
                 "method" => "session/update",
                 "params" => %{"update" => %{"sessionUpdate" => "agent_message_chunk"}}
               },
               &1
             )
           )

    refute Enum.any?(replies, &Map.has_key?(&1, "error"))
    # Deliberately not a gateway recovery verdict: this proves the ACP fixture only.
  end
end
