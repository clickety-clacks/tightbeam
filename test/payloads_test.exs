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
      attention_tier: 0
    }

    user = Payloads.server_message(base)
    assert user["streaming"] == false
    assert user["deviceId"] == "dev-1"
    assert user["clientMessageId"] == "client-1"
    refute Map.has_key?(user, "sender")
    refute Map.has_key?(user, "replyToMessageId")
    refute Map.has_key?(user, "displayLabel")

    bracketed_user = Payloads.server_message(%{base | content: "[marker] ordinary user text"})
    refute Map.has_key?(bracketed_user, "displayLabel")

    attributed_user = Payloads.server_message(%{base | sender: "user:flynn"})
    assert attributed_user["sender"] == "user:flynn"

    assistant =
      Payloads.server_message(%{
        base
        | role: "assistant",
          sender: "tightbeam",
          device_id: nil,
          client_message_id: nil,
          reply_to_message_id: "m1",
          reply_to_client_message_id: "client-1"
      })

    assert assistant["sender"] == "tightbeam"
    assert assistant["replyToMessageId"] == "m1"
    assert assistant["replyToClientMessageId"] == "client-1"
    refute Map.has_key?(assistant, "deviceId")
    refute Map.has_key?(assistant, "displayLabel")

    substrate = Payloads.server_message(%{base | sender: "process:tightbeam"})
    assert substrate["displayLabel"] == "[substrate]"

    marker =
      Payloads.server_message(%{
        base
        | role: "assistant",
          sender: "process:tightbeam",
          content: "[adapter down]\n\nThe engine stopped."
      })

    assert marker["displayLabel"] == "[marker]"
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

    failed =
      Payloads.prompt_turn_state_event(%{
        client_message_id: "client-1",
        session_key: "s1",
        state: "failed",
        error: "boom"
      })

    assert failed["payload"]["messageId"] == "client-1"
    assert failed["payload"]["correlationId"] == "client-1"
    assert failed["payload"]["terminalState"] == true
    assert failed["payload"]["error"] == "boom"
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
      operational_parent: "agent:main:clawline:flynn:main",
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
      "operationalParent" => "agent:main:clawline:flynn:main",
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
