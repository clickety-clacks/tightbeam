defmodule Tightbeam.CodexAcpPatchTest do
  use ExUnit.Case, async: true

  alias Tightbeam.CodexAcpPatch

  test "patch forwards developer instructions and surfaces account updates idempotently" do
    source = """
          modelProvider: this.getModelProvider(),
          cwd: request.cwd
          modelProvider: await this.getResumeModelProvider(),
          threadId: request.sessionId
          case "account/updated":
          case "fs/changed":
    """

    patched = CodexAcpPatch.patch(source)
    assert patched =~ "developerInstructions: request._meta?.developerInstructions"
    assert patched =~ "accountUpdated: notification.params"
    assert CodexAcpPatch.patch(patched) == patched
  end
end
