defmodule Tightbeam.ClientE2E.RunPackage do
  @moduledoc "Builds the package used by every gateway leg in one client-e2e run."
  alias Tightbeam.ClientE2E.{Provenance, Scorecard}

  def build!(repo_root, stamp) do
    package = Path.join(repo_root, "_build/npm/tightbeam")
    report = Path.join(repo_root, "_build/client-e2e-run.log")
    # An old package must never stand in for this run's missing build output.
    File.rm_rf!(package)
    File.mkdir_p!(Path.dirname(report))

    {output, status} =
      System.cmd("sh", ["packaging/assemble.sh"], cd: repo_root, stderr_to_stdout: true)

    IO.write(output)
    File.write!(report, output)

    if status != 0,
      do: raise("run package build failed with exit status #{status}; log: #{report}")

    unless File.dir?(package), do: raise("run package build produced no package at #{package}")

    unless File.regular?(Path.join(package, "bin/tightbeam-gateway")),
      do: raise("run package has no bin/tightbeam-gateway at #{package}")

    warnings =
      dirty_warnings(stamp) ++ manifest_warnings(package) ++ stamp_warnings(repo_root, stamp)

    cli = Path.join(package, "bin/tightbeam")
    digest = :crypto.hash(:sha256, File.read!(cli)) |> Base.encode16(case: :lower)
    summary = Scorecard.warning_report(warnings) <> "\nPackaged CLI SHA-256: #{digest}\n"
    IO.puts(summary)
    File.write!(report, summary, [:append])
    %{path: package, cli: cli, cli_sha256: digest, warnings: warnings, report: report}
  end

  def dirty_warnings({:clean, _sha}), do: []

  def dirty_warnings({:dirty, _sha, _fingerprint, listing} = stamp) do
    ["dirty tree: #{Provenance.to_header(stamp)}\n#{String.trim(listing)}"]
  end

  def manifest_warnings(package) do
    Tightbeam.LiveBasePayload.verify!(package)
    []
  rescue
    error -> ["package manifest could not be verified: #{Exception.message(error)}"]
  end

  def stamp_warnings(repo_root, before) do
    after_build = Provenance.stamp(repo_root)

    if before == after_build do
      []
    else
      [
        "package provenance changed: run start #{Provenance.to_header(before)}; " <>
          "after build #{Provenance.to_header(after_build)}"
      ]
    end
  rescue
    error ->
      [
        "package provenance: post-build stamp could not be taken " <>
          "(run start #{Provenance.to_header(before)}): #{Exception.message(error)}"
      ]
  end
end
