defmodule Tightbeam.Harness.ClaudeFoldedPrompt do
  @moduledoc false

  alias Tightbeam.Harness.{AdapterPatch, Support}

  @version "0.81.0"
  @package "claude-agent-acp"
  @bundle "acp-agent.js"
  @result_anchor "const isAutonomousResult = message.origin != null && AUTONOMOUS_RESULT_ORIGINS.has(message.origin.kind);"
  @idle_anchor "// Turn-over is when a title may have landed or become"
  @helper_anchor "const findUnsettledTurn = (uuid) => (session.turnQueue ?? []).find((t) => t.promptUuid === uuid && !t.settled);"

  @helper ~S"""
  // A command folded into an autonomous cycle may never get a user echo.
  // Its completed frame can precede that cycle's result. Neither alone ends
  // the prompt: retain both, then wait for idle and background work to drain.
  const settleCompletedFoldedTurns = async () => {
      if (session.cancelled || isSteering(session.activeTurn) ||
          [...session.liveBackgroundTasks.values()].some(task => task.isSubagent && !task.endedPerLevel)) {
          return;
      }
      for (const turn of [...(session.turnQueue ?? [])]) {
          if (turn.settled || turn.commandFinished !== "completed" || !turn.foldedCycleResult ||
              (session.activeTurn && session.activeTurn !== turn)) {
              continue;
          }
          const result = turn.foldedCycleResult;
          // A different terminal fate must never be rewritten as delivery.
          // Leave unsupported result shapes on the existing recovery path.
          if (result.stop_reason !== "refusal" && !result.is_error &&
              (result.subtype !== "success" || result.stop_reason !== "end_turn")) {
              continue;
          }
          session.activeTurn = turn;
          if (result.stop_reason === "refusal") {
              await settleActive({ stopReason: "refusal" });
          } else if (result.is_error) {
              await failActiveWithSessionFailure("internal_error",
                  RequestError.internalError(undefined, "The consuming cycle of this folded prompt failed."),
                  "The consuming cycle of this folded prompt failed.");
          } else {
              // Usage was already reported for the consuming cycle. Do not
              // charge the preceding user turn's accumulated usage again.
              await settleActive({ stopReason: "end_turn" });
          }
      }
  };
  """

  @result ~S"""
  // Native command frames and results are consumed in stream order. Only a
  // dispatched command in this autonomous cycle can claim its real result;
  // zero-turn background placeholders are not a completed consuming cycle.
  if (isAutonomousResult && message.num_turns > 0) {
      for (const turn of session.turnQueue ?? []) {
          if (!turn.settled && turn.commandStarted && !turn.foldedCycleResult &&
              (!turn.commandFinished || turn.commandFinished === "completed")) {
              turn.foldedCycleResult = message;
          }
      }
  }
  """

  @replacements [
    {@helper_anchor, @helper_anchor <> "\n" <> @helper},
    {@result_anchor, @result_anchor <> "\n" <> @result},
    {@idle_anchor,
     "await settleCompletedFoldedTurns();\n                                    " <> @idle_anchor}
  ]

  def fixture, do: Enum.map_join(@replacements, "\n", &elem(&1, 0))
  def patch(source), do: AdapterPatch.patch(source, @replacements, "claude", @version)

  def local(path),
    do: AdapterPatch.ensure!(path, @package, @bundle, @version, @replacements, "claude")

  def remote(target, path, detail) do
    script =
      AdapterPatch.remote_script(path, @package, @bundle, @replacements, "claude",
        version: @version
      )

    command = "node -e " <> Support.shell_quote(script)

    case target.sh.(Support.catalog_probe_argv(target.host_config.ssh, command)) do
      {_output, 0} -> {:ok, detail <> "; claude adapter patched"}
      {output, _} -> {:error, %{code: "host_unready", message: String.trim(output)}}
    end
  end
end
