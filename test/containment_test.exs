defmodule Tightbeam.ContainmentTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Containment

  @darwin? :os.type() == {:unix, :darwin}

  # Obligation 2 of the containment spec: the exact bytes this platform renders, asserted
  # ON this platform. The suite ran macOS-only for the project's whole life, so the linux
  # arm had never been executed at all.
  if @darwin? do
    test "rail profile renders exact deterministic Seatbelt bytes" do
      roots = ["/org/work", "/org/home"]

      expected = """
      (version 1)
      (deny default)

      ;; read anywhere: materials, dyld, adapter code, caches, creds-via-symlink
      (allow file-read*)

      ;; writes: deny-by-default; org trees + spike-required system paths
      (allow file-write*
        (subpath "/org/work")
        (subpath "/org/home")
        (subpath "/dev/null"))          ;; rail scripts redirect to the discard sink

      ;; process lifecycle
      (allow process-fork)
      (allow process-exec)
      (allow signal (target self))

      ;; macOS runtime baseline
      (allow mach-lookup)
      (allow sysctl-read)

      ;; network — v1 posture: open egress
      (allow network-outbound)
      """

      assert Containment.rail_profile(roots) == expected
      assert Containment.rail_profile(roots) == Containment.rail_profile(roots)
    end
  else
    test "rail profile renders exact deterministic Landlock bytes" do
      roots = ["/org/work", "/org/home"]

      expected =
        ~s({"tightbeam_containment":1,"write_roots":) <>
          ~s(["/org/work","/org/home","/dev/null"]})

      assert Containment.rail_profile(roots) == expected
      assert Containment.rail_profile(roots) == Containment.rail_profile(roots)
    end
  end

  # The regression guard for the hole the rail/adapter seam split closed. A rail check
  # script is not a harness turn, so a grant added for a harness must never widen the
  # rail wall again — and on linux `/dev` in a rail profile means `/dev/shm`, a
  # world-writable tmpfs, which is a durable write channel outside the scratch root that
  # survives its rm_rf. Proven reachable on shrdlu before the split: the script wrote
  # /dev/shm and returned PASS. The harness-addition seam itself is deleted (#36); the
  # paths it once granted (`/private/tmp`, `/dev`) stay pinned here as the guard.
  test "a rail profile grants no harness addition, and no writable /dev tree" do
    profile = Containment.rail_profile(["/org/work"])

    # Compared in the platform's GRANT FORM, not as a substring: `/dev` is a substring of
    # the `/dev/null` grant below, and the whole point is that the tree is not granted
    # while the single sink is.
    for path <- ["/private/tmp", "/dev"] do
      refute_grants(profile, path)
    end

    refute profile =~ "/dev/shm"

    # /dev/null is granted on purpose and is the ONLY fixed grant: a discard sink cannot
    # carry anything out of the scratch root, and `>/dev/null` is in shipped rail scripts.
    assert_grants(profile, "/dev/null")
  end

  test "profile accepts every explicitly permitted path character" do
    root = "/org/a space/O'Brien/(tools)/$cash;ship/é"
    assert_grants(Containment.rail_profile([root]), root)
  end

  test "profile refuses only unsafe and relative root bytes" do
    rejected = [
      "relative",
      "/bad\"quote",
      "/bad\\slash",
      "/bad\nline",
      "/bad\tcontrol"
    ]

    for root <- rejected do
      assert_raise ArgumentError, fn -> Containment.rail_profile([root]) end
    end

    for root <- ["/org/homes/../../outside/codex", "/foo//bar", "/foo/bar/"] do
      assert_grants(Containment.rail_profile([root]), root)
    end
  end

  test "profile itself refuses symlinks, accepts missing tails, and refuses other lstat errors" do
    root =
      Path.join(
        canonical(System.tmp_dir!()),
        "tb-containment-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    target = Path.join(root, "target")
    link = Path.join(root, "link")
    File.mkdir_p!(target)
    File.ln_s!(target, link)

    assert_raise ArgumentError, ~r/symlink component/, fn ->
      Containment.rail_profile([Path.join(link, "work")])
    end

    assert is_binary(Containment.rail_profile([Path.join(root, "fresh/missing/work")]))

    too_long = Path.join(root, String.duplicate("a", 256))

    assert_raise ArgumentError, ~r/cannot be validated/, fn ->
      Containment.rail_profile([too_long])
    end
  end

  # Obligation 1: the rendered profile is APPLIED by this platform's real mechanism and a
  # write outside the granted roots is DENIED. One body, both platforms, identical
  # assertions — a rail author cannot tell from a verdict which OS ran the check.
  #
  # macOS applies SBPL with sandbox-exec, which is always present. Landlock can only be
  # imposed by the wrapper itself, so the linux arm drives the real binary; `cargo build
  # --release` runs in CI ahead of the suite so this is executed on both jobs rather than
  # skipped on one. The mechanism proof that needs no build at all lives in the `cli`
  # suite (`a_write_outside_the_granted_roots_is_denied_and_leaves_nothing_behind`).
  if @darwin? do
    @applier_missing false
  else
    @release_binary Path.expand("../cli/target/release/tightbeam", __DIR__)

    @applier_missing if(File.exists?(@release_binary),
                       do: false,
                       else:
                         "release rail-exec is required to impose Landlock: #{@release_binary}"
                     )
  end

  @tag skip: @applier_missing
  test "containment enforces resolved write roots and preserves stdout" do
    tmp = canonical(System.tmp_dir!())
    nonce = "#{:os.getpid()}-#{System.unique_integer([:positive])}"
    root = Path.join(tmp, "tb-wall-work-#{nonce}")
    auth = Path.join(tmp, "tb-wall-auth-#{nonce}")
    outside = Path.join(System.user_home!(), ".tb-wall-outside-#{nonce}")
    File.mkdir_p!(root)
    File.mkdir_p!(auth)
    File.mkdir_p!(outside)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(auth)
      File.rm_rf!(outside)
    end)

    :ok = Containment.validate_roots!([root, auth])
    profile = Containment.rail_profile([root, auth])

    inside = Path.join(root, "inside")

    assert {"stdout-ok\n", :allowed} =
             contained(profile, "echo inside > #{q(inside)}; echo stdout-ok")

    assert File.read!(inside) == "inside\n"

    denied = Path.join(outside, "denied")
    assert {_output, :denied} = contained(profile, "echo denied > #{q(denied)}")
    refute File.exists?(denied)

    external_target = Path.join(outside, "through-link")
    File.ln_s!(external_target, Path.join(root, "external-link"))

    assert {_output, :denied} =
             contained(profile, "echo denied > #{q(Path.join(root, "external-link"))}")

    refute File.exists?(external_target)

    auth_target = Path.join(auth, "credential")
    File.ln_s!(auth_target, Path.join(root, "auth-link"))

    assert {_output, :allowed} =
             contained(profile, "echo refreshed > #{q(Path.join(root, "auth-link"))}")

    assert File.read!(auth_target) == "refreshed\n"
  end

  # Verdicts, not exit codes, so the assertions above are literally the same on both
  # platforms. A refusal is never a verdict: it fails the test loudly instead of reading
  # as a denial, because "containment was not applied" must never look like enforcement.
  if @darwin? do
    defp contained(profile, script) do
      case System.cmd("/usr/bin/sandbox-exec", ["-p", profile, "/bin/sh", "-c", script],
             stderr_to_stdout: true
           ) do
        {output, 0} -> {output, :allowed}
        {output, _nonzero} -> {output, :denied}
      end
    end
  else
    defp contained(profile, script) do
      dir = Path.join(System.tmp_dir!(), "tb-contained-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "check")
      # Read the wrapper's input first: a script that exits without reading makes the
      # wrapper's stdin write fail, which is SCRIPT_ERROR for a reason unrelated to the
      # write under test.
      File.write!(path, "#!/bin/sh\nIFS= read -r _line\n#{script}\n")
      File.chmod!(path, 0o755)
      on_exit(fn -> File.rm_rf!(dir) end)

      input = Path.join(dir, "input")
      File.write!(input, "{}\n")

      {output, status} =
        System.cmd("/bin/sh", [
          "-c",
          ~s(exec "$1" rail-exec --profile "$2" --timeout-ms 10000 -- "$3" < "$4" 2>&1),
          "tb-contained",
          @release_binary,
          profile,
          path,
          input
        ])

      case status do
        0 ->
          {output, :allowed}

        10 ->
          {output, :denied}

        30 ->
          # Reproduce the exact refusal against the exact profile, in the same binary, so
          # a CI-only failure is diagnosed from the runner's own per-root breakdown.
          {stage, _} = System.cmd(@release_binary, ["contain-stage", profile])
          flunk("containment was REFUSED, not applied: #{output}\nprofile=#{profile}\n#{stage}")

        other ->
          flunk("unexpected rail-exec band #{other}: #{output}")
      end
    end
  end

  defp q(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  # The grant form is per-OS; that a root IS granted is not.
  defp grant_form(root) do
    if @darwin?, do: ~s|(subpath "#{root}")|, else: JSON.encode!(root)
  end

  defp assert_grants(profile, root) do
    assert profile =~ grant_form(root),
           "profile does not grant #{root}: #{profile}"
  end

  defp refute_grants(profile, root) do
    refute profile =~ grant_form(root),
           "profile grants #{root} and must not: #{profile}"
  end

  defp canonical(path) do
    {resolved, 0} = System.cmd("/bin/realpath", [path])
    String.trim(resolved)
  end
end
