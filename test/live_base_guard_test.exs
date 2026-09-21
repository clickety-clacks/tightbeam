defmodule Tightbeam.LiveBaseGuardTest do
  use ExUnit.Case, async: true
  alias Tightbeam.LiveBaseGuard, as: Guard
  @a String.duplicate("a", 64)
  @b String.duplicate("b", 64)
  @base "/isolated/guard-fixture"
  defp marker(id), do: %{"format" => "tightbeam-build-owner/v1", "buildIdentity" => id}
  defp transition(a, b), do: %{"base" => @base, "source" => a, "target" => b}

  test "2026-09-01 wrong build refuses pure admission even with compatible schema" do
    assert {:error, %{code: "build_transition_required", observed: @a, expected: @b}} =
             Guard.admit_build(@base, @b, marker(@a), :existing, nil)
  end

  test "restart and exact compatible reverse transition admit without schema waiver" do
    assert {:ok, same} = Guard.admit_build(@base, @a, marker(@a), :existing, nil)
    assert :ok = Guard.qualify_schema(same, "current", ["current"])

    assert {:ok, reverse} =
             Guard.admit_build(@base, @a, marker(@b), :existing, transition(@b, @a))

    assert :ok = Guard.qualify_schema(reverse, "shared", ["shared"])

    assert {:error, %{code: "incompatible_schema"}} =
             Guard.qualify_schema(reverse, "newer", ["shared"])
  end

  test "override matches exact canonical base source and target" do
    for bad <- [
          Map.put(transition(@a, @b), "base", "/other"),
          transition(@b, @b),
          transition(@a, @a)
        ] do
      assert {:error, %{code: "build_transition_mismatch"}} =
               Guard.admit_build(@base, @b, marker(@a), :existing, bad)
    end

    assert {:ok, admitted} =
             Guard.admit_build(@base, @b, marker(@a), :existing, transition(@a, @b))

    for stamp <- [nil, [], ["one", "two"], "unknown"] do
      assert {:error, %{code: "incompatible_schema"}} =
               Guard.qualify_schema(admitted, stamp, ["current"])
    end
  end

  test "legacy adoption binds actual stamp and absent differs from malformed" do
    assert {:error, %{code: "build_transition_required"}} =
             Guard.admit_build(@base, @b, :absent, :existing, nil)

    adoption = Map.put(transition("unmarked", @b), "expectedSchema", "legacy018")
    assert {:ok, admitted} = Guard.admit_build(@base, @b, :absent, :existing, adoption)
    assert :ok = Guard.qualify_schema(admitted, "legacy018", ["legacy018", "current"])

    assert {:error, %{code: "legacy_schema_mismatch"}} =
             Guard.qualify_schema(admitted, "current", ["legacy018", "current"])

    assert {:error, %{code: "invalid_build_marker"}} =
             Guard.admit_build(@base, @b, %{}, :existing, adoption)

    assert {:error, _} =
             Guard.admit_build(@base, @b, :absent, :existing, transition("unmarked", @b))

    assert {:ok, _} = Guard.admit_build(@base, @b, :absent, :new_empty, nil)
  end

  test "strict wire objects reject malformed identities unknown keys and Boolean overrides" do
    assert {:ok, _} = Guard.decode_marker(JSON.encode!(marker(@a)))
    assert {:ok, _} = Guard.decode_transition(JSON.encode!(transition(@a, @b)))

    for value <- [%{}, Map.put(marker(@a), "extra", true), marker("short"), true] do
      assert {:error, _} = Guard.decode_marker(JSON.encode!(value))
    end

    for value <- [
          true,
          Map.put(transition(@a, @b), "force", true),
          Map.put(transition(@a, @b), "base", "/a/../b")
        ] do
      assert {:error, _} = Guard.decode_transition(JSON.encode!(value))
    end

    assert {:error, _} = Guard.decode_marker("{")
  end

  test "payload identity is ordered by path and binds exact bytes and complete set" do
    files = [{"ebin/a.beam", <<0, 1, 2>>}, {"priv/rules.toml", "rule"}]
    assert {:ok, manifest} = Guard.generate_manifest(files)
    assert {:ok, ^manifest} = Guard.generate_manifest(Enum.reverse(files))
    assert {:ok, identity} = Guard.verify_manifest(manifest, files)
    assert byte_size(identity) == 64

    for changed <- [
          [{"ebin/a.beam", <<0, 1, 3>>}, {"priv/rules.toml", "rule"}],
          [{"ebin/a.beam", <<0, 1, 2>>}],
          files ++ [{"ebin/extra.beam", "extra"}],
          [{"ebin/a.beam", <<0, 1, 2>>}, {"priv/rules.toml", "changed"}]
        ] do
      assert {:error, %{code: "payload_manifest_mismatch"}} =
               Guard.verify_manifest(manifest, changed)
    end
  end

  test "payload rejects duplicate and noncanonical paths rather than normalizing them" do
    for files <- [
          [],
          [{"a", "x"}, {"a", "y"}],
          [{"../outside", "x"}],
          [{"/absolute", "x"}],
          [{"a//b", "x"}],
          [{"a/./b", "x"}],
          [{"a\\b", "x"}],
          [{"a", :not_bytes}]
        ] do
      assert {:error, %{code: "invalid_payload_files"}} = Guard.generate_manifest(files)
    end
  end
end
