defmodule Tightbeam.ArchetypesQualifiedResolutionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Archetypes

  @kungfu "sample-kungfu"
  @short "coder"
  @qualified "sample-kungfu.coder"

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "qualified-archetypes-#{System.unique_integer([:positive])}")

    own_path =
      Path.join(base_dir, "identity/kungfu/#{@kungfu}/archetypes/#{@short}.toml")

    File.mkdir_p!(Path.dirname(own_path))
    File.write!(own_path, archetype_manifest!(@short))

    File.write!(
      Path.join(base_dir, "identity/kungfu/#{@kungfu}/installed.toml"),
      "name = \"#{@kungfu}\"\npaths = [\"kungfu/#{@kungfu}/archetypes/#{@short}.toml\"]\n"
    )

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{base_dir: base_dir}
  end

  test "a bare kungfu-only name returns qualified candidates", ctx do
    loaded = Archetypes.load!(ctx.base_dir)

    assert Map.has_key?(loaded, @qualified)
    assert {:ok, %{name: @qualified}} = Archetypes.resolve(@qualified)

    assert {:error, %{code: "qualified_archetype_required", candidates: [@qualified]}} =
             Archetypes.resolve(@short)
  end

  test "a substrate short name keeps its plain meaning beside a kungfu name", ctx do
    substrate = Path.join(ctx.base_dir, "identity/archetypes/#{@short}.toml")
    File.mkdir_p!(Path.dirname(substrate))
    File.write!(substrate, archetype_manifest!(@short))

    loaded = Archetypes.load!(ctx.base_dir)

    assert Map.has_key?(loaded, @short)
    assert Map.has_key?(loaded, @qualified)
    assert {:ok, %{name: @short}} = Archetypes.resolve(@short)
    assert {:ok, %{name: @qualified}} = Archetypes.resolve(@qualified)
  end

  defp archetype_manifest!(name) do
    "name = \"#{name}\"\nskills = []\nwhere = [\"*\"]\n"
  end
end
