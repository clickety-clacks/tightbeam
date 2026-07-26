defmodule TightbeamTest do
  use Tightbeam.TestCase, async: false

  test "root documentation names the durable turn pipeline invariant" do
    assert {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Tightbeam)

    assert moduledoc
           |> String.replace(~r/\s+/, " ")
           |> String.contains?("every accepted prompt reaches exactly one terminal state")
  end
end
