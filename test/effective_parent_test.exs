defmodule Tightbeam.EffectiveParentTest do
  use ExUnit.Case, async: true

  test "production parent consumers do not select the stored column directly" do
    root = Path.expand("../lib/tightbeam", __DIR__)

    allowed =
      MapSet.new([
        Path.join(root, "org.ex"),
        Path.join(root, "schema.ex"),
        Path.join(root, "transcript.ex"),
        Path.join(root, "wire/payloads.ex")
      ])

    offenders =
      root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&MapSet.member?(allowed, &1))
      |> Enum.filter(fn path ->
        source = File.read!(path)

        Regex.match?(~r/SELECT.{0,200}operationalParent/is, source)
      end)
      |> Enum.map(&Path.relative_to(&1, root))

    assert offenders == []
  end
end
