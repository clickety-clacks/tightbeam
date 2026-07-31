defmodule Tightbeam.CliCompatibilityTest do
  use ExUnit.Case, async: true

  alias Tightbeam.CliCompatibility

  test "the gateway accepts only its exact required CLI version" do
    required = CliCompatibility.required_version()

    assert :ok = CliCompatibility.check(required)

    assert {:error, newer} = CliCompatibility.check("0.2.0")
    assert newer == "your CLI offered 0.2.0; this gateway requires 0.1.0"
  end

  test "a mismatched CLI is refused with both sides of the compatibility decision" do
    assert {:error, message} = CliCompatibility.check("0.0.9")

    assert message == "your CLI offered 0.0.9; this gateway requires 0.1.0"
  end

  test "a missing or malformed version is refused against the required version" do
    assert {:error, missing} = CliCompatibility.check(nil)
    assert missing == "your CLI offered no version; this gateway requires 0.1.0"

    assert {:error, malformed} = CliCompatibility.check("not-semver")
    assert malformed == "your CLI offered not-semver; this gateway requires 0.1.0"
  end
end
