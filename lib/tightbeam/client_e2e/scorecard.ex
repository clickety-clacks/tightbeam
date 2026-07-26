defmodule Tightbeam.ClientE2E.Scorecard do
  @moduledoc """
  The v1 SCORECARD — one row per SMOKE.md step, per {harness × host} leg, and
  the verdict algebra over them (client-e2e-v1 §Architecture, r2 F3 / r3).

  The algebra is the whole point of putting this in `lib` rather than in the
  runner script: a verdict that is computed differently by each run is not a
  verdict. It is pinned here, tested, and rendered into the run document.

  Row statuses:

  - `:pass` — the step's oracles both held. A divergence that was NEGATIVE
    PROVED counts as a pass for its row and MUST cite the `harness-support.md`
    row it stands on (`divergence_ref`); an uncited divergence is not a pass,
    it is a runner-local waiver, which the spec forbids.
  - `:fail` — an oracle did not hold.
  - `:incomplete` — the step could not be driven to a verdict; carries the
    blocker, verbatim, so nobody has to reconstruct why.
  - `:manual` — the step is outside v1 automation scope and stays a human
    runbook step. VERDICT-NEUTRAL: it neither passes nor blocks a leg. Silence
    is illegal, so an unautomated step still gets a row.

  Preflight rows (P1/P2) are AUTOMATED rows and take pass/fail like any other:
  the credential check is a check, not a ceremony.

  Leg verdict:

      any :fail                          -> :fail
      else any :incomplete               -> {:incomplete, blockers}
      else no automated (non-`:manual`) row -> {:incomplete, ["no automated rows"]}
      else                               -> :pass

  The empty-leg clause is deliberate. A leg that ran nothing is the exact
  shape of a vacuous pass — the failure this driver exists to prevent — so it
  reports INCOMPLETE, never PASS.

  Run verdict is the WORST leg verdict, and a run that did not cover every
  registered harness is INCOMPLETE regardless of how its legs did (T-PARITY:
  a single-harness run is not a smoke run).
  """

  alias Tightbeam.ClientE2E.Scorecard.{Leg, Row}

  defmodule Row do
    @moduledoc "One SMOKE step's outcome on one leg."

    @type status :: :pass | :fail | :manual | :incomplete

    @type t :: %__MODULE__{
            step: String.t(),
            label: String.t(),
            journey: String.t() | nil,
            status: status(),
            note: String.t() | nil,
            divergence_ref: String.t() | nil
          }

    @enforce_keys [:step, :label, :status]
    defstruct [:step, :label, :journey, :status, :note, :divergence_ref]
  end

  defmodule Leg do
    @moduledoc "One {harness × host} pass over the journeys."

    @type t :: %__MODULE__{harness: String.t(), host: String.t(), rows: [Row.t()]}

    @enforce_keys [:harness, :host]
    defstruct [:harness, :host, rows: []]
  end

  @type verdict :: :pass | :fail | {:incomplete, [String.t()]}

  @type t :: %__MODULE__{
          gateway_sha: String.t() | nil,
          client_build: String.t() | nil,
          date: String.t() | nil,
          legs: [Leg.t()]
        }

  defstruct gateway_sha: nil, client_build: nil, date: nil, legs: []

  @doc "A pass row. `divergence_ref` cites the harness-support.md row when this leg diverges."
  @spec pass(String.t(), String.t(), keyword()) :: Row.t()
  def pass(step, label, opts \\ []) do
    row(step, label, :pass, opts)
  end

  @doc "A fail row. The note carries what did not hold."
  @spec fail(String.t(), String.t(), String.t(), keyword()) :: Row.t()
  def fail(step, label, note, opts \\ []) do
    row(step, label, :fail, Keyword.put(opts, :note, note))
  end

  @doc "An incomplete row. The blocker is required — an unexplained incomplete is noise."
  @spec incomplete(String.t(), String.t(), String.t(), keyword()) :: Row.t()
  def incomplete(step, label, blocker, opts \\ []) when is_binary(blocker) and blocker != "" do
    row(step, label, :incomplete, Keyword.put(opts, :note, blocker))
  end

  @doc "A manual row: outside v1 automation scope, verdict-neutral, still recorded."
  @spec manual(String.t(), String.t(), String.t(), keyword()) :: Row.t()
  def manual(step, label, reason, opts \\ []) when is_binary(reason) and reason != "" do
    row(step, label, :manual, Keyword.put(opts, :note, reason))
  end

  defp row(step, label, status, opts) do
    %Row{
      step: step,
      label: label,
      status: status,
      journey: opts[:journey],
      note: opts[:note],
      divergence_ref: opts[:divergence_ref]
    }
  end

  @doc "Appends rows to a leg."
  @spec add(Leg.t(), Row.t() | [Row.t()]) :: Leg.t()
  def add(%Leg{} = leg, rows), do: %{leg | rows: leg.rows ++ List.wrap(rows)}

  @doc "The verdict for one leg (see the moduledoc for the algebra)."
  @spec leg_verdict(Leg.t()) :: verdict()
  def leg_verdict(%Leg{rows: rows}) do
    blockers = for %Row{status: :incomplete} = r <- rows, do: blocker_text(r)
    automated = Enum.reject(rows, &(&1.status == :manual))

    cond do
      Enum.any?(rows, &(&1.status == :fail)) -> :fail
      blockers != [] -> {:incomplete, blockers}
      automated == [] -> {:incomplete, ["no automated rows ran on this leg"]}
      true -> :pass
    end
  end

  @doc """
  The run verdict: the worst leg verdict, and INCOMPLETE unless every
  registered harness has a leg (T-PARITY).

  `registered` is the wire names of the harnesses the org supports — pass
  `Enum.map(Tightbeam.Harness.all(), & &1.wire_name())` at the call site so
  the parity rule tracks the registry rather than a hardcoded list.
  """
  @spec run_verdict(t(), [String.t()]) :: verdict()
  def run_verdict(%__MODULE__{legs: legs}, registered) do
    covered = MapSet.new(legs, & &1.harness)
    missing = Enum.reject(registered, &MapSet.member?(covered, &1))
    verdicts = Enum.map(legs, &leg_verdict/1)

    parity_blockers =
      case {missing, legs} do
        {[], []} -> ["no legs ran"]
        {[], _} -> []
        {names, _} -> ["harness parity: no leg for #{Enum.join(names, ", ")}"]
      end

    cond do
      Enum.any?(verdicts, &(&1 == :fail)) ->
        :fail

      true ->
        blockers =
          parity_blockers ++ Enum.flat_map(verdicts, fn
            {:incomplete, list} -> list
            _ -> []
          end)

        if blockers == [], do: :pass, else: {:incomplete, blockers}
    end
  end

  @doc "Renders a verdict the way the run document and the runner's exit line say it."
  @spec verdict_text(verdict()) :: String.t()
  def verdict_text(:pass), do: "PASS"
  def verdict_text(:fail), do: "FAIL"

  def verdict_text({:incomplete, blockers}),
    do: "INCOMPLETE(" <> Enum.join(blockers, "; ") <> ")"

  @doc """
  Renders the scorecard as the markdown a run document carries: one column per
  leg, one row per step, in the order the steps were recorded on the first leg.
  """
  @spec to_markdown(t(), [String.t()]) :: String.t()
  def to_markdown(%__MODULE__{legs: legs} = scorecard, registered) do
    steps = ordered_steps(legs)
    headers = Enum.map(legs, &"#{&1.harness}@#{&1.host}")

    header_row = "| Step | " <> Enum.join(headers, " | ") <> " | notes |"
    divider = "|---" <> String.duplicate("|---", length(headers) + 1) <> "|"

    body =
      Enum.map(steps, fn {step, label} ->
        cells = Enum.map(legs, &cell_text(find_row(&1, step)))
        notes = legs |> Enum.map(&note_text(&1, step)) |> Enum.reject(&is_nil/1) |> Enum.join("; ")
        "| #{step} #{label} | " <> Enum.join(cells, " | ") <> " | #{notes} |"
      end)

    leg_verdicts =
      Enum.map(legs, fn leg ->
        "- #{leg.harness}@#{leg.host}: #{verdict_text(leg_verdict(leg))}"
      end)

    Enum.join(
      [
        header(scorecard),
        "",
        header_row,
        divider,
        Enum.join(body, "\n"),
        "",
        "## Leg verdicts",
        "",
        Enum.join(leg_verdicts, "\n"),
        "",
        "RUN VERDICT: #{verdict_text(run_verdict(scorecard, registered))}",
        ""
      ],
      "\n"
    )
  end

  defp header(scorecard) do
    "# Client-e2e scorecard — #{scorecard.date || "<date>"} @ " <>
      "#{scorecard.gateway_sha || "<gateway sha>"}\n\n" <>
      "Client build: #{scorecard.client_build || "<client build>"}"
  end

  defp ordered_steps(legs) do
    legs
    |> Enum.flat_map(& &1.rows)
    |> Enum.map(&{&1.step, &1.label})
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp find_row(%Leg{rows: rows}, step), do: Enum.find(rows, &(&1.step == step))

  defp cell_text(nil), do: "N/A"
  defp cell_text(%Row{status: :pass, divergence_ref: nil}), do: "PASS"
  defp cell_text(%Row{status: :pass, divergence_ref: ref}), do: "PASS (divergence #{ref})"
  defp cell_text(%Row{status: :fail}), do: "FAIL"
  defp cell_text(%Row{status: :incomplete}), do: "INCOMPLETE"
  defp cell_text(%Row{status: :manual}), do: "MANUAL"

  defp note_text(leg, step) do
    case find_row(leg, step) do
      %Row{note: note} when is_binary(note) -> "#{leg.harness}: #{note}"
      _ -> nil
    end
  end

  defp blocker_text(%Row{step: step, note: note}), do: "#{step}: #{note}"
end
