defmodule Tightbeam.CursorSigningTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias Tightbeam.CursorSigning
  alias Tightbeam.CursorSigning.Error
  alias Tightbeam.Wire.Router

  @domain_separator <<"tightbeam/rest-read-plane-d1/cursor/v1", 0>>

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
      |> Enum.map(fn _ ->
        Task.async(fn -> external_signature(ctx.base_dir, "stable-input") end)
      end)
      |> Task.await_many(30_000)

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

    applications =
      for application_id <- ["one", "two"] do
        Task.async(fn ->
          external_concurrency_summary(ctx.base_dir, control_dir, application_id)
        end)
      end

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

    summaries = Task.await_many(applications, 30_000)

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

    case operation do
      "provision" ->
        {:indeterminate_commit, :cursor_signing_authority_may_have_advanced} =
          Tightbeam.CursorSigning.provision(base_dir)

      "rotate" ->
        provider = Tightbeam.CursorSigning.load!(base_dir)
        {:indeterminate_commit, :cursor_signing_authority_may_have_advanced} =
          Tightbeam.CursorSigning.rotate(provider)

      "rotate-refused" ->
        provider = Tightbeam.CursorSigning.load!(base_dir)
        {:error, %Tightbeam.CursorSigning.Error{}} = Tightbeam.CursorSigning.rotate(provider)
        IO.binwrite("refused")
    end

    if operation != "rotate-refused", do: IO.binwrite("indeterminate")
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
        before_rename_signature = sign!(provider)
        {:ok, true} = verify(provider, before_rename_signature)
        File.write!(marker(control_dir, "during-before", application_id, index), "")

        await_file(Path.join(control_dir, "during-after-go"), 15_000)
        {:ok, false} = verify(provider, old_signature)
        new_signature = sign!(provider)
        {:ok, true} = verify(provider, new_signature)
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

  defp filesystem_probe_environment(probe, active_path) do
    loader_environment =
      case :os.type() do
        {:unix, :darwin} ->
          [{"DYLD_INSERT_LIBRARIES", probe}, {"DYLD_FORCE_FLAT_NAMESPACE", "1"}]

        {:unix, _name} ->
          [{"LD_PRELOAD", probe}]
      end

    [{"CURSOR_SIGNING_TEST_ACTIVE_PATH", active_path} | loader_environment]
  end

  defp failure_environment_name("active-exists"),
    do: "CURSOR_SIGNING_TEST_FAIL_WHEN_ACTIVE_EXISTS"

  defp failure_environment_name("after-rename"),
    do: "CURSOR_SIGNING_TEST_FAIL_AFTER_RENAME"

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

  defp write_material_fixture!(base_dir) do
    directory = Path.join(base_dir, "secrets")
    record = Path.join(directory, "rest-cursor-signing.v1")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    File.write!(record, :crypto.strong_rand_bytes(32))
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

    System.cmd(elixir, code_paths ++ ["-e", script | arguments], stderr_to_stdout: true)
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

    System.cmd(executable, runtime_arguments, stderr_to_stdout: true, env: environment)
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

    System.cmd(executable, runtime_arguments, stderr_to_stdout: true, env: environment)
  end
end
