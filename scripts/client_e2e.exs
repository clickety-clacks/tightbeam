# Client e2e — walks the SMOKE.md operator journeys with a sim client against a
# REAL gateway, one leg per registered harness, and prints the v1 scorecard.
#
#   TIGHTBEAM_CLIENT_E2E_TEMPLATE=~/.tightbeam-smoke-<sha> \
#   TIGHTBEAM_CLIENT_E2E_PORT=12100 \
#   TIGHTBEAM_CLIENT_E2E_HARNESSES=claude,codex \
#   TIGHTBEAM_SMOKE_MODEL_CLAUDE='claude-sonnet-5[medium]' \
#   TIGHTBEAM_SMOKE_MODEL_CODEX='gpt-5.6-sol[medium]' \
#   mix run --no-start scripts/client_e2e.exs
#
# Per leg, in this order — the order IS the contract:
#   1. PREFLIGHT the harness credential, BEFORE anything boots: a dead grant
#      masquerades downstream as an invalid model ref rather than as auth.
#   2. Provision a FRESH base_dir from the template org (credentials, homes,
#      identity — never state.db).
#   3. Boot a gateway on its own run-local port.
#   4. Walk every journey in Tightbeam.ClientE2E.Journeys.ids/0 (J0-J8).
#   5. SIGTERM, await exit, remove the directory — and if the process outlives
#      the window, KEEP the directory and say so out loud.
#
# PROVENANCE: the run refuses to start on a dirty worktree, so a scorecard's sha
# names the code that actually produced it. TIGHTBEAM_CLIENT_E2E_ALLOW_DIRTY=1
# runs anyway and stamps the scorecard DIRTY with a hash of the diff.
#
# Exits 0 only on RUN VERDICT PASS (1 on FAIL, 2 on INCOMPLETE), and writes the
# scorecard to TIGHTBEAM_CLIENT_E2E_OUT when set.

alias Tightbeam.ClientE2E
alias Tightbeam.ClientE2E.{LegGateway, Provenance, Scorecard}

