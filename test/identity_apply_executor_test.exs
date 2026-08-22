defmodule Tightbeam.IdentityApply.ExecutorTest do
  use ExUnit.Case, async: true

  alias Tightbeam.IdentityApply

  test "logical effect and continuation identifiers are deterministic and phase-separated" do
    operation_id = "iap_test"
    session_key = "agent:coder:test"

    assert IdentityApply.effect_id(operation_id, session_key, 3, "runner-stop") ==
             IdentityApply.effect_id(operation_id, session_key, 3, "runner-stop")

    refute IdentityApply.effect_id(operation_id, session_key, 3, "runner-stop") ==
             IdentityApply.effect_id(operation_id, session_key, 3, "reload")

    assert IdentityApply.continuation_message_id(operation_id, session_key) ==
             IdentityApply.continuation_message_id(operation_id, session_key)
  end

  test "the continuation names the durable query and never promises rollback" do
    prompt = IdentityApply.continuation_prompt("iap_test")

    assert prompt =~ "do not assume its external side effects were rolled back"
    assert prompt =~ "tightbeam identity apply --operation iap_test"
  end
end
