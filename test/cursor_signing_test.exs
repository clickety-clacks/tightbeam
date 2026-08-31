defmodule Tightbeam.CursorSigningTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias Tightbeam.CursorSigning
  alias Tightbeam.CursorSigning.Error
  alias Tightbeam.Wire.Router

  @domain_separator <<"tightbeam/rest-read-plane-d1/cursor/v1", 0>>

  setup_all do
    control_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-cursor-signing-probe-preflight-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(control_dir)
    on_exit(fn -> File.rm_rf!(control_dir) end)
    probe = compile_filesystem_probe!(control_dir)
    fcntl_probe = compile_fcntl_forwarding_probe!(control_dir)
    base_dir = Path.join(control_dir, "base")
    active_path = Path.join([base_dir, "secrets", "rest-cursor-signing.v1"])
    ready_marker = Path.join(control_dir, "probe-ready")
    failure_marker = Path.join(control_dir, "stage-sync-failed")
    unrelated_failure_marker = Path.join(control_dir, "unrelated-sync-failed")
    unrelated_path = Path.join(control_dir, "unrelated")
    fcntl_ready_marker = Path.join(control_dir, "fcntl-probe-ready")
    fcntl_path = Path.join(control_dir, "fcntl-path")

    if fcntl_probe != nil do
      fcntl_environment =
        filesystem_probe_environment(probe, active_path) ++
          [{"CURSOR_SIGNING_TEST_PROBE_READY", fcntl_ready_marker}]

      case run_reaped_executable(fcntl_probe, [fcntl_path], fcntl_environment) do
        {"fcntl-forwarding-ok", 0} ->
          unless File.exists?(fcntl_ready_marker) do
            raise "cursor filesystem fcntl preflight did not load the probe"
          end

        {output, status} ->
          raise "cursor filesystem fcntl forwarding preflight failed: status=#{status} output=#{inspect(output)}"
      end
    end

    script = """
    [base_dir] = System.argv()
    {:error, %Tightbeam.CursorSigning.Error{}} = Tightbeam.CursorSigning.provision(base_dir)
    IO.binwrite("refused")
    """

    environment =
      filesystem_probe_environment(probe, active_path) ++
        [
          {"CURSOR_SIGNING_TEST_PROBE_READY", ready_marker},
          {"CURSOR_SIGNING_TEST_FAIL_STAGE_SYNC_ALWAYS", "1"},
          {"CURSOR_SIGNING_TEST_FSYNC_FAILED", failure_marker}
        ]

    case external_instrumented_elixir(script, [base_dir], environment) do
      {"refused", 0} ->
        unless File.exists?(ready_marker) and File.exists?(failure_marker) do
          raise "cursor filesystem probe preflight did not activate fault injection"
        end

      {output, status} ->
        raise "cursor filesystem probe preflight failed: status=#{status} output=#{inspect(output)}"
    end

    unrelated_script = """
    [path] = System.argv()
    {:ok, file} = File.open(path, [:write, :binary])
    :ok = IO.binwrite(file, "unrelated")
    :ok = :file.sync(file)
    :ok = File.close(file)
    IO.binwrite("unrelated-synced")
    """

    unrelated_environment =
      filesystem_probe_environment(probe, active_path) ++
        [
          {"CURSOR_SIGNING_TEST_PROBE_READY", ready_marker},
          {"CURSOR_SIGNING_TEST_FAIL_STAGE_SYNC_ALWAYS", "1"},
          {"CURSOR_SIGNING_TEST_FSYNC_FAILED", unrelated_failure_marker}
        ]

    case external_instrumented_elixir(
           unrelated_script,
           [unrelated_path],
           unrelated_environment
         ) do
      {"unrelated-synced", 0} ->
        if File.exists?(unrelated_failure_marker) do
          raise "cursor filesystem probe preflight faulted an unrelated file"
        end

      {output, status} ->
        raise "cursor filesystem probe confinement preflight failed: status=#{status} output=#{inspect(output)}"
    end

    :ok
  end

  setup do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-cursor-signing-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{base_dir: base_dir}
  end

  test "absent material selects unprovisioned state until explicit first provisioning", ctx do
    assert {:ok, provider} = CursorSigning.load(ctx.base_dir)
    assert :unprovisioned = CursorSigning.lifecycle(provider)
    assert {:error, :cursor_signing_unprovisioned} = CursorSigning.validate(provider)
    assert {:error, :cursor_signing_unprovisioned} = CursorSigning.sign(provider, "cursor")

    assert {:error, :cursor_signing_unprovisioned} =
             CursorSigning.verify(provider, "cursor", <<0::256>>)

    assert {:error, :cursor_signing_unprovisioned} = CursorSigning.rotate(provider)
    assert {:error, :cursor_signing_unprovisioned} = CursorSigning.recover(provider)

    assert :ok = CursorSigning.provision(ctx.base_dir)
    assert :healthy = CursorSigning.lifecycle(provider)

    directory = Path.join(ctx.base_dir, "secrets")
    record = Path.join(directory, "rest-cursor-signing.v1")

    assert %File.Stat{type: :directory, mode: directory_mode} = File.lstat!(directory)
    assert Bitwise.band(directory_mode, 0o777) == 0o700

    assert %File.Stat{type: :regular, mode: record_mode, size: 32} = File.lstat!(record)
    assert Bitwise.band(record_mode, 0o777) == 0o600
    assert :ok = CursorSigning.validate(provider)
    before_second_provision = sign!(provider, "existing-record")

    assert {:error, %Error{reason: :already_provisioned}} =
             CursorSigning.provision(ctx.base_dir)

    assert sign!(provider, "existing-record") == before_second_provision
  end

  test "concurrent first provisioning creates exactly one complete record", ctx do
    directory = Path.join(ctx.base_dir, "secrets")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)

    results =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> CursorSigning.provision(ctx.base_dir) end) end)
      |> Task.await_many()

    assert Enum.count(results, &(&1 == :ok)) == 1

    assert Enum.count(results, fn
             {:error, %Error{reason: :already_provisioned}} -> true
             {:error, :cursor_signing_mutation_in_progress} -> true
             _other -> false
           end) == 7

    assert :ok = ctx.base_dir |> CursorSigning.load!() |> CursorSigning.validate()
  end

  test "first provisioning atomically refuses a destination created at publication", ctx do
    control_dir = Path.join(ctx.base_dir, "no-clobber-proof")
    File.mkdir_p!(control_dir)
    probe = compile_filesystem_probe!(control_dir)
    active_path = Path.join([ctx.base_dir, "secrets", "rest-cursor-signing.v1"])
    rename_ready = Path.join(control_dir, "rename-ready")
    rename_go = Path.join(control_dir, "rename-go")

    publication =
      Task.async(fn ->
        script = """
        [base_dir] = System.argv()

        {:error, %Tightbeam.CursorSigning.Error{reason: :already_provisioned}} =
          Tightbeam.CursorSigning.provision(base_dir)

        IO.binwrite("refused")
        """

        environment =
          filesystem_probe_environment(probe, active_path) ++
            [
              {"CURSOR_SIGNING_TEST_RENAME_READY", rename_ready},
              {"CURSOR_SIGNING_TEST_RENAME_GO", rename_go}
            ]

        external_instrumented_elixir(script, [ctx.base_dir], environment)
      end)

    await_file!(rename_ready)
    planted = :crypto.strong_rand_bytes(32)
    File.write!(active_path, planted)
    File.chmod!(active_path, 0o600)
    File.write!(rename_go, "")

    assert {"refused", 0} = Task.await(publication, 30_000)
    assert File.read!(active_path) == planted
    assert File.ls!(Path.dirname(active_path)) == ["rest-cursor-signing.v1"]
  end

  test "signing always prepends the fixed cursor domain separator", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)
    body = "canonical-cursor-body"
    signature = sign!(provider, body)
    material = File.read!(Path.join([ctx.base_dir, "secrets", "rest-cursor-signing.v1"]))

    expected = :crypto.mac(:hmac, :sha256, material, [@domain_separator, body])
    unscoped = :crypto.mac(:hmac, :sha256, material, body)

    assert Plug.Crypto.secure_compare(signature, expected)
    refute Plug.Crypto.secure_compare(signature, unscoped)
  end

  test "restart and separate OS processes use the same current record", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    first_provider = CursorSigning.load!(ctx.base_dir)
    first = sign!(first_provider, "stable-input")

    restarted_provider = CursorSigning.load!(ctx.base_dir)
    assert sign!(restarted_provider, "stable-input") == first

    external =
      1..2
      |> Enum.map(fn _ -> external_signature(ctx.base_dir, "stable-input") end)

    assert external == [first, first]
  end

  test "atomic rotation invalidates old signatures without a grace key", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)
    old_signature = sign!(provider, "bound-cursor")

    assert :ok = CursorSigning.rotate(provider)
    new_signature = sign!(provider, "bound-cursor")

    refute new_signature == old_signature
    assert {:ok, false} = CursorSigning.verify(provider, "bound-cursor", old_signature)
    assert {:ok, true} = CursorSigning.verify(provider, "bound-cursor", new_signature)

    restarted_provider = CursorSigning.load!(ctx.base_dir)
    assert sign!(restarted_provider, "bound-cursor") == new_signature
    assert external_signature(ctx.base_dir, "bound-cursor") == new_signature
  end

  test "durable provisioning and rotation survive immediate VM termination", ctx do
    assert 137 == external_durable_operation(ctx.base_dir, "provision")

    first_provider = CursorSigning.load!(ctx.base_dir)
    old_signature = sign!(first_provider, "durable-cursor")

    assert 137 == external_durable_operation(ctx.base_dir, "rotate")

    restarted_provider = CursorSigning.load!(ctx.base_dir)
    new_signature = sign!(restarted_provider, "durable-cursor")

    refute new_signature == old_signature

    assert {:ok, false} =
             CursorSigning.verify(restarted_provider, "durable-cursor", old_signature)

    assert {:ok, true} = CursorSigning.verify(restarted_provider, "durable-cursor", new_signature)
    assert File.ls!(Path.join(ctx.base_dir, "secrets")) == ["rest-cursor-signing.v1"]
  end

  test "pre-publication failure matrix preserves unprovisioned or prior restart authority", ctx do
    for operation <- [:provision, :rotate] do
      base_dir = Path.join(ctx.base_dir, "pre-publication-#{operation}")
      control_dir = Path.join(ctx.base_dir, "pre-publication-proof-#{operation}")
      File.mkdir_p!(control_dir)

      prior_material =
        if operation == :rotate do
          record = write_material_fixture!(base_dir)
          File.read!(record)
        end

      probe = compile_filesystem_probe!(control_dir)
      active_path = Path.join([base_dir, "secrets", "rest-cursor-signing.v1"])
      failure_marker = Path.join(control_dir, "stage-fsync-failed")

      assert {"refused", 0} =
               external_cursor_operation(base_dir, "#{operation}-refused",
                 probe: probe,
                 active_path: active_path,
                 failure_marker: failure_marker,
                 failure_mode: "stage-sync"
               )

      assert File.exists?(failure_marker)
      restarted = CursorSigning.load!(base_dir)

      case operation do
        :provision ->
          assert :unprovisioned = CursorSigning.lifecycle(restarted)
          assert File.ls!(Path.dirname(active_path)) == []

        :rotate ->
          assert :healthy = CursorSigning.lifecycle(restarted)
          assert File.read!(active_path) == prior_material
          assert File.ls!(Path.dirname(active_path)) == ["rest-cursor-signing.v1"]
      end
    end
  end

  test "post-publish directory failure is terminal and restart recovers the canonical file",
       ctx do
    control_dir = Path.join(ctx.base_dir, "fsync-proof")
    File.mkdir_p!(control_dir)
    probe = compile_filesystem_probe!(control_dir)
    active_path = Path.join([ctx.base_dir, "secrets", "rest-cursor-signing.v1"])
    provision_failure = Path.join(control_dir, "provision-fsync-failed")

    assert {"indeterminate", 0} =
             external_cursor_operation(ctx.base_dir, "provision",
               probe: probe,
               active_path: active_path,
               failure_marker: provision_failure,
               failure_mode: "active-exists"
             )

    assert File.exists?(provision_failure)
    provider = CursorSigning.load!(ctx.base_dir)
    old_signature = sign!(provider, "fsync-failure-cursor")

    assert {:ok, true} =
             CursorSigning.verify(provider, "fsync-failure-cursor", old_signature)

    assert File.ls!(Path.dirname(active_path)) == ["rest-cursor-signing.v1"]

    rotation_failure = Path.join(control_dir, "rotation-fsync-failed")

    assert {"indeterminate", 0} =
             external_cursor_operation(ctx.base_dir, "rotate",
               probe: probe,
               active_path: active_path,
               failure_marker: rotation_failure,
               failure_mode: "after-rename"
             )

    assert File.exists?(rotation_failure)
    restarted_provider = CursorSigning.load!(ctx.base_dir)
    new_signature = sign!(restarted_provider, "fsync-failure-cursor")

    refute old_signature == new_signature

    assert {:ok, false} =
             CursorSigning.verify(restarted_provider, "fsync-failure-cursor", old_signature)

    assert {:ok, true} =
             CursorSigning.verify(restarted_provider, "fsync-failure-cursor", new_signature)
  end

  test "power-loss restart matrices select only the restored canonical authority", ctx do
    input = "power-loss-cursor"
    old_material = :crypto.strong_rand_bytes(32)
    new_material = :crypto.strong_rand_bytes(32)

    old_signature =
      :crypto.mac(:hmac, :sha256, old_material, [@domain_separator, input])

    new_signature =
      :crypto.mac(:hmac, :sha256, new_material, [@domain_separator, input])

    for {name, restored, accepted, rejected} <- [
          {:old, old_material, old_signature, new_signature},
          {:new, new_material, new_signature, old_signature}
        ] do
      base_dir = Path.join(ctx.base_dir, "rotation-power-loss-#{name}")
      active_path = write_material_fixture!(base_dir, restored)
      restarted = CursorSigning.load!(base_dir)

      assert :healthy = CursorSigning.lifecycle(restarted)
      assert sign!(restarted, input) == accepted
      assert {:ok, true} = CursorSigning.verify(restarted, input, accepted)
      assert {:ok, false} = CursorSigning.verify(restarted, input, rejected)
      assert File.read!(active_path) == restored
      assert File.ls!(Path.dirname(active_path)) == ["rest-cursor-signing.v1"]
    end

    absent_base = Path.join(ctx.base_dir, "provision-power-loss-absent")
    absent = CursorSigning.load!(absent_base)
    assert :unprovisioned = CursorSigning.lifecycle(absent)
    assert {:error, :cursor_signing_unprovisioned} = CursorSigning.recover(absent)
    assert :ok = CursorSigning.provision(absent_base)
    assert :healthy = CursorSigning.lifecycle(absent)

    published_base = Path.join(ctx.base_dir, "provision-power-loss-published")
    published_material = :crypto.strong_rand_bytes(32)
    published_path = write_material_fixture!(published_base, published_material)
    published = CursorSigning.load!(published_base)
    expected = :crypto.mac(:hmac, :sha256, published_material, [@domain_separator, input])

    assert :healthy = CursorSigning.lifecycle(published)
    assert sign!(published, input) == expected
    assert File.read!(published_path) == published_material
    assert File.ls!(Path.dirname(published_path)) == ["rest-cursor-signing.v1"]
  end

  test "indeterminate commit quarantines every consumer until canonical-file recovery", ctx do
    control_dir = Path.join(ctx.base_dir, "quarantine-proof")
    File.mkdir_p!(control_dir)
    probe = compile_filesystem_probe!(control_dir)
    active_path = Path.join([ctx.base_dir, "secrets", "rest-cursor-signing.v1"])
    failure_marker = Path.join(control_dir, "directory-fsync-failed")

    write_material_fixture!(ctx.base_dir)

    {provider, host} =
      start_observer_host!(ctx.base_dir, control_dir, probe, [
        {"CURSOR_SIGNING_TEST_FAIL_AFTER_RENAME", "1"},
        {"CURSOR_SIGNING_TEST_FSYNC_FAILED", failure_marker}
      ])

    router_opts =
      Router.init(
        cursor_signing: provider,
        handlers: %{},
        base_dir: ctx.base_dir,
        cli_token: "tbc_quarantine"
      )

    assert {:indeterminate_commit, :cursor_signing_authority_may_have_advanced} =
             CursorSigning.rotate(provider)

    assert File.exists?(failure_marker)
    assert :quarantined = CursorSigning.lifecycle(provider)
    assert {:error, :cursor_signing_quarantined} = CursorSigning.sign(provider, "cursor")

    assert {:error, :cursor_signing_quarantined} =
             CursorSigning.verify(provider, "cursor", <<0::256>>)

    assert {:error, :cursor_signing_quarantined} = CursorSigning.provision(ctx.base_dir)
    assert {:error, :cursor_signing_quarantined} = CursorSigning.rotate(provider)

    response = conn(:get, "/version") |> Router.call(router_opts)

    assert response.status == 500
    assert Plug.Conn.get_resp_header(response, "cache-control") == ["no-store"]
    assert JSON.decode!(response.resp_body) == %{"error" => %{"code" => "projection_invalid"}}

    File.write!(active_path, :crypto.strong_rand_bytes(31))
    File.chmod!(active_path, 0o600)
    assert {:error, :cursor_signing_recovery_refused} = CursorSigning.recover(provider)
    assert :quarantined = CursorSigning.lifecycle(provider)

    File.write!(active_path, :crypto.strong_rand_bytes(32))
    File.chmod!(active_path, 0o600)
    assert :ok = CursorSigning.recover(provider)
    assert :healthy = CursorSigning.lifecycle(provider)
    assert {:ok, _signature} = CursorSigning.sign(provider, "recovered-cursor")
    assert File.ls!(Path.dirname(active_path)) == ["rest-cursor-signing.v1"]

    stop_observer_host!(host, control_dir)
  end

  test "disconnected VMs refuse the pending boundary and observe terminal quarantine", ctx do
    control_dir = Path.join(ctx.base_dir, "disconnected-quarantine-proof")
    File.mkdir_p!(control_dir)
    probe = compile_filesystem_probe!(control_dir)
    active_path = write_material_fixture!(ctx.base_dir)
    consumer_ready = Path.join(control_dir, "consumer-ready")
    pending_go = Path.join(control_dir, "pending-go")
    pending_done = Path.join(control_dir, "pending-done")
    sync_ready = Path.join(control_dir, "directory-sync-ready")
    sync_go = Path.join(control_dir, "directory-sync-go")
    terminal = Path.join(control_dir, "indeterminate-terminal")
    quarantine_go = Path.join(control_dir, "quarantine-go")
    quarantine_done = Path.join(control_dir, "quarantine-done")
    mutation_stop = Path.join(control_dir, "mutation-stop")

    consumer =
      Task.async(fn ->
        script = """
        defmodule DisconnectedCursorConsumer do
          def run(base_dir, ready, pending_go, pending_done, quarantine_go, quarantine_done) do
            provider = Tightbeam.CursorSigning.load!(base_dir)
            {:ok, old_signature} = Tightbeam.CursorSigning.sign(provider, "boundary-cursor")
            File.write!(ready, "")

            await_file(pending_go, 30_000)
            assert_pending(Tightbeam.CursorSigning.sign(provider, "boundary-cursor"))
            assert_pending(Tightbeam.CursorSigning.verify(provider, "boundary-cursor", old_signature))
            assert_pending(Tightbeam.CursorSigning.provision(base_dir))
            assert_pending(Tightbeam.CursorSigning.rotate(provider))
            assert_pending(Tightbeam.CursorSigning.recover(provider))
            File.write!(pending_done, "")

            await_file(quarantine_go, 30_000)
            assert_quarantined(Tightbeam.CursorSigning.sign(provider, "boundary-cursor"))
            assert_quarantined(Tightbeam.CursorSigning.verify(provider, "boundary-cursor", old_signature))
            assert_quarantined(Tightbeam.CursorSigning.provision(base_dir))
            assert_quarantined(Tightbeam.CursorSigning.rotate(provider))
            assert_quarantined(Tightbeam.CursorSigning.recover(provider))
            File.write!(quarantine_done, "")
            IO.binwrite("consumer:" <> System.pid())
          end

          defp assert_pending({:error, :cursor_signing_mutation_in_progress}), do: :ok
          defp assert_quarantined({:error, :cursor_signing_quarantined}), do: :ok

          defp await_file(_path, 0), do: raise("consumer boundary timed out")

          defp await_file(path, attempts) do
            if File.exists?(path) do
              :ok
            else
              Process.sleep(2)
              await_file(path, attempts - 1)
            end
          end
        end

        DisconnectedCursorConsumer.run(Enum.at(System.argv(), 0), Enum.at(System.argv(), 1), Enum.at(System.argv(), 2), Enum.at(System.argv(), 3), Enum.at(System.argv(), 4), Enum.at(System.argv(), 5))
        """

        external_elixir(script, [
          ctx.base_dir,
          consumer_ready,
          pending_go,
          pending_done,
          quarantine_go,
          quarantine_done
        ])
      end)

    await_file!(consumer_ready)

    mutator =
      Task.async(fn ->
        script = """
        defmodule DisconnectedCursorMutator do
          def run(base_dir, terminal, stop) do
            provider = Tightbeam.CursorSigning.load!(base_dir)

            {:indeterminate_commit, :cursor_signing_authority_may_have_advanced} =
              Tightbeam.CursorSigning.rotate(provider)

            File.write!(terminal, "")
            await_file(stop, 30_000)
            IO.binwrite("mutator:" <> System.pid())
          end

          defp await_file(_path, 0), do: raise("mutator stop timed out")

          defp await_file(path, attempts) do
            if File.exists?(path) do
              :ok
            else
              Process.sleep(2)
              await_file(path, attempts - 1)
            end
          end
        end

        DisconnectedCursorMutator.run(Enum.at(System.argv(), 0), Enum.at(System.argv(), 1), Enum.at(System.argv(), 2))
        """

        environment =
          filesystem_probe_environment(probe, active_path) ++
            [
              {"CURSOR_SIGNING_TEST_FAIL_AFTER_RENAME", "1"},
              {"CURSOR_SIGNING_TEST_DIR_SYNC_READY", sync_ready},
              {"CURSOR_SIGNING_TEST_DIR_SYNC_GO", sync_go}
            ]

        external_instrumented_elixir(
          script,
          [ctx.base_dir, terminal, mutation_stop],
          environment
        )
      end)

    await_file!(sync_ready)
    File.write!(pending_go, "")
    await_file!(pending_done)
    File.write!(sync_go, "")
    await_file!(terminal)
    File.write!(quarantine_go, "")
    await_file!(quarantine_done)

    {consumer_output, 0} = Task.await(consumer, 30_000)
    File.write!(mutation_stop, "")
    {mutator_output, 0} = Task.await(mutator, 30_000)

    assert consumer_output =~ "consumer:"
    assert mutator_output =~ "mutator:"
    refute consumer_output == String.replace(mutator_output, "mutator:", "consumer:")
  end

  test "surviving disconnected VMs recover after the publishing VM dies", ctx do
    control_dir = Path.join(ctx.base_dir, "disconnected-owner-death-proof")
    File.mkdir_p!(control_dir)
    probe = compile_filesystem_probe!(control_dir)

    for recovery_outcome <- [:success, :sync_failure] do
      assert_disconnected_owner_death_recovery!(ctx, probe, recovery_outcome)
    end
  end

  test "persistent directory-sync failure refuses recovery and stays quarantined", ctx do
    control_dir = Path.join(ctx.base_dir, "persistent-sync-proof")
    File.mkdir_p!(control_dir)
    probe = compile_filesystem_probe!(control_dir)
    active_path = Path.join([ctx.base_dir, "secrets", "rest-cursor-signing.v1"])
    failure_marker = Path.join(control_dir, "directory-fsync-failed")

    {provider, host} =
      start_observer_host!(ctx.base_dir, control_dir, probe, [
        {"CURSOR_SIGNING_TEST_FAIL_WHEN_ACTIVE_EXISTS", "1"},
        {"CURSOR_SIGNING_TEST_FAIL_DIRECTORY_SYNC_ALWAYS", "1"},
        {"CURSOR_SIGNING_TEST_FSYNC_FAILED", failure_marker}
      ])

    assert {:indeterminate_commit, :cursor_signing_authority_may_have_advanced} =
             CursorSigning.provision(ctx.base_dir)

    assert File.exists?(active_path)
    assert File.exists?(failure_marker)
    assert :quarantined = CursorSigning.lifecycle(provider)
    assert {:error, :cursor_signing_recovery_refused} = CursorSigning.recover(provider)
    assert :quarantined = CursorSigning.lifecycle(provider)
    assert {:error, :cursor_signing_quarantined} = CursorSigning.sign(provider, "cursor")

    stop_observer_host!(host, control_dir)
  end

  test "exclusive mutation admission precedes lifecycle checks across application nodes", ctx do
    for operation <- [:provision, :rotate] do
      base_dir = Path.join(ctx.base_dir, Atom.to_string(operation))
      control_dir = Path.join(ctx.base_dir, "#{operation}-admission")
      File.mkdir_p!(control_dir)

      if operation == :rotate, do: write_material_fixture!(base_dir)

      probe = compile_filesystem_probe!(control_dir)
      active_path = Path.join([base_dir, "secrets", "rest-cursor-signing.v1"])
      stage_ready = Path.join(control_dir, "stage-sync-ready")
      stage_go = Path.join(control_dir, "stage-sync-go")

      {provider, host} =
        start_observer_host!(base_dir, control_dir, probe, [
          {"CURSOR_SIGNING_TEST_STAGE_SYNC_READY", stage_ready},
          {"CURSOR_SIGNING_TEST_STAGE_SYNC_GO", stage_go}
        ])

      parent = self()

      owner =
        spawn(fn ->
          result =
            case operation do
              :provision -> CursorSigning.provision(base_dir)
              :rotate -> CursorSigning.rotate(provider)
            end

          send(parent, {:mutation_winner, operation, result})
        end)

      assert is_pid(owner)
      await_file!(stage_ready)

      assert {:error, :cursor_signing_mutation_in_progress} =
               CursorSigning.provision(base_dir)

      assert {:error, :cursor_signing_mutation_in_progress} = CursorSigning.rotate(provider)
      assert {:error, :cursor_signing_mutation_in_progress} = CursorSigning.recover(provider)
      assert {:error, :cursor_signing_mutation_in_progress} = CursorSigning.sign(provider, "x")

      File.write!(stage_go, "")
      assert_receive {:mutation_winner, ^operation, :ok}, 15_000
      assert :healthy = CursorSigning.lifecycle(provider)
      assert File.ls!(Path.dirname(active_path)) == ["rest-cursor-signing.v1"]

      stop_observer_host!(host, control_dir)
    end
  end

  @tag timeout: 180_000
  test "all nine mutation pairs preserve admission across every terminal outcome", ctx do
    matrix_root = Path.join(ctx.base_dir, "mutation-outcome-matrix")
    File.mkdir_p!(matrix_root)
    probe = compile_filesystem_probe!(matrix_root)

    outcomes = %{
      provision: [:success, :prepublication_error, :indeterminate],
      rotate: [:success, :prepublication_error, :indeterminate],
      recover: [:success, :recovery_refused]
    }

    for winner <- [:provision, :rotate, :recover],
        loser <- [:provision, :rotate, :recover],
        outcome <- Map.fetch!(outcomes, winner) do
      assert_mutation_matrix_fixture!(ctx, probe, winner, loser, outcome)
    end
  end

  test "recovery owns mutation admission through success and canonical replacement refusal",
       ctx do
    for recovery_outcome <- [:success, :replaced] do
      base_dir = Path.join(ctx.base_dir, "recovery-#{recovery_outcome}")
      control_dir = Path.join(ctx.base_dir, "recovery-proof-#{recovery_outcome}")
      File.mkdir_p!(control_dir)
      probe = compile_filesystem_probe!(control_dir)
      active_path = Path.join([base_dir, "secrets", "rest-cursor-signing.v1"])
      sync_ready = Path.join(control_dir, "directory-sync-ready")
      sync_go = Path.join(control_dir, "directory-sync-go")

      {provider, host} =
        start_observer_host!(base_dir, control_dir, probe, [
          {"CURSOR_SIGNING_TEST_FAIL_AFTER_RENAME", "1"},
          {"CURSOR_SIGNING_TEST_DIR_SYNC_READY", sync_ready},
          {"CURSOR_SIGNING_TEST_DIR_SYNC_GO", sync_go}
        ])

      parent = self()

      provision_owner =
        spawn(fn -> send(parent, {:recovery_seed, CursorSigning.provision(base_dir)}) end)

      assert is_pid(provision_owner)
      await_file!(sync_ready)
      File.write!(sync_go, "")

      assert_receive {:recovery_seed,
                      {:indeterminate_commit, :cursor_signing_authority_may_have_advanced}},
                     15_000

      assert :quarantined = CursorSigning.lifecycle(provider)
      File.rm!(sync_ready)
      File.rm!(sync_go)

      recovery_owner =
        spawn(fn -> send(parent, {:recovery_result, CursorSigning.recover(provider)}) end)

      assert is_pid(recovery_owner)
      await_file!(sync_ready)

      assert {:error, :cursor_signing_mutation_in_progress} =
               CursorSigning.provision(base_dir)

      assert {:error, :cursor_signing_mutation_in_progress} = CursorSigning.rotate(provider)
      assert {:error, :cursor_signing_mutation_in_progress} = CursorSigning.recover(provider)
      assert {:error, :cursor_signing_mutation_in_progress} = CursorSigning.sign(provider, "x")

      if recovery_outcome == :replaced do
        replacement = Path.join(Path.dirname(active_path), ".replacement")
        File.write!(replacement, :crypto.strong_rand_bytes(32))
        File.chmod!(replacement, 0o600)
        File.rename!(replacement, active_path)
      end

      File.write!(sync_go, "")

      expected =
        case recovery_outcome do
          :success -> :ok
          :replaced -> {:error, :cursor_signing_recovery_refused}
        end

      assert_receive {:recovery_result, ^expected}, 15_000

      expected_lifecycle = if recovery_outcome == :success, do: :healthy, else: :quarantined
      assert ^expected_lifecycle = CursorSigning.lifecycle(provider)

      stop_observer_host!(host, control_dir)
    end
  end

  test "owner death after publication quarantines before mutation admission is released", ctx do
    for operation <- [:provision, :rotate] do
      base_dir = Path.join(ctx.base_dir, "owner-death-#{operation}")
      control_dir = Path.join(ctx.base_dir, "owner-death-proof-#{operation}")
      File.mkdir_p!(control_dir)

      if operation == :rotate, do: write_material_fixture!(base_dir)

      probe = compile_filesystem_probe!(control_dir)
      active_path = Path.join([base_dir, "secrets", "rest-cursor-signing.v1"])
      sync_ready = Path.join(control_dir, "directory-sync-ready")
      sync_go = Path.join(control_dir, "directory-sync-go")

      {provider, host} =
        start_observer_host!(base_dir, control_dir, probe, [
          {"CURSOR_SIGNING_TEST_DIR_SYNC_READY", sync_ready},
          {"CURSOR_SIGNING_TEST_DIR_SYNC_GO", sync_go}
        ])

      parent = self()

      owner =
        spawn(fn ->
          result =
            case operation do
              :provision -> CursorSigning.provision(base_dir)
              :rotate -> CursorSigning.rotate(provider)
            end

          send(parent, {:dead_owner_result, operation, result})
        end)

      await_file!(sync_ready)

      assert {:error, :cursor_signing_mutation_in_progress} =
               CursorSigning.provision(base_dir)

      assert {:error, :cursor_signing_mutation_in_progress} = CursorSigning.rotate(provider)
      assert {:error, :cursor_signing_mutation_in_progress} = CursorSigning.recover(provider)
      assert {:error, :cursor_signing_mutation_in_progress} = CursorSigning.sign(provider, "x")

      Process.exit(owner, :kill)
      await_lifecycle!(provider, :quarantined)

      assert {:error, :cursor_signing_quarantined} = CursorSigning.sign(provider, "x")
      assert {:error, :cursor_signing_quarantined} = CursorSigning.rotate(provider)
      assert {:error, :cursor_signing_quarantined} = CursorSigning.provision(base_dir)
      refute_receive {:dead_owner_result, ^operation, _result}, 100

      File.write!(sync_go, "")
      assert :ok = CursorSigning.recover(provider)
      assert :healthy = CursorSigning.lifecycle(provider)
      assert File.ls!(Path.dirname(active_path)) == ["rest-cursor-signing.v1"]

      stop_observer_host!(host, control_dir)
    end
  end

  test "a failed rotation preserves the old complete record", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)
    signature = sign!(provider, "preserved-cursor")
    directory = Path.join(ctx.base_dir, "secrets")

    File.chmod!(directory, 0o500)

    assert {:error, %Error{reason: :wrong_mode}} = CursorSigning.rotate(provider)

    File.chmod!(directory, 0o700)
    assert {:ok, true} = CursorSigning.verify(provider, "preserved-cursor", signature)
    assert File.ls!(directory) == ["rest-cursor-signing.v1"]
  end

  test "64 request processes in two application VMs linearize across rotation", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)
    before_rotation = sign!(provider, "concurrent-cursor")
    control_dir = Path.join(ctx.base_dir, "rotation-proof")
    File.mkdir_p!(control_dir)
    probe = compile_filesystem_probe!(control_dir)
    active_path = Path.join([ctx.base_dir, "secrets", "rest-cursor-signing.v1"])

    first_application =
      Task.async(fn -> external_concurrency_summary(ctx.base_dir, control_dir, "one") end)

    await_marker_count!(control_dir, "worker-ready-", 32)

    second_application =
      Task.async(fn -> external_concurrency_summary(ctx.base_dir, control_dir, "two") end)

    await_marker_count!(control_dir, "worker-ready-", 64)
    File.write!(Path.join(control_dir, "pre-go"), "")
    await_marker_count!(control_dir, "worker-pre-", 64)

    rotation =
      Task.async(fn ->
        external_rotation_at_boundary(ctx.base_dir, control_dir, probe, active_path)
      end)

    await_file!(Path.join(control_dir, "rename-ready"))
    File.write!(Path.join(control_dir, "during-before-go"), "")
    await_marker_count!(control_dir, "worker-during-before-", 64)

    File.write!(Path.join(control_dir, "rename-go"), "")
    await_file!(Path.join(control_dir, "rename-done"))
    File.write!(Path.join(control_dir, "during-after-go"), "")
    await_marker_count!(control_dir, "worker-during-after-", 64)

    File.write!(Path.join(control_dir, "rename-finish"), "")
    assert :ok = Task.await(rotation, 30_000)
    File.write!(Path.join(control_dir, "post-go"), "")
    await_marker_count!(control_dir, "worker-post-", 64)

    after_rotation = sign!(provider, "concurrent-cursor")
    refute after_rotation == before_rotation

    summaries = Task.await_many([first_application, second_application], 30_000)

    assert Enum.sum(Enum.map(summaries, & &1.workers)) == 64
    assert summaries |> Enum.map(& &1.os_pid) |> Enum.uniq() |> length() == 2

    assert Enum.all?(summaries, fn summary ->
             summary.workers == 32 and
               summary.valid == 32
           end)

    assert {:ok, false} = CursorSigning.verify(provider, "concurrent-cursor", before_rotation)
    assert {:ok, true} = CursorSigning.verify(provider, "concurrent-cursor", after_rotation)
  end

  test "loads reject malformed, permissive, and symlink records", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    record = Path.join([ctx.base_dir, "secrets", "rest-cursor-signing.v1"])

    File.write!(record, :crypto.strong_rand_bytes(31))
    File.chmod!(record, 0o600)
    assert {:error, %Error{reason: :invalid_material}} = CursorSigning.load(ctx.base_dir)

    File.write!(record, :crypto.strong_rand_bytes(32))
    File.chmod!(record, 0o640)
    assert {:error, %Error{reason: :wrong_mode}} = CursorSigning.load(ctx.base_dir)

    File.chmod!(record, 0o4600)
    assert {:error, %Error{reason: :wrong_mode}} = CursorSigning.load(ctx.base_dir)

    File.rm!(record)
    target = Path.join(ctx.base_dir, "symlink-target")
    File.write!(target, :crypto.strong_rand_bytes(32))
    File.chmod!(target, 0o600)
    File.ln_s!(target, record)

    assert {:error, %Error{reason: :invalid_material}} = CursorSigning.load(ctx.base_dir)
  end

  test "Router refuses missing and malformed provider injection before dispatch", ctx do
    assert_raise Error, "cursor signing is unavailable", fn -> Router.init(%{}) end

    assert_raise Error, "cursor signing is unavailable", fn ->
      Router.init(cursor_signing: :not_a_provider)
    end

    assert_raise Error, "cursor signing is unavailable", fn ->
      Tightbeam.Gateway.children_after_preflight(%{cursor_signing: :not_a_provider})
    end

    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)

    assert %{cursor_signing: ^provider} = Router.init(cursor_signing: provider)
  end

  test "provider inspection, failures, logs, and ordinary responses redact private state", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)

    assert inspect(provider) == "#Tightbeam.CursorSigning<...>"
    refute Exception.message(%Error{reason: :invalid_material}) =~ ctx.base_dir

    assert capture_log(fn ->
             assert {:ok, _signature} = CursorSigning.sign(provider, "private-input")
             assert {:error, %Error{}} = CursorSigning.sign(:invalid, "private-input")
           end) == ""

    response =
      conn(:get, "/version")
      |> Router.call(
        Router.init(
          cursor_signing: provider,
          handlers: %{},
          base_dir: ctx.base_dir,
          cli_token: "tbc_privacy"
        )
      )

    assert response.status == 200
    refute response.resp_body =~ ctx.base_dir
    refute response.resp_body =~ "cursor_signing"
  end

  defp sign!(provider, input) do
    {:ok, signature} = CursorSigning.sign(provider, input)
    signature
  end

  defp external_signature(base_dir, input) do
    script = """
    [base_dir, input] = System.argv()
    provider = Tightbeam.CursorSigning.load!(base_dir)
    {:ok, signature} = Tightbeam.CursorSigning.sign(provider, input)
    IO.binwrite(Base.encode16(signature, case: :lower))
    """

    {encoded, 0} = external_elixir(script, [base_dir, input])

    Base.decode16!(encoded, case: :lower)
  end

  defp external_durable_operation(base_dir, operation) do
    script = """
    [base_dir, operation] = System.argv()

    case operation do
      "provision" ->
        :ok = Tightbeam.CursorSigning.provision(base_dir)

      "rotate" ->
        provider = Tightbeam.CursorSigning.load!(base_dir)
        :ok = Tightbeam.CursorSigning.rotate(provider)
    end

    System.halt(137)
    """

    {"", status} = external_elixir(script, [base_dir, operation])
    status
  end

  defp external_cursor_operation(base_dir, operation, options) do
    script = """
    [base_dir, operation] = System.argv()

    output =
      case operation do
      "provision" ->
        {:indeterminate_commit, :cursor_signing_authority_may_have_advanced} =
          Tightbeam.CursorSigning.provision(base_dir)

        "indeterminate"

      "rotate" ->
        provider = Tightbeam.CursorSigning.load!(base_dir)
        {:indeterminate_commit, :cursor_signing_authority_may_have_advanced} =
          Tightbeam.CursorSigning.rotate(provider)

        "indeterminate"

      "provision-refused" ->
        {:error, %Tightbeam.CursorSigning.Error{}} =
          Tightbeam.CursorSigning.provision(base_dir)

        "refused"

      "rotate-refused" ->
        provider = Tightbeam.CursorSigning.load!(base_dir)
        {:error, %Tightbeam.CursorSigning.Error{}} = Tightbeam.CursorSigning.rotate(provider)
        "refused"
    end

    IO.binwrite(output)
    """

    environment =
      filesystem_probe_environment(options[:probe], options[:active_path]) ++
        [
          {"CURSOR_SIGNING_TEST_FSYNC_FAILED", options[:failure_marker]},
          {failure_environment_name(options[:failure_mode]), "1"}
        ]

    external_instrumented_elixir(script, [base_dir, operation], environment)
  end

  defp external_concurrency_summary(base_dir, control_dir, application_id) do
    script = """
    defmodule CursorSigningConcurrencyProbe do
      @workers 32

      def run(base_dir, control_dir, application_id) do
        provider = Tightbeam.CursorSigning.load!(base_dir)

        tasks =
          for index <- 1..@workers do
            Task.async(fn -> worker(provider, control_dir, application_id, index) end)
          end

        results = Task.await_many(tasks, 30_000)

        summary = %{
          application: application_id,
          os_pid: System.pid(),
          workers: @workers,
          valid: Enum.count(results, &(&1 == :ok))
        }

        IO.binwrite(summary |> :erlang.term_to_binary() |> Base.encode64())
      end

      defp worker(provider, control_dir, application_id, index) do
        File.write!(marker(control_dir, "ready", application_id, index), "")
        await_file(Path.join(control_dir, "pre-go"), 15_000)
        old_signature = sign!(provider)
        {:ok, true} = verify(provider, old_signature)
        File.write!(marker(control_dir, "pre", application_id, index), "")

        await_file(Path.join(control_dir, "during-before-go"), 15_000)
        {:error, :cursor_signing_mutation_in_progress} =
          Tightbeam.CursorSigning.sign(provider, "concurrent-cursor")

        {:error, :cursor_signing_mutation_in_progress} = verify(provider, old_signature)
        File.write!(marker(control_dir, "during-before", application_id, index), "")

        await_file(Path.join(control_dir, "during-after-go"), 15_000)
        {:error, :cursor_signing_mutation_in_progress} =
          Tightbeam.CursorSigning.sign(provider, "concurrent-cursor")

        {:error, :cursor_signing_mutation_in_progress} = verify(provider, old_signature)
        File.write!(marker(control_dir, "during-after", application_id, index), "")

        await_file(Path.join(control_dir, "post-go"), 15_000)
        {:ok, false} = verify(provider, old_signature)
        post_signature = sign!(provider)
        {:ok, true} = verify(provider, post_signature)
        File.write!(marker(control_dir, "post", application_id, index), "")
        :ok
      end

      defp marker(control_dir, phase, application_id, index) do
        name = Enum.join(["worker", phase, application_id, Integer.to_string(index)], "-")
        Path.join(control_dir, name)
      end

      defp await_file(_path, 0), do: raise("cursor concurrency barrier timed out")

      defp await_file(path, attempts) do
        if File.exists?(path) do
          :ok
        else
          Process.sleep(2)
          await_file(path, attempts - 1)
        end
      end

      defp sign!(provider) do
        {:ok, signature} = Tightbeam.CursorSigning.sign(provider, "concurrent-cursor")
        signature
      end

      defp verify(provider, signature) do
        Tightbeam.CursorSigning.verify(provider, "concurrent-cursor", signature)
      end
    end

    [base_dir, control_dir, application_id] = System.argv()
    CursorSigningConcurrencyProbe.run(base_dir, control_dir, application_id)
    """

    {encoded, 0} = external_elixir(script, [base_dir, control_dir, application_id])

    encoded
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
  end

  defp external_rotation_at_boundary(base_dir, control_dir, probe, active_path) do
    script = """
    [base_dir] = System.argv()
    provider = Tightbeam.CursorSigning.load!(base_dir)
    :ok = Tightbeam.CursorSigning.rotate(provider)
    IO.binwrite("ok")
    """

    environment =
      filesystem_probe_environment(probe, active_path) ++
        [
          {"CURSOR_SIGNING_TEST_RENAME_READY", Path.join(control_dir, "rename-ready")},
          {"CURSOR_SIGNING_TEST_RENAME_GO", Path.join(control_dir, "rename-go")},
          {"CURSOR_SIGNING_TEST_RENAME_DONE", Path.join(control_dir, "rename-done")},
          {"CURSOR_SIGNING_TEST_RENAME_FINISH", Path.join(control_dir, "rename-finish")}
        ]

    case external_instrumented_elixir(script, [base_dir], environment) do
      {"ok", 0} -> :ok
      {_output, _status} -> raise "cursor rotation boundary probe failed"
    end
  end

  defp assert_disconnected_owner_death_recovery!(ctx, probe, recovery_outcome) do
    fixture = Atom.to_string(recovery_outcome)
    base_dir = Path.join(ctx.base_dir, "disconnected-owner-death-base-#{fixture}")
    control_dir = Path.join(ctx.base_dir, "disconnected-owner-death-control-#{fixture}")
    File.mkdir_p!(control_dir)

    active_path = write_material_fixture!(base_dir)
    provider = CursorSigning.load!(base_dir)
    input = "disconnected-owner-death-cursor"
    old_signature = sign!(provider, input)
    consumer_ready = Path.join(control_dir, "consumer-ready")
    consumer_go = Path.join(control_dir, "consumer-go")
    consumer_result = Path.join(control_dir, "consumer-result")
    recovery_sync_ready = Path.join(control_dir, "recovery-sync-ready")
    recovery_sync_go = Path.join(control_dir, "recovery-sync-go")
    recovery_sync_failed = Path.join(control_dir, "recovery-sync-failed")
    recovery_sync_arm = Path.join(control_dir, "recovery-sync-arm")
    mutator_pid = Path.join(control_dir, "mutator-pid")
    mutator_sync_ready = Path.join(control_dir, "mutator-sync-ready")
    mutator_sync_go = Path.join(control_dir, "mutator-sync-go")

    consumer =
      Task.async(fn ->
        script = """
        defmodule DisconnectedOwnerDeathConsumer do
          def run(base_dir, input, outcome, ready, go, sync_arm, result_path) do
            provider = Tightbeam.CursorSigning.load!(base_dir)
            {:ok, _old_signature} = Tightbeam.CursorSigning.sign(provider, input)
            File.write!(sync_arm, "")
            File.write!(ready, "")
            await_file(go, 30_000)

            result = {
              String.to_atom(outcome),
              Tightbeam.CursorSigning.sign(provider, input),
              Tightbeam.CursorSigning.sign(provider, input),
              Tightbeam.CursorSigning.lifecycle(provider)
            }

            publish(result_path, result)
          end

          defp publish(path, term) do
            temporary = path <> ".tmp-" <> System.pid()
            encoded = term |> :erlang.term_to_binary() |> Base.encode64()
            File.write!(temporary, encoded, [:binary])
            File.rename!(temporary, path)
          end

          defp await_file(_path, 0), do: raise("owner-death consumer timed out")

          defp await_file(path, attempts) do
            if File.exists?(path) do
              :ok
            else
              Process.sleep(2)
              await_file(path, attempts - 1)
            end
          end
        end

        DisconnectedOwnerDeathConsumer.run(Enum.at(System.argv(), 0), Enum.at(System.argv(), 1), Enum.at(System.argv(), 2), Enum.at(System.argv(), 3), Enum.at(System.argv(), 4), Enum.at(System.argv(), 5), Enum.at(System.argv(), 6))
        """

        recovery_environment =
          case recovery_outcome do
            :success ->
              [
                {"CURSOR_SIGNING_TEST_RECOVERY_SYNC_ARM", recovery_sync_arm},
                {"CURSOR_SIGNING_TEST_RECOVERY_SYNC_READY", recovery_sync_ready},
                {"CURSOR_SIGNING_TEST_RECOVERY_SYNC_GO", recovery_sync_go}
              ]

            :sync_failure ->
              [
                {"CURSOR_SIGNING_TEST_RECOVERY_SYNC_ARM", recovery_sync_arm},
                {"CURSOR_SIGNING_TEST_FAIL_RECOVERY_SYNC_WHEN_ARMED", "1"},
                {"CURSOR_SIGNING_TEST_FAIL_DIRECTORY_SYNC_ALWAYS", "1"},
                {"CURSOR_SIGNING_TEST_FSYNC_FAILED", recovery_sync_failed}
              ]
          end

        external_instrumented_elixir(
          script,
          [
            base_dir,
            input,
            fixture,
            consumer_ready,
            consumer_go,
            recovery_sync_arm,
            consumer_result
          ],
          filesystem_probe_environment(probe, active_path) ++ recovery_environment
        )
      end)

    await_file!(consumer_ready)

    mutator =
      Task.async(fn ->
        script = """
        [base_dir, pid_path] = System.argv()
        temporary = pid_path <> ".tmp-" <> System.pid()
        File.write!(temporary, System.pid())
        File.rename!(temporary, pid_path)
        provider = Tightbeam.CursorSigning.load!(base_dir)
        Tightbeam.CursorSigning.rotate(provider)
        """

        external_instrumented_elixir(
          script,
          [base_dir, mutator_pid],
          filesystem_probe_environment(probe, active_path) ++
            [
              {"CURSOR_SIGNING_TEST_DIR_SYNC_READY", mutator_sync_ready},
              {"CURSOR_SIGNING_TEST_DIR_SYNC_GO", mutator_sync_go}
            ]
        )
      end)

    on_exit(fn ->
      Enum.each([consumer_go, recovery_sync_go, mutator_sync_go], &File.write(&1, ""))

      case File.read(mutator_pid) do
        {:ok, os_pid} -> kill_os_process(os_pid)
        {:error, _reason} -> :ok
      end

      await_process_exit!(consumer.pid)
      await_process_exit!(mutator.pid)
    end)

    await_file!(mutator_pid)
    await_file!(mutator_sync_ready)
    assert {_, 0} = kill_os_process(File.read!(mutator_pid))
    {_mutator_output, mutator_status} = Task.await(mutator, 30_000)
    refute mutator_status == 0

    File.write!(consumer_go, "")

    if recovery_outcome == :success do
      await_file!(recovery_sync_ready)
      refute File.exists?(consumer_result)
      File.write!(recovery_sync_go, "")
    end

    result = await_encoded_term!(consumer_result)
    {_consumer_output, 0} = Task.await(consumer, 30_000)

    case {recovery_outcome, result} do
      {:success, {:success, {:ok, recovered}, {:ok, repeated}, :healthy}} ->
        assert recovered == repeated
        refute recovered == old_signature
        assert sign!(provider, input) == recovered

      {:sync_failure,
       {:sync_failure, {:error, :cursor_signing_quarantined},
        {:error, :cursor_signing_quarantined}, :quarantined}} ->
        assert File.exists?(recovery_sync_failed)

      other ->
        flunk("unexpected disconnected owner-death result: #{inspect(other)}")
    end
  end

  defp kill_os_process(os_pid) do
    executable = System.find_executable("kill") || raise "kill is unavailable"
    System.cmd(executable, ["-KILL", String.trim(os_pid)], stderr_to_stdout: true)
  end

  defp assert_mutation_matrix_fixture!(ctx, probe, winner, loser, outcome) do
    fixture = Enum.join([winner, loser, outcome], "-")
    base_dir = Path.join(ctx.base_dir, "matrix-base-#{fixture}")
    control_dir = Path.join(ctx.base_dir, "matrix-control-#{fixture}")
    File.mkdir_p!(control_dir)

    if winner in [:rotate, :recover], do: write_material_fixture!(base_dir)

    active_path = Path.join([base_dir, "secrets", "rest-cursor-signing.v1"])
    loser_ready = Path.join(control_dir, "loser-ready")
    loser_go = Path.join(control_dir, "loser-go")
    loser_overlap = Path.join(control_dir, "loser-overlap")
    loser_post_go = Path.join(control_dir, "loser-post-go")
    loser_post = Path.join(control_dir, "loser-post")
    lock_ready = Path.join(control_dir, "lock-ready")
    lock_go = Path.join(control_dir, "lock-go")
    winner_result = Path.join(control_dir, "winner-result")
    winner_stop = Path.join(control_dir, "winner-stop")

    loser_task =
      Task.async(fn ->
        external_elixir(
          mutation_matrix_loser_script(),
          [
            base_dir,
            Atom.to_string(loser),
            loser_ready,
            loser_go,
            loser_overlap,
            loser_post_go,
            loser_post
          ]
        )
      end)

    await_file!(loser_ready)

    lock_ordinal = if winner == :recover, do: "4", else: "2"

    environment =
      filesystem_probe_environment(probe, active_path) ++
        mutation_matrix_failure_environment(winner, outcome) ++
        [
          {"CURSOR_SIGNING_TEST_LOCK_READY", lock_ready},
          {"CURSOR_SIGNING_TEST_LOCK_GO", lock_go},
          {"CURSOR_SIGNING_TEST_LOCK_ORDINAL", lock_ordinal}
        ]

    winner_task =
      Task.async(fn ->
        external_instrumented_elixir(
          mutation_matrix_winner_script(),
          [
            base_dir,
            Atom.to_string(winner),
            Atom.to_string(outcome),
            lock_ready,
            lock_go,
            winner_result,
            winner_stop
          ],
          environment
        )
      end)

    on_exit(fn ->
      Enum.each([loser_go, loser_post_go, lock_go, winner_stop], &File.write(&1, ""))
      await_process_exit!(loser_task.pid)
      await_process_exit!(winner_task.pid)
    end)

    await_file!(lock_ready)
    File.write!(loser_go, "")
    loser_overlap_result = await_encoded_term!(loser_overlap)

    assert loser_overlap_result ==
             {:error, :cursor_signing_mutation_in_progress}

    if winner == :recover and outcome == :recovery_refused do
      File.write!(active_path, :crypto.strong_rand_bytes(31))
      File.chmod!(active_path, 0o600)
    end

    File.write!(lock_go, "")
    winner_result = await_encoded_term!(winner_result)
    assert mutation_matrix_winner_class(winner_result) == outcome

    File.write!(loser_post_go, "")
    loser_post_result = await_encoded_term!(loser_post)

    assert mutation_matrix_post_class(loser_post_result, winner, outcome) ==
             mutation_matrix_expected_post(winner, outcome)

    File.write!(winner_stop, "")
    {_loser_output, 0} = Task.await(loser_task, 30_000)
    {_winner_output, 0} = Task.await(winner_task, 30_000)
  end

  defp mutation_matrix_failure_environment(_winner, :prepublication_error),
    do: [{"CURSOR_SIGNING_TEST_FAIL_STAGE_SYNC_ALWAYS", "1"}]

  defp mutation_matrix_failure_environment(_winner, :indeterminate),
    do: [{"CURSOR_SIGNING_TEST_FAIL_AFTER_RENAME", "1"}]

  defp mutation_matrix_failure_environment(:recover, _outcome),
    do: [{"CURSOR_SIGNING_TEST_FAIL_AFTER_RENAME", "1"}]

  defp mutation_matrix_failure_environment(_winner, _outcome), do: []

  defp mutation_matrix_winner_class(:ok), do: :success

  defp mutation_matrix_winner_class(
         {:indeterminate_commit, :cursor_signing_authority_may_have_advanced}
       ),
       do: :indeterminate

  defp mutation_matrix_winner_class({:error, %Error{}}), do: :prepublication_error

  defp mutation_matrix_winner_class({:error, :cursor_signing_recovery_refused}),
    do: :recovery_refused

  defp mutation_matrix_post_class({:ok, signature}, _winner, _outcome)
       when is_binary(signature),
       do: :healthy

  defp mutation_matrix_post_class({:error, :cursor_signing_unprovisioned}, _winner, _outcome),
    do: :unprovisioned

  defp mutation_matrix_post_class({:error, :cursor_signing_quarantined}, _winner, _outcome),
    do: :quarantined

  defp mutation_matrix_expected_post(:provision, :prepublication_error), do: :unprovisioned
  defp mutation_matrix_expected_post(_winner, :indeterminate), do: :quarantined
  defp mutation_matrix_expected_post(:recover, :recovery_refused), do: :quarantined
  defp mutation_matrix_expected_post(_winner, _outcome), do: :healthy

  defp mutation_matrix_loser_script do
    """
    defmodule MutationMatrixLoser do
      def run(base_dir, operation, ready, go, overlap, post_go, post) do
        provider = Tightbeam.CursorSigning.load!(base_dir)
        File.write!(ready, "")
        await_file(go, 30_000)
        publish(overlap, invoke(operation, base_dir, provider))
        await_file(post_go, 30_000)
        publish(post, Tightbeam.CursorSigning.sign(provider, "matrix-cursor"))
      end

      defp invoke("provision", base_dir, _provider),
        do: Tightbeam.CursorSigning.provision(base_dir)

      defp invoke("rotate", _base_dir, provider),
        do: Tightbeam.CursorSigning.rotate(provider)

      defp invoke("recover", _base_dir, provider),
        do: Tightbeam.CursorSigning.recover(provider)

      defp encode(term), do: term |> :erlang.term_to_binary() |> Base.encode64()

      defp publish(path, term) do
        temporary = path <> ".tmp-" <> System.pid()
        File.write!(temporary, encode(term), [:binary])
        File.rename!(temporary, path)
      end

      defp await_file(_path, 0), do: raise("matrix loser timed out")

      defp await_file(path, attempts) do
        if File.exists?(path) do
          :ok
        else
          Process.sleep(2)
          await_file(path, attempts - 1)
        end
      end
    end

    MutationMatrixLoser.run(Enum.at(System.argv(), 0), Enum.at(System.argv(), 1), Enum.at(System.argv(), 2), Enum.at(System.argv(), 3), Enum.at(System.argv(), 4), Enum.at(System.argv(), 5), Enum.at(System.argv(), 6))
    """
  end

  defp mutation_matrix_winner_script do
    """
    defmodule MutationMatrixWinner do
      def run(base_dir, operation, _outcome, _lock_ready, _lock_go, result_path, stop) do
        provider = Tightbeam.CursorSigning.load!(base_dir)
        provider = seed_recovery(provider, operation)

        result = invoke(operation, base_dir, provider)
        publish(result_path, result)
        await_file(stop, 30_000)
      end

      defp seed_recovery(provider, "recover") do
        System.put_env("CURSOR_SIGNING_TEST_FAIL_AFTER_RENAME", "1")

        {:indeterminate_commit, :cursor_signing_authority_may_have_advanced} =
          Tightbeam.CursorSigning.rotate(provider)

        provider
      end

      defp seed_recovery(provider, _operation), do: provider

      defp invoke("provision", base_dir, _provider),
        do: Tightbeam.CursorSigning.provision(base_dir)

      defp invoke("rotate", _base_dir, provider),
        do: Tightbeam.CursorSigning.rotate(provider)

      defp invoke("recover", _base_dir, provider),
        do: Tightbeam.CursorSigning.recover(provider)

      defp publish(path, term) do
        temporary = path <> ".tmp-" <> System.pid()
        encoded = term |> :erlang.term_to_binary() |> Base.encode64()
        File.write!(temporary, encoded, [:binary])
        File.rename!(temporary, path)
      end

      defp await_file(_path, 0), do: raise("matrix winner timed out")

      defp await_file(path, attempts) do
        if File.exists?(path) do
          :ok
        else
          Process.sleep(2)
          await_file(path, attempts - 1)
        end
      end
    end

    MutationMatrixWinner.run(Enum.at(System.argv(), 0), Enum.at(System.argv(), 1), Enum.at(System.argv(), 2), Enum.at(System.argv(), 3), Enum.at(System.argv(), 4), Enum.at(System.argv(), 5), Enum.at(System.argv(), 6))
    """
  end

  defp await_encoded_term!(path, attempts \\ 30_000)

  defp await_encoded_term!(_path, 0), do: raise("matrix result publication timed out")

  defp await_encoded_term!(path, attempts) do
    case read_encoded_term(path) do
      {:ok, term} ->
        term

      :retry ->
        Process.sleep(2)
        await_encoded_term!(path, attempts - 1)
    end
  end

  defp read_encoded_term(path) do
    with {:ok, encoded} <- File.read(path),
         {:ok, binary} <- Base.decode64(encoded) do
      try do
        {:ok, :erlang.binary_to_term(binary, [:safe])}
      rescue
        _error -> :retry
      end
    else
      _failure -> :retry
    end
  end

  defp compile_filesystem_probe!(directory) do
    compiler = System.find_executable("cc") || raise "C compiler is unavailable"
    source = Path.join(__DIR__, "support/cursor_signing_fs_probe.c")

    {output, arguments} =
      case :os.type() do
        {:unix, :darwin} ->
          {Path.join(directory, "cursor-signing-fs-probe.dylib"),
           ["-dynamiclib", "-O2", "-Wall", "-o"]}

        {:unix, _name} ->
          {Path.join(directory, "cursor-signing-fs-probe.so"),
           ["-shared", "-fPIC", "-O2", "-Wall", "-o"]}
      end

    link_arguments = if :os.type() == {:unix, :darwin}, do: [], else: ["-ldl"]

    case System.cmd(compiler, arguments ++ [output, source] ++ link_arguments,
           stderr_to_stdout: true
         ) do
      {"", 0} -> output
      {_diagnostic, _status} -> raise "cursor filesystem probe compilation failed"
    end
  end

  defp compile_fcntl_forwarding_probe!(directory) do
    case :os.type() do
      {:unix, :darwin} ->
        source = Path.join(directory, "fcntl-forwarding-probe.c")
        executable = Path.join(directory, "fcntl-forwarding-probe")

        File.write!(source, """
        #include <fcntl.h>
        #include <limits.h>
        #include <unistd.h>

        int main(int argc, char **argv) {
          int descriptors[2] = {-1, -1};
          int path_fd = -1;
          char path[PATH_MAX];
          static const char success[] = "fcntl-forwarding-ok";
          int status = 10;

          if (argc != 2) {
            goto done;
          }

          status = 11;
          if (pipe(descriptors) != 0) {
            goto done;
          }

          status = 12;
          if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) != 0) {
            goto done;
          }

          status = 13;
          if ((fcntl(descriptors[0], F_GETFD) & FD_CLOEXEC) == 0) {
            goto done;
          }

          status = 14;
          if (fcntl(descriptors[1], F_SETNOSIGPIPE, 1) != 0) {
            goto done;
          }

          status = 15;
          if (fcntl(descriptors[1], F_GETNOSIGPIPE) != 1) {
            goto done;
          }

          status = 16;
          path_fd = open(argv[1], O_CREAT | O_RDWR, 0600);

          if (path_fd < 0) {
            goto done;
          }

          status = 17;
          if (fcntl(path_fd, F_GETPATH, path) != 0) {
            goto done;
          }

          status = 18;
          if (path[0] != '/') {
            goto done;
          }

          status = 19;
          if (write(STDOUT_FILENO, success, sizeof(success) - 1) !=
              (ssize_t)(sizeof(success) - 1)) {
            goto done;
          }

          status = 0;

        done:
          if (path_fd >= 0) {
            close(path_fd);
          }

          if (descriptors[0] >= 0) {
            close(descriptors[0]);
          }

          if (descriptors[1] >= 0) {
            close(descriptors[1]);
          }

          return status;
        }
        """)

        compiler = System.find_executable("cc") || raise "C compiler is unavailable"

        case System.cmd(
               compiler,
               ["-std=c11", "-Wall", "-Wextra", "-Werror", source, "-o", executable],
               stderr_to_stdout: true
             ) do
          {"", 0} -> executable
          {output, status} -> raise "fcntl forwarding probe compile failed: #{status}: #{output}"
        end

      {:unix, _name} ->
        nil
    end
  end

  defp filesystem_probe_environment(probe, active_path) do
    loader_environment =
      case :os.type() do
        {:unix, :darwin} ->
          [{"DYLD_INSERT_LIBRARIES", probe}]

        {:unix, _name} ->
          [{"LD_PRELOAD", probe}]
      end

    [{"CURSOR_SIGNING_TEST_ACTIVE_PATH", active_path} | loader_environment]
  end

  defp failure_environment_name("active-exists"),
    do: "CURSOR_SIGNING_TEST_FAIL_WHEN_ACTIVE_EXISTS"

  defp failure_environment_name("after-rename"),
    do: "CURSOR_SIGNING_TEST_FAIL_AFTER_RENAME"

  defp failure_environment_name("stage-sync"),
    do: "CURSOR_SIGNING_TEST_FAIL_STAGE_SYNC_ALWAYS"

  defp await_file!(path, attempts \\ 1_000)

  defp await_file!(_path, 0), do: raise("cursor filesystem boundary timeout")

  defp await_file!(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(10)
      await_file!(path, attempts - 1)
    end
  end

  defp await_marker_count!(control_dir, prefix, expected, attempts \\ 1_000)

  defp await_marker_count!(_control_dir, _prefix, _expected, 0) do
    raise "cursor concurrency marker timeout"
  end

  defp await_marker_count!(control_dir, prefix, expected, attempts) do
    count =
      control_dir
      |> File.ls!()
      |> Enum.count(&String.starts_with?(&1, prefix))

    if count == expected do
      :ok
    else
      Process.sleep(10)
      await_marker_count!(control_dir, prefix, expected, attempts - 1)
    end
  end

  defp await_lifecycle!(provider, expected, attempts \\ 1_000)

  defp await_lifecycle!(_provider, _expected, 0) do
    raise "cursor lifecycle transition timed out"
  end

  defp await_lifecycle!(provider, expected, attempts) do
    if CursorSigning.lifecycle(provider) == expected do
      :ok
    else
      Process.sleep(10)
      await_lifecycle!(provider, expected, attempts - 1)
    end
  end

  defp write_material_fixture!(base_dir, material \\ :crypto.strong_rand_bytes(32)) do
    directory = Path.join(base_dir, "secrets")
    record = Path.join(directory, "rest-cursor-signing.v1")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    File.write!(record, material)
    File.chmod!(record, 0o600)
    record
  end

  defp start_observer_host!(base_dir, control_dir, probe, environment) do
    unless Node.alive?(), do: raise("cursor observer host requires a distributed test node")

    ready = Path.join(control_dir, "observer-ready")
    stop = Path.join(control_dir, "observer-stop")

    script = """
    defmodule CursorSigningObserverHost do
      def run(parent_node, base_dir, ready, stop) do
        true = Node.connect(String.to_atom(parent_node))
        :global.sync()
        {:ok, _provider} = Tightbeam.CursorSigning.load(base_dir)
        File.write!(ready, "")
        await_file(stop, 30_000)
        IO.binwrite("ok")
      end

      defp await_file(_path, 0), do: raise("cursor observer host timed out")

      defp await_file(path, attempts) do
        if File.exists?(path) do
          :ok
        else
          Process.sleep(10)
          await_file(path, attempts - 1)
        end
      end
    end

    [parent_node, base_dir, ready, stop] = System.argv()
    CursorSigningObserverHost.run(parent_node, base_dir, ready, stop)
    """

    host =
      Task.async(fn ->
        external_distributed_instrumented_elixir(
          script,
          [Atom.to_string(Node.self()), base_dir, ready, stop],
          filesystem_probe_environment(
            probe,
            Path.join([base_dir, "secrets", "rest-cursor-signing.v1"])
          ) ++
            environment
        )
      end)

    on_exit(fn ->
      File.write(stop, "")
      await_process_exit!(host.pid)
    end)

    await_file!(ready)
    :global.sync()
    {CursorSigning.load!(base_dir), host}
  end

  defp stop_observer_host!(host, control_dir) do
    File.write!(Path.join(control_dir, "observer-stop"), "")
    {_output, 0} = Task.await(host, 15_000)
    :global.sync()
    :ok
  end

  defp await_process_exit!(pid, attempts \\ 1_500)

  defp await_process_exit!(_pid, 0), do: raise("cursor observer host did not stop")

  defp await_process_exit!(pid, attempts) do
    if Process.alive?(pid) do
      Process.sleep(10)
      await_process_exit!(pid, attempts - 1)
    else
      :ok
    end
  end

  defp external_elixir(script, arguments) do
    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    elixir = System.find_executable("elixir") || raise "elixir is unavailable"

    run_reaped_executable(elixir, code_paths ++ ["-e", script | arguments])
  end

  defp external_instrumented_elixir(script, arguments, environment) do
    root = :code.root_dir() |> List.to_string()
    erts_version = :erlang.system_info(:version) |> List.to_string()
    executable = Path.join([root, "erts-#{erts_version}", "bin", "beam.smp"])
    bindir = Path.dirname(executable)
    elixir_root = :code.lib_dir(:elixir) |> List.to_string()

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    runtime_arguments =
      [
        "--",
        "-root",
        root,
        "-bindir",
        bindir,
        "-progname",
        "erl",
        "--",
        "-noshell",
        "-elixir_root",
        elixir_root,
        "-pa",
        Path.join(elixir_root, "ebin"),
        "-s",
        "elixir",
        "start_cli",
        "--",
        "--",
        "-extra"
      ] ++ code_paths ++ ["-e", script | arguments]

    run_reaped_executable(executable, runtime_arguments, environment)
  end

  defp external_distributed_instrumented_elixir(script, arguments, environment) do
    root = :code.root_dir() |> List.to_string()
    erts_version = :erlang.system_info(:version) |> List.to_string()
    executable = Path.join([root, "erts-#{erts_version}", "bin", "beam.smp"])
    bindir = Path.dirname(executable)
    elixir_root = :code.lib_dir(:elixir) |> List.to_string()
    node_name = "cursor_signing_probe_#{System.unique_integer([:positive])}"
    cookie = Node.get_cookie() |> Atom.to_string()

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    runtime_arguments =
      [
        "--",
        "-root",
        root,
        "-bindir",
        bindir,
        "-progname",
        "erl",
        "-sname",
        node_name,
        "-setcookie",
        cookie,
        "--",
        "-noshell",
        "-elixir_root",
        elixir_root,
        "-pa",
        Path.join(elixir_root, "ebin"),
        "-s",
        "elixir",
        "start_cli",
        "--",
        "--",
        "-extra"
      ] ++ code_paths ++ ["-e", script | arguments]

    run_reaped_executable(executable, runtime_arguments, environment)
  end

  defp run_reaped_executable(executable, arguments, environment \\ []) do
    options = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, arguments},
      {:env,
       Enum.map(environment, fn {name, value} ->
         {String.to_charlist(name), String.to_charlist(value)}
       end)}
    ]

    port = Port.open({:spawn_executable, executable}, options)

    try do
      collect_external_output(port, [])
    after
      if Port.info(port) != nil do
        Port.close(port)
      end
    end
  end

  defp collect_external_output(port, chunks) do
    receive do
      {^port, {:data, data}} ->
        collect_external_output(port, [data | chunks])

      {^port, {:exit_status, status}} ->
        {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    end
  end
end
