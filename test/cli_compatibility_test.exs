defmodule Tightbeam.CliCompatibilityTest do
  use ExUnit.Case, async: true

  alias Tightbeam.CliCompatibility

  test "the gateway accepts its minimum and newer semantic CLI versions" do
    minimum = CliCompatibility.minimum_supported_version()

    assert :ok = CliCompatibility.check(minimum)
    assert :ok = CliCompatibility.check("0.2.0")
    assert :ok = CliCompatibility.check("1.0.0")
  end

  test "an older CLI is refused with both sides of the compatibility decision" do
    assert {:error, message} = CliCompatibility.check("0.0.9")

    assert message ==
             "your CLI is too old, it says 0.0.9; this gateway needs 0.1.0 or newer"
  end

  test "a missing or malformed version is an incompatible answer" do
    assert {:error, missing} = CliCompatibility.check(nil)
    assert missing =~ "your CLI did not state its version"
    assert missing =~ "this gateway needs 0.1.0 or newer"

    assert {:error, malformed} = CliCompatibility.check("not-semver")
    assert malformed =~ "your CLI is too old, it says not-semver"
    assert malformed =~ "this gateway needs 0.1.0 or newer"
  end
end
