defmodule Tightbeam.CliCompatibilityTest do
  use ExUnit.Case, async: true

  alias Tightbeam.CliCompatibility

  test "a pre-1.0 gateway accepts only its exact CLI version" do
    required = CliCompatibility.required_version()

    assert :ok = CliCompatibility.check(required)
    assert :ok = CliCompatibility.check("0.9.0", "0.9.0")

    assert {:error, newer} = CliCompatibility.check("0.9.1", "0.9.0")
    assert newer == "your CLI offered 0.9.1; this gateway requires 0.9.0"
  end

  test "a mismatched CLI is refused with both sides of the compatibility decision" do
    required = CliCompatibility.required_version()
    assert {:error, message} = CliCompatibility.check("0.0.9")

    assert message == "your CLI offered 0.0.9; this gateway requires #{required}"
  end

  test "a gateway at or above 1.0 accepts same-MAJOR minor and patch drift" do
    assert :ok = CliCompatibility.check("1.1.0", "1.0.0")
    assert :ok = CliCompatibility.check("1.0.7", "1.4.2")

    assert {:error, message} = CliCompatibility.check("2.0.0", "1.4.2")
    assert message == "your CLI offered 2.0.0; this gateway requires 1.4.2"
  end

  test "a missing or malformed version is refused against the required version" do
    required = CliCompatibility.required_version()
    assert {:error, missing} = CliCompatibility.check(nil)
    assert missing == "your CLI offered no version; this gateway requires #{required}"

    assert {:error, malformed} = CliCompatibility.check("not-semver")
    assert malformed == "your CLI offered not-semver; this gateway requires #{required}"
  end
end
