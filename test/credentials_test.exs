defmodule Tightbeam.CredentialsTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Credentials

  setup do
    base = Path.join(System.tmp_dir!(), "tb-credentials-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  test "onboarding is serialized gate stop write mark start resume and writes 0600 once", ctx do
    owner = self()

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        onboarders: %{
          openai: fn _state ->
            send(owner, :obtain)
            {:ok, %{bytes: ~S({"token":"new"}), expires_at: nil}}
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
        start: fn _ ->
          assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) ==
                   ~S({"token":"new"})

          send(owner, :start)
          :ok
        end,
        resume: fn _ ->
          send(owner, :resume)
          :ok
        end
      )

    assert :ok = Credentials.onboard(:openai, server)
    assert_receive :gate
    assert_receive :stop
    assert_receive :obtain
    assert_receive :start
    assert_receive :resume

    store = Path.join([ctx.base, "auth", "codex", "auth.json"])
    home = Path.join([ctx.base, "homes", "eezo", "codex", "auth.json"])
    metadata = Path.join([ctx.base, "auth", "codex", ".tightbeam", "credential.json"])
    assert File.stat!(store).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(metadata).mode |> Bitwise.band(0o777) == 0o600
    assert File.lstat!(home).type == :symlink
    assert Credentials.status(:openai, server) == :onboarded
  end

  test "failed onboarding stays stopped and never starts the revoked runtime", ctx do
    owner = self()

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        onboarders: %{openai: fn _ -> {:error, :human_unavailable} end},
        gate: fn _ ->
          send(owner, :gate)
          :ok
        end,
        stop: fn _ ->
          send(owner, :stop)
          :ok
        end,
        start: fn _ ->
          send(owner, :forbidden_start)
          :ok
        end,
        resume: fn _ ->
          send(owner, :forbidden_resume)
          :ok
        end
      )

    assert {:error, :human_unavailable} = Credentials.onboard(:openai, server)
    assert_receive :gate
    assert_receive :stop
    refute_receive :forbidden_start
    refute_receive :forbidden_resume
    assert Credentials.status(:openai, server) == {:needs_onboarding, :missing}
  end

  test "Codex credential is never written while stop cannot confirm runtime exit", ctx do
    store = Path.join([ctx.base, "auth", "codex", "auth.json"])
    File.mkdir_p!(Path.dirname(store))
    File.write!(store, "runtime-owned")

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        onboarders: %{openai: fn _ -> flunk("onboarder ran while runtime was live") end},
        stop: fn :openai -> {:error, :runtime_live} end
      )

    assert {:error, :runtime_live} = Credentials.onboard(:openai, server)
    assert File.read!(store) == "runtime-owned"
  end

  test "expiry is compared only at read seams and schedules no timer", ctx do
    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        now: fn -> 100 end,
        onboarders: %{
          anthropic: fn _ ->
            {:ok, %{bytes: "setup-token", expires_at: 101, subscription_status: "supported"}}
          end
        }
      )

    assert :ok = Credentials.onboard(:anthropic, server)
    assert Credentials.status(:anthropic, server) == :onboarded
    assert {:messages, []} = Process.info(server, :messages)

    :sys.replace_state(server, fn state -> %{state | now: fn -> 101 end} end)
    assert Credentials.status(:anthropic, server) == {:needs_onboarding, :expired}
    assert {:messages, []} = Process.info(server, :messages)
  end

  test "only pinned fixtures are terminal", _ctx do
    terminal = fixture("codex-account-updated-logged-out-0.145.0.json")
    logged_in = fixture("codex-account-updated-chatgpt-0.145.0.json")
    claude = fixture("claude-persisted-invalid-token.json")

    assert Credentials.terminal_evidence?(:openai, terminal)
    assert Credentials.terminal_evidence?(:anthropic, claude)
    refute Credentials.terminal_evidence?(:openai, logged_in)

    for name <- [
          "transient-401.json",
          "unknown-account-event.json",
          "reauthentication-required.json",
          "refresh-reason-unauthorized.json"
        ] do
      refute Credentials.terminal_evidence?(:openai, fixture(name))
    end
  end

  test "terminal mark parks without restart and replacement onboarding resumes on new bytes",
       ctx do
    owner = self()

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        onboarders: %{
          openai: fn _ -> {:ok, %{bytes: "replacement", expires_at: nil}} end
        },
        gate: fn _ ->
          send(owner, :gate)
          :ok
        end,
        park: fn _ ->
          send(owner, :park)
          :ok
        end,
        stop: fn _ ->
          send(owner, :stop)
          :ok
        end,
        start: fn _ ->
          send(owner, {:start, File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"]))})
          :ok
        end,
        resume: fn _ ->
          send(owner, :resume)
          :ok
        end
      )

    evidence = fixture("codex-account-updated-logged-out-0.145.0.json")
    assert :ok = Credentials.mark_terminal(:openai, evidence, server)
    assert_receive :gate
    assert_receive :park
    refute_receive {:start, _}
    refute_receive :resume
    assert Credentials.status(:openai, server) == {:needs_onboarding, :revoked}

    assert :ok = Credentials.onboard(:openai, server)
    assert_receive :gate
    assert_receive :stop
    assert_receive {:start, "replacement"}
    assert_receive :resume
    assert Credentials.status(:openai, server) == :onboarded
  end

  test "Claude no-subscription is a stable unsupported status", ctx do
    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        onboarders: %{anthropic: fn _ -> {:error, {:unsupported, :no_subscription}} end}
      )

    assert {:error, {:unsupported, :no_subscription}} =
             Credentials.onboard(:anthropic, server)

    assert Credentials.status(:anthropic, server) ==
             {:needs_onboarding, {:unsupported, :no_subscription}}
  end

  test "interactive CLI phase keeps credential bytes off control messages", ctx do
    owner = self()

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        gate: fn _ ->
          send(owner, :gate)
          :ok
        end,
        stop: fn _ ->
          send(owner, :stop)
          :ok
        end,
        start: fn _ ->
          send(owner, :start)
          :ok
        end,
        resume: fn _ ->
          send(owner, :resume)
          :ok
        end
      )

    assert {:ok, staging} = Credentials.begin_onboard(:openai, server)
    assert_receive :gate
    assert_receive :stop
    assert {:messages, []} = Process.info(server, :messages)
    File.write!(Path.join(staging, "auth.json"), "device-code-result")

    assert :ok = Credentials.finish_onboard(:openai, server)
    assert_receive :start
    assert_receive :resume
    refute File.exists?(staging)

    assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) ==
             "device-code-result"
  end

  test "satellite onboarding installs entirely on that machine without credential transport",
       ctx do
    owner = self()

    sh = fn command ->
      send(owner, {:remote_credential_command, command})

      remote_command =
        command
        |> Enum.drop(6)
        |> Enum.join(" ")

      System.cmd("sh", ["-c", remote_command], stderr_to_stdout: true)
    end

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "worker",
        ssh: "worker",
        sh: sh
      )

    assert {:ok, staging} = Credentials.begin_onboard(:openai, server)
    assert staging =~ "/staging/credential-onboarding/openai-"
    assert Credentials.status(:openai, server) == {:needs_onboarding, :in_progress}

    File.write!(Path.join(staging, "auth.json"), "satellite-only-secret")
    assert :ok = Credentials.finish_onboard(:openai, server)
    assert Credentials.status(:openai, server) == :onboarded

    store = Path.join([ctx.base, "auth", "codex", "auth.json"])
    home = Path.join([ctx.base, "homes", "worker", "codex", "auth.json"])
    assert File.read!(store) == "satellite-only-secret"
    assert File.lstat!(home).type == :symlink

    commands = collect_remote_credential_commands([])
    refute Enum.any?(commands, &(Enum.join(&1, " ") =~ "satellite-only-secret"))
  end

  test "interactive Claude no-subscription cancellation persists unsupported health", ctx do
    {:ok, server} =
      Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

    assert {:ok, staging} = Credentials.begin_onboard(:anthropic, server)

    assert :ok =
             Credentials.cancel_onboard(
               :anthropic,
               :unsupported_no_subscription,
               server
             )

    refute File.exists?(staging)

    assert Credentials.status(:anthropic, server) ==
             {:needs_onboarding, {:unsupported, :no_subscription}}
  end

  test "machine contexts never share credential bytes", ctx do
    other = ctx.base <> "-other"
    on_exit(fn -> File.rm_rf!(other) end)

    {:ok, one} = server(ctx.base, "one", "machine-one")
    {:ok, two} = server(other, "two", "machine-two")
    assert :ok = Credentials.onboard(:openai, one)
    assert :ok = Credentials.onboard(:openai, two)
    assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) == "machine-one"
    assert File.read!(Path.join([other, "auth", "codex", "auth.json"])) == "machine-two"
  end

  defp server(base, name, bytes) do
    Credentials.start_link(
      name: nil,
      base_dir: base,
      machine: name,
      onboarders: %{openai: fn _ -> {:ok, %{bytes: bytes, expires_at: nil}} end}
    )
  end

  defp fixture(name) do
    "test/fixtures/credentials"
    |> Path.join(name)
    |> File.read!()
    |> JSON.decode!()
  end

  defp collect_remote_credential_commands(acc) do
    receive do
      {:remote_credential_command, command} ->
        collect_remote_credential_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
