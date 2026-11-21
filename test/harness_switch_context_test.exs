defmodule Tightbeam.HarnessSwitchContextTest do
  use ExUnit.Case, async: true

  alias Tightbeam.{HarnessHealth, HarnessProcess, HarnessSwitchContext}

  defmodule CatalogFixture do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:get, {host, harness}}, _from, {owner, inventories} = state) do
      send(owner, {:catalog_lookup, host, harness})
      {:reply, Map.get(inventories, harness, {[], {:unavailable, :missing}}), state}
    end
  end

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
    assert Application.get_env(:tightbeam, :harness_switch_context_enabled)
    assert [compactor, claude] = config.compactors
    assert claude.route == :acp
    assert claude.harness == Tightbeam.Harness.Claude
    assert claude.model == "claude-haiku-5-5"
    assert [claude_price] = claude.source_applicability
    assert claude_price.compactor_input_usd_per_million == 0.5

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
    assert source.checked_on == "2026-11-21"
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
    assert no_route.fallback_reason =~ "no qualified harness was available"
    assert String.downcase(no_route.prompt) =~ "retrieve transcript fixture-session"

    assert no_route.prompt =~
             "Compaction could not start because no qualified harness was available."

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

    assert failed.fallback_reason =~
             "Compaction failed on every available harness: codex (request timed out)."

    assert failed.prompt =~
             "Compaction failed on every available harness: codex (request timed out)."

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

    assert result.prompt =~
             "Fallback reason: Compaction could not start because no qualified harness was available"

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

    assert Enum.any?(
             insufficient.compaction_evidence.unavailable,
             &(&1.reason == "input exceeded its context capacity")
           )

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
    assert blank.fallback_reason =~ "codex (returned empty output)"

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

    assert Enum.any?(
             unlisted.compaction_evidence.unavailable,
             &(&1.reason =~ "not listed for this source model and tier")
           )

    assert equal_price.outcome == "fallback"

    assert Enum.any?(
             equal_price.compaction_evidence.unavailable,
             &(&1.reason =~ "rates are not strictly cheaper")
           )

    refute_receive :unexpected_call
  end

  test "runtime qualification uses host catalog capacity and credential for its provider" do
    host = Tightbeam.Placement.local_host_name()
    owner = self()

    entry = %{
      family: "gpt-6-luna",
      context: nil,
      efforts: ["low"],
      provider: :openai,
      max_input_tokens: 272_000
    }

    {db, plan} =
      runtime_plan({[entry], :fresh}, fn ^host, :openai ->
        send(owner, :credential_checked)
        :onboarded
      end)

    result = compact_history(plan)

    assert result.outcome == "compacted"
    assert result.compaction_evidence.configured_context_tokens == 272_000
    assert_receive {:catalog_lookup, ^host, "codex"}
    assert_receive :credential_checked
    assert_receive {:compactor_called, "gpt-6-luna"}
    assert Process.alive?(db)
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

  test "missing or unavailable host catalog yields no attempts" do
    {_db, plan} =
      runtime_plan({[], {:unavailable, :missing}}, fn _, _ ->
        flunk("an unavailable catalog has no route credential")
      end)

    result = compact_history(plan)
    assert result.outcome == "fallback"
    assert [%{reason: "catalog_route_unavailable"}] = result.compaction_evidence.unavailable
    assert result.compaction_evidence.attempts == []
    refute_receive {:compactor_called, _}
  end

  test "a catalog model without an onboarded credential yields no attempts" do
    {_, plan} =
      runtime_plan({[catalog_entry("gpt-6-luna", :openai)], :fresh}, fn _, :openai ->
        {:needs_onboarding, :revoked}
      end)

    result = compact_history(plan)

    assert [%{reason: "credential_unavailable"}] = result.compaction_evidence.unavailable
    assert result.compaction_evidence.attempts == []
    refute_receive {:compactor_called, _}
  end

  test "a real health fence steers candidates, and account quota is committed before failover" do
    host = Tightbeam.Placement.local_host_name()
    now = System.system_time(:millisecond)
    db = start_supervised!({Tightbeam.DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)

    catalog = %{
      "codex" => {[catalog_entry("gpt-6-luna", :openai)], :fresh},
      "claude" => {[catalog_entry("claude-haiku-5-5", :anthropic)], :fresh}
    }

    settings = Application.fetch_env!(:tightbeam, :harness_switch_context)
    assert {:ok, :no_launch} = HarnessProcess.begin_park(db, {:claude, "shared", host})

    plan =
      runtime_plan(db, catalog, settings, fn _, _ -> :onboarded end, fn
        %{model: "gpt-6-luna"}, _, _ ->
          {:error, {:prompt_failed, %{"data" => %{"codexErrorInfo" => "usageLimitExceeded"}}}}

        %{model: "claude-haiku-5-5"}, _, _ ->
          assert HarnessProcess.parked?(db, {:codex, "shared", host})
          {:ok, "summary after quota", %{}}
      end)

    result = compact_history(plan)
    assert result.outcome == "compacted"

    assert [
             %{health: %{observation_id: observation_id, incident_id: incident_id}},
             %{harness: "claude"}
           ] =
             result.compaction_evidence.attempts

    incident = HarnessHealth.get(db, incident_id)
    assert incident.harness == "codex"
    assert [%{id: ^observation_id, session_key: nil, assignment_id: nil}] = incident.observations

    assert %{status: "recorded"} =
             HarnessHealth.observe_compactor_failure(db, %{
               context_id: "other-switch",
               harness: "codex",
               host: host,
               model: "gpt-6-luna",
               reason: {:session_create_failed, :timeout},
               observed_at: now
             })

    assert %{since: ^now, failure_class: "adapter_unavailable"} =
             HarnessHealth.compactor_observation(db, "codex", host, now)

    assert HarnessHealth.compactor_observation(db, "codex", host, now + 120_001) == nil
  end

  test "an otherwise qualified configured Fable or Astra route never runs" do
    [codex, claude] =
      configured_compactors(
        fn _, _ -> flunk("Astra cannot compact") end,
        fn _, _ -> flunk("Fable cannot compact") end
      )

    routes =
      Enum.map([{codex, "gpt-6-astra-2"}, {claude, "claude-fable-5-2"}], fn {route, model} ->
        [source] = route.source_applicability
        %{route | model: model, source_applicability: [%{source | compactor_model: model}]}
      end)

    result = compact_history(routes)
    assert result.outcome == "fallback"
    assert result.compaction_evidence.attempts == []

    assert Enum.map(result.compaction_evidence.unavailable, & &1.reason) ==
             ["model_not_permitted", "model_not_permitted"]
  end

  test "advisory steering retains fenced candidates and stops at the first fitting summary" do
    owner = self()

    [codex, claude] =
      configured_compactors(
        &send(owner, {:unexpected_codex, &1, &2}),
        fn _, _ -> {:ok, "qualified Claude summary", %{}} end
      )

    plan =
      synthetic_plan([codex, claude], fn
        %{harness: Tightbeam.Harness.Codex} -> [%{reason: "existing fence"}]
        %{harness: Tightbeam.Harness.Claude} -> []
      end)

    result = compact_history(plan)
    assert result.outcome == "compacted"
    assert result.compactor_model == "claude-haiku-5-5"
    assert Enum.map(result.compaction_evidence.base_order, & &1.harness) == ["codex", "claude"]
    assert Enum.map(result.compaction_evidence.steered_order, & &1.harness) == ["claude", "codex"]
    assert [%{harness: "claude"}] = result.compaction_evidence.attempts
    refute_receive {:unexpected_codex, _, _}
  end

  test "failure is recorded before the fenced alternate is tried and the excerpt names every failure" do
    owner = self()

    [codex, claude] =
      configured_compactors(
        fn _, _ -> {:error, :timeout} end,
        fn _, _ ->
          assert_received {:recorded, "gpt-6-luna", :timeout}
          {:error, :provider_refused}
        end
      )

    plan =
      [codex, claude]
      |> synthetic_plan(fn _ -> [%{reason: "existing fence"}] end)
      |> Map.put(:failure, fn _snapshot, route, reason ->
        send(owner, {:recorded, route.model, reason})
        %{observation_id: "fixture-observation"}
      end)

    result = compact_history(plan)

    assert result.outcome == "fallback"

    assert result.compaction_evidence.attempts == [
             %{
               harness: "codex",
               model: "gpt-6-luna",
               reason: "request timed out",
               health: %{observation_id: "fixture-observation"}
             },
             %{
               harness: "claude",
               model: "claude-haiku-5-5",
               reason: "provider_refused",
               health: %{observation_id: "fixture-observation"}
             }
           ]

    assert result.prompt =~
             "Compaction failed on every available harness: codex (request timed out), claude (provider_refused)."

    assert result.prompt =~ "There is no room to carry a transcript excerpt."
    assert result.prompt =~ "Retrieve the full history from the source transcript."
    assert count(result.prompt, "current input marker") == 1
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

    assert Enum.any?(
             result.compaction_evidence.unavailable,
             &(&1.reason =~ "not listed for this source model and tier")
           )

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

  defp runtime_plan(catalog_inventory, credential_status) do
    owner = self()
    db = start_supervised!({Tightbeam.DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)

    plan =
      runtime_plan(
        db,
        %{"codex" => catalog_inventory},
        %{compactor: compactor(nil)},
        credential_status,
        fn compactor, _, _ ->
          send(owner, {:compactor_called, compactor.model})
          {:ok, "compacted", %{route: "codex_acp"}}
        end
      )

    {db, plan}
  end

  defp runtime_plan(db, inventories, settings, credential_status, call) do
    catalog = start_supervised!({CatalogFixture, {self(), inventories}})

    config = %{
      base_dir: System.tmp_dir!(),
      model_catalog: catalog,
      harness_switch_context: settings,
      harness_switch_credential_status: credential_status,
      harness_switch_compactor_call: call
    }

    HarnessSwitchContext.compactor_plan(db, config, %{host: Tightbeam.Placement.local_host_name()})
  end

  defp catalog_entry(model, provider) do
    %{
      family: model,
      context: nil,
      efforts: ["low"],
      provider: provider,
      max_input_tokens: 272_000
    }
  end

  defp configured_compactors(codex_call, claude_call) do
    [codex, claude] = Application.fetch_env!(:tightbeam, :harness_switch_context).compactors

    [
      Map.merge(codex, %{context_tokens: 272_000, call: codex_call}),
      Map.merge(claude, %{context_tokens: 1_000_000, call: claude_call})
    ]
  end

  defp synthetic_plan(routes, fences) do
    %{
      routes: routes,
      resolve: &{:ok, &1},
      fences: fn _, route -> fences.(route) end,
      failure: fn _, _, _ -> nil end
    }
  end

  defp compact_history(plan) do
    HarnessSwitchContext.build_handoff(
      snapshot(),
      fixture_entries(String.duplicate("historical source detail ", 180)),
      "current input marker",
      [],
      budget(2_500),
      plan
    )
  end

  defp count(value, substring), do: length(String.split(value, substring)) - 1
end
