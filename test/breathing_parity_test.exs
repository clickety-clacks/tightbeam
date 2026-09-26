defmodule Tightbeam.BreathingParityTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Breathing, DB}

  # Identical input rows and complete expected public JSON on both product lines.
  # No output is generated from the implementation under test.
  @fixture File.read!(Path.join(__DIR__, "fixtures/breathing-v1-parity.json"))
           |> JSON.decode!()

  for scenario <- @fixture["cases"] do
    @scenario scenario
    test "A16 exact public parity: #{@scenario["name"]}" do
      db = :"breathing_parity_#{System.unique_integer([:positive])}"
      start_supervised!({DB, path: ":memory:", name: db})
      :ok = ensure_all_schemas(db)
      :ok = DB.execute(db, maintenance_seed(@fixture["seed"]))

      if @scenario["sql"] != "", do: :ok = DB.execute(db, @scenario["sql"])

      target = @scenario["target"]

      actual =
        Breathing.query(db, target["kind"], target["id"]) |> JSON.encode!() |> JSON.decode!()

      assert actual == @scenario["expected"]
      refute JSON.encode!(actual) =~ "PARITY-SECRET-MUST-NOT-LEAK"
    end
  end

  # 0.1.9 has no operationalParent column. It is not physical evidence.
  # Keep the shared fixture and all expected outputs identical to main.
  defp maintenance_seed(sql) do
    sql
    |> String.replace("ownerUserId,origin,operationalParent,", "ownerUserId,origin,")
    |> String.replace("'user:owner','active',", "'user:owner',")
    |> String.replace("'user:owner','active2',", "'user:owner',")
    |> String.replace("'user:owner','retired',", "'user:owner',")
  end
end
