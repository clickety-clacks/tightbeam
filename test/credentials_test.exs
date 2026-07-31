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
        start: fn _, _ ->
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
        start: fn _, _ ->
          send(owner, :forbidden_start)
          :ok
        end,
        resume: fn _ ->
          send(owner, :forbidden_resume)
          :ok
        end,
        publish_sessions: fn _captured, transition ->
          send(owner, {:forbidden_publish, transition})
        end
      )

    assert {:error, :human_unavailable} = Credentials.onboard(:openai, server)
    assert_receive :gate
    assert_receive :stop
    refute_receive :forbidden_start
    refute_receive :forbidden_resume
    refute_receive {:forbidden_publish, _}
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

  test "terminal evidence delegates to the harness classifier", _ctx do
    terminal_capture = fixture("codex-account-updated-logged-out-0.145.0.json")
    terminal = terminal_capture["params"]
    logged_in = fixture("codex-account-updated-chatgpt-0.145.0.json")["params"]

    assert Credentials.terminal_evidence?(:openai, terminal)
    refute Credentials.terminal_evidence?(:openai, logged_in)
    refute Credentials.terminal_evidence?(:openai, terminal_capture)
    refute Credentials.terminal_evidence?(:anthropic, terminal)
    refute Credentials.terminal_evidence?(:openai, %{"classification" => "terminal"})

    for {provider, harness, evidence} <- [
          {:openai, Tightbeam.Harness.Codex, terminal},
          {:openai, Tightbeam.Harness.Codex, logged_in},
          {:anthropic, Tightbeam.Harness.Claude, terminal}
        ] do
      assert Credentials.terminal_evidence?(provider, evidence) ==
               (harness.classify_auth_event(evidence) == :terminal)
    end

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
        start: fn _, _ ->
          send(owner, {:start, File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"]))})
          :ok
        end,
        resume: fn _ ->
          send(owner, :resume)
          :ok
        end,
        capture_sessions: fn provider ->
          send(owner, {:capture, provider})
          [:captured_session]
        end,
        publish_sessions: fn captured, transition ->
          send(owner, {:publish, captured, transition})
          :ok
        end
      )

    evidence = fixture("codex-account-updated-logged-out-0.145.0.json")["params"]
    assert :ok = Credentials.mark_terminal(:openai, evidence, server)
    assert_receive :gate
    assert_receive {:capture, :openai}
    assert_receive :park
    assert_receive {:publish, [:captured_session], :terminal}
    refute_receive {:start, _}
    refute_receive :resume
    assert Credentials.status(:openai, server) == {:needs_onboarding, :revoked}

    assert :ok = Credentials.mark_terminal(:openai, evidence, server)
    refute_receive :gate
    refute_receive {:capture, :openai}
    refute_receive :park
    refute_receive {:publish, _, :terminal}

    assert :ok = Credentials.onboard(:openai, server)
    assert_receive :gate
    assert_receive :stop
    assert_receive {:start, "replacement"}
    assert_receive {:capture, :openai}
    assert_receive :resume
    assert_receive {:publish, [:captured_session], :onboarded}
    assert Credentials.status(:openai, server) == :onboarded
  end

  test "terminal capture remains immutable while the park mutates membership", ctx do
    owner = self()
    {:ok, membership} = Agent.start_link(fn -> [:before_one, :before_two] end)

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        capture_sessions: fn :openai -> Agent.get(membership, & &1) end,
        park: fn :openai ->
          Agent.update(membership, fn _ -> [:after] end)
          :ok
        end,
        publish_sessions: fn captured, transition ->
          send(owner, {:immutable_publish, captured, transition})
          :ok
        end
      )

    evidence = fixture("codex-account-updated-logged-out-0.145.0.json")["params"]
    assert :ok = Credentials.mark_terminal(:openai, evidence, server)
    assert_receive {:immutable_publish, [:before_one, :before_two], :terminal}
    assert Agent.get(membership, & &1) == [:after]
  end

  test "raising and exiting publishers do not change terminal or onboarding results", ctx do
    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        onboarders: %{
          openai: fn _state -> {:ok, %{bytes: "replacement", expires_at: nil}} end
        },
        capture_sessions: fn :openai -> [:session] end,
        publish_sessions: fn
          [:session], :terminal -> raise "publisher failed"
          [:session], :onboarded -> exit(:publisher_failed)
        end
      )

    evidence = fixture("codex-account-updated-logged-out-0.145.0.json")["params"]
    assert :ok = Credentials.mark_terminal(:openai, evidence, server)
    assert Credentials.status(:openai, server) == {:needs_onboarding, :revoked}
    assert :ok = Credentials.onboard(:openai, server)
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
        start: fn _, _ ->
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

    assert :ok = Credentials.finish_onboard(:openai, :subscription, server)
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
    assert :ok = Credentials.finish_onboard(:openai, :subscription, server)
    assert Credentials.status(:openai, server) == :onboarded

    store = Path.join([ctx.base, "auth", "codex", "auth.json"])
    home = Path.join([ctx.base, "homes", "worker", "codex", "auth.json"])
    assert File.read!(store) == "satellite-only-secret"
    assert File.lstat!(home).type == :symlink

    commands = collect_remote_credential_commands([])
    refute Enum.any?(commands, &(Enum.join(&1, " ") =~ "satellite-only-secret"))
  end

  test "interactive Claude no-subscription cancellation persists unsupported health", ctx do
    owner = self()

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        publish_sessions: fn _captured, transition ->
          send(owner, {:forbidden_cancel_publish, transition})
        end
      )

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

    refute_receive {:forbidden_cancel_publish, _}
  end

  test "an abandoned onboarding lease expires and the next begin succeeds", ctx do
    owner = self()
    # A counter, not a sleep: the lease is compared at read seams against `now`,
    # so a test can move time instead of spending it.
    clock = :counters.new(1, [])
    :counters.put(clock, 1, 1_000)

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        onboarding_lease_ms: 60_000,
        now: fn -> :counters.get(clock, 1) end,
        log_event: fn kind, subject, detail ->
          send(owner, {:event, kind, subject, detail})
        end
      )

    assert {:ok, staging} = Credentials.begin_onboard(:openai, server)

    # The CLI dies here — it never calls finish, and never calls cancel. Cancel is
    # client-driven, so nothing on this side has been told the ceremony is over.
    assert {:error, :onboarding_in_progress} = Credentials.begin_onboard(:openai, server)
    assert Credentials.status(:openai, server) == {:needs_onboarding, :in_progress}

    :counters.add(clock, 1, 61)

    # Past the TTL the provider is onboardable again without a gateway restart,
    # and the expiry left the same trace an explicit cancel would have.
    assert {:ok, fresh} = Credentials.begin_onboard(:openai, server)
    assert fresh != staging
    assert_received {:event, "credential_lease_expired", "openai@eezo", nil}
    refute File.exists?(staging)
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

  describe "credential kind" do
    test "an API key banks with its kind recorded and no expiry", ctx do
      {:ok, server} = Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

      {:ok, staging} = Credentials.begin_onboard(:anthropic, server)
      File.write!(Path.join(staging, "oauth-token"), "sk-ant-api03-staged")
      assert :ok = Credentials.finish_onboard(:anthropic, :api_key, server)

      metadata = credential_metadata(ctx.base, "claude")

      assert metadata["kind"] == "api_key"
      assert metadata["onboarded"] == true

      # API keys are static: no rotation, no refresh. A synthetic expiry would
      # eventually have `credential_status` demand a re-onboard for a credential
      # that still works.
      assert metadata["expires_at"] == nil
      assert metadata["subscription_status"] == nil

      assert Credentials.status(:anthropic, server) == :onboarded
      assert Credentials.kind(:anthropic, server) == :api_key
      assert Credentials.kind_at(ctx.base, :anthropic) == :api_key
    end

    test "a subscription banks with its kind and keeps its expiry", ctx do
      {:ok, server} = Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

      {:ok, staging} = Credentials.begin_onboard(:anthropic, server)
      File.write!(Path.join(staging, "oauth-token"), "sk-ant-oat01-staged")
      assert :ok = Credentials.finish_onboard(:anthropic, :subscription, server)

      metadata = credential_metadata(ctx.base, "claude")

      assert metadata["kind"] == "subscription"
      assert is_integer(metadata["expires_at"])
      assert metadata["subscription_status"] == "supported"
      assert Credentials.kind(:anthropic, server) == :subscription
    end

    test "no credential is its own state, not a kind", ctx do
      {:ok, server} = Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

      assert Credentials.kind(:anthropic, server) == :none
      assert Credentials.kind(:openai, server) == :none
      assert Credentials.kind_at(ctx.base, :openai) == :none
    end

    test "one host holds a different kind per provider", ctx do
      {:ok, server} = Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

      {:ok, claude_staging} = Credentials.begin_onboard(:anthropic, server)
      File.write!(Path.join(claude_staging, "oauth-token"), "sk-ant-api03-staged")
      :ok = Credentials.finish_onboard(:anthropic, :api_key, server)

      {:ok, codex_staging} = Credentials.begin_onboard(:openai, server)
      File.write!(Path.join(codex_staging, "auth.json"), ~s({"tokens":{"access_token":"t"}}))
      :ok = Credentials.finish_onboard(:openai, :subscription, server)

      assert Credentials.kind(:anthropic, server) == :api_key
      assert Credentials.kind(:openai, server) == :subscription
    end
  end

  defp credential_metadata(base, harness) do
    [base, "auth", harness, ".tightbeam", "credential.json"]
    |> Path.join()
    |> File.read!()
    |> JSON.decode!()
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
