defmodule Tightbeam.HarklightListenerTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, EventLog, Harklight, Model, Org}

  setup do
    db = String.to_atom("harklight_listener_db_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('flynn',0,'admin_add',1)"
      )

    create_session(db, "harklight-origin", "Origin")
    create_session(db, "other-origin", "Other origin")

    registry =
      start_supervised!({Registry, keys: :unique, name: Tightbeam.Harklight.ListenerRegistry})

    supervisor =
      start_supervised!(
        {Tightbeam.Harklight.ListenerSupervisor, name: Tightbeam.Harklight.ListenerSupervisor}
      )

    %{db: db, registry: registry, supervisor: supervisor}
  end

  test "repeated failures for one handle leave other listeners running and record the failed handle",
       ctx do
    original_path = System.get_env("PATH")

    directory =
      Path.join(System.tmp_dir!(), "harklight-listener-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    executable = Path.join(directory, "harklight-agent")

    File.write!(
      executable,
      """
      #!/bin/sh
      if [ "$4" = "failing-handle" ]; then
        sleep 0.05
        exit 17
      fi
      exec sleep 30
      """
    )

    File.chmod!(executable, 0o755)
    System.put_env("PATH", Enum.join([directory, original_path], ":"))

    on_exit(fn ->
      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
      File.rm_rf(directory)
    end)

    register(ctx.db, "harklight-origin", "failing-handle")
    register(ctx.db, "other-origin", "healthy-handle")

    {:ok, healthy_pid} =
      Harklight.ListenerSupervisor.ensure(
        ctx.db,
        "healthy-handle",
        Tightbeam.Harklight.ListenerSupervisor
      )

    for _attempt <- 1..4 do
      {:ok, failed_pid} =
        Harklight.ListenerSupervisor.ensure(
          ctx.db,
          "failing-handle",
          Tightbeam.Harklight.ListenerSupervisor
        )

      wait_for_down(failed_pid)
      assert handle_state(ctx.db, "failing-handle") == "listener_failed"
      assert Process.alive?(ctx.supervisor)
      assert Process.alive?(healthy_pid)
    end

    assert Harklight.registered_handles(ctx.db) == ["failing-handle", "healthy-handle"]

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "harklight_listener_failed")
           ) == 4
  end

  defp register(db, recipient, handle) do
    result =
      Harklight.register(
        db,
        %{
          principal: {:session, recipient},
          params: %{session_handle: handle, sender_id: "sender-1", message_id: "message-1"}
        },
        start_listener: false
      )

    assert result.state == "listening"
  end

  defp handle_state(db, handle) do
    assert {:ok, [[state]]} =
             DB.query(db, "SELECT state FROM harklight_handles WHERE sessionHandle=?1", [handle])

    state
  end

  defp wait_for_down(pid) do
    reference = Process.monitor(pid)
    assert_receive {:DOWN, ^reference, :process, ^pid, _reason}, 2_000
  end

  defp create_session(db, session_key, display_name) do
    Org.create(db, %{
      session_key: session_key,
      display_name: display_name,
      kind: "custom",
      is_built_in: false,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end
end
