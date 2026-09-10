defmodule Tightbeam.CorePrimitiveTest do
  use ExUnit.Case, async: true

  alias Tightbeam.StateResources

  test "native primitives preserve JSON types, including nested values" do
    for value <- [nil, true, false] do
      assert StateResources.work_item(value) === value
      item = StateResources.work_item(%{nested: %{values: [value]}})
      assert item == %{"nested" => %{"values" => [value]}}
      assert JSON.decode!(JSON.encode!(item)) == item
    end
  end

  test "literal primitive strings and ordinary enum atoms keep their meaning" do
    for value <- ["nil", "true", "false"] do
      assert StateResources.work_item(value) === value
    end

    assert StateResources.work_item(%{state: :open}) == %{"state" => "open"}
  end

  test "closed encoder rejects nonnullable null and string booleans" do
    item = %{"userId" => "owner", "isAdmin" => false, "createdAt" => 1, "rowVersion" => 1}

    assert StateResources.encode_item("users", item, %{}) ==
             ~s({"userId":"owner","isAdmin":false,"createdAt":1,"rowVersion":1})

    for invalid <- [nil, "true", "false"] do
      assert_raise ArgumentError, fn ->
        StateResources.encode_item("users", Map.put(item, "isAdmin", invalid), %{})
      end
    end
  end
end
