defmodule Tightbeam.RailTimeoutEvidence do
  @moduledoc """
  Failure-surface text for a `script_timeout` deny (tasks #38, #43).

  Lives here rather than in a test file because two suites need it: the C5 conformance
  runner renders it, and `RailScriptTest` asserts what it may and may not conclude.

  Two layers produce `script_timeout` — the rail-exec binary enforcing the declared
  `timeout_ms` (it `killpg`s the process group and exits 20), and `RailScript.await/3`
  giving up on a wrapper that never reported by `timeout_ms + 2_000`. They mean opposite
  things: the first is the time-box working, the second is a wrapper that rendered no
  verdict at all.

  The discriminator is the recorded `exit_class`. `timeout` comes only from the wrapper's
  own exit 20; `unreported` is a class the wrapper cannot produce, written by `await/3`
  at the moment it gives up.

  The duration does NOT discriminate and is reported only as context. It is BEAM-side
  wall clock (`rail_script.ex`), so a starved or suspended caller inflates it past the
  backstop threshold on a run the binary genuinely enforced — pinned by a real-binary
  starvation test in `RailScriptTest`, which asserts the class still reads
  binary-enforced under exactly that inflation.
  """

  alias Tightbeam.EventLog

  @binary_layer "RAIL-EXEC BINARY (enforcement)"
  @backstop_layer "BEAM BACKSTOP (no verdict)"

  @doc "Evidence lines for a script_timeout deny; empty string for anything else."
  @spec render(term(), map()) :: String.t()
  def render({:deny, %{reason: "script_timeout"}}, %{db: db, timeout_ms: budget})
      when is_integer(budget) do
    row = last_rail_script(db)
    class = row["exit_class"]

    measured =
      case row["duration_ms"] do
        nil -> "unrecorded"
        ms -> "#{ms}ms"
      end

    "\n  script_timeout evidence — layer: #{layer(class)}" <>
      "\n    recorded exit class: #{class || "unrecorded (no rail_script lifecycle row)"}" <>
      "\n    measured duration : #{measured} (BEAM-side wall clock; NOT the discriminator)" <>
      "\n    declared budget   : #{budget}ms (rail-exec enforces this, exits 20)" <>
      "\n    backstop threshold: #{budget + 2_000}ms (await/3 gives up on the port here)" <>
      "\n  #{guidance(class)}"
  end

  def render(_actual, _ctx), do: ""

  @doc "The `duration_ms` of the most recent `rail_script` lifecycle row, or nil."
  @spec duration_ms(GenServer.server()) :: non_neg_integer() | nil
  def duration_ms(db), do: last_rail_script(db)["duration_ms"]

  @doc "The `exit_class` of the most recent `rail_script` lifecycle row, or nil."
  @spec exit_class(GenServer.server()) :: String.t() | nil
  def exit_class(db), do: last_rail_script(db)["exit_class"]

  defp layer("timeout"), do: @binary_layer
  defp layer("unreported"), do: @backstop_layer
  defp layer(_), do: "NOT DETERMINED"

  defp guidance("timeout"),
    do:
      "The wrapper reported exit 20, so it ran its own timer to expiry and killed the " <>
        "process group. The script really did outlive its declared budget."

  defp guidance("unreported"),
    do:
      "The wrapper never reported a status and await/3 closed the port, so no process " <>
        "group kill was observed. Look at the wrapper, not the script."

  defp guidance(_),
    do:
      "No rail_script row carries a class for this deny, so the layer is not recorded. " <>
        "Do not infer it from the duration."

  defp last_rail_script(db) do
    EventLog.lifecycle_events(db)
    |> Enum.filter(&(&1.kind == "rail_script"))
    |> List.last()
    |> case do
      nil -> %{}
      event -> JSON.decode!(event.detail)
    end
  end
end
