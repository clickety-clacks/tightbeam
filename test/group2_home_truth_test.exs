defmodule Tightbeam.Group2HomeTruthTest do
  use ExUnit.Case, async: true
  alias Tightbeam.{Credentials, Homes}

  test "onboarding and regeneration share one host-local truth and preserve refusal bytes" do
    base = Path.join(System.tmp_dir!(), "group2-home-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    owner = self()
    bytes = ~S({"token":"synthetic-only"})
    {:ok, input} = Agent.start_link(fn -> bytes end)
    home = Homes.home_path(base, "fixture-host", :codex)
    credential = Credentials.credential_path(base, "fixture-host", :openai)
    metadata = Path.join([home, ".tightbeam", "credential.json"])

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: base,
        machine: "fixture-host",
        onboarders: %{
          openai: fn _ ->
            send(owner, :obtain)
            {:ok, %{bytes: Agent.get(input, & &1), expires_at: nil}}
          end
        },
        gate: fn _ ->
          send(owner, :gate)
          :ok
        end,
        stop: fn _ ->
          send(owner, :stop)
          :ok
        end,
        start: fn _, _ ->
          assert File.read!(credential) == bytes
          assert File.lstat!(credential).type == :regular
          refute File.exists?(Path.join(base, "auth"))
          send(owner, :start)
          :ok
        end,
        on_credential_present: fn _ ->
          assert JSON.decode!(File.read!(metadata))["onboarded"]
          send(owner, :present)
          :ok
        end,
        resume: fn _ ->
          send(owner, :resume)
          :ok
        end
      )

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
      if Process.alive?(input), do: Agent.stop(input)
    end)

    assert :ok = Credentials.onboard(:openai, server)

    for step <- [:gate, :stop, :obtain, :start, :present, :resume] do
      assert_receive ^step
    end

    assert Credentials.status(:openai, server) == :onboarded
    assert Credentials.kind(:openai, server) == :subscription
    assert Bitwise.band(File.stat!(credential).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(metadata).mode, 0o777) == 0o600
    File.write!(Path.join(home, "history.jsonl"), "synthetic-history")
    before_metadata = File.read!(metadata)
    Homes.project(base, %{machine: "fixture-host", harness: :codex, rails: "new-generic-hooks"})
    assert File.read!(credential) == bytes
    assert File.read!(metadata) == before_metadata
    assert File.read!(Path.join(home, "history.jsonl")) == "synthetic-history"
    assert File.lstat!(credential).type == :regular
    refute File.exists?(Path.join(base, "auth"))
    refute File.exists?(Credentials.credential_path(base, "other-host", :openai))
    Agent.update(input, fn _ -> "" end)
    assert {:error, _} = Credentials.onboard(:openai, server)
    assert_receive :gate
    assert_receive :stop
    assert_receive :obtain
    refute_receive :start
    refute_receive :present
    refute_receive :resume
    assert File.read!(credential) == bytes
    File.write!(metadata, "malformed-json")

    assert {:needs_onboarding, {:credential_store_unreadable, _}} =
             Credentials.status(:openai, server)

    assert File.read!(credential) == bytes
  end
end
