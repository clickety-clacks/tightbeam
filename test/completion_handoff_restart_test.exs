defmodule Tightbeam.CompletionHandoffRestartTest do
  use Tightbeam.TestCase, async: false

  # Two operating-system processes share one base directory. The first commits
  # a finish notice's delivery and halts before the delivery's follow-through;
  # the second is an ordinary gateway boot whose turn-end sweeper must store
  # the opener's reminder from the delivered record.
  @tag :tmp_dir
  @tag timeout: 240_000
  test "a finish notice's reminder is stored after a stop between delivery and follow-through",
       %{tmp_dir: tmp} do
    fixture = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "completion_handoff_restart.exs")

    for phase <- ~w(deliver restart) do
      {output, status} =
        System.cmd(fixture.executable, fixture.args ++ [phase],
          env: fixture.env,
          stderr_to_stdout: true
        )

      File.write!(Path.join(tmp, "#{phase}.log"), output)
      assert status == 0, output
      assert output =~ "completion-handoff-restart: #{phase} ok"
    end
  end
end
