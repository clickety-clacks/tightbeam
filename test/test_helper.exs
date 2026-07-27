# The suite is not hermetic, and every dependency it has on the machine around it
# is named here. It was silent before, and silence is what let a macOS-only suite
# look green for the project's whole life: on a dev mac the developer's own
# environment satisfied all of these by accident, so the first linux run reported
# 44 failures, three of which were never about linux at all. A missing dependency
# now refuses the run and says which one and how to satisfy it, because each of
# them fails as something else entirely — a phantom identity conflict with no
# conflicting paths, a boot that raises "no usable harness CLI", a journey that
# reports `:enoent` without naming what was not found.
missing =
  []
  |> then(fn acc ->
    # `git merge` and `git commit` refuse to write without a committer, and
    # Identity.relearn!/1 merges with no author env, so a host with no git
    # identity gets {:conflict, []} — a conflict with no conflicting paths.
    result =
      try do
        System.cmd("git", ["var", "GIT_COMMITTER_IDENT"], stderr_to_stdout: true)
      rescue
        _ -> {"", :git_missing}
      end

    case result do
      {_ident, 0} ->
        acc

      {_output, :git_missing} ->
        ["git on PATH (the identity suite drives a real git repo)." | acc]

      {_output, _status} ->
        [
          "a git committer identity (identity_test commits and merges a real repo).\n" <>
            "      git config --global user.name  \"your name\"\n" <>
            "      git config --global user.email \"you@example.com\""
          | acc
        ]
    end
  end)
  |> then(fn acc ->
    # acp_conn, acp_adapter and adapter_coordinator run their ACP stubs with
    # `System.find_executable("node")`, which is nil rather than an error when
    # node is absent — the port then fails to open on a cmd whose head is nil.
    if System.find_executable("node") do
      acc
    else
      ["node on PATH (the ACP adapter tests exec their stub servers with it)." | acc]
    end
  end)
  |> then(fn acc ->
    # Gateway boot refuses unless at least one REGISTERED harness CLI probes on
    # PATH (Gateway.assert_harness_binary_ready!/1). The test registry is
    # [Claude, Codex, Fixture] — :fixture_harness is on in config/test.exs — so
    # any one of these three names satisfies it.
    if Enum.any?(["claude", "codex", "fixture"], &System.find_executable/1) do
      acc
    else
      [
        "a registered harness CLI on PATH — claude, codex, or fixture — for the\n" <>
          "      gateway boot probe. The in-repo fixture harness CLI is enough:\n" <>
          "      export PATH=\"#{Path.expand("../priv/harness_cli", __DIR__)}:$PATH\""
        | acc
      ]
    end
  end)
  |> then(fn acc ->
    # ClientE2E.Substrate.query/2 reads the gateway's state.db by EXEC'ing
    # sqlite3(1) — it does not go through exqlite. Without it J0 reports
    # "driver error: Erlang error: :enoent", which names neither sqlite3 nor
    # PATH. The GitHub runner images happen to ship it and every dev mac has it;
    # shrdlu does not, which is one of the 44 first-linux-run failures.
    if System.find_executable("sqlite3") do
      acc
    else
      [
        "sqlite3 on PATH (client_e2e reads state.db by exec'ing it, not via exqlite)."
        | acc
      ]
    end
  end)
  |> then(fn acc ->
    # rail_script, conformance's rail-exec fixtures and cli_integration exec the
    # RELEASE binary, not a debug build and not `cargo run`.
    binary = Path.expand("../cli/target/release/tightbeam", __DIR__)

    if File.exists?(binary) do
      acc
    else
      [
        "the release CLI at #{binary}\n" <>
          "      (rail-exec and cli_integration exec it directly).\n" <>
          "      cargo build --release --manifest-path cli/Cargo.toml"
        | acc
      ]
    end
  end)

if missing != [] do
  IO.puts(:stderr, """

  This suite cannot run here. #{length(missing)} declared prerequisite(s) missing:

  #{missing |> Enum.reverse() |> Enum.with_index(1) |> Enum.map_join("\n\n  ", fn {text, i} -> "#{i}. #{text}" end)}

  Nothing is skipped and nothing is faked around this: each of these changes what
  the suite observes, so a run without them would report a verdict it has not earned.
  """)

  System.halt(1)
end

# ExUnit's default assert_receive budget is 100ms, and nobody chose it. Several
# acp_adapter tests wait on a message that can only arrive after a real `node`
# ACP stub has booted and completed a handshake, and node's cold start alone eats
# most of 100ms on a loaded macOS runner: two of three macOS CI samples failed a
# DIFFERENT subset of that one module (4 then 6 tests, all "no matching message
# after 100ms" with an empty mailbox), while the same module passes on a quiet dev
# mac and on the linux runner. That is a budget failure, not a defect the suite
# found, and a flaky gate cannot arbitrate platform parity.
#
# This weakens no assertion. Every one of these tests still requires its exact
# message and still fails if it never arrives; the only thing that changes is how
# long a correct message is allowed to take. Tests that assert something must NOT
# arrive use refute_receive, whose own timeout is untouched.
ExUnit.start(assert_receive_timeout: 1_000)

suite_tmp = Application.fetch_env!(:tightbeam, :test_suite_tmp)

# Remove the suite scratch root when the VM exits, NOT after each suite run:
# `--repeat-until-failure` reruns the whole suite inside one BEAM and fires
# `ExUnit.after_suite/1` every time. Deleting the root between iterations leaves
# TMPDIR dangling, so `System.tmp_dir!/0` silently falls back to the shared /tmp
# and per-test scratch names collide across concurrent `mix test` processes.
System.at_exit(fn _status -> File.rm_rf!(suite_tmp) end)
