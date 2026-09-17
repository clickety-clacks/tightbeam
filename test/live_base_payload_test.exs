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

  test "assembled bytes carry one runtime identity the guard reads back", %{tmp_dir: tmp} do
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

    # The identity binds the whole shipped closure, not just the BEAM files: a
    # changed CLI or launcher is a different build.
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
