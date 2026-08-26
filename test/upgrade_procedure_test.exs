defmodule Tightbeam.UpgradeProcedureTest do
  use ExUnit.Case, async: true

  @upgrade Path.expand("../docs/UPGRADE.md", __DIR__)
  @release_train Path.expand("../docs/RELEASE_TRAIN.md", __DIR__)

  test "upgrade requires fleet CLI update with complete per-host readback" do
    procedure = File.read!(@upgrade)
    section = section!(procedure, "## Update every registered satellite CLI")

    assert procedure =~
             "# 4. update every registered satellite CLI and retain the per-host readback"

    assert section =~ "tightbeam update-clients --as-user <adminUserId>"
    assert section =~ "registered CLI version from every satellite host"
    assert section =~ "reads `uname -sm` and derives that host's\ntarget"
    assert section =~ "`already current (<version>)` or `updated (<old-version> -> <version>)`"
    assert section =~ "for every registered satellite"
    assert section =~ "Any missing host"
    assert section =~ "or `refused` outcome\nstops the upgrade"
  end

  test "upgrade preserves cross-target refusal and rollback readback" do
    section = File.read!(@upgrade) |> section!("## Update every registered satellite CLI")

    assert section =~ "It refuses a cross-architecture replacement"
    assert section =~ "Verify the package against the\nrelease `SHA256SUMS`"
    assert section =~ "Do not bypass the target refusal"
    assert section =~ "A gateway rollback includes the same stage"
    assert section =~ "retain that rollback readback with the rollback evidence"
  end

  test "release train requires the canonical upgrade stage without duplicating it" do
    procedure = File.read!(@release_train)
    section = section!(procedure, "## Require the fleet CLI stage during deployment")

    assert section =~
             "[satellite CLI update and readback](UPGRADE.md#update-every-registered-satellite-cli)"

    assert section =~ "per-host version and target evidence"
    assert section =~ "A rollback must run\nthe same stage"
    refute procedure =~ "tightbeam update-clients"
  end

  defp section!(document, heading) do
    [section | _] =
      document
      |> String.split(heading, parts: 2)
      |> List.last()
      |> String.split("\n## ")

    section
  end
end
