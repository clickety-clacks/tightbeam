defmodule Tightbeam.IdTest do
  use ExUnit.Case, async: true

  test "uuid5 matches the RFC 4122 DNS vector" do
    assert Tightbeam.Id.uuid5("6ba7b810-9dad-11d1-80b4-00c04fd430c8", "www.widgets.com") ==
             "21f7f8de-8051-5b89-8680-0195ef798b6a"
  end

  test "uuid5 rejects noncanonical namespaces" do
    for namespace <- [
          "6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
          "6ba7b8109dad11d180b400c04fd430c8",
          "6ba7b810-9dad-11d1-80b4-00c04fd430cg",
          ""
        ] do
      assert_raise ArgumentError, fn -> Tightbeam.Id.uuid5(namespace, "name") end
    end
  end
end
