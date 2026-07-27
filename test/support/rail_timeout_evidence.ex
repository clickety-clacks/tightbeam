defmodule Tightbeam.RailTimeoutEvidence do
  @moduledoc """
  Failure-surface text for a `script_timeout` deny (task #38).

  Lives here rather than in a test file because two suites need it: the C5
  conformance runner renders it, and `RailScriptTest` asserts it never names a
  layer.

  Two layers produce `script_timeout` and both land on exit status 20 — the
  rail-exec binary enforcing the declared `timeout_ms` (real enforcement: it
  `killpg`s the process group and exits 20), and `RailScript.await/3` giving up
  on the port at `timeout_ms + 2_000` and SYNTHESIZING status 20 for a wrapper
  that never reported (contention: no verdict was rendered).

  Timing cannot separate them, so this reports evidence and refuses to conclude.
  The duration is BEAM-side wall clock (`rail_script.ex:13`, `:27`), so a starved
  or suspended process inflates it past the backstop threshold on a run the
  binary actually enforced — pinned by a real-binary test in `RailScriptTest`. An
  earlier version claimed a layer from the duration and mislabelled exactly that
  case; a confident mislabel is worse than the ambiguity, because it sends the
  next investigator the wrong way.

  The fact that WOULD settle it — did the port report an exit status
  (`rail_script.ex:185`) or did `await/3` synthesize one (`:188-191`) — is known
  at the decision point and never recorded. Surfacing it needs a
  rails-mechanism-v1 amendment.
  """

  alias Tightbeam.EventLog

  @doc "Evidence lines for a script_timeout deny; empty string for anything else."
  @spec render(term(), map()) :: String.t()
  def render({:deny, %{reason: "script_timeout"}}, %{db: db, timeout_ms: budget})
      when is_integer(budget) do
    measured =
      case duration_ms(db) do
        nil -> "unrecorded (no rail_script lifecycle row)"
        ms -> "#{ms}ms"
      end

    "\n  script_timeout evidence — LAYER NOT DETERMINED:" <>
      "\n    measured duration : #{measured} (BEAM-side wall clock)" <>
      "\n    declared budget   : #{budget}ms (rail-exec enforces this, exits 20)" <>
      "\n    backstop threshold: #{budget + 2_000}ms (await/3 synthesizes 20 here)" <>
      "\n  Both layers report reason=script_timeout and script_exit_class=timeout. The" <>
      "\n  duration does NOT separate them: it is measured in the BEAM, so scheduler" <>
      "\n  starvation can inflate it past the backstop threshold on a run rail-exec" <>
      "\n  genuinely enforced. Do not infer the layer from these numbers. The deciding" <>
      "\n  fact (did the port report an exit status?) is not recorded — see task #38."
  end

  def render(_actual, _ctx), do: ""

  @doc "The `duration_ms` of the most recent `rail_script` lifecycle row, or nil."
  @spec duration_ms(GenServer.server()) :: non_neg_integer() | nil
  def duration_ms(db) do
    EventLog.lifecycle_events(db)
    |> Enum.filter(&(&1.kind == "rail_script"))
    |> List.last()
    |> case do
      nil -> nil
      event -> JSON.decode!(event.detail)["duration_ms"]
    end
  end
end
