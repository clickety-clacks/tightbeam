defmodule Tightbeam.BootTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, ManagedProcesses, Model, Org}

  # Durable process custody at boot (spec art_6817803a rev6 §B5, review
  # att_8017ebe7 F2, owner ruling att_c990c4fe).
  #
  # `Gateway.recover_process_custody/1`'s two passes are proven in org_test.exs.
  # What THIS file proves is the thing the finding was actually about: that BOOT
  # calls it. A recovery function nothing invokes is the same defect as an
  # unwired barrier, one layer down — so the test drives the real
  # `Boot.start_link/1` rather than the function it is supposed to reach.
  setup do
    # Boot resolves the DB by its registered name, so the fixture must use it.
    start_supervised!({DB, path: ":memory:", name: Tightbeam.DB})

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-boot-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    :ok = Tightbeam.Schema.ensure_all(Tightbeam.DB)

    {:ok, _} =
      DB.query(
        Tightbeam.DB,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)"
      )

    %{base_dir: base_dir}
  end

  defp session(key) do
    Org.create(Tightbeam.DB, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp preparing(session_key) do
    attrs = %{
      process_id: "mp_boot_#{System.unique_integer([:positive])}",
      owner_user_id: "flynn",
      owner_session_key: session_key,
      session_generation: 0,
      launch_turn_seq: nil,
      host: "testhost",
      purpose: "onboarding_ceremony",
      command_descriptor: "codex login",
      launch_token: "tok_#{System.unique_integer([:positive])}",
      launch_deadline: 10_000,
      lease_expires_at: 60_000,
      now: 1_000
    }

    {:ok, {:ok, row}} =
      DB.transaction(Tightbeam.DB, &ManagedProcesses.insert_preparing(&1, attrs))

    row
  end

  defp retire(key) do
    {:ok, s} =
      DB.transaction(Tightbeam.DB, &Org.retire_in_txn(&1, key, "user:flynn", 1_000))

    s
  end

  # The interrupted shape §B5 acceptance 24 describes: the session is retiring,
  # its last process has already terminalized, and the thing that would have
  # finalized it died with the previous boot. Nothing else will ever trigger it.
  test "boot finalizes a session whose last process settled before the crash", ctx do
    session("agent:boot-stranded")
    row = preparing("agent:boot-stranded")

    assert %{state: "active"} = retire("agent:boot-stranded")
    blocked = ManagedProcesses.get(Tightbeam.DB, row.processId)

    {:ok, _} =
      DB.transaction(Tightbeam.DB, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "launch_cancel_requested", revision: blocked.revision],
          %{state: "launch_canceled", resolved_at: 7_000, now: 7_000}
        )
      end)

    assert ManagedProcesses.fence(Tightbeam.DB, "agent:boot-stranded").state == "retiring"
    assert %{state: "active"} = Org.get(Tightbeam.DB, "agent:boot-stranded")

    assert :ignore = Tightbeam.Boot.start_link(ctx.base_dir)

    assert %{state: "retired"} = Org.get(Tightbeam.DB, "agent:boot-stranded")
    assert ManagedProcesses.fence(Tightbeam.DB, "agent:boot-stranded").state == "retired"
  end

  # The other half of the same rule: boot must NOT tidy away what it cannot
  # prove. Evidence is `:not_probed` on this line, so an unresolved row keeps
  # blocking its session across restarts rather than being terminalized by the
  # act of rebooting.
  test "boot leaves an unresolved process unresolved and its session blocked", ctx do
    session("agent:boot-unproven")
    row = preparing("agent:boot-unproven")

    {:ok, _} =
      DB.transaction(Tightbeam.DB, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "preparing", revision: 1],
          %{state: "identity_unknown", uncertainty_cause: "launch_handoff_unknown", now: 2_000}
        )
      end)

    assert %{state: "active"} = retire("agent:boot-unproven")

    assert :ignore = Tightbeam.Boot.start_link(ctx.base_dir)

    assert %{state: "active"} = Org.get(Tightbeam.DB, "agent:boot-unproven")
    still = ManagedProcesses.get(Tightbeam.DB, row.processId)
    assert still.state == "identity_unknown"
    assert still.stopCause == "session_retired"
    refute still.state in ManagedProcesses.terminal_states()
  end

  # Rebooting twice must not terminalize anything the first boot could not.
  test "boot recovery is idempotent across restarts", ctx do
    session("agent:boot-twice")
    row = preparing("agent:boot-twice")
    assert %{state: "active"} = retire("agent:boot-twice")

    assert :ignore = Tightbeam.Boot.start_link(ctx.base_dir)
    first = ManagedProcesses.get(Tightbeam.DB, row.processId)

    assert :ignore = Tightbeam.Boot.start_link(ctx.base_dir)
    second = ManagedProcesses.get(Tightbeam.DB, row.processId)

    assert second.state == first.state
    refute second.state in ManagedProcesses.terminal_states()
    assert %{state: "active"} = Org.get(Tightbeam.DB, "agent:boot-twice")
  end
end
