defmodule Tightbeam.HarnessConformanceTest do
  use ExUnit.Case, async: false

  alias Tightbeam.Harness

  @manifest_path Application.app_dir(:tightbeam, "priv/harness_bundle.json")
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> JSON.decode!()
  @contract @manifest["vector_contract"]
  @harnesses Enum.uniq(Harness.all() ++ [Harness.Fixture])

  test "Harness moduledoc renders exactly the manifest obligation IDs" do
    manifest_ids = @manifest["obligations"] |> MapSet.new(& &1["id"])

    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Harness)

    moduledoc_ids =
      moduledoc
      |> then(&Regex.scan(~r/\bHB-\d{2}-[A-Z-]+\b/, &1))
      |> List.flatten()
      |> MapSet.new()

    assert moduledoc_ids == manifest_ids
  end

  for harness <- @harnesses do
    test "#{inspect(harness)} satisfies every manifest conformance vector" do
      vectors = unquote(harness).conformance_vectors()

      assert MapSet.new(Map.keys(vectors)) == MapSet.new(Map.keys(@contract))

      Enum.each(@contract, fn {callback, contract} ->
        callback_vectors = Map.fetch!(vectors, callback)

        assert MapSet.new(callback_vectors, & &1.case) ==
                 MapSet.new(contract["required_cases"])

        Enum.each(callback_vectors, fn vector ->
          assert Harness.Support.observe_vector(unquote(harness), callback, vector) ==
                   vector.expected,
                 "#{inspect(unquote(harness))} #{callback}/#{vector.case} violated " <>
                   contract["oracle"]

          case vector.support do
            :supported ->
              :ok

            {:unsupported, divergence} ->
              assert String.starts_with?(divergence, "DIV-")
          end
        end)
      end)
    end
  end
end
