defmodule Tightbeam.WorkItemBodySmokeScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../scripts/work_item_body_smoke.exs", __DIR__)

  test "R41 smoke checks exact persisted detail and records gateway cleanup" do
    source = File.read!(@script)

    for marker <- [
          "TIGHTBEAM_WORK_ITEM_BODY_SMOKE_TEMPLATE",
          "TIGHTBEAM_WORK_ITEM_BODY_SMOKE_PORT",
          "cli/target/release/tightbeam",
          "specs/smoke/work-item-body.md",
          "Scope",
          "assert_detail!(detail, @body, smoke_user, item_id)",
          "LegGateway.provision!",
          "LegGateway.boot",
          "LegGateway.restart",
          "LegGateway.teardown",
          "R41 phase=restart-readback",
          "R41 gateway=restart old_pid=",
          "restart_boot_failed",
          "Path.join(gateway.base_dir, \"work\")",
          "System.cmd(binary, args, cd: work_dir",
          "R41 teardown=",
          "if result != :ok"
        ] do
      assert source =~ marker
    end

    refute source =~ "TIGHTBEAM_WORK_ITEM_BODY_SMOKE_PORT\", \"12188\""
    refute source =~ "String.contains?(body, \"R41\")"
  end
end
