defmodule Tightbeam.ReleaseCookieResolutionTest do
  # Exercise the actual generated launcher without reading credential files or
  # starting a distributed node.
  use Tightbeam.TestCase, async: false

  @moduletag :release_build

  setup_all do
    mix = System.find_executable("mix") || "mix"

    release_dir =
      Path.join(System.tmp_dir!(), "tb-real-release-#{System.unique_integer([:positive])}")

    {out, status} =
      System.cmd(mix, ["release", "--overwrite", "--path", release_dir],
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    assert status == 0, "mix release failed:\n#{out}"

    launcher = Path.join(release_dir, "bin/tightbeam_gateway")
    assert {:error, :enoent} = File.lstat(Path.join(release_dir, "releases/COOKIE"))

    on_exit(fn -> File.rm_rf!(release_dir) end)
    %{launcher: launcher}
  end

  test "the generated launcher uses a disconnected VM even with a conflicting distribution environment",
       %{launcher: launcher} do
    expr =
      ~s{unless Node.alive?() or System.get_env("RELEASE_COOKIE"), do: IO.puts("local release eval")}

    {out, status} =
      System.cmd(launcher, ["eval", expr],
        env: [{"RELEASE_DISTRIBUTION", "sname"}, {"RELEASE_COOKIE", "synthetic-unused"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert String.trim(out) == "local release eval"
  end

  test "the generated launcher refuses distributed commands before execution", %{
    launcher: launcher
  } do
    for verb <- ~w(rpc remote stop restart pid) do
      {out, status} = System.cmd(launcher, [verb], stderr_to_stdout: true)
      assert status == 64, out
      assert out =~ "Distributed commands are unavailable"
    end
  end
end
