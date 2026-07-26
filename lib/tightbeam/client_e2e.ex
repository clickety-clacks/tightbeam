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
          preflight: boolean(),
          turn_timeout_ms: pos_integer(),
          settle_ms: pos_integer()
        ]

  @doc """
  Runs one leg and returns its scorecard leg.

  Options: `:host`, `:port`, `:base_dir` (required); `:harness` and
  `:host_name` name the leg; `:journeys` restricts the walk (defaults to all
  of `Journeys.ids/0`); `:preflight` (default true) runs SMOKE's P1/P2
  credential check for this leg's harness first.
  """
  @spec run_leg(opts()) :: Leg.t()
  def run_leg(opts) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.fetch!(opts, :port)
    base_dir = Keyword.fetch!(opts, :base_dir)
    harness = Keyword.get(opts, :harness, "claude")
    host_name = Keyword.get(opts, :host_name, Tightbeam.Placement.local_host_name())
    ids = Keyword.get(opts, :journeys, Journeys.ids())

    leg = %Leg{harness: harness, host: host_name}

    leg =
      if Keyword.get(opts, :preflight, true) do
        Scorecard.add(leg, preflight(harness, base_dir))
      else
        leg
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
        leg

      {:error, step, reason} ->
        Scorecard.add(leg, unreachable_rows(host, port, step, reason, ids))
    end
  end

  @doc """
  SMOKE.md's credential PREFLIGHT for one harness leg, as an automated
  scorecard row.

  Dead credentials do not fail as "auth" downstream — they masquerade (an
  expired grant surfaces as an invalid model ref, because no auth means no
  catalog means every value invalid), so the run checks the grant before it
  walks anything. A preflight FAIL blocks the leg, and after a clean preflight
  any auth-shaped failure later in the run is a FINDING, not noise.

  Two checks, both through the harness REGISTRY — this module names no harness
  and no credential mechanic, which is the seam `scripts/check_harness_seam.sh`
  enforces:

  1. `credential_ready?/2` — the store rows the harness needs are in place.
  2. `fetch_catalog/1` — the catalog the harness serves is usable. For a
     harness whose catalog is a live authenticated fetch this is a real grant
     probe; for one whose catalog is a cached file it proves the cache, not
     the grant.

  That second caveat is a real gap against SMOKE's P1/P2, which run each
  harness's own liveness command. Expressing those through the registry needs
  a `credential_live?` callback that does not exist yet; until it does, the
  row's note says which of the two checks stood behind the verdict rather than
  claiming the stronger one.
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
    host_name = Tightbeam.Placement.local_host_name()

    # The registry's target shape: `ssh: nil` is what marks the host local, and
    # the leg's gateway is always the local one.
    target = %{
      base_dir: base_dir,
      host_config: %{base_dir: base_dir, ssh: nil},
      host_name: host_name,
      options: %{},
      sh: &System.cmd(hd(&1), tl(&1), stderr_to_stdout: true)
    }

    home = Tightbeam.Homes.home_path(base_dir, host_name, module.id())

    cond do
      not module.credential_ready?(target, home) ->
        Scorecard.fail(step, label, "the harness reports its credential store is not ready in #{base_dir}")

      true ->
        case module.fetch_catalog(target) do
          {:ok, [_ | _]} ->
            Scorecard.pass(step, label, note: "credential store ready; catalog fetch usable")

          {:ok, []} ->
            Scorecard.fail(step, label, "catalog fetch returned no models")

          {:error, reason} ->
            Scorecard.fail(step, label, "catalog fetch failed: #{inspect(reason)}")
        end
    end
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
