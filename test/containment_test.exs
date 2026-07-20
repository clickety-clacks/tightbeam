defmodule Tightbeam.ContainmentTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Containment

  test "profile renders exact deterministic Seatbelt bytes" do
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
      (subpath "/private/tmp")        ;; claude Terminal per-command workdir
      (subpath "/dev"))               ;; claude session-new PTY allocation

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

    assert Containment.profile(roots) == expected
    assert Containment.profile(roots) == Containment.profile(roots)
  end

  test "profile accepts every explicitly permitted path character" do
    root = "/org/a space/O'Brien/(tools)/$cash;ship/é"
    assert Containment.profile([root]) =~ ~s|(subpath "#{root}")|
  end

  test "profile refuses unsafe, relative, and lexically noncanonical roots" do
    rejected = [
      "relative",
      "/bad\"quote",
      "/bad\\slash",
      "/bad\nline",
      "/bad\tcontrol",
      "/org/homes/../../outside/codex",
      "/foo//bar",
      "/foo/bar/"
    ]

    for root <- rejected do
      assert_raise ArgumentError, fn -> Containment.profile([root]) end
    end
  end

  test "validate_roots refuses symlinks, accepts missing tails, and refuses other lstat errors" do
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
      Containment.validate_roots!([Path.join(link, "work")])
    end

    assert :ok = Containment.validate_roots!([Path.join(root, "fresh/missing/work")])

    too_long = Path.join(root, String.duplicate("a", 256))

    assert_raise ArgumentError, ~r/cannot be validated/, fn ->
      Containment.validate_roots!([too_long])
    end
  end

  @darwin? :os.type() == {:unix, :darwin} and File.exists?("/usr/bin/sandbox-exec")
  @tag :darwin
  @tag skip: if(@darwin?, do: false, else: "sandbox-exec is unavailable")
  test "sandbox-exec enforces resolved write roots and preserves stdout" do
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
    profile = Containment.profile([root, auth])

    inside = Path.join(root, "inside")
    assert {"stdout-ok\n", 0} = sandbox(profile, "echo inside > #{q(inside)}; echo stdout-ok")
    assert File.read!(inside) == "inside\n"

    denied = Path.join(outside, "denied")
    assert {_output, status} = sandbox(profile, "echo denied > #{q(denied)}")
    refute status == 0
    refute File.exists?(denied)

    external_target = Path.join(outside, "through-link")
    File.ln_s!(external_target, Path.join(root, "external-link"))

    assert {_output, status} =
             sandbox(profile, "echo denied > #{q(Path.join(root, "external-link"))}")

    refute status == 0
    refute File.exists?(external_target)

    auth_target = Path.join(auth, "credential")
    File.ln_s!(auth_target, Path.join(root, "auth-link"))
    assert {_output, 0} = sandbox(profile, "echo refreshed > #{q(Path.join(root, "auth-link"))}")
    assert File.read!(auth_target) == "refreshed\n"
  end

  defp sandbox(profile, script) do
    System.cmd("/usr/bin/sandbox-exec", ["-p", profile, "/bin/sh", "-c", script],
      stderr_to_stdout: true
    )
  end

  defp q(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp canonical(path) do
    {resolved, 0} = System.cmd("/bin/realpath", [path])
    String.trim(resolved)
  end
end
