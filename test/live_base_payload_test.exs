defmodule Tightbeam.LiveBasePayloadTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.LiveBasePayload, as: Payload
  @moduletag :tmp_dir
  @tag payload_safety: true
  test "manifest and package ancestor symlinks refuse without changing targets", %{tmp_dir: tmp} do
    root = fixture(tmp)
    Payload.generate!(root)
    manifest = Path.join(Payload.application!(root), "build-manifest.json")
    original = File.read!(manifest)
    saved = Path.join(tmp, "saved-manifest")
    File.rename!(manifest, saved)
    File.ln_s!(saved, manifest)
    assert_raise RuntimeError, fn -> Payload.verify!(root) end

    assert_raise Tightbeam.LiveBaseAdmission.Refusal, fn ->
      Tightbeam.LiveBaseAdmission.payload_files!(Path.dirname(manifest))
    end

    assert File.read!(saved) == original
    File.rm!(manifest)
    File.rename!(saved, manifest)
    alias_root = Path.join(tmp, "package-alias")
    File.ln_s!(root, alias_root)
    assert_raise RuntimeError, fn -> Payload.verify!(alias_root) end
    assert File.read!(manifest) == original
  end

  for mode <- ~w(traversal absolute duplicate symlink hardlink ancestor) do
    @tag payload_safety: true
    test "archive rejects #{mode} before writing any payload", %{tmp_dir: tmp} do
      archive = Path.join(tmp, "invalid.tgz")
      destination = Path.join(tmp, "extract")
      File.mkdir_p!(destination)

      script = ~S"""
      import io, sys, tarfile
      archive, mode = sys.argv[1:]
      with tarfile.open(archive, "w:gz") as tar:
          def add(name, kind=tarfile.REGTYPE, link=""):
              item = tarfile.TarInfo(name)
              item.type = kind
              item.linkname = link
              item.size = 1 if kind == tarfile.REGTYPE else 0
              tar.addfile(item, io.BytesIO(b"x") if item.size else None)
          add("tightbeam/safe")
          if mode == "traversal": add("tightbeam/../escape")
          elif mode == "absolute": add("/outside")
          elif mode == "duplicate": add("tightbeam/safe")
          elif mode == "symlink": add("tightbeam/link", tarfile.SYMTYPE, "../outside")
          elif mode == "hardlink": add("tightbeam/link", tarfile.LNKTYPE, "tightbeam/safe")
          elif mode == "ancestor": add("tightbeam/safe/child")
      """

      assert {_, 0} = System.cmd("python3", ["-c", script, archive, unquote(mode)])

      assert {output, status} =
               System.cmd("python3", ["packaging/extract-payload.py", archive, destination],
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "payload archive refused:"
      assert File.ls!(destination) == []
      refute File.exists?(Path.join(tmp, "escape"))
    end
  end

  defp fixture(tmp) do
    root = Path.join(tmp, "tightbeam")

    for {path, bytes} <- [
          {"package.json", "{}"},
          {"bin/tightbeam", "synthetic CLI"},
          {"bin/tightbeam-gateway", "synthetic launcher"},
          {"release/releases/1/sys.config", "synthetic config"},
          {"release/lib/tightbeam-1/ebin/tightbeam.app", "synthetic app"},
          {"release/lib/tightbeam-1/ebin/fixture.beam", "synthetic beam"},
          {"release/lib/tightbeam-1/priv/resource", "synthetic resource"}
        ] do
      target = Path.join(root, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, bytes)
    end

    root
  end

  test "assembled and extracted bytes share runtime identity and bind external behavior", %{
    tmp_dir: tmp
  } do
    root = fixture(tmp)
    identity = Payload.generate!(root)
    assert identity == Payload.verify!(root)
    app = Payload.application!(root)
    manifest = app |> Path.join("build-manifest.json") |> File.read!() |> JSON.decode!()

    assert {:ok, ^identity} =
             Tightbeam.LiveBaseGuard.verify_manifest(
               manifest,
               Tightbeam.LiveBaseAdmission.payload_files!(app)
             )

    archive = Path.join(tmp, "package.tgz")

    # Match the shipped assembler: Darwin metadata can create a ._tightbeam entry
    # outside the package root, which the extractor correctly refuses.
    metadata_flags =
      if :os.type() == {:unix, :darwin},
        do: ["--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags"],
        else: []

    assert {_, 0} =
             System.cmd("tar", metadata_flags ++ ["czf", archive, "-C", tmp, "tightbeam"])

    assert {output, 0} =
             System.cmd("sh", ["packaging/verify-payload.sh", archive], stderr_to_stdout: true)

    assert String.trim(output) == identity

    scratch = Path.join(tmp, "physical-scratch")
    alias_scratch = Path.join(tmp, "scratch-alias")
    File.mkdir_p!(scratch)
    File.ln_s!(scratch, alias_scratch)

    assert {alias_output, 0} =
             System.cmd("sh", ["packaging/verify-payload.sh", archive],
               env: [{"TMPDIR", alias_scratch}],
               stderr_to_stdout: true
             )

    assert String.trim(alias_output) == identity
    assert File.ls!(scratch) == []
    assert File.lstat!(alias_scratch).type == :symlink

    for relative <- ["bin/tightbeam", "bin/tightbeam-gateway", "release/releases/1/sys.config"] do
      path = Path.join(root, relative)
      original = File.read!(path)
      File.write!(path, original <> "-changed")
      assert_raise RuntimeError, fn -> Payload.verify!(root) end
      File.write!(path, original)
    end

    assert Payload.verify!(root) == identity
  end

  test "missing extra and symlink payload inputs refuse", %{tmp_dir: tmp} do
    root = fixture(tmp)
    identity = Payload.generate!(root)
    path = Path.join(root, "bin/tightbeam")
    original = File.read!(path)
    File.rm!(path)
    assert_raise File.Error, fn -> Payload.verify!(root) end
    File.write!(path, original)
    extra = Path.join(root, "release/extra")
    File.write!(extra, "unexpected")
    assert_raise RuntimeError, fn -> Payload.verify!(root) end
    File.rm!(extra)
    File.ln_s!(path, extra)
    assert_raise RuntimeError, fn -> Payload.verify!(root) end
    File.rm!(extra)
    assert Payload.verify!(root) == identity
  end
end
