defmodule Tightbeam.LegacyCredentialMigrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, EventLog, Homes, Placement, Spinup}

  @host "testhost"
  @fixtures [
    %{
      harness: :codex,
      provider: :openai,
      filename: "auth.json",
      link: :relative,
      bytes: "fixture-codex-auth-record"
    },
    %{
      harness: :claude,
      provider: :anthropic,
      filename: ".credentials.json",
      link: :absolute,
      bytes: "fixture-claude-auth-record"
    }
  ]

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tb-legacy-auth-#{System.unique_integer([:positive])}")

    db = :"legacy_auth_db_#{System.unique_integer([:positive])}"
    File.mkdir_p!(base_dir)
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = EventLog.ensure_schema(db)
    :ok = Placement.ensure_schema(db)

    register_hosts(db, %{
      @host => %{ssh: nil, base_dir: base_dir, cli_bin: nil}
    })

    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{base_dir: base_dir, db: db}
  end

  test "local Spinup readiness materializes both supported legacy layouts and keeps shared auth referents",
       ctx do
    for fixture <- @fixtures do
      paths = create_linked_fixture!(ctx.base_dir, @host, fixture)
      shared_home = Homes.home_path(ctx.base_dir, "other-host", fixture.harness)
      File.mkdir_p!(shared_home)
      shared_entry = Path.join(shared_home, fixture.filename)
      File.ln_s!(paths.source, shared_entry)
      stage_adapter!(ctx.base_dir, fixture.harness)

      assert :ok = ensure_ready(ctx, fixture.harness, @host)

      assert {:ok, %{type: :regular, mode: source_mode, uid: source_uid, gid: source_gid}} =
               File.lstat(paths.entry)

      source_stat = File.stat!(paths.source)
      assert Bitwise.band(source_mode, 0o777) == 0o600
      assert Bitwise.band(source_stat.mode, 0o777) == 0o640
      assert Bitwise.band(File.stat!(Path.dirname(paths.source)).mode, 0o777) == 0o700
      assert source_uid == source_stat.uid
      assert source_gid == source_stat.gid
      assert File.read!(paths.entry) == fixture.bytes
      assert File.read!(paths.source) == fixture.bytes
      assert {:ok, %{type: :symlink}} = File.lstat(shared_entry)
      assert File.read!(shared_entry) == fixture.bytes

      migrated_stat = File.stat!(paths.entry)
      assert :ok = ensure_ready(ctx, fixture.harness, @host)
      assert File.stat!(paths.entry).inode == migrated_stat.inode
      assert File.read!(paths.entry) == fixture.bytes
    end
  end

  test "remote Spinup readiness materializes links on the target host before the real file check",
       ctx do
    remote_base = Path.join(ctx.base_dir, "remote-install")

    register_hosts(ctx.db, %{
      "worker" => %{ssh: "worker", base_dir: remote_base, cli_bin: nil}
    })

    for fixture <- @fixtures do
      paths = create_linked_fixture!(remote_base, "worker", fixture)
      stage_adapter!(remote_base, fixture.harness)

      assert :ok = ensure_ready(ctx, fixture.harness, "worker", &run_local_ssh/1)
      assert {:ok, %{type: :regular}} = File.lstat(paths.entry)
      assert File.read!(paths.entry) == fixture.bytes
      assert File.read!(paths.source) == fixture.bytes
      assert Bitwise.band(File.stat!(paths.entry).mode, 0o777) == 0o600
      assert Bitwise.band(File.stat!(paths.source).mode, 0o777) == 0o640
      assert Bitwise.band(File.stat!(Path.dirname(paths.source)).mode, 0o777) == 0o700
      assert File.stat!(paths.entry).uid == File.stat!(paths.source).uid
      assert File.stat!(paths.entry).gid == File.stat!(paths.source).gid
    end
  end

  test "local and remote readiness recover a link displaced by an interrupted promotion", ctx do
    remote_base = Path.join(ctx.base_dir, "remote-install")

    register_hosts(ctx.db, %{
      "worker" => %{ssh: "worker", base_dir: remote_base, cli_bin: nil}
    })

    for fixture <- @fixtures do
      local_paths = create_linked_fixture!(ctx.base_dir, @host, fixture)
      stage_adapter!(ctx.base_dir, fixture.harness)
      local_stage = simulate_interrupted_migration!(local_paths)

      assert {:error, :enoent} = File.lstat(local_paths.entry)
      assert :ok = ensure_ready(ctx, fixture.harness, @host)
      assert {:ok, %{type: :regular, mode: local_mode}} = File.lstat(local_paths.entry)
      assert Bitwise.band(local_mode, 0o777) == 0o600
      assert File.read!(local_paths.entry) == fixture.bytes
      assert File.read!(local_paths.source) == fixture.bytes
      refute File.exists?(local_stage)

      remote_paths = create_linked_fixture!(remote_base, "worker", fixture)
      stage_adapter!(remote_base, fixture.harness)
      remote_stage = simulate_interrupted_migration!(remote_paths, "credential")

      assert {:error, :enoent} = File.lstat(remote_paths.entry)
      assert :ok = ensure_ready(ctx, fixture.harness, "worker", &run_local_ssh/1)
      assert {:ok, %{type: :regular, mode: remote_mode}} = File.lstat(remote_paths.entry)
      assert Bitwise.band(remote_mode, 0o777) == 0o600
      assert File.read!(remote_paths.entry) == fixture.bytes
      assert File.read!(remote_paths.source) == fixture.bytes
      refute File.exists?(remote_stage)
    end
  end

  test "local and remote readiness refuse conflicting recovery stages without discarding either",
       ctx do
    fixture = hd(@fixtures)
    local_paths = create_linked_fixture!(ctx.base_dir, @host, fixture)
    stage_adapter!(ctx.base_dir, fixture.harness)

    local_stages =
      simulate_conflicting_regular_displacements!(local_paths, [
        "fixture-credential-generation-n1",
        "fixture-credential-generation-n2"
      ])

    assert {:error, %{code: "host_unready", message: local_message}} =
             ensure_ready(ctx, fixture.harness, @host)

    refute local_message =~ "fixture-credential-generation-n1"
    refute local_message =~ "fixture-credential-generation-n2"
    assert {:error, :enoent} = File.lstat(local_paths.entry)
    assert_conflicting_stages_preserved!(local_stages)
    assert File.read!(local_paths.source) == fixture.bytes

    remote_base = Path.join(ctx.base_dir, "remote-install")

    register_hosts(ctx.db, %{
      "worker" => %{ssh: "worker", base_dir: remote_base, cli_bin: nil}
    })

    remote_paths = create_linked_fixture!(remote_base, "worker", fixture)
    stage_adapter!(remote_base, fixture.harness)

    remote_stages =
      simulate_conflicting_regular_displacements!(remote_paths, [
        "fixture-credential-generation-n1",
        "fixture-credential-generation-n2"
      ])

    assert {:error, %{code: "host_unready", message: remote_message}} =
             ensure_ready(ctx, fixture.harness, "worker", &run_local_ssh/1)

    refute remote_message =~ "fixture-credential-generation-n1"
    refute remote_message =~ "fixture-credential-generation-n2"
    assert {:error, :enoent} = File.lstat(remote_paths.entry)
    assert_conflicting_stages_preserved!(remote_stages)
    assert File.read!(remote_paths.source) == fixture.bytes
  end

  test "exclusive staged promotion keeps a credential written after destination validation",
       ctx do
    fixture = hd(@fixtures)
    paths = create_linked_fixture!(ctx.base_dir, @host, fixture)
    staged = Path.join(paths.home, ".staged-auth.json")
    File.write!(staged, "fixture-staged-old-record")

    File.rm!(paths.entry)
    File.write!(paths.entry, "fixture-newer-interleaved-record")

    assert :ok = Homes.promote_staged_legacy_credential(staged, paths.entry)
    assert File.read!(paths.entry) == "fixture-newer-interleaved-record"
    assert File.read!(paths.source) == fixture.bytes
  end

  test "local and remote readiness restore a regular credential displaced before interruption",
       ctx do
    fixture = hd(@fixtures)
    paths = create_linked_fixture!(ctx.base_dir, @host, fixture)
    stage_adapter!(ctx.base_dir, fixture.harness)

    stage_dir =
      simulate_interrupted_regular_displacement!(paths, "fixture-newer-interleaved-record")

    assert {:error, :enoent} = File.lstat(paths.entry)
    assert :ok = ensure_ready(ctx, fixture.harness, @host)
    assert {:ok, %{type: :regular}} = File.lstat(paths.entry)
    assert File.read!(paths.entry) == "fixture-newer-interleaved-record"
    assert File.read!(paths.source) == fixture.bytes
    refute File.exists?(stage_dir)

    remote_base = Path.join(ctx.base_dir, "remote-install")

    register_hosts(ctx.db, %{
      "worker" => %{ssh: "worker", base_dir: remote_base, cli_bin: nil}
    })

    remote_paths = create_linked_fixture!(remote_base, "worker", fixture)
    stage_adapter!(remote_base, fixture.harness)

    remote_stage =
      simulate_interrupted_regular_displacement!(
        remote_paths,
        "fixture-newer-interleaved-record",
        "credential"
      )

    assert {:error, :enoent} = File.lstat(remote_paths.entry)
    assert :ok = ensure_ready(ctx, fixture.harness, "worker", &run_local_ssh/1)
    assert {:ok, %{type: :regular}} = File.lstat(remote_paths.entry)
    assert File.read!(remote_paths.entry) == "fixture-newer-interleaved-record"
    assert File.read!(remote_paths.source) == fixture.bytes
    refute File.exists?(remote_stage)
  end

  test "remote readiness preserves a regular credential written at the promotion boundary", ctx do
    fixture = hd(@fixtures)
    remote_base = Path.join(ctx.base_dir, "remote-install")

    register_hosts(ctx.db, %{
      "worker" => %{ssh: "worker", base_dir: remote_base, cli_bin: nil}
    })

    paths = create_linked_fixture!(remote_base, "worker", fixture)
    stage_adapter!(remote_base, fixture.harness)

    assert :ok =
             ensure_ready(ctx, fixture.harness, "worker", &run_local_ssh_with_interleaved_write/1)

    assert {:ok, %{type: :regular}} = File.lstat(paths.entry)
    assert File.read!(paths.entry) == "fixture-newer-interleaved-record"
    assert File.read!(paths.source) == fixture.bytes
  end

  test "a newer regular home file stays authoritative and an out-of-bound link is refused", ctx do
    fixture = %{hd(@fixtures) | link: :absolute}
    paths = create_linked_fixture!(ctx.base_dir, @host, fixture, :regular)
    File.write!(paths.entry, "fixture-newer-home-record")
    stage_adapter!(ctx.base_dir, fixture.harness)

    assert :ok = ensure_ready(ctx, fixture.harness, @host)
    assert File.read!(paths.entry) == "fixture-newer-home-record"
    assert File.read!(paths.source) == fixture.bytes

    external = Path.join(ctx.base_dir, "outside-auth.json")
    File.write!(external, "fixture-outside-auth-record")
    File.rm!(paths.entry)
    File.ln_s!(external, paths.entry)

    assert {:error, %{code: "host_unready", message: message}} =
             ensure_ready(ctx, fixture.harness, @host)

    assert message =~ "could not safely materialize"
    assert message =~ "installation boundary"
    refute message =~ fixture.bytes
    refute message =~ "fixture-outside-auth-record"
    assert {:ok, %{type: :symlink}} = File.lstat(paths.entry)
    assert File.read_link!(paths.entry) == external
    assert File.read!(external) == "fixture-outside-auth-record"
    assert File.read!(paths.source) == fixture.bytes
  end

  test "cyclic local and remote links remain intact and return actionable refusals", ctx do
    fixture = hd(@fixtures)
    local_paths = create_linked_fixture!(ctx.base_dir, @host, fixture)
    File.rm!(local_paths.entry)
    File.ln_s!(local_paths.entry, local_paths.entry)
    stage_adapter!(ctx.base_dir, fixture.harness)

    assert {:error, %{code: "host_unready", message: local_message}} =
             ensure_ready(ctx, fixture.harness, @host)

    assert local_message =~ "installation boundary"
    refute local_message =~ fixture.bytes
    assert {:ok, %{type: :symlink}} = File.lstat(local_paths.entry)
    assert File.read_link!(local_paths.entry) == local_paths.entry
    assert File.read!(local_paths.source) == fixture.bytes

    remote_base = Path.join(ctx.base_dir, "remote-install")

    register_hosts(ctx.db, %{
      "worker" => %{ssh: "worker", base_dir: remote_base, cli_bin: nil}
    })

    remote_paths = create_linked_fixture!(remote_base, "worker", fixture)
    File.rm!(remote_paths.entry)
    File.ln_s!(remote_paths.entry, remote_paths.entry)
    stage_adapter!(remote_base, fixture.harness)

    assert {:error, %{code: "host_unready", message: remote_message}} =
             ensure_ready(ctx, fixture.harness, "worker", &run_local_ssh/1)

    assert remote_message =~ "installation boundary"
    refute remote_message =~ fixture.bytes
    assert {:ok, %{type: :symlink}} = File.lstat(remote_paths.entry)
    assert File.read_link!(remote_paths.entry) == remote_paths.entry
    assert File.read!(remote_paths.source) == fixture.bytes
  end

  test "missing and unreadable auth sources leave their links and do not claim readiness", ctx do
    fixture = hd(@fixtures)
    paths = create_linked_fixture!(ctx.base_dir, @host, fixture, :link_without_source)
    stage_adapter!(ctx.base_dir, fixture.harness)

    assert {:error, %{code: "host_unready", message: missing_message}} =
             ensure_ready(ctx, fixture.harness, @host)

    assert missing_message =~ "expected auth file is missing"
    assert {:ok, %{type: :symlink}} = File.lstat(paths.entry)
    refute File.exists?(paths.source)

    File.mkdir_p!(Path.dirname(paths.source))
    File.write!(paths.source, fixture.bytes)
    File.chmod!(paths.source, 0o000)

    try do
      assert {:error, %{code: "host_unready", message: unreadable_message}} =
               ensure_ready(ctx, fixture.harness, @host)

      assert unreadable_message =~ "expected auth file is unreadable"
      assert {:ok, %{type: :symlink}} = File.lstat(paths.entry)
    after
      File.chmod!(paths.source, 0o600)
    end

    assert File.read!(paths.source) == fixture.bytes
  end

  test "staging failure leaves the link and source intact; readiness succeeds after retry", ctx do
    fixture = hd(@fixtures)
    paths = create_linked_fixture!(ctx.base_dir, @host, fixture)
    stage_adapter!(ctx.base_dir, fixture.harness)
    original_mode = File.stat!(paths.home).mode
    File.chmod!(paths.home, 0o500)

    try do
      assert {:error, %{code: "host_unready", message: message}} =
               ensure_ready(ctx, fixture.harness, @host)

      assert message =~ "private migration stage could not be created"
      assert {:ok, %{type: :symlink}} = File.lstat(paths.entry)
      assert File.read!(paths.source) == fixture.bytes
    after
      File.chmod!(paths.home, original_mode)
    end

    assert :ok = ensure_ready(ctx, fixture.harness, @host)
    assert {:ok, %{type: :regular}} = File.lstat(paths.entry)
    assert File.read!(paths.entry) == fixture.bytes
    assert File.read!(paths.source) == fixture.bytes
  end

  defp create_linked_fixture!(base_dir, host, fixture, target_mode \\ :link) do
    source = Tightbeam.Credentials.legacy_credential_path(base_dir, fixture.provider)

    home = Homes.home_path(base_dir, host, fixture.harness)
    entry = Path.join(home, fixture.filename)
    File.mkdir_p!(Path.dirname(source))
    File.chmod!(Path.dirname(source), 0o700)
    File.mkdir_p!(home)

    unless target_mode == :link_without_source do
      File.write!(source, fixture.bytes)
      File.chmod!(source, 0o640)
    end

    case target_mode do
      :regular ->
        :ok

      :link_without_source ->
        File.ln_s!(legacy_target(source, home, fixture), entry)

      _ ->
        File.ln_s!(legacy_target(source, home, fixture), entry)
    end

    %{source: source, home: home, entry: entry}
  end

  defp simulate_interrupted_migration!(paths, staged_filename \\ nil) do
    stage_dir = Path.join(paths.home, ".tightbeam-auth-migration-interrupted")
    staged = Path.join(stage_dir, staged_filename || Path.basename(paths.source))
    previous = Path.join(stage_dir, "previous-home-entry")

    File.mkdir!(stage_dir)
    File.chmod!(stage_dir, 0o700)
    File.cp!(paths.source, staged)
    File.chmod!(staged, 0o600)
    File.rename!(paths.entry, previous)
    stage_dir
  end

  defp simulate_interrupted_regular_displacement!(paths, bytes, staged_filename \\ nil) do
    stage_dir = Path.join(paths.home, ".tightbeam-auth-migration-interrupted")
    staged = Path.join(stage_dir, staged_filename || Path.basename(paths.source))
    previous = Path.join(stage_dir, "previous-home-entry")

    File.mkdir!(stage_dir)
    File.chmod!(stage_dir, 0o700)
    File.cp!(paths.source, staged)
    File.chmod!(staged, 0o600)
    File.rm!(paths.entry)
    File.write!(previous, bytes)
    File.chmod!(previous, 0o600)
    stage_dir
  end

  defp simulate_conflicting_regular_displacements!(paths, credentials) do
    File.rm(paths.entry)

    credentials
    |> Enum.with_index(1)
    |> Enum.map(fn {bytes, generation} ->
      stage_dir = Path.join(paths.home, ".tightbeam-auth-migration-conflict-#{generation}")
      previous = Path.join(stage_dir, "previous-home-entry")
      File.mkdir!(stage_dir)
      File.chmod!(stage_dir, 0o700)
      File.write!(previous, bytes)
      File.chmod!(previous, 0o600)
      {stage_dir, previous, bytes}
    end)
  end

  defp assert_conflicting_stages_preserved!(stages) do
    for {stage_dir, previous, bytes} <- stages do
      assert File.dir?(stage_dir)
      assert Bitwise.band(File.stat!(stage_dir).mode, 0o777) == 0o700
      assert Bitwise.band(File.stat!(previous).mode, 0o777) == 0o600
      assert File.read!(previous) == bytes
    end
  end

  defp legacy_target(source, _home, %{link: :relative}) do
    Path.join([
      "..",
      "..",
      "..",
      "auth",
      Path.basename(Path.dirname(source)),
      Path.basename(source)
    ])
  end

  defp legacy_target(source, _home, _fixture), do: source

  defp stage_adapter!(base_dir, harness) do
    module = Tightbeam.Harness.module!(harness)

    path =
      Path.join([
        base_dir,
        "adapters",
        "node_modules",
        ".bin",
        Path.basename(module.install_package())
      ])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
  end

  defp ensure_ready(ctx, harness, host, sh \\ nil) do
    opts = [db: ctx.db, patch_adapter: fn _harness, _path -> :ok end]
    opts = if sh, do: Keyword.put(opts, :sh, sh), else: opts
    Spinup.ensure_ready(%{base_dir: ctx.base_dir}, harness, host, opts)
  end

  defp run_local_ssh(command) do
    script = command |> Enum.drop(6) |> Enum.join(" ")
    System.cmd("sh", ["-c", script], stderr_to_stdout: true)
  end

  defp run_local_ssh_with_interleaved_write(command) do
    script = command |> Enum.drop(6) |> Enum.join(" ")

    interleaved =
      String.replace(
        script,
        "if ln \"$stage/credential\" \"$entry\" >/dev/null 2>&1; then",
        "printf '%s' 'fixture-newer-interleaved-record' > \"$entry\"\n" <>
          "if ln \"$stage/credential\" \"$entry\" >/dev/null 2>&1; then"
      )

    System.cmd("sh", ["-c", interleaved], stderr_to_stdout: true)
  end
end
