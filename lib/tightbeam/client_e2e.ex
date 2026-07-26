defmodule Tightbeam.ClientE2E do
  @moduledoc """
  The client-e2e DRIVER: it pairs a fresh sim client against a REAL running
  gateway, walks the journeys in order, and returns a scorecard leg.

  One leg is one {harness × host} pass, exactly as SMOKE.md's matrix means it.
  The runner is deliberately thin — the oracles live in
  `Tightbeam.ClientE2E.Journeys` and the verdict algebra in
  `Tightbeam.ClientE2E.Scorecard` — so that what a run MEANS never depends on
  how it was invoked.

  Failure posture: a leg that cannot pair or connect does not crash and does
  not skip; it records the failure as a FAIL row and the rest of the journeys
  as blocked. That is required proof 3 in the spec — pointing this driver at a
  wrong port must produce a failing run with a legible client-side error, not
  a quiet green one.
  """

  alias Tightbeam.ClientE2E.{Journeys, Scorecard, SimClient}
  alias Tightbeam.ClientE2E.Scorecard.Leg

  @default_turn_timeout_ms 180_000
  @default_settle_ms 2_500

  @type opts :: [
          host: String.t(),
          port: :inet.port_number(),
          base_dir: String.t(),
          harness: String.t(),
          host_name: String.t(),
          model: String.t() | nil,
          journeys: [String.t()],
          gateway: Tightbeam.ClientE2E.LegGateway.t() | nil,
          preflight_row: Scorecard.Row.t() | nil,
          turn_timeout_ms: pos_integer(),
          settle_ms: pos_integer()
        ]

  @doc """
  Runs one leg, returning `{leg, current_gateway}`.

  The gateway comes back because J7 REPLACES it: whoever tears down at the end
  must signal the process that is actually running.

  Options: `:host`, `:port`, `:base_dir`, `:harness` (all required — the
  harness has NO default on purpose: a driver that silently picks one names a
  harness, and the registry is the only authority on which legs exist);
  `:host_name` names the leg's host; `:journeys` restricts the walk (defaults
  to all of `Journeys.ids/0`); `:preflight_row` carries the row the runner
  already produced BEFORE boot (SMOKE: preflight runs first, before anything
  boots).
  """
  @spec run_leg(opts()) :: {Leg.t(), Tightbeam.ClientE2E.LegGateway.t() | nil}
  def run_leg(opts) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.fetch!(opts, :port)
    base_dir = Keyword.fetch!(opts, :base_dir)
    harness = Keyword.fetch!(opts, :harness)
    host_name = Keyword.get(opts, :host_name, Tightbeam.Placement.local_host_name())
    ids = Keyword.get(opts, :journeys, Journeys.ids())

    leg = %Leg{harness: harness, host: host_name}

    # The preflight row is produced by the RUNNER before the gateway boots
    # (SMOKE: "FIRST, before anything boots"), and merely carried here.
    leg =
      case Keyword.get(opts, :preflight_row) do
        nil -> leg
        row -> Scorecard.add(leg, row)
      end

    device_id = "sim-client-e2e-#{System.unique_integer([:positive])}"

    case connect(host, port, device_id) do
      {:ok, client} ->
        ctx = %{
          base_dir: base_dir,
          host: host,
          port: port,
          client: client,
          main_key: nil,
          # J7 restarts the gateway, so it needs the handle the runner booted.
          # nil is legitimate (the in-process test harness has none) and J7
          # reports itself incomplete rather than pretending.
          gateway: Keyword.get(opts, :gateway),
          leg: %{harness: harness, host: host_name, model: Keyword.get(opts, :model)},
          turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, @default_turn_timeout_ms),
          settle_ms: Keyword.get(opts, :settle_ms, @default_settle_ms)
        }

        {ctx, leg} =
          Enum.reduce(ids, {ctx, leg}, fn id, {ctx, leg} ->
            {ctx, rows} = Journeys.run(ctx, id)
            {ctx, Scorecard.add(leg, rows)}
          end)

        SimClient.disconnect(ctx.client)
        # The CURRENT gateway, not the one we were handed: J7 restarts it, and a
        # caller that tears down the pre-restart handle signals a dead pid and
        # can delete the base_dir out from under the live gateway.
        {leg, ctx.gateway}

      {:error, step, reason} ->
        {Scorecard.add(leg, unreachable_rows(host, port, step, reason, ids)),
         Keyword.get(opts, :gateway)}
    end
  end

  @doc """
  A leg blocked before it started: the preflight row plus an `incomplete` row
  for every step that never ran.

  SMOKE P3 — "a preflight FAIL blocks that leg until fixed or waived by name" —
  so nothing boots and no journey runs. The blocked steps are recorded rather
  than omitted, because a step that silently vanishes from a report is how a
  blocked leg reads as a short green one.
  """
  @spec blocked_leg(String.t(), String.t(), Scorecard.Row.t()) :: Leg.t()
  def blocked_leg(harness, host_name, preflight_row) do
    blocked =
      Enum.map(Journeys.oracles(), fn oracle ->
        Scorecard.incomplete(
          oracle.step,
          oracle.label,
          "preflight-failed: #{preflight_row.step} did not pass, so this leg was not booted " <>
            "(SMOKE P3)",
          journey: oracle.journey
        )
      end)

    Scorecard.add(%Leg{harness: harness, host: host_name}, [preflight_row | blocked])
  end

  @doc """
  SMOKE.md's credential PREFLIGHT for one harness leg, as an automated
  scorecard row. Runs BEFORE anything boots — the runbook is explicit that a
  dead grant must be caught first, because downstream it masquerades (no auth
  means no catalog means every model value invalid).

  Everything here goes through the harness REGISTRY; this module names no
  harness and no credential mechanic, which is the seam
  `scripts/check_harness_seam.sh` enforces.

  The grading turns on a question the driver ANSWERS RATHER THAN ASSUMES: is
  this harness's catalog fetch actually gated on the credential? It is measured
  by `catalog_gated?/2` — fetch the catalog from a copy of the org with the
  credential store removed. A harness whose catalog is a live authenticated
  call fails without it (its successful fetch therefore PROVED the grant is
  live); a harness whose catalog is a cached file succeeds without it, so its
  fetch proves only that a file exists.

  - gated + catalog usable  -> `pass`, liveness proved.
  - not gated               -> `incomplete`, PRESENCE-ONLY, pointing at the
    `credential_live?` registry callback (task #15). Not a pass: a populated
    cache beside an expired credential would otherwise read as green, which is
    precisely the false comfort this row exists to prevent.
  """
  @spec preflight(String.t(), String.t()) :: Scorecard.Row.t()
  def preflight(harness, base_dir) do
    step = "P-" <> harness
    label = "auth #{harness}"

    case Enum.find(Tightbeam.Harness.all(), &(&1.wire_name() == harness)) do
      nil -> Scorecard.incomplete(step, label, "#{harness} is not a registered harness")
      module -> probe_credential(module, step, label, base_dir)
    end
  end

  defp probe_credential(module, step, label, base_dir) do
    home = Tightbeam.Homes.home_path(base_dir, Tightbeam.Placement.local_host_name(), module.id())

    cond do
      not module.credential_ready?(target(base_dir), home) ->
        Scorecard.fail(step, label, "the harness reports its credential store is not ready in #{base_dir}")

      true ->
        case module.fetch_catalog(target(base_dir)) do
          {:ok, [_ | _]} -> grade_catalog(module, step, label, base_dir)
          {:ok, []} -> Scorecard.fail(step, label, "catalog fetch returned no models")
          {:error, reason} -> Scorecard.fail(step, label, "catalog fetch failed: #{inspect(reason)}")
        end
    end
  end

  defp grade_catalog(module, step, label, base_dir) do
    if catalog_gated?(module, base_dir) do
      Scorecard.pass(step, label,
        note: "credential store ready; catalog fetch is credential-gated, so the grant is LIVE"
      )
    else
      Scorecard.incomplete(
        step,
        label,
        "PRESENCE-ONLY: the credential store is in place, but this harness's catalog fetch " <>
          "succeeds without it (cache-backed), so nothing here proves the grant is live — an " <>
          "expired credential beside a populated cache would look identical. Liveness needs the " <>
          "credential_live? registry callback (task #15)."
      )
    end
  end

  @doc """
  Whether `module`'s catalog fetch actually depends on the credential store.

  Measured, not assumed: the org's credential-bearing directories are copied to
  a scratch org, the credential store is removed from the COPY, and the catalog
  is fetched there. The real org is never touched.
  """
  @spec catalog_gated?(module(), String.t()) :: boolean()
  def catalog_gated?(module, base_dir) do
    scratch = Path.join(System.tmp_dir!(), "client-e2e-gate-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(scratch)

      for dir <- ["auth", "homes"], File.dir?(Path.join(base_dir, dir)) do
        File.cp_r!(Path.join(base_dir, dir), Path.join(scratch, dir))
      end

      File.rm_rf!(Tightbeam.Credentials.store_dir(scratch, module.credential_provider()))

      case module.fetch_catalog(target(scratch)) do
        {:ok, [_ | _]} -> false
        _ -> true
      end
    after
      File.rm_rf!(scratch)
    end
  end

  # The registry's target shape: `ssh: nil` is what marks the host local, and
  # the leg's gateway is always the local one.
  defp target(base_dir) do
    %{
      base_dir: base_dir,
      host_config: %{base_dir: base_dir, ssh: nil},
      host_name: Tightbeam.Placement.local_host_name(),
      options: %{},
      sh: &System.cmd(hd(&1), tl(&1), stderr_to_stdout: true)
    }
  end

  defp connect(host, port, device_id) do
    case SimClient.pair(host, port, device_id: device_id, claimed_name: "client-e2e") do
      {:ok, %{token: token}} ->
        case SimClient.connect(host, port, token, device_id: device_id) do
          {:ok, client} -> {:ok, client}
          {:error, reason} -> {:error, :auth, reason}
        end

      {:error, reason} ->
        {:error, :pair, reason}
    end
  end

  # The vacuity guard made concrete: no client, no journeys, and the leg says
  # so in the client's own vocabulary (the transport error it hit) rather than
  # reporting nothing.
  defp unreachable_rows(host, port, step, reason, ids) do
    detail = "#{step} failed against #{host}:#{port}: #{inspect(reason)}"

    blocked =
      Journeys.oracles()
      |> Enum.filter(&(&1.journey in ids and &1.step not in ["1", "2"]))
      |> Enum.map(fn oracle ->
        Scorecard.incomplete(oracle.step, oracle.label, "no client session: #{detail}",
          journey: oracle.journey
        )
      end)

    [
      Scorecard.fail("1", "boot", detail, journey: "J0"),
      Scorecard.fail("2", "pair", detail, journey: "J0") | blocked
    ]
  end
end
