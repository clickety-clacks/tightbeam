# An authoritative run must come through scripts/verify_mix.sh.  Focused developer
# runs do not set this marker and remain ordinary `mix test test/file.exs` commands.
# The wrapper names this VM through argv instead of an inherited Erlang flag, forces
# OS-owned port allocation, and supplies the expected name so this seam can prove it
# received the isolated invocation rather than merely trusting a marker.
if System.get_env("TIGHTBEAM_AUTHORITATIVE_GATE") == "1" do
  expected_node = System.get_env("TIGHTBEAM_GATE_NODE")
  actual_node = node() |> Atom.to_string() |> String.split("@", parts: 2) |> hd()
  port = Application.get_env(:tightbeam, :port)

  problems =
    []
    |> then(fn acc ->
      if is_binary(expected_node) and String.starts_with?(expected_node, "tightbeam_mix_gate_"),
        do: acc,
        else: ["TIGHTBEAM_GATE_NODE is missing or invalid" | acc]
    end)
    |> then(fn acc ->
      if actual_node == expected_node,
        do: acc,
        else: ["suite node is #{actual_node}, expected #{inspect(expected_node)}" | acc]
    end)
    |> then(fn acc ->
      if port == 0,
        do: acc,
        else: ["test gateway port is #{inspect(port)}, expected 0" | acc]
    end)

  if problems != [] do
    IO.puts(:stderr, """

    This authoritative Mix gate is not isolated:

    #{problems |> Enum.reverse() |> Enum.map_join("\n", &"  - #{&1}")}

    Run scripts/verify_mix.sh instead of marking a direct mix test as authoritative.
    """)

    System.halt(1)
  end

  # The claim is consumed by this top-level VM. Some conformance tests launch
  # nested focused Mix tests, and an argv-level node name deliberately does not
  # propagate to them. Leaving the claim in the environment would make those
  # ordinary child runs impersonate an authoritative gate and refuse correctly.
  System.delete_env("TIGHTBEAM_AUTHORITATIVE_GATE")
  System.delete_env("TIGHTBEAM_GATE_NODE")
end

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
    # The C5 script guards are real /bin/sh scripts and they parse their input with
    # `jq` and resolve their workdir with `realpath`
    # (test/conformance/c5_script_guards/scripts/*). A host without either does not
    # fail loudly: the script dies, the wrapper reports a nonzero exit, the
    # substrate classifies it `script_error` — and every C5 POSITIVE case expects a
    # denial, so it is handed the denial it was looking for and passes having
    # exercised no guard at all. That is the same hole the conformance suite now
    # closes from the other side by pinning the denial REASON and not just the rule
    # name; this closes it from the host side.
    case Enum.reject(["jq", "realpath"], &System.find_executable/1) do
      [] ->
        acc

      missing ->
        [
          "#{Enum.join(missing, " and ")} on PATH (the C5 rail-guard scripts parse\n" <>
            "      their input with jq and resolve holder_workdir with realpath; without\n" <>
            "      them every C5 positive case passes vacuously)."
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
# long a correct message is allowed to take.
#
# refute_receive is the OPPOSITE case and the dangerous one, so read this before
# reaching for it. It fails toward GREEN: a message that should have arrived but
# has merely been delayed past the window is indistinguishable from a message
# that was correctly never sent, so load turns a real defect into a pass. The
# 100ms default was left in place here for a long time with a note calling it
# deliberate, and the census behind #83 found twelve sites relying on it where
# nothing guaranteed the refuted work had even STARTED — the absence being
# asserted was the absence of a beginning.
#
# The floor is deliberately NOT raised, and the reason is worth keeping. It would
# cover scheduler- and mailbox-scale delay, which is not what made those sites
# unsound: the quantities there were process-spawn scale — measured on this
# project, /bin/sh reaching a fork is 235-1668ms and a `node` ACP stub boot is
# worse. A floor that covered THAT would have to be seconds. Meanwhile every
# PASSING refute pays its window in full, so the cost is paid by the healthy
# path at all 34 sites that take the default and none of it is paid by the bug.
#
# So a global floor buys no soundness it can name while charging every site for
# it, and the number would be chosen for no site in particular. If a specific
# refute needs a longer window, measure that site and widen it there.
#
# What actually closes the hole is the barrier. If you are refuting a message,
# first make the racing side signal that it has STARTED, assert_receive that
# signal, and only then refute — or use a barrier the TARGET answers, which for
# a multi-sender race means reading the target's own books rather than trusting
# mailbox order between processes that never exchanged a message.
# test/support/test_case.ex documents the sanctioned ones.
# The pinned-bundle acceptance test (:cursor_bundle) inspects the LIVE
# cursor-agent vendor bundle — its shas and its credential-store selector code.
# That verdict can only be earned on a machine holding the pinned bundle; no
# committed fixture can stand in for it (the point is the real bytes). Unlike
# the prerequisites above, cursor-agent is not something every contributor or
# CI runner installs, so absence here is a DECLARED exclusion — visible in the
# run's excluded count — rather than a suite refusal or a silent skip. Where
# the binary exists, the test always runs.
cursor_bundle_exclusions =
  if System.find_executable("cursor-agent"), do: [], else: [cursor_bundle: true]

ExUnit.start(assert_receive_timeout: 1_000, exclude: cursor_bundle_exclusions)

suite_tmp = Application.fetch_env!(:tightbeam, :test_suite_tmp)

ExUnit.after_suite(fn _result ->
  leaked = Tightbeam.HarnessProcessCensus.capture_for_suite(suite_tmp)

  if leaked.count != 0 do
    raise """
    harness process fixtures leaked from this suite run:
    #{Tightbeam.HarnessProcessCensus.format(leaked)}
    """
  end
end)

defmodule Tightbeam.CredentialParkTestReceiver do
  use GenServer

  def start_link(fun), do: GenServer.start_link(__MODULE__, fun)
  def init(fun), do: {:ok, fun}

  def handle_call({:tightbeam_command, command}, _from, fun) do
    command = Tightbeam.CommandEdge.validate_command!(command)
    {:reply, fun.(command.provider), fun}
  end
end

# Remove the suite scratch root when the VM exits, NOT after each suite run:
# `--repeat-until-failure` reruns the whole suite inside one BEAM and fires
# `ExUnit.after_suite/1` every time. Deleting the root between iterations leaves
# TMPDIR dangling, so `System.tmp_dir!/0` silently falls back to the shared /tmp
# and per-test scratch names collide across concurrent `mix test` processes.
System.at_exit(fn _status -> File.rm_rf!(suite_tmp) end)
