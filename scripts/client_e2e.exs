# Client e2e — walks the SMOKE.md operator journeys with a sim client against a
# REAL gateway, one leg per harness, and prints the v1 scorecard.
#
#   TIGHTBEAM_CLIENT_E2E_TEMPLATE=~/.tightbeam-beam \
#   TIGHTBEAM_CLIENT_E2E_PORT=12100 \
#   TIGHTBEAM_CLIENT_E2E_HARNESSES=claude,codex \
#   TIGHTBEAM_SMOKE_MODEL_CLAUDE=fable \
#   TIGHTBEAM_SMOKE_MODEL_CODEX='gpt-5.6-sol[medium]' \
#   mix run --no-start scripts/client_e2e.exs
#
# Each leg provisions a FRESH base_dir from the template org (credentials,
# homes, identity — never state.db), boots its own gateway on its own port,
# walks J0-J6, then SIGTERMs the gateway and removes the directory. Exits
# non-zero unless the run verdict is PASS, and writes the scorecard to
# TIGHTBEAM_CLIENT_E2E_OUT when set.
#
# Journeys J7 (restart resilience) and J8 (wakes) are v1 spec scope but are NOT
# driven here; they are recorded as manual rows so their absence is visible in
# the scorecard rather than silent.

alias Tightbeam.ClientE2E
alias Tightbeam.ClientE2E.{LegGateway, Scorecard}

defmodule ClientE2ERunner do
  @unautomated [
    {"14", "restart resilience", "J7 is spec scope, not driven by this lane's driver"},
    {"15", "restart queue survival", "J7 is spec scope, not driven by this lane's driver"},
    {"16", "wakes", "J8 is spec scope, not driven by this lane's driver"}
  ]

  def run do
    template = env!("TIGHTBEAM_CLIENT_E2E_TEMPLATE")
    base_port = env("TIGHTBEAM_CLIENT_E2E_PORT", "12100") |> String.to_integer()
    repo_root = File.cwd!()

    if base_port < 12_000 do
      raise "client-e2e runs on throwaway ports >= 12000 (got #{base_port})"
    end

    harnesses = legs()

    legs =
      harnesses
      |> Enum.with_index()
      |> Enum.map(fn {harness, index} -> run_leg(harness, template, base_port + index, repo_root) end)

    scorecard = %Scorecard{
      legs: legs,
      date: Date.utc_today() |> Date.to_iso8601(),
      gateway_sha: gateway_sha(),
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
      verdict -> System.halt(if(verdict == :fail, do: 1, else: 2))
    end
  end

  defp run_leg(harness, template, port, repo_root) do
    base_dir = Path.expand("~/.tightbeam-client-e2e-#{harness}-#{System.os_time(:second)}")
    IO.puts("\nclient-e2e leg #{harness} port=#{port} base_dir=#{base_dir}")
    LegGateway.provision!(template, base_dir)

    gateway =
      LegGateway.boot!(base_dir, port,
        repo_root: repo_root,
        env: leg_env(harness)
      )

    try do
      leg =
        ClientE2E.run_leg(
          host: "127.0.0.1",
          port: port,
          base_dir: base_dir,
          harness: harness,
          model: model_for(harness)
        )

      leg = Enum.reduce(@unautomated, leg, fn {step, label, why}, leg ->
        Scorecard.add(leg, Scorecard.manual(step, label, why))
      end)

      IO.puts("leg #{harness}: #{Scorecard.verdict_text(Scorecard.leg_verdict(leg))}")
      leg
    after
      LegGateway.teardown(gateway)
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

  defp gateway_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp env(name, default), do: System.get_env(name) || default

  defp env!(name) do
    System.get_env(name) ||
      raise "#{name} is required (see the header of scripts/client_e2e.exs)"
  end
end

ClientE2ERunner.run()
