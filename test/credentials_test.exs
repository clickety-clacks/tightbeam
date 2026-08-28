defmodule Tightbeam.CredentialsTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Credentials

  setup do
    base = Path.join(System.tmp_dir!(), "tb-credentials-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  test "onboarding commits before the credential-present callback and success publication", ctx do
    owner = self()

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        onboarders: %{
          openai: fn _state ->
            send(owner, {:step, :obtain})
            {:ok, %{bytes: ~S({"token":"new"}), expires_at: nil}}
          end
        },
        gate: fn _ ->
          send(owner, {:step, :gate})
          :ok
        end,
        stop: fn _ ->
          send(owner, {:step, :stop})
          :ok
        end,
        start: fn _, _ ->
          assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) ==
                   ~S({"token":"new"})

          send(owner, {:step, :start})
          :ok
        end,
        on_credential_present: fn :openai ->
          assert credential_metadata(ctx.base, "codex")["onboarded"] == true
          send(owner, {:step, :credential_present})
          :ok
        end,
        resume: fn _ ->
          send(owner, {:step, :resume})
          :ok
        end
      )

    assert :ok = Credentials.onboard(:openai, server)

    steps =
      for _ <- 1..6 do
        assert_receive {:step, step}
        step
      end

    assert steps == [:gate, :stop, :obtain, :start, :credential_present, :resume]
    refute_receive {:step, :credential_present}

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

  test "an absent credential store is missing rather than unreadable", ctx do
    store = Path.join([ctx.base, "auth", "codex"])
    {:ok, server} = Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

    refute File.exists?(store)
    assert Credentials.status(:openai, server) == {:needs_onboarding, :missing}
  end

  test "a symlinked credential store refuses with its path and actual shape", ctx do
    store = Path.join([ctx.base, "auth", "codex"])
    target = Path.join(ctx.base, "symlink-target")
    metadata = Path.join([target, ".tightbeam", "credential.json"])
    File.mkdir_p!(Path.dirname(metadata))
    File.write!(Path.join(target, "auth.json"), ~S({"token":"present"}))
    File.write!(metadata, ~S({"provider":"openai","onboarded":true}))
    File.mkdir_p!(Path.dirname(store))
    File.ln_s!(target, store)

    {:ok, server} = Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

    reason =
      {:credential_store_unreadable, %{path: store, found: :symlink, expected: :directory}}

    assert Credentials.status(:openai, server) == {:needs_onboarding, reason}
    assert Credentials.kind(:openai, server) == {:error, reason}
  end

  test "corrupt credential metadata refuses with its path and expected shape", ctx do
    store = Path.join([ctx.base, "auth", "codex"])
    metadata = Path.join([store, ".tightbeam", "credential.json"])
    File.mkdir_p!(Path.dirname(metadata))
    File.write!(metadata, "not json")

    {:ok, server} = Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

    assert Credentials.status(:openai, server) ==
             {:needs_onboarding,
              {:credential_store_unreadable,
               %{path: metadata, found: :invalid_json, expected: :valid_json_object}}}
  end

  test "remote absence requires a positively traversable parent", ctx do
    parent = Path.join([ctx.base, "auth"])
    File.mkdir_p!(parent)

    {:ok, server} = remote_server(ctx.base)

    assert Credentials.status(:openai, server) == {:needs_onboarding, :missing}
  end

  test "remote store below an untraversable parent refuses rather than guessing absence", ctx do
    parent = Path.join([ctx.base, "auth"])
    File.mkdir_p!(parent)
    File.chmod!(parent, 0o600)
    on_exit(fn -> File.chmod(parent, 0o700) end)

    {:ok, server} = remote_server(ctx.base)

    assert Credentials.status(:openai, server) ==
             {:needs_onboarding,
              {:credential_store_unreadable,
               %{path: parent, found: :untraversable, expected: :traversable_directory}}}
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

    {:ok, park_receiver} =
      Tightbeam.CredentialParkTestReceiver.start_link(fn _provider ->
        send(owner, :park)
        :ok
      end)

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
        park_edge: Tightbeam.CommandEdge.request_to(park_receiver),
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

  test "an unconfirmed park is returned as data and Credentials keeps the durable gate", ctx do
    owner = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    {:ok, park_receiver} =
      Tightbeam.CredentialParkTestReceiver.start_link(fn :openai ->
        case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
          0 -> {:error, {:park_unconfirmed, :identity_unavailable}}
          1 -> :ok
        end
      end)

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        park_edge: Tightbeam.CommandEdge.request_to(park_receiver),
        capture_sessions: fn :openai -> [:captured_session] end,
        publish_sessions: fn captured, transition ->
          send(owner, {:publish, captured, transition})
          :ok
        end,
        log_event: fn kind, subject, detail ->
          send(owner, {:log_event, kind, subject, detail})
          :ok
        end
      )

    evidence = fixture("codex-account-updated-logged-out-0.145.0.json")["params"]

    assert {:error, {:park_unconfirmed, :identity_unavailable}} =
             Credentials.mark_terminal(:openai, evidence, server)

    assert Process.alive?(server)
    assert Credentials.status(:openai, server) == {:needs_onboarding, :revoked}
    assert_receive {:log_event, "credential_park_unconfirmed", "openai@eezo", detail}
    assert detail =~ "park_unconfirmed"
    refute_receive {:publish, _, _}

    assert :ok = Credentials.mark_terminal(:openai, evidence, server)
    assert_receive {:publish, [:captured_session], :terminal}
    assert Agent.get(attempts, & &1) == 2
  end

  test "terminal parking leaves Credentials responsive while the coordinator edge is pending",
       ctx do
    owner = self()

    {:ok, park_receiver} =
      Tightbeam.CredentialParkTestReceiver.start_link(fn :openai ->
        send(owner, {:park_edge_entered, self()})

        receive do
          :release_park -> :ok
        end
      end)

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        onboarders: %{openai: fn _ -> {:ok, %{bytes: "replacement", expires_at: nil}} end},
        park_edge: Tightbeam.CommandEdge.request_to(park_receiver)
      )

    evidence = fixture("codex-account-updated-logged-out-0.145.0.json")["params"]
    terminal = Task.async(fn -> Credentials.mark_terminal(:openai, evidence, server) end)
    assert_receive {:park_edge_entered, ^park_receiver}

    onboard = Task.async(fn -> Credentials.onboard(:openai, server) end)

    assert Credentials.status(:openai, server) == {:needs_onboarding, :revoked}
    assert Process.alive?(server)
    assert Task.yield(onboard, 20) == nil

    send(park_receiver, :release_park)
    assert Task.await(terminal) == :ok
    assert Task.await(onboard) == :ok
  end

  test "terminal capture remains immutable while the park mutates membership", ctx do
    owner = self()
    {:ok, membership} = Agent.start_link(fn -> [:before_one, :before_two] end)

    {:ok, park_receiver} =
      Tightbeam.CredentialParkTestReceiver.start_link(fn :openai ->
        Agent.update(membership, fn _ -> [:after] end)
        :ok
      end)

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        capture_sessions: fn :openai -> Agent.get(membership, & &1) end,
        park_edge: Tightbeam.CommandEdge.request_to(park_receiver),
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
    {:ok, park_receiver} =
      Tightbeam.CredentialParkTestReceiver.start_link(fn :openai -> :ok end)

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        onboarders: %{
          openai: fn _state -> {:ok, %{bytes: "replacement", expires_at: nil}} end
        },
        park_edge: Tightbeam.CommandEdge.request_to(park_receiver),
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

  test "interactive phase keeps the old same-kind runtime serving until installed replacement",
       ctx do
    owner = self()
    {:ok, runtime} = Agent.start_link(fn -> {:serving, :subscription} end)

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        gate: fn _ ->
          send(owner, :gate)
          :ok
        end,
        stop: fn :openai ->
          assert Agent.get(runtime, & &1) == {:serving, :subscription}

          assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) ==
                   "device-code-result"

          assert credential_metadata(ctx.base, "codex")["last_health"] ==
                   "present_but_unverified"

          Agent.update(runtime, fn _ -> {:stopped, :subscription} end)
          send(owner, {:finish_step, :stop})
          :ok
        end,
        start: fn :openai, :subscription ->
          assert Agent.get(runtime, & &1) == {:stopped, :subscription}

          assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) ==
                   "device-code-result"

          Agent.update(runtime, fn _ -> {:serving, :subscription, :replacement} end)
          send(owner, {:finish_step, :start})
          :ok
        end,
        on_credential_present: fn :openai ->
          assert Agent.get(runtime, & &1) == {:serving, :subscription, :replacement}
          assert credential_metadata(ctx.base, "codex")["onboarded"]
          send(owner, {:finish_step, :commit})
          :ok
        end,
        resume: fn _ ->
          send(owner, {:finish_step, :resume})
          :ok
        end
      )

    assert {:ok, staging, lease_id} = Credentials.begin_onboard(:openai, server)
    assert_receive :gate
    refute_receive {:finish_step, :stop}
    assert Agent.get(runtime, & &1) == {:serving, :subscription}
    assert {:messages, []} = Process.info(server, :messages)
    File.write!(Path.join(staging, "auth.json"), "device-code-result")
    refute_receive {:finish_step, :stop}

    assert :ok = Credentials.finish_onboard(:openai, :subscription, lease_id, server)

    steps =
      for _ <- 1..4 do
        assert_receive {:finish_step, step}
        step
      end

    assert steps == [:stop, :start, :commit, :resume]
    assert Agent.get(runtime, & &1) == {:serving, :subscription, :replacement}
    refute File.exists?(staging)

    assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) ==
             "device-code-result"
  end

  test "failed and canceled interactive phases keep the prior runtime serving", ctx do
    owner = self()
    {:ok, prior_runtime} = Agent.start_link(fn -> :serving end)

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        stop: fn provider ->
          Agent.update(prior_runtime, fn _ -> :parked end)
          send(owner, {:forbidden_stop, provider})
          :ok
        end,
        start: fn provider, _kind ->
          send(owner, {:forbidden_start, provider})
          :ok
        end
      )

    assert {:ok, failed_staging, failed_lease_id} =
             Credentials.begin_onboard(:openai, server)

    assert Agent.get(prior_runtime, & &1) == :serving
    refute_receive {:forbidden_stop, :openai}

    assert {:error, {:device_auth_failed, :enoent}} =
             Credentials.finish_onboard(
               :openai,
               :subscription,
               failed_lease_id,
               server
             )

    refute File.exists?(failed_staging)
    assert Agent.get(prior_runtime, & &1) == :serving
    refute_receive {:forbidden_stop, :openai}
    refute_receive {:forbidden_start, :openai}

    assert {:ok, canceled_staging, canceled_lease_id} =
             Credentials.begin_onboard(:anthropic, server)

    assert Agent.get(prior_runtime, & &1) == :serving
    refute_receive {:forbidden_stop, :anthropic}

    assert :ok = Credentials.cancel_onboard(:anthropic, canceled_lease_id, server)
    refute File.exists?(canceled_staging)
    assert Agent.get(prior_runtime, & &1) == :serving
    refute_receive {:forbidden_stop, :anthropic}
    refute_receive {:forbidden_start, :anthropic}
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

    assert {:ok, staging, lease_id} = Credentials.begin_onboard(:openai, server)
    assert staging =~ "/staging/credential-onboarding/openai-"
    assert Credentials.status(:openai, server) == {:needs_onboarding, :in_progress}

    File.write!(Path.join(staging, "auth.json"), "satellite-only-secret")
    assert :ok = Credentials.finish_onboard(:openai, :subscription, lease_id, server)
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

    assert {:ok, staging, lease_id} = Credentials.begin_onboard(:anthropic, server)

    assert :ok =
             Credentials.cancel_onboard(
               :anthropic,
               lease_id,
               :unsupported_no_subscription,
               server
             )

    refute File.exists?(staging)

    assert Credentials.status(:anthropic, server) ==
             {:needs_onboarding, {:unsupported, :no_subscription}}

    refute_receive {:forbidden_cancel_publish, _}
  end

  test "a second begin supersedes the pending lease and its stale finish fails loudly", ctx do
    owner = self()

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: "eezo",
        stop: fn provider ->
          send(owner, {:stop, provider})
          :ok
        end
      )

    assert {:ok, staging, stale_lease_id} = Credentials.begin_onboard(:openai, server)
    File.write!(Path.join(staging, "auth.json"), ~S({"token":"stale"}))
    refute_receive {:stop, :openai}

    assert {:ok, fresh, current_lease_id} = Credentials.begin_onboard(:openai, server)
    assert fresh != staging
    assert current_lease_id != stale_lease_id
    refute_receive {:stop, :openai}
    refute File.exists?(staging)
    File.write!(Path.join(fresh, "auth.json"), ~S({"token":"successor"}))

    assert {:error, :onboarding_lease_superseded} =
             Credentials.finish_onboard(:openai, :subscription, stale_lease_id, server)

    refute File.exists?(Path.join([ctx.base, "auth", "codex", "auth.json"]))
    assert File.exists?(fresh)
  end

  test "a stale cancel does not cancel the successor's lease", ctx do
    {:ok, server} =
      Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

    assert {:ok, _abandoned, stale_lease_id} = Credentials.begin_onboard(:anthropic, server)
    assert {:ok, fresh, current_lease_id} = Credentials.begin_onboard(:anthropic, server)

    assert {:error, :onboarding_lease_superseded} =
             Credentials.cancel_onboard(:anthropic, stale_lease_id, server)

    assert File.exists?(fresh)
    assert Credentials.status(:anthropic, server) == {:needs_onboarding, :in_progress}
    assert :ok = Credentials.cancel_onboard(:anthropic, current_lease_id, server)
    refute File.exists?(fresh)
  end

  test "an operator whose CLI died can immediately begin again", ctx do
    {:ok, server} =
      Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

    assert {:ok, abandoned, _abandoned_id} = Credentials.begin_onboard(:anthropic, server)
    assert {:ok, fresh, _fresh_id} = Credentials.begin_onboard(:anthropic, server)
    assert fresh != abandoned
    refute File.exists?(abandoned)
  end

  test "an abandoned onboarding lease expires server-side at a read seam", ctx do
    owner = self()

    # A counter, not a sleep: the lease is compared at read seams against `now`,
    # so the test moves time instead of spending it (the module's stated posture).
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

    assert {:ok, staging, _lease_id} = Credentials.begin_onboard(:openai, server)
    assert Credentials.status(:openai, server) == {:needs_onboarding, :in_progress}

    # The CLI dies here — it never calls finish, and never calls cancel. Cancel is
    # client-driven, so nothing on this side has been told the ceremony is over.
    # Before the server-side lease this wedged as :in_progress until a gateway restart.
    :counters.add(clock, 1, 61)

    # A read seam (status) sweeps the expired lease: the provider heals into exactly
    # the condition an explicit cancel would have left — staging gone, pending cleared —
    # and the expiry is logged as its own lifecycle event carrying `lease_expired`.
    assert Credentials.status(:openai, server) == {:needs_onboarding, :missing}
    assert_received {:event, "credential_lease_expired", "openai@eezo", nil}
    refute File.exists?(staging)

    # And the next begin succeeds on fresh staging without a restart.
    assert {:ok, fresh, _fresh_id} = Credentials.begin_onboard(:openai, server)
    assert fresh != staging
  end

  describe "finish_onboard commit and rollback" do
    test "a stop refusal keeps the installed candidate unverified and never starts", ctx do
      owner = self()

      {:ok, server} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          machine: "eezo",
          stop: fn :openai ->
            assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) ==
                     ~S({"token":"candidate"})

            refute credential_metadata(ctx.base, "codex")["onboarded"]

            assert credential_metadata(ctx.base, "codex")["last_health"] ==
                     "present_but_unverified"

            send(owner, :stop_refused)
            {:error, :runtime_stop_refused}
          end,
          start: fn _, _ -> send(owner, :forbidden_start) end,
          on_credential_present: fn _ -> send(owner, :forbidden_credential_present) end,
          resume: fn _ -> send(owner, :forbidden_resume) end,
          publish_sessions: fn _, _ -> send(owner, :forbidden_publish) end
        )

      assert {:ok, staging, lease_id} = Credentials.begin_onboard(:openai, server)
      refute_receive :stop_refused
      File.write!(Path.join(staging, "auth.json"), ~S({"token":"candidate"}))

      assert {:error, :runtime_stop_refused} =
               Credentials.finish_onboard(:openai, :subscription, lease_id, server)

      assert_receive :stop_refused

      assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) ==
               ~S({"token":"candidate"})

      assert {:needs_onboarding, {:present_but_unverified, cause}} =
               Credentials.status(:openai, server)

      assert cause["finish"] =~ "runtime_stop_refused"
      refute credential_metadata(ctx.base, "codex")["onboarded"]
      refute File.exists?(staging)
      refute_receive :forbidden_start
      refute_receive :forbidden_credential_present
      refute_receive :forbidden_resume
      refute_receive :forbidden_publish
    end

    test "success calls the credential-present callback once after durable state", ctx do
      owner = self()

      {:ok, server} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          machine: "eezo",
          start: fn :openai, :subscription ->
            send(owner, {:finish_step, :start})
            :ok
          end,
          on_credential_present: fn :openai ->
            assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) ==
                     ~S({"token":"candidate"})

            assert credential_metadata(ctx.base, "codex")["onboarded"] == true
            send(owner, {:finish_step, :credential_present})
            :ok
          end,
          capture_sessions: fn :openai ->
            send(owner, {:finish_step, :capture})
            [:session]
          end,
          resume: fn :openai ->
            send(owner, {:finish_step, :resume})
            :ok
          end,
          publish_sessions: fn [:session], :onboarded ->
            send(owner, {:finish_step, :publish})
            :ok
          end
        )

      assert {:ok, staging, lease_id} = Credentials.begin_onboard(:openai, server)
      File.write!(Path.join(staging, "auth.json"), ~S({"token":"candidate"}))

      assert :ok = Credentials.finish_onboard(:openai, :subscription, lease_id, server)

      steps =
        for _ <- 1..5 do
          assert_receive {:finish_step, step}
          step
        end

      assert steps == [:start, :credential_present, :capture, :resume, :publish]
      refute_receive {:finish_step, :credential_present}
      refute File.exists?(staging)
    end

    test "a start failure KEEPS the new credential and refuses visibly", ctx do
      owner = self()

      {:ok, server} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          machine: "eezo",
          start: fn :openai, :subscription -> {:error, :runtime_start_failed} end,
          on_credential_present: fn _ -> send(owner, :forbidden_credential_present) end,
          resume: fn _ -> send(owner, :forbidden_resume) end,
          publish_sessions: fn _, _ -> send(owner, :forbidden_publish) end
        )

      assert {:ok, staging, lease_id} = Credentials.begin_onboard(:openai, server)
      File.write!(Path.join(staging, "auth.json"), ~S({"token":"candidate"}))

      assert {:error, :runtime_start_failed} =
               Credentials.finish_onboard(:openai, :subscription, lease_id, server)

      # The operator's credential stays where they put it: the substrate holds no
      # opinion about a vendor login, and reverting one silently resumes spend on
      # an account the operator believes is disconnected (Mike, 2026-08-14).
      assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) ==
               ~S({"token":"candidate"})

      # ...and the org reads FAILED, matching what the operator just watched fail.
      assert {:needs_onboarding, {:present_but_unverified, cause}} =
               Credentials.status(:openai, server)

      assert cause["finish"] =~ "runtime_start_failed"

      refute File.exists?(staging)
      refute_receive :forbidden_credential_present
      refute_receive :forbidden_resume
      refute_receive :forbidden_publish
    end

    test "the refusal survives a restart — a failed login never looks healthy again",
         ctx do
      {:ok, server} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          machine: "eezo",
          start: fn :openai, :subscription -> {:error, :runtime_start_failed} end
        )

      assert {:ok, staging, lease_id} = Credentials.begin_onboard(:openai, server)
      File.write!(Path.join(staging, "auth.json"), ~S({"token":"candidate"}))

      assert {:error, :runtime_start_failed} =
               Credentials.finish_onboard(:openai, :subscription, lease_id, server)

      # A fresh server reads only durable state: the marker, not the memory.
      {:ok, restarted} =
        Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

      assert {:needs_onboarding, {:present_but_unverified, cause}} =
               Credentials.status(:openai, restarted)

      assert cause["finish"] =~ "runtime_start_failed"
    end

    test "raised and exited start failures refuse and clean the lease without killing the owner",
         ctx do
      owner = self()

      failures = [
        {"raise", fn -> raise "runtime-start-crash" end,
         {:error, {:credential_start_failed, {:exception, "runtime-start-crash"}}}},
        {"exit", fn -> exit(:runtime_start_exit) end,
         {:error, {:credential_start_failed, {:exit, :runtime_start_exit}}}}
      ]

      Enum.each(failures, fn {label, fail_start, expected} ->
        base = Path.join(ctx.base, label)

        {:ok, server} =
          Credentials.start_link(
            name: nil,
            base_dir: base,
            machine: "eezo",
            start: fn :openai, :subscription -> fail_start.() end,
            on_credential_present: fn _ -> send(owner, :forbidden_credential_present) end,
            resume: fn _ -> send(owner, :forbidden_resume) end,
            publish_sessions: fn _, _ -> send(owner, :forbidden_publish) end
          )

        assert {:ok, staging, lease_id} = Credentials.begin_onboard(:openai, server)
        File.write!(Path.join(staging, "auth.json"), ~S({"token":"candidate"}))

        assert ^expected =
                 Credentials.finish_onboard(:openai, :subscription, lease_id, server)

        assert Process.alive?(server)

        # Crashing and exiting starts refuse like any other start failure: the
        # operator's credential stays, the org reads failed.
        assert File.read!(Path.join([base, "auth", "codex", "auth.json"])) ==
                 ~S({"token":"candidate"})

        refute File.exists?(staging)

        assert {:needs_onboarding, {:present_but_unverified, cause}} =
                 Credentials.status(:openai, server)

        assert cause["finish"] =~ "credential_start_failed"
      end)

      refute_receive :forbidden_credential_present
      refute_receive :forbidden_resume
      refute_receive :forbidden_publish
    end

    # THE INCIDENT TEST (2026-08-14). The prior contract restored the previous
    # credential when activation failed, which meant an operator who watched a
    # login fail — and may have chosen to stay logged out, "I was running out of
    # tokens anyway" — silently kept spending on the account they believed was
    # disconnected. It also deadlocked recovery: activation cannot succeed while
    # the adapter circuit is latched, and the latch is guaranteed exactly when
    # the old credential has stopped working. A swap fails when you need it.
    test "a start failure DISPLACES the prior credential — no silent revival of old spend",
         ctx do
      owner = self()
      credential = Path.join([ctx.base, "auth", "codex", "auth.json"])
      metadata = Path.join([ctx.base, "auth", "codex", ".tightbeam", "credential.json"])
      prior_credential = ~S({"token":"prior","spacing":true}) <> "\n"
      prior_metadata = ~S( { "provider": "openai", "onboarded": true, "kind": "api_key" } )
      File.mkdir_p!(Path.dirname(metadata))
      File.write!(credential, prior_credential)
      File.write!(metadata, prior_metadata)

      {:ok, server} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          machine: "eezo",
          start: fn :openai, :subscription -> {:error, :runtime_start_failed} end,
          on_credential_present: fn _ -> send(owner, :forbidden_credential_present) end
        )

      assert {:ok, staging, lease_id} = Credentials.begin_onboard(:openai, server)
      File.write!(Path.join(staging, "auth.json"), ~S({"token":"candidate"}))

      assert {:error, :runtime_start_failed} =
               Credentials.finish_onboard(:openai, :subscription, lease_id, server)

      # The prior credential is GONE — it cannot be revived to spend behind the
      # operator's back.
      assert File.read!(credential) == ~S({"token":"candidate"})
      refute File.read!(credential) == prior_credential

      # The prior metadata claimed `onboarded: true`. Leaving that would report a
      # healthy org describing a credential the operator thinks they replaced.
      refute File.read!(metadata) == prior_metadata

      assert {:needs_onboarding, {:present_but_unverified, cause}} =
               Credentials.status(:openai, server)

      assert cause["finish"] =~ "runtime_start_failed"

      refute File.exists?(staging)
      refute_receive :forbidden_credential_present
    end

    test "a satellite metadata failure refuses without transporting credential bytes", ctx do
      owner = self()

      # Seed a PRIOR onboarded credential, so the stale-health scenario Sol
      # named has something stale to leave behind if the ordering regresses.
      prior_credential = "prior-satellite-secret"
      credential_path = Path.join([ctx.base, "auth", "codex", "auth.json"])
      metadata_path = Path.join([ctx.base, "auth", "codex", ".tightbeam", "credential.json"])
      File.mkdir_p!(Path.dirname(metadata_path))
      File.write!(credential_path, prior_credential)
      File.write!(metadata_path, ~S({"provider":"openai","onboarded":true,"kind":"subscription"}))

      sh = fn command ->
        send(owner, {:remote_finish_command, command})
        text = Enum.join(command, " ")

        if text =~ "last_health" and text =~ "onboarded" do
          {"metadata refused", 1}
        else
          run_remote_command(command)
        end
      end

      {:ok, server} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          machine: "worker",
          ssh: "worker",
          sh: sh,
          on_credential_present: fn _ -> send(owner, :forbidden_credential_present) end
        )

      assert {:ok, staging, lease_id} = Credentials.begin_onboard(:openai, server)
      File.write!(Path.join(staging, "auth.json"), "satellite-candidate-secret")

      # The marker commits BEFORE the credential is installed, so an unwritable
      # metadata path refuses with the store still untouched.
      assert {:error, {:credential_metadata_write_failed, message}} =
               Credentials.finish_onboard(:openai, :subscription, lease_id, server)

      assert inspect(message) =~ "metadata refused"
      refute File.exists?(staging)
      refute_receive :forbidden_credential_present

      # Nothing was installed, so the prior state stays coherent: the prior
      # credential and its prior metadata still describe each other. The stale
      # `onboarded: true` can never come to describe a candidate that was never
      # activated (Sol xhigh blocking 1).
      assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) == prior_credential

      # And a restarted gateway reads the same thing from disk, not from memory.
      {:ok, restarted} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          machine: "worker",
          ssh: "worker",
          sh: &run_remote_command/1
        )

      assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) == prior_credential

      # `:onboarded` is the CORRECT reading here, and the point of the ordering:
      # the refusal happened before anything was installed, so the prior
      # credential and its prior metadata still describe each other. A failed
      # onboarding is a clean no-op — nothing was silently restored, because
      # nothing was ever removed. The stale-health defect would show up as this
      # metadata describing a DIFFERENT credential; assert it does not.
      assert Credentials.status(:openai, restarted) == :onboarded

      # The property this test exists for, unchanged: credential bytes never
      # cross the ssh edge as command text.
      commands = collect_remote_finish_commands([])
      refute Enum.any?(commands, &(Enum.join(&1, " ") =~ "satellite-candidate-secret"))
    end

    test "a satellite start failure persists a present-but-unverified cause and keeps the candidate",
         ctx do
      owner = self()

      {:ok, server} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          machine: "worker",
          ssh: "worker",
          sh: &run_remote_command/1,
          start: fn :openai, :subscription -> {:error, :runtime_start_failed} end,
          on_credential_present: fn _ -> send(owner, :forbidden_credential_present) end,
          resume: fn _ -> send(owner, :forbidden_resume) end,
          publish_sessions: fn _, _ -> send(owner, :forbidden_publish) end
        )

      assert {:ok, staging, lease_id} = Credentials.begin_onboard(:openai, server)
      File.write!(Path.join(staging, "auth.json"), "candidate-remains-present")

      assert {:error, :runtime_start_failed} =
               Credentials.finish_onboard(:openai, :subscription, lease_id, server)

      assert File.read!(Path.join([ctx.base, "auth", "codex", "auth.json"])) ==
               "candidate-remains-present"

      metadata = credential_metadata(ctx.base, "codex")
      assert metadata["onboarded"] == false
      assert metadata["last_health"] == "present_but_unverified"
      assert metadata["present_but_unverified"]["finish"] =~ "runtime_start_failed"

      assert {:needs_onboarding, {:present_but_unverified, cause}} =
               Credentials.status(:openai, server)

      assert cause == metadata["present_but_unverified"]
      refute File.exists?(staging)
      refute_receive :forbidden_credential_present
      refute_receive :forbidden_resume
      refute_receive :forbidden_publish
    end

    # The FAILURE marker write can itself fail. Status must still fail closed —
    # falling back to the durable pre-activation marker ("has not committed")
    # that `prepare_staged_activation` wrote before the start was attempted.
    test "a failure-marker write failure still makes status fail closed", ctx do
      owner = self()
      credential = Path.join([ctx.base, "auth", "codex", "auth.json"])
      metadata = Path.join([ctx.base, "auth", "codex", ".tightbeam", "credential.json"])
      File.mkdir_p!(Path.dirname(metadata))
      File.write!(credential, ~S({"token":"prior"}))
      File.write!(metadata, ~S({"provider":"openai","onboarded":true,"kind":"api_key"}))

      sh = fn command ->
        text = Enum.join(command, " ")

        if text =~ "present_but_unverified" and text =~ "runtime_start_failed" do
          {"marker refused", 1}
        else
          run_remote_command(command)
        end
      end

      {:ok, server} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          machine: "worker",
          ssh: "worker",
          sh: sh,
          start: fn :openai, :subscription -> {:error, :runtime_start_failed} end,
          on_credential_present: fn _ -> send(owner, :forbidden_credential_present) end,
          resume: fn _ -> send(owner, :forbidden_resume) end,
          publish_sessions: fn _, _ -> send(owner, :forbidden_publish) end
        )

      assert {:ok, staging, lease_id} = Credentials.begin_onboard(:openai, server)
      File.write!(Path.join(staging, "auth.json"), ~S({"token":"candidate"}))

      assert {:error,
              {:onboarding_failed_and_marker_failed,
               %{
                 finish: {:error, :runtime_start_failed},
                 marker: {:credential_metadata_write_failed, message}
               }}} = Credentials.finish_onboard(:openai, :subscription, lease_id, server)

      assert message =~ "marker refused"
      assert File.read!(credential) == ~S({"token":"candidate"})

      durable_marker = JSON.decode!(File.read!(metadata))
      assert durable_marker["onboarded"] == false
      assert durable_marker["present_but_unverified"]["finish"] =~ "has not committed"

      assert {:needs_onboarding, {:present_but_unverified, cause}} =
               Credentials.status(:openai, server)

      assert cause["finish"] =~ "runtime_start_failed"
      assert Process.alive?(server)
      refute File.exists?(staging)

      GenServer.stop(server)

      {:ok, restarted} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          machine: "worker",
          ssh: "worker",
          sh: sh
        )

      # DURABILITY, read from disk by a process that never saw the failure: the
      # detailed cause was refused, so what survives is the pre-activation
      # marker's generic text. Less specific than the vendor's own words, and
      # still fails closed — which is the property that matters.
      assert {:needs_onboarding, {:present_but_unverified, restarted_cause}} =
               Credentials.status(:openai, restarted)

      assert restarted_cause == durable_marker["present_but_unverified"]
      assert restarted_cause["finish"] =~ "credential activation has not committed"
      refute_receive :forbidden_credential_present
      refute_receive :forbidden_resume
      refute_receive :forbidden_publish
    end
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

      {:ok, staging, lease_id} = Credentials.begin_onboard(:anthropic, server)
      File.write!(Path.join(staging, ".credentials.json"), "sk-ant-api03-staged")
      assert :ok = Credentials.finish_onboard(:anthropic, :api_key, lease_id, server)

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

      {:ok, staging, lease_id} = Credentials.begin_onboard(:anthropic, server)

      File.write!(
        Path.join(staging, ".credentials.json"),
        ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-staged"}})
      )

      assert :ok = Credentials.finish_onboard(:anthropic, :subscription, lease_id, server)

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

      {:ok, claude_staging, claude_lease_id} = Credentials.begin_onboard(:anthropic, server)
      File.write!(Path.join(claude_staging, ".credentials.json"), "sk-ant-api03-staged")
      :ok = Credentials.finish_onboard(:anthropic, :api_key, claude_lease_id, server)

      {:ok, codex_staging, codex_lease_id} = Credentials.begin_onboard(:openai, server)
      File.write!(Path.join(codex_staging, "auth.json"), ~s({"tokens":{"access_token":"t"}}))
      :ok = Credentials.finish_onboard(:openai, :subscription, codex_lease_id, server)

      assert Credentials.kind(:anthropic, server) == :api_key
      assert Credentials.kind(:openai, server) == :subscription
    end
  end

  # A HOLLOW CREDENTIAL IS DIRT, AND DIRT IS REPORTED, NOT BANKED.
  #
  # The incident these pin: a re-onboard left `accessToken: ""`, `refreshToken: ""`,
  # `expiresAt: 0` in BOTH tightbeam stores while the vendor's own credential was fine,
  # and every session afterwards read "expired", tried to refresh, and died
  # `authentication_failed`. Two coder sessions were killed by it before it was traced.
  #
  # The writer was never the ceremony. Claude Code OWNS the `.credentials.json` inside a
  # harness home and rotates it in place; `Homes.sweep_auth/2` harvests that file at every
  # gateway boot (gateway.ex:193) and `store_harvested/3` wrote the bytes over the SHARED
  # auth store without ever looking at them. So one agent's hollow home file poisoned the
  # credential for every agent on the next boot — and the reboot was what re-applied the
  # poison, which is why restarting never healed it.
  # THE ARTIFACT, NOT AN IDEALISED VERSION OF IT.
  #
  # The key SET is captured from the vendor's own writer, not invented: three independent
  # Claude-Code-written `.credentials.json` files on gibson (the live one plus the two
  # rename-aside backups `.pre-harvest-*` and `.stale-*`) carry exactly these seven keys, in
  # this order. An earlier version of these tests used a four-key subset, which is a
  # hand-drawn fixture wearing the incident's clothes: it would stay green against a guard
  # that only ever handled the tidy shape, and the file that actually broke eezo has three
  # more keys than that.
  #
  # PROVENANCE, stated exactly. File-verified from the incident: `accessToken` empty,
  # `refreshToken` empty, `expiresAt` 0. Captured from the vendor's live key set: the
  # remaining four keys and their types. The zeroed/emptied VALUES for those four are the
  # inference — a cleared record keeps its keys — and they are deliberately the part under
  # test, because the guard must not depend on which of them happen to be present.
  @hollow_vendor_record ~s({"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"refreshTokenExpiresAt":0,"scopes":[],"subscriptionType":"","rateLimitTier":""}})

  # The same seven keys, populated — so a test that expects harvesting to SUCCEED is not
  # quietly passing because it used a different shape from the one that must fail.
  @healthy_vendor_record ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-fresh","refreshToken":"sk-ant-ort01-fresh","expiresAt":4102444800000,"refreshTokenExpiresAt":4102444800000,"scopes":["user:inference","user:sessions:claude_code"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}})

  describe "banking refuses a hollow credential" do
    test "harvesting a hollow vendor record refuses, names it, and banks nothing", ctx do
      store = Path.join([ctx.base, "auth", "claude", ".credentials.json"])
      home = Path.join([ctx.base, "homes", "eezo", "claude"])
      File.mkdir_p!(Path.dirname(store))
      File.mkdir_p!(home)

      good =
        ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-good","refreshToken":"sk-ant-ort01-good","expiresAt":4102444800000}})

      File.write!(store, good)

      # The shape observed on gibson: every key present, every value empty or zero.
      File.write!(
        Path.join(home, ".credentials.json"),
        @hollow_vendor_record
      )

      # THE SWEEP SURVIVES IT. This runs on the gateway boot path, where a raise is not a
      # refusal anyone reads -- it is a kernel panic and a gateway that will not start.
      # Refusing to bank is the requirement; taking the org down to announce it is not.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Tightbeam.Homes.sweep_auth(ctx.base, :claude)
        end)

      # NAMED, not merely refused: the operator has to be able to find the file. The home
      # rather than the file itself, because the credential FILENAME is private to each
      # harness module and exposing it would mean a new behaviour callback on every
      # harness — a wider change than this fix earns. The home holds one credential.
      assert log =~ home
      assert log =~ "accessToken"

      # And the good credential is still standing. This is the half that matters:
      # refusing to bank is worthless if the store was already overwritten.
      assert File.read!(store) == good
    end

    # ONE POISONED HOME MUST NOT COST THE OTHERS. `sweep_auth/2` globs `homes/*/<harness>`,
    # so an exception escaping one iteration would abort the `Enum.each` over every
    # remaining home -- and, one level up, over every remaining harness.
    test "a hollow home does not stop the sweep from harvesting the healthy ones", ctx do
      store = Path.join([ctx.base, "auth", "claude", ".credentials.json"])
      File.mkdir_p!(Path.dirname(store))
      File.write!(store, ~s({"claudeAiOauth":{"accessToken":"old","expiresAt":1}}))

      # `aaa` sorts before `zzz`, so the poisoned home is swept FIRST and the healthy one
      # only lands if the sweep kept going.
      hollow_home = Path.join([ctx.base, "homes", "aaa", "claude"])
      healthy_home = Path.join([ctx.base, "homes", "zzz", "claude"])
      File.mkdir_p!(hollow_home)
      File.mkdir_p!(healthy_home)

      File.write!(
        Path.join(hollow_home, ".credentials.json"),
        @hollow_vendor_record
      )

      rotated = @healthy_vendor_record

      File.write!(Path.join(healthy_home, ".credentials.json"), rotated)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Tightbeam.Homes.sweep_auth(ctx.base, :claude)
      end)

      assert File.read!(store) == rotated
    end

    test "store_harvested refuses hollow bytes rather than writing them", ctx do
      store = Path.join([ctx.base, "auth", "claude", ".credentials.json"])
      File.mkdir_p!(Path.dirname(store))
      File.write!(store, ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-good"}}))

      assert_raise RuntimeError, fn ->
        Credentials.store_harvested(
          ctx.base,
          :anthropic,
          @hollow_vendor_record
        )
      end

      assert File.read!(store) == ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-good"}})
    end

    test "an empty credential file is refused too", ctx do
      File.mkdir_p!(Path.join([ctx.base, "auth", "claude"]))

      assert_raise RuntimeError, fn ->
        Credentials.store_harvested(ctx.base, :anthropic, "")
      end
    end

    # THE REGRESSION THIS GUARD COULD EASILY CAUSE. An anthropic `.credentials.json` is
    # not always an OAuth record: `bank_anthropic_api_key` (ceremonies.rs:775) writes a
    # BARE KEY STRING to the same filename. A validator that assumed JSON would refuse
    # every api_key install on this path.
    test "a bare api key still harvests — it is not an OAuth record", ctx do
      store = Path.join([ctx.base, "auth", "claude", ".credentials.json"])
      home = Path.join([ctx.base, "homes", "eezo", "claude"])
      File.mkdir_p!(Path.dirname(store))
      File.mkdir_p!(home)
      File.write!(store, "sk-ant-api03-old")
      File.write!(Path.join(home, ".credentials.json"), "sk-ant-api03-rotated")

      assert :ok = Tightbeam.Homes.sweep_auth(ctx.base, :claude)
      assert File.read!(store) == "sk-ant-api03-rotated"
    end

    test "a healthy vendor rotation still harvests", ctx do
      store = Path.join([ctx.base, "auth", "claude", ".credentials.json"])
      home = Path.join([ctx.base, "homes", "eezo", "claude"])
      File.mkdir_p!(Path.dirname(store))
      File.mkdir_p!(home)

      File.write!(
        store,
        ~s({"claudeAiOauth":{"accessToken":"old","refreshToken":"r","expiresAt":1}})
      )

      rotated = @healthy_vendor_record

      File.write!(Path.join(home, ".credentials.json"), rotated)

      assert :ok = Tightbeam.Homes.sweep_auth(ctx.base, :claude)
      assert File.read!(store) == rotated
    end

    # THE REGRESSION AT ITS REAL ALTITUDE: not `sweep_auth/2`, but the function
    # `Application.start/2` actually calls.
    #
    # `sweep_auth/2` returning `:ok` proves the sweep survives; it does NOT prove the BOOT
    # survives, and the two are different claims — `children_after_preflight/1` is where the
    # sweep is invoked (gateway.ex), and `application.ex` runs it with no rescue around it.
    # Asserting at the boot function is what would also catch a NEW raising call added to
    # this path later, which a test aimed at `sweep_auth` alone would sail straight past.
    test "a hollow home does not stop the gateway from composing its boot children", ctx do
      store = Path.join([ctx.base, "auth", "claude", ".credentials.json"])
      home = Path.join([ctx.base, "homes", "eezo", "claude"])
      File.mkdir_p!(Path.dirname(store))
      File.mkdir_p!(home)
      File.write!(store, @healthy_vendor_record)
      File.write!(Path.join(home, ".credentials.json"), @hollow_vendor_record)

      db = :"credentials_boot_#{System.unique_integer([:positive])}"
      start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
      :ok = Tightbeam.Schema.ensure_all(db)

      config = %{
        db: db,
        base_dir: ctx.base,
        port: 4_321,
        cwd: ctx.base,
        default_harness: :claude,
        default_model: Tightbeam.Model.new("claude-fable-5"),
        max_live_sessions_per_user: 50,
        wake_tick_ms: 60_000,
        onboarding_lease_ms: 1_800_000
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert [_ | _] = Tightbeam.Gateway.children_after_preflight(config)
        end)

      # It refused, and it said so where an operator looks.
      assert log =~ home

      # And the credential every OTHER agent depends on is untouched.
      assert File.read!(store) == @healthy_vendor_record
    end

    # ROUTE 2 OF 3: the ceremony's own bank. Proved by test rather than by construction --
    # this one goes through `write_credential!/3` and `atomic_write!`, a different mechanism
    # from the harvest route above, and a guard that is never exercised is not a guard.
    test "the onboarding ceremony refuses to bank a hollow credential", ctx do
      {:ok, server} = Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")
      {:ok, staging, lease_id} = Credentials.begin_onboard(:anthropic, server)

      File.write!(
        Path.join(staging, ".credentials.json"),
        @hollow_vendor_record
      )

      # A REFUSAL, not a crash. Writing this test is what caught that a raise here killed
      # the Credentials GenServer and reached the operator as an exit instead of a sentence
      # — the guard "worked" and reported nothing anyone could act on.
      assert {:error, {:hollow_credential, %{found: found}}} =
               Credentials.finish_onboard(:anthropic, :subscription, lease_id, server)

      assert found =~ "accessToken"
      assert Process.alive?(server)
      refute File.exists?(Path.join([ctx.base, "auth", "claude", ".credentials.json"]))
    end

    # ROUTE 3 OF 3: `harvest_auth_back/4`, reached through home reconciliation. This is the
    # door that most needed its own test: it is `File.read!` + `File.cp!` in a loop, NOT
    # `atomic_write!`, so "the good credential survives" rests on a different mechanism than
    # the route that was already covered.
    test "reconciling a home refuses to copy a hollow credential over the store", ctx do
      store_dir = Path.join([ctx.base, "auth", "claude"])
      store = Path.join(store_dir, ".credentials.json")
      File.mkdir_p!(store_dir)

      good =
        ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-good","refreshToken":"sk-ant-ort01-good","expiresAt":4102444800000}})

      File.write!(store, good)

      home = Tightbeam.Homes.home_path(ctx.base, "eezo", :claude)
      File.mkdir_p!(home)

      # A REGULAR file in the home, not the symlink reconcile normally leaves: that is
      # exactly the "left by runtime rotation" state harvest exists to pick up.
      File.write!(
        Path.join(home, ".credentials.json"),
        @hollow_vendor_record
      )

      assert_raise RuntimeError, fn ->
        Tightbeam.Homes.project(ctx.base, %{harness: :claude, machine: "eezo", rails: nil})
      end

      assert File.read!(store) == good
    end

    # F3: the shapes the `is_map` guard let through. A PRESENT `claudeAiOauth` that carries
    # no record is hollow by the same reasoning as an empty token — it announces an OAuth
    # credential and holds nothing to authenticate with.
    test "a claudeAiOauth key that is not an OAuth record is hollow", ctx do
      File.mkdir_p!(Path.join([ctx.base, "auth", "claude"]))

      for bytes <- [
            ~s({"claudeAiOauth":null}),
            ~s({"claudeAiOauth":""}),
            ~s({"claudeAiOauth":[]}),
            ~s({"claudeAiOauth":"sk-ant-oat01-looks-like-a-token"})
          ] do
        assert_raise RuntimeError, fn ->
          Credentials.store_harvested(ctx.base, :anthropic, bytes)
        end
      end
    end
  end

  describe "daemon credential delivery" do
    test "stages a fixed OpenCode Go credential without returning a path", ctx do
      credentials_directory = Path.join(ctx.base, "daemon-credentials")
      File.mkdir_p!(credentials_directory)
      File.chmod!(credentials_directory, 0o700)
      source = Path.join(credentials_directory, "opencode-go-api-key")
      File.write!(source, "fake-daemon-key\n")
      File.chmod!(source, 0o600)

      {:ok, server} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          credentials_directory: credentials_directory,
          machine: "eezo"
        )

      assert {:ok, lease_id} = Credentials.begin_daemon_onboard(:opencode_go, server)
      assert is_binary(lease_id)
      staging = :sys.get_state(server).pending.opencode_go.path
      assert File.dir?(staging)
      assert :ok = Credentials.finish_onboard(:opencode_go, :api_key, lease_id, server)
      refute File.exists?(staging)

      store = Path.join([ctx.base, "auth", "pi", "auth.json"])

      assert JSON.decode!(File.read!(store)) == %{
               "opencode-go" => %{"type" => "api_key", "key" => "fake-daemon-key"}
             }

      assert File.read!(source) == "fake-daemon-key\n"
      assert File.stat!(store).mode |> Bitwise.band(0o777) == 0o600
    end

    test "refuses a symlink or permissions visible to another user", ctx do
      credentials_directory = Path.join(ctx.base, "daemon-credentials")
      File.mkdir_p!(credentials_directory)
      File.chmod!(credentials_directory, 0o700)
      target = Path.join(ctx.base, "target-key")
      File.write!(target, "fake-daemon-key")
      File.chmod!(target, 0o600)
      source = Path.join(credentials_directory, "opencode-go-api-key")
      File.ln_s!(target, source)

      {:ok, server} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          credentials_directory: credentials_directory,
          machine: "eezo"
        )

      File.chmod!(credentials_directory, 0o750)

      assert {:error, {:daemon_credential_unavailable, :credentials_directory_not_private}} =
               Credentials.begin_daemon_onboard(:opencode_go, server)

      File.chmod!(credentials_directory, 0o700)

      assert {:error, {:daemon_credential_unavailable, {:credential_file_not_regular, :symlink}}} =
               Credentials.begin_daemon_onboard(:opencode_go, server)

      File.rm!(source)
      File.write!(source, "fake-daemon-key")
      File.chmod!(source, 0o640)

      assert {:error, {:daemon_credential_unavailable, :credential_file_not_private}} =
               Credentials.begin_daemon_onboard(:opencode_go, server)
    end

    test "refuses daemon delivery to a remote credential owner", ctx do
      credentials_directory = Path.join(ctx.base, "daemon-credentials")
      File.mkdir_p!(credentials_directory)
      File.chmod!(credentials_directory, 0o700)

      {:ok, server} =
        Credentials.start_link(
          name: nil,
          base_dir: ctx.base,
          credentials_directory: credentials_directory,
          machine: "worker",
          ssh: "worker"
        )

      assert {:error, :daemon_credential_requires_local_host} =
               Credentials.begin_daemon_onboard(:opencode_go, server)
    end
  end

  defp credential_metadata(base, harness) do
    [base, "auth", harness, ".tightbeam", "credential.json"]
    |> Path.join()
    |> File.read!()
    |> JSON.decode!()
  end

  defp remote_server(base) do
    Credentials.start_link(
      name: nil,
      base_dir: base,
      machine: "worker",
      ssh: "worker",
      sh: fn command ->
        remote_command = command |> Enum.drop(6) |> Enum.join(" ")
        System.cmd("sh", ["-c", remote_command], stderr_to_stdout: true)
      end
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

  defp collect_remote_finish_commands(acc) do
    receive do
      {:remote_finish_command, command} ->
        collect_remote_finish_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp run_remote_command(command) do
    remote_command = command |> Enum.drop(6) |> Enum.join(" ")
    System.cmd("sh", ["-c", remote_command], stderr_to_stdout: true)
  end
end
