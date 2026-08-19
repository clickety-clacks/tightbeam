defmodule Tightbeam.ApplicationRefusalTest do
  # AN EXPECTED REFUSAL MUST EXIT WITH ITS SENTENCE; A DEFECT MUST STILL CRASH.
  #
  # Measured on shrdlu from the npm tarball, before the fix: the no-harness-CLI refusal
  # printed the right words and then produced "Kernel pid terminated
  # (application_controller)" plus an erl_crash.dump — a release runs the app as
  # permanent, so `{:error, _}` from start/2 escalates into a kernel panic.
  #
  # This boots the application IN A SUBPROCESS rather than asserting against a seam.
  # The previous version of this file could not fail for its stated reason: its third
  # test asserted `Application.get_env(:tightbeam, :refusal_exit, :halt) == :halt`,
  # which is the fallback the assertion itself supplies — it exercised Elixir's standard
  # library, and stayed green against a `refuse/1` that had been changed to `:ok`. The
  # other two reached the decision through a public `refuse_for_test/1` and a config
  # hook that let production return instead of halting; both are gone, so the only way
  # left to prove this is to run it.
  use ExUnit.Case, async: true

  # The sentence as an operator sees it, anchored at its START. Both Logger and OTP's
  # own "application exited" notice quote the same words mid-line behind a timestamp and
  # a level tag, so only a line that BEGINS with them can have come from
  # `IO.puts(:stderr, ...)`.
  @refusal "Tightbeam cannot start because no registered harness CLI is installed"

  # A PATH with a real Elixir toolchain and NO harness CLI.
  #
  # Not "the toolchain's own bindir": on this box `codex` is installed into
  # /opt/homebrew/bin alongside `elixir`, so borrowing that directory wholesale would
  # have handed the harness right back and the boot would have SUCCEEDED — the test
  # would then fail for a reason it does not name. (The guard below caught exactly
  # that, which is why it is an assertion and not a comment.)
  #
  # So: link only the executables `mix run` needs into a directory of our own, and add
  # the system dirs for the `dirname`/`basename` the elixir wrapper shells out to.
  defp harnessless_path do
    bin = Path.join(System.tmp_dir!(), "tb-toolchain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin)
    on_exit_rm(bin)

    # WRAPPER SCRIPTS, not symlinks. OTP's `erl` is itself a shell script that
    # derives its root from $0's directory; invoked through a symlink in our
    # scratch dir it cannot, and falls back to a build-time path that does not
    # exist on the host — measured on the macOS CI runner as exit 126,
    # "/tmp/otp-aarch64-apple-darwin/.../erlexec: No such file or directory".
    # An exec by absolute real path keeps $0 pointing where the tool lives.
    for tool <- ~w(elixir elixirc mix erl escript) do
      case System.find_executable(tool) do
        nil ->
          :ok

        real ->
          path = Path.join(bin, tool)

          if tool == "mix" do
            # `elixir -S mix` resolves mix from PATH and evaluates its CONTENT
            # as Elixir source — a sh wrapper here is handed to the Elixir
            # compiler ("undefined variable exec"). A symlink reads through.
            File.ln_s!(real, path)
          else
            File.write!(path, "#!/bin/sh\nexec #{real} \"$@\"\n")
            File.chmod!(path, 0o755)
          end
      end
    end

    [bin, "/usr/bin", "/bin"]
  end

  defp boot_with(env, path, tmp) do
    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-S", "mix", "run", "--no-halt"],
        cd: File.cwd!(),
        stderr_to_stdout: true,
        env:
          [
            {"PATH", path},
            {"MIX_ENV", "prod"},
            {"TIGHTBEAM_BASE_DIR", tmp},
            {"TIGHTBEAM_CWD", tmp},
            {"TIGHTBEAM_PORT", "0"}
          ] ++ env
      )

    {output, status}
  end

  defp on_exit_rm(dir), do: ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)

  @tag :refusal_subprocess
  @tag timeout: 180_000
  test "a first run with no harness CLI on PATH says so, exits 1, and writes no crash dump" do
    dirs = harnessless_path()

    for dir <- dirs, harness <- ["claude", "codex"] do
      refute File.exists?(Path.join(dir, harness)),
             "#{harness} is on the PATH this test builds (#{dir}), so the boot would " <>
               "succeed and this test could not fail for its stated reason"
    end

    parent = Path.join(System.tmp_dir!(), "tb-refusal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(parent)
    on_exit_rm(parent)

    # The base dir is NOT created. A refusal must decide before it builds anything, so
    # its continued absence is an assertion, not a precondition.
    base = Path.join(parent, "base")
    dump = Path.join(parent, "erl_crash.dump")

    dump_before = dump_stamps(dirs_to_watch(parent))

    {output, status} = boot_with([{"ERL_CRASH_DUMP", dump}], Enum.join(dirs, ":"), base)

    # 1. IT EXITS NON-ZERO. A refusal that exits 0 is a gateway that "started".
    assert status == 1, "expected exit 1, got #{status}. Output:\n#{output}"

    # 2. IT SAYS WHY, AS A BARE SENTENCE, NOT ONLY AS A LOG LINE.
    #
    #    Asserted as an UNPREFIXED line, deliberately. `output =~ @refusal` is not
    #    enough and was measured passing against the broken form: `Logger.error/1`
    #    prints the same words with a timestamp and an `[error]` tag, so a
    #    Logger-only implementation satisfies a substring check while producing
    #    exactly the failure this fix exists to prevent — Logger is asynchronous and
    #    `System.halt/1` does not flush it, so the release exited 1 with a ZERO-BYTE
    #    log. Only `IO.puts(:stderr, ...)` puts the sentence at the start of a line.
    assert Enum.any?(String.split(output, "\n"), &String.starts_with?(&1, @refusal)),
           "the refusal reached the operator only through the async logger, not " <>
             "synchronously on stderr. Output:\n#{output}"

    # 3. IT DOES NOT ESCALATE. If `refuse/1` returns {:error, _} instead of halting,
    #    OTP reports the failed application start itself — which is the shape that
    #    becomes "Kernel pid terminated" plus a dump in a release, where the app is
    #    permanent. Both phrasings are pinned: the mix-run one this test can reach,
    #    and the release one it cannot.
    refute output =~ "returned an error",
           "start/2 returned an error instead of halting, so OTP reported the " <>
             "refusal rather than us. Output:\n#{output}"

    refute output =~ "Kernel pid terminated",
           "the refusal escalated into a kernel panic. Output:\n#{output}"

    # 4. IT NAMES THE CAUSE AND THE REMEDY, WITHOUT A STACKTRACE. These assertions
    #    moved here from an in-process test in application_test.exs that called
    #    `Application.start/2` directly and asserted `{:error, message}`. That test
    #    depended on the deleted `:refusal_exit` seam; against a refusal that really
    #    halts, it took the whole suite VM down with it. There is now one test of this
    #    behaviour and it exercises the real path.
    assert output =~ "expected on a fresh machine"
    assert output =~ "Install `claude` or `codex`"
    assert output =~ "Run `tightbeam doctor`"

    refute output =~ "** (",
           "the refusal carried a stacktrace, which is the shape it exists to replace. " <>
             "Output:\n#{output}"

    # 5. IT DECIDES BEFORE IT BUILDS ANYTHING. The base dir was never created by this
    #    test, and a refusal must not create it either — no store, no artifacts.
    refute File.exists?(base),
           "the refusal created its base dir before deciding it could not start"

    # 6. IT LEAVES NO NEW DUMP. The dump was the whole defect: a first-run state
    #    presented as a VM crash, in the install directory. ERL_CRASH_DUMP is pointed at
    #    a path of our own so this cannot be satisfied by a dump landing elsewhere.
    refute File.exists?(dump), "an expected refusal wrote a crash dump"
    #
    #    Asserted as "no dump APPEARED OR CHANGED", not "no dump exists": the VM writes
    #    erl_crash.dump into its working directory, which for `mix run` is the project
    #    root, and this repository already carries an unrelated one from a crash on
    #    2026-07-28. A bare existence check therefore failed on a stale file and would
    #    equally have PASSED for the wrong reason on a machine where someone had just
    #    deleted one.
    assert dump_stamps(dirs_to_watch(parent)) == dump_before,
           "an expected refusal wrote a crash dump into the working directory"
  end

  defp dirs_to_watch(parent), do: [parent, File.cwd!()]

  defp dump_stamps(dirs) do
    Map.new(dirs, fn dir ->
      path = Path.join(dir, "erl_crash.dump")

      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime, size: size}} -> {path, {mtime, size}}
        {:error, _} -> {path, :absent}
      end
    end)
  end
end
