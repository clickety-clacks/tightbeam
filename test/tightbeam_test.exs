defmodule TightbeamTest do
  use ExUnit.Case
  doctest Tightbeam

  test "greets the world" do
    assert Tightbeam.hello() == :world
  end
end
