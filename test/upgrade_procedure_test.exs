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
    assert section =~ "SELECT name, ssh, cliBin FROM hosts ORDER BY name;"
    assert section =~ ~s|REMOTE_CLI_Q=$(shell_quote "$CLI_BIN/tightbeam")|
    assert section =~ ~s(ssh -- "$SSH_DEST" "$REMOTE_CLI_Q version; uname -sm")

    assert section =~
             "`already current (<version>)` or\n`updated (<old-version> -> <version>)`"

    assert section =~ "plus the deployed version and\n`uname -sm` target for every inventory row"
    assert section =~ "Any missing host, missing probe,\nversion mismatch, target mismatch"
    assert section =~ "or `refused` outcome stops the\nupgrade"
  end

  test "upgrade preserves cross-target refusal and rollback readback" do
    section = File.read!(@upgrade) |> section!("## Update every registered satellite CLI")

    assert section =~ "It refuses a cross-architecture replacement"
    assert section =~ "`Darwin arm64` selects `darwin-aarch64`"
    assert section =~ "`Linux x86_64` selects `linux-x86_64`"
    assert section =~ "Any other result has no supported\npackage and stops the upgrade"
    assert section =~ "Verify the matching package against the release\n`SHA256SUMS`"
    assert section =~ ~s(tar -xzf "$PACKAGE" -C "$LOCAL_STAGE" tightbeam/bin/tightbeam)
    assert section =~ ~s(scp -- "$LOCAL_STAGE/tightbeam/bin/tightbeam" "$SSH_DEST:$REMOTE_STAGE")
    assert section =~ ~s|REMOTE_STAGE_Q=$(shell_quote "$REMOTE_STAGE")|
    assert section =~ ~s|REMOTE_VERSION=$(ssh -- "$SSH_DEST"|
    assert section =~ ~s(if [ "$REMOTE_VERSION" != "$VERSION" ]; then)
    assert section =~ ~s(ssh -- "$SSH_DEST" "rm -f $REMOTE_STAGE_Q")
    assert section =~ ~s(ssh -- "$SSH_DEST" "mv -f $REMOTE_STAGE_Q $REMOTE_CLI_Q")
    assert section =~ "Do not bypass the target refusal"
    assert section =~ "A gateway rollback includes the same stage"
    assert section =~ "Repeat the inventory and per-host probe"
    assert section =~ "retain that complete\nrollback readback with the rollback evidence"
  end

  test "release train requires the canonical upgrade stage without duplicating it" do
    procedure = File.read!(@release_train)
    section = section!(procedure, "## Require the fleet CLI stage during deployment")

    assert section =~
             "[satellite CLI update and readback](UPGRADE.md#update-every-registered-satellite-cli)"

    assert section =~ "per-host version and target evidence"
    assert section =~ "gateway registry inventory"
    assert section =~ "explicit target/version probes"
    assert section =~ "A rollback must run\nthe same stage"
    refute procedure =~ "tightbeam update-clients"
  end

  test "documented remote quoting preserves option-like destinations and difficult paths" do
    section = File.read!(@upgrade) |> section!("## Update every registered satellite CLI")
    quote_function = between!(section, "# BEGIN fleet-shell-quote", "# END fleet-shell-quote")

    root =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-upgrade-quote-#{System.unique_integer([:positive])}"
      )

    cli_bin = Path.join(root, "o'brien tight beam/bin")
    stage = Path.join(cli_bin, ".tightbeam.release-0.2.0")
    installed = Path.join(cli_bin, "tightbeam")
    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(cli_bin)
    File.write!(stage, "#!/bin/sh\nprintf '0.2.0\\n'\n")
    File.chmod!(stage, 0o755)

    script = """
    #{quote_function}
    SSH_DEST=-mistyped-host
    REMOTE_STAGE=$3
    REMOTE_CLI=$4
    set -- -- "$SSH_DEST"
    test "$1" = --
    test "$2" = -mistyped-host
    REMOTE_STAGE_Q=$(shell_quote "$REMOTE_STAGE")
    REMOTE_CLI_Q=$(shell_quote "$REMOTE_CLI")
    REMOTE_VERSION=$(bash -c "$REMOTE_STAGE_Q version")
    test "$REMOTE_VERSION" = 0.2.0
    bash -c "mv -f $REMOTE_STAGE_Q $REMOTE_CLI_Q"
    """

    assert {"", 0} =
             System.cmd("bash", ["-c", script, "bash", "unused", "unused", stage, installed])

    assert File.exists?(installed)
  end

  defp section!(document, heading) do
    [section | _] =
      document
      |> String.split(heading, parts: 2)
      |> List.last()
      |> String.split("\n## ")

    section
  end

  defp between!(document, opening, closing) do
    [_before, rest] = String.split(document, opening, parts: 2)
    [body, _after] = String.split(rest, closing, parts: 2)
    body
  end
end
