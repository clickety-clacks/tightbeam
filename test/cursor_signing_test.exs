defmodule Tightbeam.CursorSigningTest do
  use ExUnit.Case, async: true

  alias Tightbeam.CursorSigning

  setup do
    path = Path.join(System.tmp_dir!(), "cursor-signing-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "loads only a mode-0600 regular 32-byte record and signs with the D1 domain", %{path: path} do
    File.write!(path, :binary.copy(<<7>>, 32))
    File.chmod!(path, 0o600)

    assert {:ok, provider} = CursorSigning.load_path(path)
    assert :ok = CursorSigning.validate(provider)
    assert {:ok, signature} = CursorSigning.sign(provider, "cursor-body")
    assert {:ok, true} = CursorSigning.verify(provider, "cursor-body", signature)
    assert {:ok, false} = CursorSigning.verify(provider, "other-body", signature)
  end

  test "fails closed for absent, unsafe, and malformed material", %{path: path} do
    assert {:ok, unprovisioned} = CursorSigning.load_path(path)
    assert {:error, :cursor_signing_unprovisioned} = CursorSigning.sign(unprovisioned, "body")

    File.write!(path, :binary.copy(<<7>>, 31))
    File.chmod!(path, 0o600)
    assert {:ok, quarantined} = CursorSigning.load_path(path)
    assert {:error, :cursor_signing_quarantined} = CursorSigning.sign(quarantined, "body")

    File.write!(path, :binary.copy(<<7>>, 32))
    File.chmod!(path, 0o644)
    assert {:ok, quarantined} = CursorSigning.load_path(path)
    assert {:error, :cursor_signing_quarantined} = CursorSigning.sign(quarantined, "body")
  end

  test "does not retain material and rechecks the durable record before every signature", %{
    path: path
  } do
    File.write!(path, :binary.copy(<<7>>, 32))
    File.chmod!(path, 0o600)

    assert {:ok, provider} = CursorSigning.load_path(path)
    refute Map.has_key?(provider, :material)

    File.write!(path, :binary.copy(<<7>>, 31))
    assert {:error, :cursor_signing_quarantined} = CursorSigning.sign(provider, "body")
  end
end