defmodule ClientE2ERunner do
  def run do
    template = env!("TIGHTBEAM_CLIENT_E2E_TEMPLATE")
    base_port = env("TIGHTBEAM_CLIENT_E2E_PORT", "12100") |> String.to_integer()
    repo_root = File.cwd!()

    if base_port < 12_000 do
      raise "client-e2e runs on throwaway ports >= 12000 (got #{base_port})"
    end

    provenance = provenance!()

    legs =
      legs()
      |> Enum.with_index()
      |> Enum.map(fn {harness, index} -> run_leg(harness, template, base_port + index, repo_root) end)

    scorecard = %Scorecard{
      legs: legs,
      date: Date.utc_today() |> Date.to_iso8601(),
      gateway_sha: provenance,
      client_build: "sim-client (driver)"
    }

    registered = Enum.map(Tightbeam.Harness.all(), & &1.wire_name())
    markdown = Scorecard.to_markdown(scorecard, registered)
    IO.puts("\n" <> markdown)

    if out = System.get_env("TIGHTBEAM_CLIENT_E2E_OUT") do
      File.write!(out, markdown)
      IO.puts("scorecard written to #{out}")
    end

    case Scorecard.run_verdict(scorecard, registered) do
      :pass -> :ok
      :fail -> System.halt(1)
      {:incomplete, _blockers} -> System.halt(2)
    end
  end

  defp run_leg(harness, template, port, repo_root) do
    base_dir = Path.expand("~/.tightbeam-client-e2e-#{harness}-#{System.os_time(:second)}")
    IO.puts("\nclient-e2e leg #{harness} port=#{port} base_dir=#{base_dir}")
    LegGateway.provision!(template, base_dir)

    # Preflight FIRST, against the provisioned org, while no gateway exists.
    preflight_row = ClientE2E.preflight(harness, base_dir)
    IO.puts("  preflight #{preflight_row.step}: #{preflight_row.status}")

    # SMOKE P3: anything other than PASS blocks the leg. In particular,
    # credential liveness UNKNOWN is an INCOMPLETE/blocker, never permission to
    # boot. Every step the leg would have walked is recorded as blocked rather
    # than omitted.
    if ClientE2E.preflight_blocked?(preflight_row) do
      IO.puts("  preflight BLOCKED — leg not booted (SMOKE P3)")
      leg = ClientE2E.blocked_leg(harness, Tightbeam.Placement.local_host_name(), preflight_row)
      IO.puts("leg #{harness}: #{Scorecard.verdict_text(Scorecard.leg_verdict(leg))}")
      File.rm_rf(base_dir)
      leg
    else
      run_booted_leg(harness, base_dir, port, repo_root, preflight_row)
    end
  end

  defp run_booted_leg(harness, base_dir, port, repo_root, preflight_row) do
    try do
      # Boot INSIDE the try so the after-block owns teardown on every path,
      # including a boot that half-succeeds and leaves a process behind.
      case LegGateway.boot(base_dir, port, repo_root: repo_root, env: leg_env(harness)) do
        {:error, reason, gateway} ->
          Process.put(:leg_gateway, gateway)

          %Scorecard.Leg{harness: harness, host: Tightbeam.Placement.local_host_name()}
          |> Scorecard.add(preflight_row)
          |> Scorecard.add(
            Scorecard.fail(
              "1",
              "boot",
              "gateway did not come up: #{inspect(reason)}; log: #{gateway.log_path}",
              journey: "J0"
            )
          )

        {:ok, gateway} ->
          Process.put(:leg_gateway, gateway)

          # run_leg hands back the CURRENT gateway: J7 restarts it, and tearing
          # down the pre-restart handle would signal a dead pid and delete the
          # base_dir from under the live one.
          {leg, current_gateway} =
            ClientE2E.run_leg(
              host: "127.0.0.1",
              port: port,
              base_dir: base_dir,
              harness: harness,
              model: model_for(harness),
              gateway: gateway,
              preflight_row: preflight_row
            )

          Process.put(:leg_gateway, current_gateway || gateway)
          IO.puts("leg #{harness}: #{Scorecard.verdict_text(Scorecard.leg_verdict(leg))}")
          leg
      end
    after
      teardown(Process.get(:leg_gateway), base_dir)
      Process.delete(:leg_gateway)
    end
  end

  # A gateway that outlived SIGTERM keeps its directory, and gets said out loud:
  # deleting state from under a live process makes the next leg's bind failure
  # unexplainable.
  defp teardown(nil, base_dir) do
    IO.puts("  no gateway handle; leaving #{base_dir} in place")
  end

  defp teardown(gateway, _base_dir) do
    case LegGateway.teardown(gateway) do
      :ok ->
        :ok

      {:error, :still_running, pid} ->
        IO.puts(
          "  WARNING: gateway pid #{pid} outlived SIGTERM; base_dir KEPT at " <>
            "#{gateway.base_dir} (port #{gateway.port} may still be held)"
        )

      {:error, :not_removed, path, reason} ->
        IO.puts(
          "  WARNING: gateway stopped, but #{path} could not be removed " <>
            "(#{inspect(reason)}); base_dir KEPT at #{gateway.base_dir}"
        )
    end
  end

  defp leg_env(harness) do
    [
      {"TIGHTBEAM_DEFAULT_HARNESS", harness},
      {"TIGHTBEAM_DEFAULT_MODEL", model_for(harness)}
    ]
  end

  defp model_for(harness) do
    env!("TIGHTBEAM_SMOKE_MODEL_#{String.upcase(harness)}")
  end

  defp legs do
    case System.get_env("TIGHTBEAM_CLIENT_E2E_HARNESSES") do
      nil -> Enum.map(Tightbeam.Harness.all(), & &1.wire_name())
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  # The scorecard's sha must name the code that produced it, or a PASS proves an
  # unrecorded working-tree state. The stamp itself lives in
  # Tightbeam.ClientE2E.Provenance, where the suite can hold it — both review
  # rounds found their provenance defects in script code no test could reach.
  defp provenance! do
    case Provenance.stamp() do
      {:clean, sha} ->
        sha

      {:dirty, _sha, fingerprint, listing} = stamp ->
        if System.get_env("TIGHTBEAM_CLIENT_E2E_ALLOW_DIRTY") == "1" do
          Provenance.to_header(stamp)
        else
          raise """
          refusing to run on a dirty worktree — a scorecard from an uncommitted tree \
          cannot be reproduced from its sha.

          #{String.trim(listing)}

          Commit, or set TIGHTBEAM_CLIENT_E2E_ALLOW_DIRTY=1 to run with the scorecard \
          stamped DIRTY (diff #{fingerprint}).
          """
        end
    end
  end

  defp env(name, default), do: System.get_env(name) || default

  defp env!(name) do
    System.get_env(name) ||
      raise "#{name} is required (see the header of scripts/client_e2e.exs)"
  end
end

ClientE2ERunner.run()
