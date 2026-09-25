defmodule Tightbeam.CredentialWarmFixtureTest do
  use ExUnit.Case, async: true

  alias Tightbeam.{Credentials, CredentialWarmFixture}
  alias Tightbeam.Harness.Claude

  setup do
    base = Path.join(System.tmp_dir!(), "tb-warm-isolation-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  test "onboarding uses the injected runner and preserves a failed warm", %{base: base} do
    runner = CredentialWarmFixture.runner(base, "fixture")
    home = Path.join([base, "homes", "fixture", "claude"])
    target = %{host_config: %{ssh: nil}, sh: runner}

    assert {:error, {:warm_failed, 1, "fixture warm refused"}} = Claude.warm_home(target, home)
    assert_receive {:fixture_warm, ^home}
    refute_receive {:fixture_warm, _}

    {:ok, server} =
      Credentials.start_link(name: nil, base_dir: base, machine: "fixture", sh: runner)

    state = :sys.get_state(server)
    assert state.sh == runner
    assert state.sh_out == runner

    assert {:ok, staging, lease} = Credentials.begin_onboard(:anthropic, server)
    File.write!(Path.join(staging, ".credentials.json"), "fixture-api-key")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Credentials.finish_onboard(:anthropic, :api_key, lease, server)
      end)

    assert_receive {:fixture_warm, ^home}
    refute_receive {:fixture_warm, _}
    assert log =~ "fixture warm refused"
    assert Credentials.status(:anthropic, server) == :onboarded

    assert File.read!(Credentials.credential_path(base, "fixture", :anthropic)) ==
             "fixture-api-key\n"
  end

  test "unexpected argv, another home, and SSH cannot fall back to execution", %{base: base} do
    runner = CredentialWarmFixture.runner(base, "fixture")

    for command <- [
          ["claude", "--version"],
          [
            "env",
            "CLAUDE_CONFIG_DIR=/not-the-fixture",
            "claude",
            "-p",
            "ok",
            "--model",
            "sonnet"
          ],
          ["ssh", "fixture", "claude -p ok --model sonnet"],
          ["sh", "-c", "claude -p ok"],
          ["codex", "--version"]
        ] do
      assert_raise ExUnit.AssertionError, fn -> runner.(command) end
    end

    refute_receive {:fixture_warm, _}
  end
end
