defmodule Tightbeam.CliCompatibilityTest do
  use ExUnit.Case, async: true

  alias Tightbeam.CliCompatibility

  test "a pre-1.0 gateway accepts only its exact CLI version" do
    required = CliCompatibility.required_version()

    assert :ok = CliCompatibility.check(required)
    assert :ok = CliCompatibility.check("0.9.0", "0.9.0")

    assert {:error, newer} = CliCompatibility.check("0.9.1", "0.9.0")
    assert newer == "your CLI offered 0.9.1; this gateway requires 0.9.0"

    assert :ok = CliCompatibility.check("0.9.9+cli", "0.9.9+cli")

    assert {:error, different_build} =
             CliCompatibility.check("0.9.9+cli", "0.9.9+gateway")

    assert different_build ==
             "your CLI offered 0.9.9+cli; this gateway requires 0.9.9+gateway"
  end

  test "a mismatched CLI is refused with both sides of the compatibility decision" do
    required = CliCompatibility.required_version()
    assert {:error, message} = CliCompatibility.check("0.0.9")

    assert message == "your CLI offered 0.0.9; this gateway requires #{required}"
  end

  test "a gateway at or above 1.0 accepts same-MAJOR minor and patch drift" do
    assert :ok = CliCompatibility.check("1.0.0", "1.0.1")
    assert :ok = CliCompatibility.check("1.1.0", "1.0.0")
    assert :ok = CliCompatibility.check("1.0.7", "1.4.2")

    assert {:error, _message} = CliCompatibility.check("0.9.9", "1.0.0")
    assert {:error, _message} = CliCompatibility.check("1.0.0", "2.0.0")
    assert {:error, message} = CliCompatibility.check("2.0.0", "1.4.2")
    assert message == "your CLI offered 2.0.0; this gateway requires 1.4.2"
  end

  test "a 1.0 prerelease on either side remains under the stable boundary" do
    assert {:error, offered_prerelease} =
             CliCompatibility.check("1.0.0-rc.1", "1.0.0")

    assert offered_prerelease ==
             "your CLI offered 1.0.0-rc.1; this gateway requires 1.0.0"

    assert {:error, required_prerelease} =
             CliCompatibility.check("1.0.0", "1.0.0-rc.1")

    assert required_prerelease ==
             "your CLI offered 1.0.0; this gateway requires 1.0.0-rc.1"
  end

  test "a missing or malformed version is refused against the required version" do
    required = CliCompatibility.required_version()
    assert {:error, missing} = CliCompatibility.check(nil)
    assert missing == "your CLI offered no version; this gateway requires #{required}"

    assert {:error, malformed} = CliCompatibility.check("not-semver")
    assert malformed == "your CLI offered not-semver; this gateway requires #{required}"
  end
end
