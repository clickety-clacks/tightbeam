import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{base: base, config: config} ->
  # Synthetic package layout only: never execute these bytes or install a package.
  pkg_dir = Path.join(Path.dirname(base), "release-cli-fixture")
  release_root = Path.join(pkg_dir, "release")
  File.mkdir_p!(Path.join(pkg_dir, "bin"))
  File.mkdir_p!(release_root)
  File.write!(Path.join(pkg_dir, "bin/tightbeam"), "release-cli-binary")
  cwd = Path.join(pkg_dir, "cwd")
  File.mkdir_p!(cwd)
  refute File.exists?(Path.join(cwd, "cli/target"))
  previous = System.get_env("RELEASE_ROOT")
  System.put_env("RELEASE_ROOT", release_root)

  try do
    File.cd!(cwd, fn ->
      Gateway.children(%{config | port: 0})
      installed = Path.join(base, "bin/tightbeam")
      assert File.read!(installed) == "release-cli-binary"
      assert File.stat!(installed).mode |> Bitwise.band(0o777) == 0o755
    end)
  after
    if previous,
      do: System.put_env("RELEASE_ROOT", previous),
      else: System.delete_env("RELEASE_ROOT")
  end
end)

IO.puts("guarded-gateway-release-layout: ok")
