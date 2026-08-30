defmodule Tightbeam.IdentityRendererTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Identity.{IncludeError, Renderer}

  @fixture_root Path.expand("fixtures/identity-universal-root", __DIR__)

  test "real Gibson fragment fixtures render in universal-root directive position" do
    specs = File.read!(Path.join(@fixture_root, "specs-home.md"))
    dev = File.read!(Path.join(@fixture_root, "dev-on-gibson.md"))

    catalog = %{
      "specs-home.md" => specs,
      "dev-on-gibson.md" => dev,
      "operating-model.md" => "model-before\n#include \"dev-on-gibson.md\"\nmodel-after",
      "operating-manual.md" => "manual-before\n#include \"specs-home.md\"\nmanual-after"
    }

    model =
      Renderer.render!(catalog["operating-model.md"], "guidance/operating-model.md", catalog,
        universal_root: "operating-model.md"
      ).bytes

    manual =
      Renderer.render!(catalog["operating-manual.md"], "guidance/operating-manual.md", catalog,
        universal_root: "operating-manual.md"
      ).bytes

    assert model == "model-before\n#{String.trim_trailing(dev, "\n")}\nmodel-after"
    assert manual == "manual-before\n#{String.trim_trailing(specs, "\n")}\nmanual-after"
    refute Regex.match?(~r/^#include/m, model <> "\n" <> manual)
  end

  test "nested includes preserve order and ordinary occurrences repeat" do
    catalog = %{"a.md" => "A1\n#include \"b.md\"\nA2", "b.md" => "B"}

    rendered =
      Renderer.render!("start\n#include \"a.md\"\n#include \"b.md\"\nend", "root", catalog)

    assert rendered.bytes == "start\nA1\nB\nA2\nB\nend"
    assert Enum.map(rendered.provenance, & &1.fragment_name) == ["a.md", "b.md", "b.md"]
  end

  test "direct and transitive duplicate universal roots name both provenance paths" do
    direct = %{"operating-model.md" => "model"}

    error =
      assert_raise IncludeError, fn ->
        Renderer.render!(
          "#include \"operating-model.md\"\n#include \"operating-model.md\"",
          "archetypes/demo.toml",
          direct
        )
      end

    assert error.cause == :duplicate_universal_root
    assert length(error.paths) == 2
    assert Enum.any?(error.paths, &String.contains?(&1, ":1"))
    assert Enum.any?(error.paths, &String.contains?(&1, ":2"))

    transitive = Map.put(direct, "ordinary.md", "#include \"operating-model.md\"")

    error =
      assert_raise IncludeError, fn ->
        Renderer.render!(
          "#include \"operating-model.md\"\n#include \"ordinary.md\"",
          "archetypes/demo.toml",
          transitive
        )
      end

    assert error.cause == :duplicate_universal_root
    assert Enum.any?(error.paths, &String.contains?(&1, "ordinary.md:1"))
  end

  test "universal roots cannot reach either universal root" do
    catalog = %{
      "operating-model.md" => "#include \"ordinary.md\"",
      "operating-manual.md" => "manual",
      "ordinary.md" => "#include \"operating-manual.md\""
    }

    error =
      assert_raise IncludeError, fn ->
        Renderer.render!(catalog["operating-model.md"], "guidance/operating-model.md", catalog,
          universal_root: "operating-model.md"
        )
      end

    assert error.cause == :universal_root_reentry
    assert error.chain == ["ordinary.md", "operating-manual.md"]
  end

  test "malformed, path-bearing, missing, cycle, and eleventh active include are typed" do
    for line <- ["#include \"path/name.md\"", "#include 'name.md'", "#include \"name.txt\""] do
      error = assert_raise IncludeError, fn -> Renderer.render!(line, "root", %{}) end
      assert error.cause == :invalid_directive
      assert error.line == 1
    end

    error =
      assert_raise IncludeError, fn -> Renderer.render!("#include \"nope.md\"", "root", %{}) end

    assert error.cause == :missing_fragment
    assert error.paths == ["nope.md"]

    error =
      assert_raise IncludeError, fn ->
        Renderer.render!("#include \"a.md\"", "root", %{
          "a.md" => "#include \"b.md\"",
          "b.md" => "#include \"a.md\""
        })
      end

    assert error.cause == :cycle
    assert error.chain == ["a.md", "b.md", "a.md"]

    deep =
      Map.new(1..11, fn n ->
        {"f#{n}.md", if(n == 11, do: "done", else: "#include \"f#{n + 1}.md\"")}
      end)

    error =
      assert_raise IncludeError, fn -> Renderer.render!("#include \"f1.md\"", "root", deep) end

    assert error.cause == :depth_exceeded
    assert List.last(error.chain) == "f11.md"
  end

  test "flat catalog rejects duplicate basenames and names both paths" do
    error =
      assert_raise IncludeError, fn ->
        Renderer.catalog!([{"guidance/a/shared.md", "one"}, {"guidance/b/shared.md", "two"}])
      end

    assert error.cause == :duplicate_basename
    assert error.paths == ["guidance/a/shared.md", "guidance/b/shared.md"]
  end
end
