defmodule Tightbeam.HarnessSwitchContextTest do
  use ExUnit.Case, async: true

  alias Tightbeam.HarnessSwitchContext

  @source_price_url "https://developers.openai.com/api/docs/models/gpt-6-sol"
  @compactor_price_url "https://developers.openai.com/api/docs/models/gpt-6-luna"

  test "a fitting handoff keeps history and current input separate without calling a configured compactor" do
    test_pid = self()
    current = "WID19B_CURRENT_INPUT=keep-this-verbatim"
    compactor = compactor(fn _input, _instructions -> send(test_pid, :unexpected_call) end)

    result =
      HarnessSwitchContext.build_handoff(
        snapshot(%{pending_message_ids: ["fixture-pending-message"]}),
        fixture_entries("WID19B_GOAL=keep-the-visible-work"),
        current,
        [],
        budget(20_000),
        compactor
      )

    assert result.outcome == "fit_no_call"
    assert result.budget.handoff_within_allowance
    assert result.budget.destination_within_context
    assert result.prompt =~ "## Historical working context"
    assert result.prompt =~ "WID19B_GOAL=keep-the-visible-work"
    assert result.prompt =~ "## Current input (verbatim; this turn only)"
    assert count(result.prompt, current) == 1
    assert result.prompt =~ "pending-at-switch IDs excluded 1"
    refute result.prompt =~ "fixture-pending-message"
    refute_receive :unexpected_call
  end

  test "history exactly at the allowance fits without calling the configured compactor" do
    test_pid = self()
    context = snapshot()
    entries = fixture_entries("WID19B_EXACT_BOUNDARY=preserve")
    current = "WID19B_CURRENT_INPUT=exact-boundary"

    measured =
      HarnessSwitchContext.build_handoff(context, entries, current, [], budget(10_000), nil)

    exact =
      HarnessSwitchContext.build_handoff(
        context,
        entries,
        current,
        [],
        budget(measured.historical_context_bytes_upper),
        compactor(fn _input, _instructions -> send(test_pid, :unexpected_call) end)
      )

    assert exact.budget.available_history_tokens == exact.historical_context_bytes_upper
    assert exact.outcome == "fit_no_call"
    assert exact.budget.handoff_within_allowance
    refute_receive :unexpected_call
  end

  test "the elected runtime route names its model and exact source price applicability" do
    config = Application.fetch_env!(:tightbeam, :harness_switch_context)
    compactor = config.compactor

    assert compactor.route == :codex_acp
    assert compactor.harness in Tightbeam.Harness.all()
    assert compactor.harness.wire_name() == "codex"
    assert compactor.model == "gpt-6-luna"
    assert compactor.effort == "low"
    refute Map.has_key?(compactor, :context_tokens)
    assert compactor.max_output_tokens == 16_000

    assert [source] = compactor.source_applicability
    assert source.source_model == "gpt-6-sol"
    assert source.source_model_contexts == [nil]
    assert source.compactor_model == compactor.model
    assert source.source_context_tier == source.compactor_context_tier
    assert source.source_processing_tier == source.compactor_processing_tier
    assert source.checked_on == "2026-11-11"
  end

  test "an over-budget nil-default Sol source uses the configured cheaper route and fits" do
    test_pid = self()

    fixture =
      "WID19B_GOAL=release-safely\n" <>
        "WID19B_DECISION=keep-history-visible\n" <>
        "WID19B_CONSTRAINT=do-not-touch-live-state\n" <>
        "WID19B_CURRENT_WORK=carry-the-source-task\n" <>
        "WID19B_BLOCKER=none\n" <>
        "WID19B_EVIDENCE=https://example.test/evidence/context-fixture.md\n" <>
        String.duplicate("older transcript detail ", 180)

    compacted =
      "WID19B_GOAL=release-safely\n" <>
        "WID19B_DECISION=keep-history-visible\n" <>
        "WID19B_CONSTRAINT=do-not-touch-live-state\n" <>
        "WID19B_CURRENT_WORK=carry-the-source-task\n" <>
        "WID19B_BLOCKER=none\n" <>
        "WID19B_EVIDENCE=https://example.test/evidence/context-fixture.md"

    route =
      compactor(fn input, instructions ->
        send(test_pid, {:compacted_input, input, instructions})
        {:ok, compacted, %{input_tokens: 1_100, output_tokens: 190, service_tier: "default"}}
      end)

    result =
      HarnessSwitchContext.build_handoff(
        snapshot(%{source_model_context: nil}),
        fixture_entries(fixture),
        "WID19B_CURRENT_INPUT=next-request",
        [],
        budget(1_700),
        route
      )

    assert_receive {:compacted_input, input, instructions}
    assert input =~ "older transcript detail"
    assert instructions =~ "goals"
    assert result.outcome == "compacted"
    assert result.budget.handoff_within_allowance
    assert result.budget.destination_within_context
    assert result.historical_context_bytes_upper <= result.budget.available_history_tokens
    assert result.compactor_model == "gpt-6-luna"
    assert result.compactor_usage.service_tier == "default"
    assert result.compaction.route == "codex_acp"
    assert result.compaction.input_capacity_upper > result.compaction.input_bytes_upper
    assert result.compaction.output_bytes_upper == byte_size(compacted)
    assert result.compaction.destination_bytes_upper <= result.compaction.destination_allowance
    assert result.compaction.source_applicability.price_unit == "USD per 1M text tokens"
    assert result.compaction.source_applicability.source_model_contexts == [nil]

    for marker <- [
          "WID19B_GOAL=release-safely",
          "WID19B_DECISION=keep-history-visible",
          "WID19B_CONSTRAINT=do-not-touch-live-state",
          "WID19B_CURRENT_WORK=carry-the-source-task",
          "WID19B_BLOCKER=none",
          "https://example.test/evidence/context-fixture.md"
        ] do
      assert result.prompt =~ marker
    end

    assert count(result.prompt, "WID19B_CURRENT_INPUT=next-request") == 1
    assert result.prompt =~ "model-generated portable context"
    assert result.prompt =~ "compactor input contained 1 recent processed message"
    assert result.prompt =~ "does not claim to retain each message verbatim"
    refute result.prompt =~ "omitted processed coverage none"
  end

  test "missing compactor and failed compaction produce a truthful bounded fallback" do
    entries = fixture_entries(String.duplicate("processed source detail ", 180))
    context_budget = budget(760)

    no_route =
      HarnessSwitchContext.build_handoff(
        snapshot(),
        entries,
        "WID19B_CURRENT_INPUT=next-request",
        [],
        context_budget,
        nil
      )

    assert no_route.outcome == "fallback"
    assert no_route.fallback_reason =~ "not configured"
    assert no_route.prompt =~ "Summary unavailable"
    assert String.downcase(no_route.prompt) =~ "retrieve transcript fixture-session"
    assert no_route.prompt =~ "Fallback: compactor not configured"
    assert no_route.included_message_ids == []
    assert no_route.omitted_message_ids == ["fixture-message-1"]
    assert no_route.budget.handoff_within_allowance

    failed_route =
      compactor(fn _input, _instructions -> {:error, :timeout} end)

    failed =
      HarnessSwitchContext.build_handoff(
        snapshot(),
        entries,
        "WID19B_CURRENT_INPUT=next-request",
        [],
        context_budget,
        failed_route
      )

    assert failed.outcome == "fallback"
    assert failed.fallback_reason == "compactor request timed out"
    assert failed.prompt =~ "Fallback: compactor request timed out"
    assert count(failed.prompt, "WID19B_CURRENT_INPUT=next-request") == 1
  end

  test "bounded fallback keeps the newest intact message and identifies omitted coverage" do
    snapshot =
      snapshot(%{
        processed_message_ids: ["fixture-old", "fixture-recent"],
        processed_window_count: 2,
        processed_window_truncated?: false
      })

    entries = [
      %{
        id: "fixture-old",
        seq: 1,
        role: "user",
        sender: "User",
        content: String.duplicate("older transcript detail ", 80),
        status: "delivered"
      },
      %{
        id: "fixture-recent",
        seq: 2,
        role: "assistant",
        sender: "Codex",
        content: "WID19B_RECENT=keep-this-complete-message",
        status: "delivered"
      }
    ]

    recent_only =
      HarnessSwitchContext.build_handoff(
        snapshot,
        [List.last(entries)],
        "WID19B_CURRENT_INPUT=next-request",
        [],
        budget(10_000),
        nil
      )

    available = recent_only.historical_context_bytes_upper + 100

    result =
      HarnessSwitchContext.build_handoff(
        snapshot,
        entries,
        "WID19B_CURRENT_INPUT=next-request",
        [],
        budget(available),
        nil
      )

    assert result.outcome == "fallback"
    assert result.included_message_ids == ["fixture-recent"]
    assert result.omitted_message_ids == ["fixture-old"]
    assert result.prompt =~ "WID19B_RECENT=keep-this-complete-message"
    refute result.prompt =~ "older transcript detail"

    assert result.prompt =~
             "omitted processed coverage in that window 1 recent processed message ID(s)"

    assert result.prompt =~ "Fallback reason: compactor not configured"
    assert result.prompt =~ "retrieve originals from the source transcript"
  end

  test "insufficient compactor capacity, blank output, and an oversized output all fall back" do
    entries = fixture_entries(String.duplicate("processed source detail ", 80))
    input_budget = budget(850)

    insufficient =
      HarnessSwitchContext.build_handoff(
        snapshot(),
        entries,
        "WID19B_CURRENT_INPUT=next-request",
        [],
        input_budget,
        compactor(
          fn _input, _instructions -> flunk("capacity failure must not call the route") end,
          context_tokens: 200
        )
      )

    assert insufficient.outcome == "fallback"
    assert insufficient.fallback_reason =~ "input exceeded its context capacity"

    blank =
      HarnessSwitchContext.build_handoff(
        snapshot(),
        entries,
        "WID19B_CURRENT_INPUT=next-request",
        [],
        input_budget,
        compactor(fn _input, _instructions ->
          {:ok, "  ", %{input_tokens: 100, output_tokens: 0}}
        end)
      )

    assert blank.outcome == "fallback"
    assert blank.fallback_reason == "compactor returned empty output"

    oversized =
      HarnessSwitchContext.build_handoff(
        snapshot(),
        entries,
        "WID19B_CURRENT_INPUT=next-request",
        [],
        input_budget,
        compactor(fn _input, _instructions ->
          {:ok, String.duplicate("still too long ", 100),
           %{input_tokens: 100, output_tokens: 500}}
        end)
      )

    assert oversized.outcome == "fallback"
    assert oversized.fallback_reason =~ "output did not fit destination allowance"
    assert String.downcase(oversized.prompt) =~ "retrieve transcript fixture-session"
  end

  test "unknown destination capacity makes no call and uses the bounded retrieval notice" do
    test_pid = self()

    result =
      HarnessSwitchContext.build_handoff(
        snapshot(),
        fixture_entries("WID19B_GOAL=source-work"),
        "WID19B_CURRENT_INPUT=next-request",
        [],
        %{},
        compactor(fn _input, _instructions -> send(test_pid, :unexpected_call) end)
      )

    assert result.outcome == "fallback"
    assert result.budget.status == "unverified"
    assert result.historical_context_bytes_upper <= 256
    assert result.prompt =~ "Summary unavailable"
    assert String.downcase(result.prompt) =~ "retrieve transcript fixture-session"
    refute_receive :unexpected_call
  end

  test "an unlisted or non-cheaper source cannot use the configured route" do
    test_pid = self()
    route = compactor(fn _input, _instructions -> send(test_pid, :unexpected_call) end)
    long_entries = fixture_entries(String.duplicate("processed source detail ", 180))

    unlisted =
      HarnessSwitchContext.build_handoff(
        snapshot(%{source_model: "gpt-6-luna"}),
        long_entries,
        "WID19B_CURRENT_INPUT=next-request",
        [],
        budget(760),
        route
      )

    equal_price =
      HarnessSwitchContext.build_handoff(
        snapshot(),
        long_entries,
        "WID19B_CURRENT_INPUT=next-request",
        [],
        budget(760),
        compactor(fn _input, _instructions -> send(test_pid, :unexpected_call) end,
          price_row: %{source_input_usd_per_million: 0.1, source_output_usd_per_million: 0.5}
        )
      )

    assert unlisted.outcome == "fallback"
    assert unlisted.fallback_reason =~ "not listed for this source model and tier"
    assert equal_price.outcome == "fallback"
    assert equal_price.fallback_reason =~ "rates are not strictly cheaper"
    refute_receive :unexpected_call
  end

  test "runtime compactor input capacity comes from its exact host harness model catalog entry" do
    test_pid = self()

    config = %{
      harness_switch_context: %{
        compactor:
          compactor(fn _input, _instructions ->
            send(test_pid, :unexpected_call)
          end)
      },
      harness_switch_catalog_entry: fn host, harness, model ->
        send(test_pid, {:catalog_lookup, host, harness, model})
        %{max_input_tokens: 272_000}
      end,
      harness_switch_compactor_call: fn _compactor, _input, _instructions ->
        {:ok, "compacted", %{route: "codex_acp"}}
      end
    }

    compactor = HarnessSwitchContext.compactor_for_switch(config, %{host: "test-host"})

    assert compactor.context_tokens == 272_000
    assert is_function(compactor.call, 2)

    assert_receive {:catalog_lookup, "test-host", "codex",
                    %Tightbeam.Model{family: "gpt-6-luna", effort: "low", context: nil}}
  end

  test "destination allowance tracks the captured instructions, tools, and actual current input" do
    config = %{
      harness_switch_catalog_entry: fn "test-host", "codex", %Tightbeam.Model{context: nil} ->
        %{max_input_tokens: 100_000}
      end
    }

    session = %{
      host: "test-host",
      harness: "codex",
      model: Tightbeam.Model.new("gpt-6-sol")
    }

    payload = %{
      identity_tokens_upper: 120,
      tool_definition_tokens_upper: 80,
      component_sources: %{
        identity_tokens_upper: "fixture exact destination guidance and session metadata",
        tool_definition_tokens_upper: "fixture exact destination MCP definitions"
      }
    }

    baseline =
      destination_allowance(config, session, payload, "next")

    assert baseline ==
             100_000 - 120 - 80 -
               byte_size("\n## Current input (verbatim; this turn only)\nnext") - 16_384

    more_identity = Map.update!(payload, :identity_tokens_upper, &(&1 + 7))
    more_tools = Map.update!(payload, :tool_definition_tokens_upper, &(&1 + 3))

    assert destination_allowance(config, session, more_identity, "next") == baseline - 7
    assert destination_allowance(config, session, more_tools, "next") == baseline - 3
    assert destination_allowance(config, session, payload, "next longer") == baseline - 7
  end

  test "missing exact compactor catalog capacity prevents the call and stays on bounded fallback" do
    test_pid = self()

    config = %{
      harness_switch_context: %{
        compactor: compactor(fn _input, _instructions -> send(test_pid, :unexpected_call) end)
      },
      harness_switch_catalog_entry: fn _host, _harness, _model -> nil end,
      harness_switch_compactor_call: fn _compactor, _input, _instructions ->
        send(test_pid, :unexpected_call)
        {:ok, "must not run", %{route: "codex_acp"}}
      end
    }

    compactor = HarnessSwitchContext.compactor_for_switch(config, %{host: "test-host"})

    assert is_nil(compactor.context_tokens)

    result =
      HarnessSwitchContext.build_handoff(
        snapshot(),
        fixture_entries(String.duplicate("historical source detail ", 80)),
        "WID19B_CURRENT_INPUT=preserve",
        [],
        budget(850),
        compactor
      )

    assert result.outcome == "fallback"
    assert result.fallback_reason =~ "capacity"
    refute_receive :unexpected_call
  end

  test "a listed source outside its recorded context tier falls back without a call" do
    test_pid = self()

    result =
      HarnessSwitchContext.build_handoff(
        snapshot(%{source_model_context: "long"}),
        fixture_entries(String.duplicate("processed source detail ", 180)),
        "WID19B_CURRENT_INPUT=next-request",
        [],
        budget(760),
        compactor(fn _input, _instructions -> send(test_pid, :unexpected_call) end)
      )

    assert result.outcome == "fallback"
    assert result.fallback_reason =~ "not listed for this source model and tier"
    refute_receive :unexpected_call
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        context_id: "hsc-fixture-context",
        session_key: "fixture-session",
        source_harness: "codex",
        source_model: "gpt-6-sol",
        source_model_context: nil,
        source_pointer_id: 7,
        source_native_session_id: "fixture-native-session",
        source_cleared_through_seq: 0,
        processed_message_ids: ["fixture-message-1"],
        processed_window_count: 1,
        processed_window_truncated?: false,
        processed_window_starts_at_seq: nil,
        pending_message_ids: [],
        excluded_message_ids: [],
        excluded_window_count: 0,
        excluded_window_truncated?: false,
        excluded_window_starts_at_seq: nil,
        summary_reason: "no supported source summary content and durable coverage event"
      },
      overrides
    )
  end

  defp fixture_entries(content) do
    [
      %{
        id: "fixture-message-1",
        seq: 1,
        role: "user",
        sender: "User",
        content: content,
        status: "delivered"
      }
    ]
  end

  defp budget(context_tokens) do
    identity_tokens_upper = 80
    tool_definition_tokens_upper = 40
    pending_input_tokens_upper = 75
    reserve_tokens = 16_384

    catalog_input_limit_tokens =
      context_tokens + identity_tokens_upper + tool_definition_tokens_upper +
        pending_input_tokens_upper + reserve_tokens

    %{
      catalog_input_limit_tokens: catalog_input_limit_tokens,
      selected_context_limit_tokens: catalog_input_limit_tokens,
      context_tokens: catalog_input_limit_tokens,
      identity_tokens_upper: identity_tokens_upper,
      tool_definition_tokens_upper: tool_definition_tokens_upper,
      pending_input_tokens_upper: pending_input_tokens_upper,
      reserve_tokens: reserve_tokens,
      catalog_key: "fixture-host|codex|fixture-model",
      selected_context: "default",
      evidence: "synthetic exact catalog and serialized payload fixture",
      component_sources: %{
        catalog_input_limit_tokens: "synthetic exact catalog row",
        selected_context_limit_tokens: "synthetic context-cap catalog row",
        identity_tokens_upper: "synthetic serialized identity payload bytes",
        tool_definition_tokens_upper: "synthetic serialized tool payload bytes",
        pending_input_tokens_upper: "synthetic serialized current prompt and input frame",
        reserve_tokens: "v7 C4 shared output/protocol reserve"
      }
    }
  end

  defp destination_allowance(config, session, payload, current_input) do
    budget =
      HarnessSwitchContext.destination_budget(config, session, current_input, [], payload)

    handoff =
      HarnessSwitchContext.build_handoff(
        snapshot(),
        fixture_entries("WID19B_HISTORY=preserve"),
        current_input,
        [],
        budget,
        nil
      )

    assert handoff.budget.reserve_tokens == 16_384
    handoff.budget.available_history_tokens
  end

  defp compactor(call, opts \\ []) do
    price_row =
      Map.merge(
        %{
          source_model: "gpt-6-sol",
          compactor_model: "gpt-6-luna",
          source_model_contexts: [nil],
          source_context_tier: "standard-short",
          compactor_context_tier: "standard-short",
          source_processing_tier: "default",
          compactor_processing_tier: "default",
          source_input_usd_per_million: 2.0,
          source_output_usd_per_million: 10.0,
          compactor_input_usd_per_million: 0.1,
          compactor_output_usd_per_million: 0.5,
          source_price_url: @source_price_url,
          compactor_price_url: @compactor_price_url,
          price_unit: "USD per 1M text tokens",
          checked_on: "2026-11-11"
        },
        Keyword.get(opts, :price_row, %{})
      )

    Map.merge(
      %{
        route: :codex_acp,
        harness: Tightbeam.Harness.Codex,
        model: "gpt-6-luna",
        context_tokens: 10_000,
        max_output_tokens: 600,
        protocol_overhead_bytes_upper: 400,
        effort: "low",
        source_applicability: [price_row],
        call: call
      },
      Keyword.take(opts, [:context_tokens]) |> Enum.into(%{})
    )
  end

  defp count(value, substring), do: length(String.split(value, substring)) - 1
end
