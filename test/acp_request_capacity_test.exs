defmodule Tightbeam.Acp.RequestCapacityTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Acp.Conn

  test "Claude submitted text is not restricted by the Codex text limit or a guessed provider-body cap" do
    text = String.duplicate("🙂", Tightbeam.SubmissionSize.codex_text_limit() + 1)
    params = %{sessionId: "s", prompt: [%{type: "text", text: text}]}
    assert {:ok, frame} = Conn.request_frame(7, "session/prompt", params, nil, "claude")
    assert JSON.decode!(frame)["params"]["prompt"] == [%{"type" => "text", "text" => text}]

    # An explicitly configured transport limit is still enforced before writing.
    assert {:error, {:transport_capacity_exceeded, actual, limit}} =
             Conn.request_frame(7, "session/prompt", params, byte_size(frame) - 1, "claude")

    assert actual == byte_size(frame)
    assert limit == actual - 1
  end

  test "actual submission prewrite checks combined Codex text and retains unresolved requests" do
    limit = Tightbeam.SubmissionSize.codex_text_limit()

    params = %{
      sessionId: "s",
      prompt: [
        %{type: "text", text: String.duplicate("🙂", limit - 1)},
        %{type: "text", text: "e\u0301"}
      ]
    }

    reason = {:submission_text_limit_exceeded, limit + 1, limit}
    assert {:error, ^reason} = Conn.request_frame(7, "session/prompt", params, nil, "codex")
    unresolved = %{method: "session/prompt", prompt_session_id: "other", orphaned: true}
    state = %Conn{port: nil, next_id: 7, pending: %{6 => unresolved}}
    ref = make_ref()

    assert {:reply, {:error, {:acp_request_not_dispatched, ^reason}}, ^state} =
             Conn.handle_call(
               {:request, "session/prompt", params,
                [submission_harness: "codex", notify_dispatched: {self(), ref}]},
               {self(), make_ref()},
               state
             )

    assert_receive {:acp_request_not_dispatched, ^ref, ^reason}
    refute_receive {:acp_request_dispatched, ^ref, _}
    assert state.pending[6] == unresolved
    assert state.next_id == 7

    evidence =
      Tightbeam.NoticeSubmission.prewrite_evidence(
        :prompt,
        {:acp_request_not_dispatched, reason}
      )

    assert Tightbeam.NoticeSubmission.valid_evidence?(evidence)
    refute Tightbeam.NoticeSubmission.valid_evidence?(Map.put(evidence, "invented", true))
  end

  test "Codex text at the inclusive limit fits despite larger UTF8 transport bytes" do
    limit = Tightbeam.SubmissionSize.codex_text_limit()
    params = %{sessionId: "s", prompt: [%{type: "text", text: String.duplicate("🙂", limit)}]}
    assert {:ok, frame} = Conn.request_frame(7, "session/prompt", params, nil, "codex")
    assert byte_size(frame) > limit * 4

    assert {:error, {:transport_capacity_exceeded, actual, 1}} =
             Conn.request_frame(7, "session/prompt", params, 1, "codex")

    assert actual == byte_size(frame)
  end

  test "transport measurement includes the complete escaped request and delimiter" do
    params = %{sessionId: "s", prompt: [%{type: "text", text: "quoted \"\\\n🙂"}]}
    {:ok, frame} = Conn.request_frame(999, "session/prompt", params)

    assert frame ==
             JSON.encode!(%{jsonrpc: "2.0", id: 999, method: "session/prompt", params: params}) <>
               "\n"

    assert byte_size(frame) > byte_size(hd(params.prompt).text)
    assert {:ok, ^frame} = Conn.request_frame(999, "session/prompt", params, byte_size(frame))

    assert {:error, {:transport_capacity_exceeded, actual, limit}} =
             Conn.request_frame(999, "session/prompt", params, byte_size(frame) - 1)

    assert actual == byte_size(frame)
    assert limit == actual - 1
    {:ok, next_frame} = Conn.request_frame(1000, "session/prompt", params)
    assert byte_size(next_frame) == actual + 1
  end

  test "an oversized request is classified before any port effect or pending request" do
    params = %{sessionId: "s", prompt: [%{type: "text", text: "source stays intact"}]}
    {:ok, frame} = Conn.request_frame(7, "session/prompt", params)
    ref = make_ref()
    from = {self(), make_ref()}
    state = %Conn{port: nil, next_id: 7}
    limit = byte_size(frame) - 1
    reason = {:transport_capacity_exceeded, byte_size(frame), limit}

    assert {:reply, {:error, {:acp_request_not_dispatched, ^reason}}, ^state} =
             Conn.handle_call(
               {:request, "session/prompt", params,
                [max_request_bytes: limit, notify_dispatched: {self(), ref}]},
               from,
               state
             )

    assert_receive {:acp_request_not_dispatched, ^ref, ^reason}
    refute_receive {:acp_request_dispatched, ^ref, _}
    assert state.pending == %{}
    assert state.next_id == 7
    refute state.closed
  end

  test "invalid discovered transport capacities refuse before a write" do
    for limit <- [0, -1, 1.5, "65536", :unknown] do
      state = %Conn{port: nil}
      ref = make_ref()

      assert {:reply, {:error, {:acp_request_not_dispatched, :invalid_transport_capacity}},
              ^state} =
               Conn.handle_call(
                 {:request, "session/prompt", %{sessionId: "s"},
                  [max_request_bytes: limit, notify_dispatched: {self(), ref}]},
                 {self(), make_ref()},
                 state
               )

      assert_receive {:acp_request_not_dispatched, ^ref, :invalid_transport_capacity}
      refute_receive {:acp_request_dispatched, ^ref, _}
    end
  end

  test "capacity refusal cannot erase another request's unknown-effect evidence" do
    unresolved = %{method: "session/prompt", prompt_session_id: "other", orphaned: true}
    state = %Conn{port: nil, next_id: 12, pending: %{11 => unresolved}}
    ref = make_ref()

    assert {:reply, {:error, {:acp_request_not_dispatched, reason}}, ^state} =
             Conn.handle_call(
               {:request, "session/prompt", %{sessionId: "s"},
                [max_request_bytes: 1, notify_dispatched: {self(), ref}]},
               {self(), make_ref()},
               state
             )

    assert {:transport_capacity_exceeded, _, 1} = reason
    assert_receive {:acp_request_not_dispatched, ^ref, ^reason}
    assert state.pending[11] == unresolved
  end
end
