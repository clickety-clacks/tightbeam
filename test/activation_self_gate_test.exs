defmodule Tightbeam.ActivationSelfGateTest do
  use ExUnit.Case, async: true

  @fixture_dir Path.expand("fixtures/activations", __DIR__)
  @pins %{
    "engineering.jsonl" => "5ade2056315401d6c0e3a1988969d0d842c348be8f50b4616dab7602e6c6a4f6",
    "marketing.jsonl" => "6408cd99b703cd4048697b9a9568e92aefe2657fe0dcdda5b9efe7927f2a6dc5",
    "biosciences.jsonl" => "8def2b1ac502bfde66c69b70e05f2284e24e14dddbecb3ee832f46b6e03e9053"
  }

  test "the three mandatory design fixtures retain their exact bytes and closed evidence shape" do
    Enum.each(@pins, fn {name, expected_sha} ->
      bytes = File.read!(Path.join(@fixture_dir, name))
      assert bytes =~ ~r/\A[^\n]+\n\z/
      assert sha256(bytes) == expected_sha

      fixture = JSON.decode!(bytes)
      assert fixture["fixtureKind"] == "static-design"
      assert fixture["runtimeCapture"] == "pending-implementation"
      assert is_binary(fixture["consumer"])
      assert is_binary(fixture["policyOwner"])
      assert is_binary(fixture["scenario"])

      events = fixture["events"]

      assert Enum.map(events, & &1["kind"]) ==
               ~w(declared authority-attached attempted observed acknowledged acknowledged)

      attempted = Enum.find(events, &(&1["kind"] == "attempted"))
      observed = Enum.find(events, &(&1["kind"] == "observed"))
      acknowledgements = Enum.filter(events, &(&1["kind"] == "acknowledged"))

      assert attempted["noticeWakeId"]
      assert observed["noticeWakeId"]
      assert observed["payload"]["certainty"] == "determinate"

      assert MapSet.new(Enum.map(acknowledgements, & &1["payload"]["noticedEventId"])) ==
               MapSet.new([attempted["eventId"], observed["eventId"]])
    end)
  end

  test "domain examples remain fixture data instead of substrate vocabulary" do
    root = Path.expand("..", __DIR__)

    for relative <- [
          "lib/tightbeam/activations.ex",
          "lib/tightbeam/gateway.ex",
          "lib/tightbeam/wire/router.ex",
          "cli/src/args.rs",
          "cli/src/dispatch.rs"
        ] do
      source = File.read!(Path.join(root, relative))
      refute source =~ "engineering."
      refute source =~ "marketing."
      refute source =~ "biosciences."
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
