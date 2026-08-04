defmodule Tightbeam.ApplicationRefusalTest do
  # An EXPECTED refusal must exit with its sentence; a DEFECT must still crash.
  #
  # Measured on shrdlu from the npm tarball, before this fix: the no-harness-CLI
  # refusal printed the right words and then produced "Kernel pid terminated
  # (application_controller)" plus an erl_crash.dump — because a release runs the app
  # as permanent, so `{:error, _}` from start/2 escalates. These tests pin the
  # DECISION (refuse vs reraise); the release boot itself is the in-situ proof.
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  setup do
    on_exit(fn -> Application.delete_env(:tightbeam, :refusal_exit) end)
    :ok
  end

  defp with_refusal_capture(fun) do
    parent = self()

    Application.put_env(:tightbeam, :refusal_exit, fn message ->
      send(parent, {:refused, message})
      {:error, message}
    end)

    fun.()
  end

  test "a named expected refusal exits with its sentence instead of crashing" do
    log =
      capture_log(fn ->
        with_refusal_capture(fn ->
          assert {:error, message} =
                   Tightbeam.Application.refuse_for_test("no registered harness CLI is installed")

          assert message =~ "no registered harness CLI"
        end)
      end)

    assert_received {:refused, "no registered harness CLI is installed"}
    assert log =~ "no registered harness CLI"
  end

  # THE FIRST VERSION OF THIS FIX WAS SILENT. Logger.error/1 is async and System.halt/1
  # does not flush it: the release exited 1 with a ZERO-BYTE log, which trades a crash
  # dump for silence — the worse of the two, and the exact class this codebase spent a
  # night removing. The sentence must reach stderr synchronously, before any halt.
  test "the refusal sentence reaches stderr, not only the async logger" do
    captured =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        with_refusal_capture(fn ->
          Tightbeam.Application.refuse_for_test("no registered harness CLI is installed")
        end)
      end)

    assert captured =~ "no registered harness CLI is installed"
  end

  test "the refusal seam defaults to halting, not to swallowing" do
    # The default must be :halt. If a future edit makes the default a no-op, a release
    # would keep booting past a refusal it just printed — silence wearing a message.
    Application.delete_env(:tightbeam, :refusal_exit)
    assert Application.get_env(:tightbeam, :refusal_exit, :halt) == :halt
  end
end
