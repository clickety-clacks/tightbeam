defmodule Tightbeam.ModelPolicy.CanonicalJSONTest do
  use ExUnit.Case, async: true

  alias Tightbeam.ModelPolicy.CanonicalJSON

  test "orders object keys by UTF-16 code units" do
    value = %{
      "\u20ac" => "Euro Sign",
      "\r" => "Carriage Return",
      "\ufb33" => "Hebrew Letter Dalet With Dagesh",
      "1" => "One",
      "😀" => "Emoji: Grinning Face",
      "\u0080" => "Control",
      "ö" => "Latin Small Letter O With Diaeresis"
    }

    assert CanonicalJSON.encode!(value) ==
             "{\"\\r\":\"Carriage Return\",\"1\":\"One\",\"\u0080\":\"Control\",\"ö\":\"Latin Small Letter O With Diaeresis\",\"€\":\"Euro Sign\",\"😀\":\"Emoji: Grinning Face\",\"דּ\":\"Hebrew Letter Dalet With Dagesh\"}"
  end

  test "uses ECMAScript string escaping and number serialization" do
    assert CanonicalJSON.encode!("\b\t\n\f\r\"\\\u000f") ==
             "\"\\b\\t\\n\\f\\r\\\"\\\\\\u000f\""

    assert CanonicalJSON.encode!([
             333_333_333.33333329,
             1.0e30,
             4.50,
             2.0e-3,
             1.0e-27,
             -0.0
           ]) == "[333333333.3333333,1e+30,4.5,0.002,1e-27,0]"
  end

  test "hashes the exact canonical bytes" do
    value = %{"b" => 2, "a" => [true, nil, "x"]}
    bytes = "{\"a\":[true,null,\"x\"],\"b\":2}"

    assert CanonicalJSON.encode!(value) == bytes

    assert CanonicalJSON.sha256(value) ==
             :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  test "refuses keys and strings outside the RFC 8785 data model" do
    assert_raise ArgumentError, ~r/object key is not a string/, fn ->
      CanonicalJSON.encode!(%{a: 1})
    end

    assert_raise ArgumentError, ~r/not valid Unicode/, fn ->
      CanonicalJSON.encode!(<<0xFF>>)
    end
  end
end
