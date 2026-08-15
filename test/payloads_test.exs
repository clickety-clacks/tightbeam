defmodule Tightbeam.Wire.PayloadsTest do
  use ExUnit.Case, async: true
  alias Tightbeam.Model

  alias Tightbeam.Wire.Payloads

  test "pair, auth, ack, typing, activity, and sync frames use string camelCase keys" do
    assert Payloads.pair_result({:ok, "token", "flynn"}) == %{
             "type" => "pair_result",
             "success" => true,
             "token" => "token",
             "userId" => "flynn"
           }

    assert Payloads.pair_result({:error, "pending"}) == %{
             "type" => "pair_result",
             "success" => false,
             "reason" => "pending"
           }

    auth =
      Payloads.auth_result_success(%{
        user_id: "flynn",
        session_id: "connection-1",
        is_admin: true,
        replay_count: 2,
        replay_truncated: false,
        history_reset: false,
        session_keys: ["s1"],
        stream_read_states: %{"s1" => "m1"},
        stream_tail_states: %{
          "s1" => %{"lastMessageId" => "m2", "lastMessageRole" => "assistant"}
        },
        features: ["streams"],
        dm_scope: nil
      })

    assert auth["sessionKeys"] == ["s1"]
    assert auth["dmScope"] == nil
    assert Payloads.auth_result_failure("auth_failed")["success"] == false
    assert Payloads.ack("client-1") == %{"type" => "ack", "id" => "client-1"}
    assert Payloads.assistant_typing("s1", true)["sessionKey"] == "s1"

    assert Payloads.activity_event(%{is_active: true, message_id: "m1", session_key: "s1"})[
             "payload"
           ] == %{
             "isActive" => true,
             "messageId" => "m1",
             "sessionKey" => "s1"
           }

    assert Payloads.sync_complete() == %{"type" => "sync_complete"}
  end

  test "server message includes only non-nil conditional keys" do
    base = %{
      seq: 1,
      id: "m1",
      session_key: "s1",
      role: "user",
      content: "hi",
      timestamp: 1000,
      sender: nil,
      device_id: "dev-1",
      client_message_id: "client-1",
      reply_to_message_id: nil,
      reply_to_client_message_id: nil,
      llm_visible_message_id: "client-1",
      attachments: [],
      attention_tier: 0,
      message_type: nil,
      marker: nil
    }

    user = Payloads.server_message(base)
    assert user["streaming"] == false
    assert user["deviceId"] == "dev-1"
    assert user["clientMessageId"] == "client-1"
    refute Map.has_key?(user, "sender")
    refute Map.has_key?(user, "replyToMessageId")
    refute Map.has_key?(user, "messageType")
    refute Map.has_key?(user, "marker")

    assistant =
      Payloads.server_message(%{
        base
        | role: "assistant",
          sender: "tightbeam",
          device_id: nil,
          client_message_id: nil,
          reply_to_message_id: "m1",
          reply_to_client_message_id: "client-1",
          message_type: "assistant"
      })

    assert assistant["sender"] == "tightbeam"
    assert assistant["replyToMessageId"] == "m1"
    assert assistant["replyToClientMessageId"] == "client-1"
    assert assistant["messageType"] == "assistant"
    refute Map.has_key?(assistant, "deviceId")

    marker =
      Payloads.server_message(%{
        base
        | role: "assistant",
          sender: "process:tightbeam",
          device_id: nil,
          client_message_id: nil,
          message_type: "marker",
          marker: %{kind: "harness-switch", from: "claude", to: "codex"}
      })

    assert marker["type"] == "message"
    assert marker["messageType"] == "marker"

    assert marker["marker"] == %{
             "kind" => "harness-switch",
             "from" => "claude",
             "to" => "codex"
           }

    future = Payloads.server_message(%{base | message_type: "future-class"})
    assert future["messageType"] == "future-class"
  end

  test "wire error and prompt state omit optional nil keys" do
    assert Payloads.wire_error("server_error") == %{"type" => "error", "code" => "server_error"}

    error = Payloads.wire_error("server_error", "boom", "m1")
    assert error["message"] == "boom"
    assert error["messageId"] == "m1"

    running =
      Payloads.prompt_turn_state_event(%{
        client_message_id: "client-1",
        session_key: "s1",
        state: "running",
        error: nil
      })

    assert running["payload"]["terminalState"] == false
    refute Map.has_key?(running["payload"], "error")
    refute Map.has_key?(running["payload"], "failure")

    failure = %{
      "code" => "onboarding_in_progress",
      "message" => "Onboarding is waiting for a browser step.",
      "onboarding" => %{
        "ceremonyId" => "oc_1",
        "provider" => "anthropic",
        "host" => "gibson",
        "state" => "awaitingUser",
        "nextAction" => "openUrlThenSubmitCode"
      }
    }

    failed =
      Payloads.prompt_turn_state_event(%{
        client_message_id: "client-1",
        session_key: "s1",
        state: "failed",
        error: "Onboarding is waiting for a browser step.",
        failure: failure
      })

    assert failed["payload"]["messageId"] == "client-1"
    assert failed["payload"]["correlationId"] == "client-1"
    assert failed["payload"]["terminalState"] == true
    assert failed["payload"]["error"] == "Onboarding is waiting for a browser step."
    assert failed["payload"]["failure"] == failure
  end

  test "onboarding updates use the complete closed state mapping" do
    expected = %{
      "preparing" => "preparing",
      "awaiting_user" => "awaitingUser",
      "validating" => "validating",
      "ready_to_commit" => "readyToCommit",
      "committing" => "committing",
      "recovery_required" => "recoveryRequired",
      "succeeded" => "succeeded",
      "canceled" => "canceled",
      "expired" => "expired",
      "superseded" => "superseded",
      "failed" => "failed"
    }

    assert Map.new(expected, fn {stored, _wire} ->
             {stored, Payloads.onboarding_wire_state(stored)}
           end) == expected

    view = %{
      "ceremonyId" => "oc_1",
      "state" => "awaiting_user",
      "authorizationUrl" => "https://example.invalid/authorize",
      "nextAction" => "openUrlThenSubmitCode"
    }

    assert Payloads.onboarding_update(view) == %{
             "type" => "onboarding_update",
             "onboarding" => %{view | "state" => "awaitingUser"}
           }

    assert_raise ArgumentError, ~r/unknown onboarding stored state/, fn ->
      Payloads.onboarding_wire_state("awaiting-user")
    end
  end

  test "stream builders preserve exact wrapper shapes" do
    session = %{
      session_key: "s1",
      display_name: "Main",
      kind: "main",
      order_index: 0,
      is_built_in: true,
      adopted: true,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: "agent:main:clawline:flynn:main",
      handle: nil,
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      thinking_level: nil,
      state: "active",
      created_at: 1,
      updated_at: 2
    }

    existing_keys = %{
      "sessionKey" => "s1",
      "displayName" => "Main",
      "kind" => "main",
      "orderIndex" => 0,
      "isBuiltIn" => true,
      "createdAt" => 1,
      "updatedAt" => 2,
      "adopted" => true,
      "startedBy" => "user"
    }

    stream = Payloads.stream_session(session)

    assert stream ==
             Map.merge(existing_keys, %{
               "origin" => "user:flynn",
               "spawnedBy" => "agent:main:clawline:flynn:main"
             })

    # `origin` and `spawnedBy` drop out when absent; `startedBy` never does —
    # a client that has to handle a missing value has to invent a policy for it.
    stream_without_provenance =
      session
      |> Map.put(:origin, nil)
      |> Map.put(:spawned_by, nil)
      |> Payloads.stream_session()

    assert stream_without_provenance == %{existing_keys | "startedBy" => "substrate"}
    refute Map.has_key?(stream_without_provenance, "origin")
    refute Map.has_key?(stream_without_provenance, "spawnedBy")

    assert Payloads.stream_snapshot([stream]) == %{
             "type" => "stream_snapshot",
             "streams" => [stream]
           }

    assert Payloads.stream_created(stream) == %{"type" => "stream_created", "stream" => stream}
    assert Payloads.stream_updated(stream) == %{"type" => "stream_updated", "stream" => stream}
    assert Payloads.stream_deleted("s1") == %{"type" => "stream_deleted", "sessionKey" => "s1"}

    assert Payloads.stream_read_state("s1", "m1") == %{
             "type" => "stream_read_state",
             "sessionKey" => "s1",
             "lastReadMessageId" => "m1"
           }
  end
end
