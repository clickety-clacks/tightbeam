defmodule Tightbeam.CodexUsageTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.CodexUsage
  alias Tightbeam.Harness.Codex, as: CodexHarness

  @key {:codex, "shared", "gibson"}

  setup do
    owner = self()
    name = {:global, {__MODULE__, make_ref()}}

    cache =
      start_supervised!(
        {CodexUsage,
         name: name, request: fn adapter, claim -> send(owner, {:usage_read, adapter, claim}) end}
      )

    %{cache: cache}
  end

  test "normalizes only the Codex limit and emits exact ordered windows" do
    raw = %{
      "rateLimitsByLimitId" => %{
        "codex" => %{
          "primary" => %{
            "usedPercent" => 28,
            "windowDurationMins" => 300,
            "resetsAt" => 1_770_003_600
          },
          "secondary" => %{
            "usedPercent" => 59,
            "windowDurationMins" => 10_080,
            "resetsAt" => nil
          },
          "credits" => "PRIVATE-CREDIT",
          "planType" => "PRIVATE-PLAN"
        },
        "other" => %{"primary" => %{"usedPercent" => 99}}
      },
      "rateLimits" => %{"primary" => %{"usedPercent" => 98}},
      "rateLimitResetCredits" => "PRIVATE-RESET-CREDIT",
      "account" => "PRIVATE-ACCOUNT"
    }

    assert {:accepted, _baseline, windows, 1_770_000_000_000, false} =
             CodexUsage.map_read_result({:ok, raw}, 1_770_000_000_000)

    assert windows == [
             %{label: "5h", remaining_percent: 72, reset_at: 1_770_003_600_000},
             %{label: "Week", remaining_percent: 41, reset_at: nil}
           ]

    normalized = inspect(CodexUsage.normalize_full(raw))
    refute normalized =~ "PRIVATE"
    refute normalized =~ "other"
  end

  test "rejects invalid windows, keeps one valid window, and takes the primary duplicate" do
    one_valid = %{
      "rateLimits" => %{
        "primary" => %{"usedPercent" => 20, "windowDurationMins" => 300, "resetsAt" => nil},
        "secondary" => %{
          "usedPercent" => 101,
          "windowDurationMins" => 10_080,
          "resetsAt" => nil
        }
      }
    }

    assert %{windows: [%{label: "5h", remaining_percent: 80}], invalid?: true} =
             CodexUsage.normalize_full(one_valid)

    duplicate = %{
      "rateLimits" => %{
        "primary" => %{"usedPercent" => 20, "windowDurationMins" => 300, "resetsAt" => nil},
        "secondary" => %{"usedPercent" => 70, "windowDurationMins" => 300, "resetsAt" => nil}
      }
    }

    assert %{windows: [%{remaining_percent: 80}], invalid?: true} =
             CodexUsage.normalize_full(duplicate)
  end

  test "coalesces reads and moves through loading, fresh, stale, and recovered", %{cache: cache} do
    adapter = self()
    CodexUsage.adapter_ready(cache, @key, adapter, :subscription)

    assert %{usage: %{freshness: "loading", windows: []}} =
             CodexUsage.project(cache, @key, :subscription, 1_770_000_000_000)

    assert_receive {:usage_read, ^adapter, first_claim}

    CodexUsage.project(cache, @key, :subscription, 1_770_000_000_000)
    refute_receive {:usage_read, ^adapter, _claim}

    result =
      CodexUsage.map_read_result(
        {:ok, full_snapshot(28, 1_770_003_600)},
        1_770_000_000_000
      )

    CodexUsage.adapter_event(cache, @key, adapter, {:full, first_claim, result})

    assert %{generation: generation, usage: %{freshness: "fresh", windows: windows}} =
             CodexUsage.project(cache, @key, :subscription, 1_770_000_000_001)

    assert [%{remaining_percent: 72}] = windows

    assert %{generation: ^generation, usage: %{freshness: "stale", windows: ^windows}} =
             CodexUsage.project(cache, @key, :subscription, 1_770_003_600_000)

    assert_receive {:usage_read, ^adapter, reset_claim}
    CodexUsage.adapter_event(cache, @key, adapter, {:full, reset_claim, {:error, :timeout}})

    assert %{generation: ^generation, usage: %{freshness: "stale", windows: ^windows}} =
             CodexUsage.project(cache, @key, :subscription, 1_770_000_000_002)
  end

  test "an adapter restart retains stale data and fences its late completion", %{cache: cache} do
    old_adapter = spawn_adapter()
    new_adapter = spawn_adapter()
    on_exit(fn -> Process.exit(old_adapter, :kill) end)
    on_exit(fn -> Process.exit(new_adapter, :kill) end)

    CodexUsage.adapter_ready(cache, @key, old_adapter, :subscription)
    assert_receive {:usage_read, ^old_adapter, first_claim}

    first = CodexUsage.map_read_result({:ok, full_snapshot(10, nil)}, 100)
    CodexUsage.adapter_event(cache, @key, old_adapter, {:full, first_claim, first})
    %{generation: generation} = CodexUsage.project(cache, @key, :subscription, 101)

    CodexUsage.adapter_down(cache, @key, old_adapter)

    assert %{generation: ^generation, usage: %{freshness: "stale"}} =
             CodexUsage.project(cache, @key, :subscription, 102)

    CodexUsage.adapter_ready(cache, @key, new_adapter, :subscription)
    assert_receive {:usage_read, ^new_adapter, replacement_claim}

    late = CodexUsage.map_read_result({:ok, full_snapshot(99, nil)}, 103)
    CodexUsage.adapter_event(cache, @key, old_adapter, {:full, first_claim, late})

    fresh = CodexUsage.map_read_result({:ok, full_snapshot(30, nil)}, 104)
    CodexUsage.adapter_event(cache, @key, new_adapter, {:full, replacement_claim, fresh})

    assert %{generation: ^generation, usage: %{freshness: "fresh", windows: [window]}} =
             CodexUsage.project(cache, @key, :subscription, 105)

    assert window.remaining_percent == 70
  end

  test "terminal auth creates a new empty generation and old failures cannot republish", %{
    cache: cache
  } do
    adapter = self()
    CodexUsage.adapter_ready(cache, @key, adapter, :subscription)
    assert_receive {:usage_read, ^adapter, claim}
    before = CodexUsage.project(cache, @key, :subscription, 100).generation

    CodexUsage.adapter_event(cache, @key, adapter, {:auth, :terminal})

    assert %{generation: after_terminal, usage: usage} =
             CodexUsage.project(cache, @key, :subscription, 101)

    refute after_terminal == before

    assert usage == %{
             freshness: "unavailable",
             windows: [],
             unavailableReason: "account_binding_unavailable"
           }

    CodexUsage.adapter_event(
      cache,
      @key,
      adapter,
      {:full, claim, {:error, :provider_unavailable}}
    )

    assert %{generation: ^after_terminal, usage: ^usage} =
             CodexUsage.project(cache, @key, :subscription, 102)
  end

  test "a credential replacement changes generation before a replacement read", %{cache: cache} do
    adapter = self()
    CodexUsage.adapter_ready(cache, @key, adapter, :subscription)
    assert_receive {:usage_read, ^adapter, _claim}
    before = CodexUsage.project(cache, @key, :subscription, 100).generation

    assert :ok = CodexUsage.binding_changed(cache, :openai, "gibson")

    assert %{generation: after_change, usage: usage} =
             CodexUsage.project(cache, @key, :subscription, 101)

    refute after_change == before
    assert usage.unavailableReason == "account_binding_unavailable"
    refute_receive {:usage_read, ^adapter, _claim}
  end

  test "rate-limit refusal mapping never parses provider error fields" do
    sentinel = %{"code" => -32_602, "message" => "DO-NOT-PARSE-AUTH-SENTINEL"}

    assert CodexUsage.map_read_result({:error, sentinel}, 100) ==
             {:error, :provider_unavailable}

    assert CodexUsage.map_read_result({:error, :timeout}, 100) == {:error, :timeout}
  end

  test "sparse updates require a baseline and null fields preserve it", %{cache: cache} do
    adapter = self()
    CodexUsage.adapter_ready(cache, @key, adapter, :subscription)
    assert_receive {:usage_read, ^adapter, claim}

    sparse =
      CodexUsage.normalize_sparse(%{
        "rateLimits" => %{
          "primary" => %{"usedPercent" => 50, "windowDurationMins" => nil, "resetsAt" => nil}
        }
      })

    CodexUsage.adapter_event(cache, @key, adapter, {:sparse, sparse, 110})
    refute_receive {:usage_read, ^adapter, _other_claim}
    assert %{usage: %{freshness: "loading"}} = CodexUsage.project(cache, @key, :subscription, 111)

    full = CodexUsage.map_read_result({:ok, full_snapshot(20, 500)}, 112)
    CodexUsage.adapter_event(cache, @key, adapter, {:full, claim, full})
    CodexUsage.adapter_event(cache, @key, adapter, {:sparse, sparse, 113})

    assert %{usage: %{freshness: "fresh", windows: [window]}} =
             CodexUsage.project(cache, @key, :subscription, 114)

    assert window == %{label: "5h", remaining_percent: 50, reset_at: 500_000}
  end

  test "a sparse merge updates its baseline without inventing a public generation", %{
    cache: cache
  } do
    adapter = self()
    CodexUsage.adapter_ready(cache, @key, adapter, :subscription)
    assert_receive {:usage_read, ^adapter, claim}

    raw = %{
      "rateLimits" => %{
        "primary" => %{"usedPercent" => 20, "windowDurationMins" => 300, "resetsAt" => nil},
        "secondary" => %{"usedPercent" => 70, "windowDurationMins" => 301, "resetsAt" => nil}
      }
    }

    CodexUsage.adapter_event(
      cache,
      @key,
      adapter,
      {:full, claim, CodexUsage.map_read_result({:ok, raw}, 100)}
    )

    used_update =
      CodexUsage.normalize_sparse(%{"rateLimits" => %{"secondary" => %{"usedPercent" => 60}}})

    CodexUsage.adapter_event(cache, @key, adapter, {:sparse, used_update, 101})

    duration_update =
      CodexUsage.normalize_sparse(%{
        "rateLimits" => %{"secondary" => %{"windowDurationMins" => 10_080}}
      })

    CodexUsage.adapter_event(cache, @key, adapter, {:sparse, duration_update, 102})

    assert %{usage: %{windows: [five_hour, week]}} =
             CodexUsage.project(cache, @key, :subscription, 103)

    assert five_hour.remaining_percent == 80
    assert week == %{label: "Week", remaining_percent: 40, reset_at: nil}
  end

  test "ineligible bindings omit usage and status merge preserves session accounting", %{
    cache: cache
  } do
    assert CodexUsage.project(cache, @key, :api_key, 100) == nil
    assert CodexUsage.project(cache, {:claude, "shared", "gibson"}, :subscription, 100) == nil

    payload = %{
      display: %{authMode: "oauth"},
      sessionUsage: %{inputTokens: 12},
      run: %{state: "idle"}
    }

    merged =
      CodexUsage.merge_status(payload, %{
        generation: "mcg-test",
        usage: %{freshness: "loading", windows: []}
      })

    assert merged.sessionUsage == %{inputTokens: 12}
    assert merged.display.codexUsage == %{freshness: "loading", windows: []}
    assert merged.metadataContextGeneration == "mcg-test"

    assert Map.delete(merged, :metadataContextGeneration)
           |> update_in([:display], &Map.delete(&1, :codexUsage)) == payload
  end

  test "logs and process status expose labels but not raw provider fields", %{cache: cache} do
    adapter = self()

    raw =
      full_snapshot(13, 4_102_938_475)
      |> Map.put("account", "DO-NOT-LOG-ACCOUNT")
      |> Map.put("credits", "DO-NOT-LOG-CREDITS")

    log =
      capture_log(fn ->
        CodexUsage.adapter_ready(cache, @key, adapter, :subscription)
        assert_receive {:usage_read, ^adapter, claim}
        result = CodexUsage.map_read_result({:ok, raw}, 1_770_123_456_789)
        CodexUsage.adapter_event(cache, @key, adapter, {:full, claim, result})
        CodexUsage.project(cache, @key, :subscription, 1)
      end)

    assert log =~ "codex_usage_capture"
    refute log =~ "DO-NOT-LOG"
    refute log =~ "4102938475"
    refute log =~ "1770123456789"

    status = :sys.get_status(cache) |> inspect()
    refute status =~ "DO-NOT-LOG"
    refute status =~ "4102938475"
    refute status =~ "1770123456789"
  end

  test "provider sentinels and raw values never escape the privacy boundary", %{cache: cache} do
    nonce = Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)

    sentinels =
      for field <- ~w(account plan credit balance message token cookie),
          do: "privacy-#{field}-#{nonce}"

    [account, plan, credit, balance, message, token, cookie] = sentinels
    used_percent = 37
    reset_seconds = 1_987_654_321
    fetched_at = 1_770_123_456_789
    accepted_host = "privacy-accepted-#{nonce}"
    accepted_key = {:codex, "shared", accepted_host}
    accepted_adapter = spawn_adapter()
    on_exit(fn -> send(accepted_adapter, :stop) end)

    raw =
      full_snapshot(used_percent, reset_seconds)
      |> Map.merge(%{
        "accountId" => account,
        "planType" => plan,
        "credits" => credit,
        "balance" => balance,
        "message" => message,
        "accessToken" => token,
        "cookie" => cookie
      })

    sparse_raw = %{
      "rateLimits" => %{
        "primary" => %{
          "usedPercent" => used_percent,
          "accountId" => account,
          "planType" => plan,
          "credits" => credit,
          "balance" => balance,
          "message" => message,
          "accessToken" => token,
          "cookie" => cookie
        }
      }
    }

    temp_storage = Path.join(System.tmp_dir!(), "codex-usage-privacy-#{nonce}")
    File.mkdir_p!(temp_storage)
    on_exit(fn -> File.rmdir(temp_storage) end)

    log =
      capture_log(fn ->
        CodexUsage.adapter_ready(cache, accepted_key, accepted_adapter, :subscription)
        assert_receive {:usage_read, ^accepted_adapter, accepted_claim}

        accepted = CodexUsage.map_read_result({:ok, raw}, fetched_at)

        CodexUsage.adapter_event(
          cache,
          accepted_key,
          accepted_adapter,
          {:full, accepted_claim, accepted}
        )

        barrier(cache)

        sparse = CodexUsage.normalize_sparse(sparse_raw)

        CodexUsage.adapter_event(
          cache,
          accepted_key,
          accepted_adapter,
          {:sparse, sparse, fetched_at + 1}
        )

        barrier(cache)

        failure_scenarios = [
          {:invalid_usage,
           CodexUsage.map_read_result(
             {:ok,
              %{
                "rateLimits" => %{
                  "primary" => %{
                    "usedPercent" => 101,
                    "windowDurationMins" => 300,
                    "message" => message
                  }
                }
              }},
             fetched_at
           )},
          {:timeout, {:error, :timeout}},
          {:provider_unavailable,
           CodexUsage.map_read_result({:error, %{"message" => message}}, fetched_at)}
        ]

        for {{name, result}, index} <- Enum.with_index(failure_scenarios) do
          key = {:codex, "shared", "privacy-#{name}-#{nonce}-#{index}"}
          adapter = spawn_adapter()
          CodexUsage.adapter_ready(cache, key, adapter, :subscription)
          assert_receive {:usage_read, ^adapter, claim}
          CodexUsage.adapter_event(cache, key, adapter, {:full, claim, result})
          barrier(cache)
          send(adapter, :stop)
        end

        superseded_key = {:codex, "shared", "privacy-superseded-#{nonce}"}
        superseded_adapter = spawn_adapter()
        CodexUsage.adapter_ready(cache, superseded_key, superseded_adapter, :subscription)
        assert_receive {:usage_read, ^superseded_adapter, _claim}

        CodexUsage.adapter_event(
          cache,
          superseded_key,
          superseded_adapter,
          {:full, %{generation: make_ref(), incarnation: make_ref()}, {:error, :timeout}}
        )

        barrier(cache)
        send(superseded_adapter, :stop)

        binding_host = "privacy-binding-#{nonce}"
        binding_key = {:codex, "shared", binding_host}
        binding_adapter = spawn_adapter()
        CodexUsage.adapter_ready(cache, binding_key, binding_adapter, :subscription)
        assert_receive {:usage_read, ^binding_adapter, _binding_claim}
        CodexUsage.binding_changed(cache, :openai, binding_host)
        send(binding_adapter, :stop)

        CodexUsage.project(cache, accepted_key, :subscription, fetched_at + 2)
        barrier(cache)
      end)

    state = :sys.get_state(cache)
    status = :sys.get_status(cache)
    projection = CodexUsage.project(cache, accepted_key, :subscription, fetched_at + 3)

    for sentinel <- sentinels do
      refute inspect(state) =~ sentinel
      refute inspect(status) =~ sentinel
      refute inspect(projection) =~ sentinel
      refute log =~ sentinel

      {_, repository_scan_status} =
        System.cmd("git", ["grep", "--fixed-strings", "-e", sentinel, "--", "."],
          stderr_to_stdout: true
        )

      assert repository_scan_status == 1
    end

    refute contains_term?(state, used_percent)
    refute contains_term?(state, reset_seconds)
    refute contains_term?(status, used_percent)
    refute contains_term?(status, reset_seconds)
    refute contains_term?(projection, used_percent)
    refute contains_term?(projection, reset_seconds)
    assert contains_term?(state, 100 - used_percent)
    assert contains_term?(state, reset_seconds * 1_000)
    assert File.ls!(temp_storage) == []

    crash_log = crash_after_sanitized_capture(raw, sentinels, reset_seconds, fetched_at)

    for sentinel <- sentinels do
      refute crash_log =~ sentinel
    end

    refute crash_log =~ Integer.to_string(reset_seconds)
  end

  test "structured capture events use the closed schema and terminal outcomes", %{cache: cache} do
    events =
      capture_usage_events(fn ->
        scenarios = [
          {:accepted, CodexUsage.map_read_result({:ok, full_snapshot(20, nil)}, 100)},
          {:invalid,
           CodexUsage.map_read_result(
             {:ok,
              %{
                "rateLimits" => %{
                  "primary" => %{"usedPercent" => 101, "windowDurationMins" => 300}
                }
              }},
             100
           )},
          {:timeout, {:error, :timeout}},
          {:provider_unavailable, {:error, :provider_unavailable}}
        ]

        for {outcome, result} <- scenarios do
          host = "observability-#{outcome}"
          key = {:codex, "shared", host}
          adapter = spawn_adapter()
          CodexUsage.adapter_ready(cache, key, adapter, :subscription)
          assert_receive {:usage_read, ^adapter, claim}
          CodexUsage.adapter_event(cache, key, adapter, {:full, claim, result})
          barrier(cache)
          send(adapter, :stop)
        end

        coalesced_key = {:codex, "shared", "observability-coalesced"}
        coalesced_adapter = spawn_adapter()
        CodexUsage.adapter_ready(cache, coalesced_key, coalesced_adapter, :subscription)
        assert_receive {:usage_read, ^coalesced_adapter, coalesced_claim}

        CodexUsage.adapter_event(
          cache,
          coalesced_key,
          coalesced_adapter,
          {:sparse, CodexUsage.normalize_sparse(%{"rateLimits" => %{}}), 100}
        )

        barrier(cache)

        accepted = CodexUsage.map_read_result({:ok, full_snapshot(30, nil)}, 101)

        CodexUsage.adapter_event(
          cache,
          coalesced_key,
          coalesced_adapter,
          {:full, coalesced_claim, accepted}
        )

        barrier(cache)
        send(coalesced_adapter, :stop)

        superseded_key = {:codex, "shared", "observability-superseded"}
        superseded_adapter = spawn_adapter()
        CodexUsage.adapter_ready(cache, superseded_key, superseded_adapter, :subscription)
        assert_receive {:usage_read, ^superseded_adapter, current_claim}

        CodexUsage.adapter_event(
          cache,
          superseded_key,
          superseded_adapter,
          {:full, %{current_claim | refresh: make_ref()}, accepted}
        )

        CodexUsage.adapter_event(
          cache,
          superseded_key,
          superseded_adapter,
          {:full, current_claim, accepted}
        )

        barrier(cache)
        send(superseded_adapter, :stop)

        terminal_key = {:codex, "shared", "observability-account-binding-unavailable"}
        terminal_adapter = spawn_adapter()
        CodexUsage.adapter_ready(cache, terminal_key, terminal_adapter, :subscription)
        assert_receive {:usage_read, ^terminal_adapter, _claim}
        CodexUsage.adapter_event(cache, terminal_key, terminal_adapter, {:auth, :terminal})
        barrier(cache)
        send(terminal_adapter, :stop)
      end)

    allowed_fields =
      MapSet.new([
        :event,
        :harness,
        :host,
        :binding_generation,
        :source,
        :outcome,
        :freshness,
        :windows
      ])

    runtime_fields = MapSet.new([:application, :domain, :file, :gl, :line, :mfa, :pid, :time])

    for %{meta: metadata} <- events do
      application_fields =
        metadata
        |> Map.keys()
        |> MapSet.new()
        |> MapSet.difference(runtime_fields)

      assert application_fields == allowed_fields
      assert metadata.event == "codex_usage_capture"
      assert metadata.harness == :codex
      assert is_binary(metadata.host)
      assert is_binary(metadata.binding_generation)
      assert metadata.source in [:read, :update]

      assert metadata.outcome in [
               :accepted,
               :coalesced,
               :superseded,
               :invalid,
               :timeout,
               :provider_unavailable,
               :account_binding_unavailable
             ]

      assert metadata.freshness in ["loading", "fresh", "stale", "unavailable"]
      assert Enum.all?(metadata.windows, &(&1 in ["5h", "Week"]))
    end

    outcomes = MapSet.new(events, & &1.meta.outcome)

    assert MapSet.subset?(
             MapSet.new([
               :accepted,
               :coalesced,
               :superseded,
               :invalid,
               :timeout,
               :provider_unavailable,
               :account_binding_unavailable
             ]),
             outcomes
           )

    terminal_outcomes =
      MapSet.new([
        :accepted,
        :superseded,
        :invalid,
        :timeout,
        :provider_unavailable,
        :account_binding_unavailable
      ])

    events
    |> Enum.group_by(& &1.meta.host, & &1.meta.outcome)
    |> Enum.each(fn {_host, host_outcomes} ->
      assert Enum.any?(host_outcomes, &MapSet.member?(terminal_outcomes, &1))
    end)
  end

  test "twenty concurrent reads coalesce and accepted events are idempotent", %{cache: cache} do
    adapter = self()
    CodexUsage.adapter_ready(cache, @key, adapter, :subscription)
    assert_receive {:usage_read, ^adapter, claim}

    results =
      1..20
      |> Task.async_stream(
        fn _ -> CodexUsage.project(cache, @key, :subscription, 100) end,
        max_concurrency: 20,
        ordered: false,
        timeout: 1_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?(%{usage: %{freshness: "loading", windows: []}}, &1))
    refute_receive {:usage_read, ^adapter, _other_claim}

    accepted = CodexUsage.map_read_result({:ok, full_snapshot(28, nil)}, 101)
    CodexUsage.adapter_event(cache, @key, adapter, {:full, claim, accepted})
    state_after_accept = barrier(cache)
    projection_after_accept = CodexUsage.project(cache, @key, :subscription, 102)

    CodexUsage.adapter_event(cache, @key, adapter, {:full, claim, accepted})
    state_after_full_replay = barrier(cache)

    assert state_after_full_replay.sequence == state_after_accept.sequence

    assert CodexUsage.project(cache, @key, :subscription, 103) ==
             projection_after_accept

    equal_sparse =
      CodexUsage.normalize_sparse(%{
        "rateLimits" => %{
          "primary" => %{
            "usedPercent" => 28,
            "windowDurationMins" => 300,
            "resetsAt" => nil
          }
        }
      })

    CodexUsage.adapter_event(cache, @key, adapter, {:sparse, equal_sparse, 104})
    state_after_sparse = barrier(cache)

    assert state_after_sparse.sequence == state_after_full_replay.sequence

    assert entry_state(state_after_sparse, @key).accepted.mutation_sequence ==
             entry_state(state_after_accept, @key).accepted.mutation_sequence

    assert CodexUsage.project(cache, @key, :subscription, 105) ==
             projection_after_accept
  end

  test "all atomic event permutations expose only complete generations", %{cache: cache} do
    orderings = permutations([:full, :sparse, :binding, :read])
    assert length(orderings) == 24

    for {ordering, index} <- Enum.with_index(orderings) do
      host = "atomic-#{index}"
      key = {:codex, "shared", host}
      adapter = self()

      CodexUsage.adapter_ready(cache, key, adapter, :subscription)
      assert_receive {:usage_read, ^adapter, claim}
      initial_generation = entry_state(barrier(cache), key).generation

      sparse =
        CodexUsage.normalize_sparse(%{
          "rateLimits" => %{"primary" => %{"usedPercent" => 40}}
        })

      {observed, _state} =
        Enum.reduce(ordering, {nil, barrier(cache)}, fn
          :full, {observed, _state} ->
            accepted = CodexUsage.map_read_result({:ok, full_snapshot(30, nil)}, 100)
            CodexUsage.adapter_event(cache, key, adapter, {:full, claim, accepted})
            {observed, barrier(cache)}

          :sparse, {observed, _state} ->
            CodexUsage.adapter_event(cache, key, adapter, {:sparse, sparse, 101})
            {observed, barrier(cache)}

          :binding, {observed, _state} ->
            assert :ok = CodexUsage.binding_changed(cache, :openai, host)
            {observed, barrier(cache)}

          :read, {_observed, state} ->
            {CodexUsage.project(cache, key, :subscription, 102), state}
        end)

      assert_complete_projection(observed, initial_generation)

      assert %{generation: final_generation, usage: final_usage} =
               CodexUsage.project(cache, key, :subscription, 103)

      refute final_generation == initial_generation

      assert final_usage == %{
               freshness: "unavailable",
               windows: [],
               unavailableReason: "account_binding_unavailable"
             }
    end
  end

  test "one adapter key shares a generation and distinct keys stay isolated", %{cache: cache} do
    shared_key = {:codex, "shared", "cache-scope-shared"}
    isolated_key = {:codex, "shared", "cache-scope-isolated"}
    shared_adapter = spawn_adapter()
    isolated_adapter = spawn_adapter()

    on_exit(fn -> Process.exit(shared_adapter, :kill) end)
    on_exit(fn -> Process.exit(isolated_adapter, :kill) end)

    CodexUsage.adapter_ready(cache, shared_key, shared_adapter, :subscription)
    assert_receive {:usage_read, ^shared_adapter, shared_claim}

    CodexUsage.adapter_ready(cache, isolated_key, isolated_adapter, :subscription)
    assert_receive {:usage_read, ^isolated_adapter, _isolated_claim}

    accepted = CodexUsage.map_read_result({:ok, full_snapshot(22, nil)}, 100)
    CodexUsage.adapter_event(cache, shared_key, shared_adapter, {:full, shared_claim, accepted})
    barrier(cache)

    first_session = CodexUsage.project(cache, shared_key, :subscription, 101)
    second_session = CodexUsage.project(cache, shared_key, :subscription, 102)

    assert first_session == second_session
    assert first_session.usage.windows == [%{label: "5h", remaining_percent: 78, reset_at: nil}]
    refute_receive {:usage_read, ^shared_adapter, _another_claim}

    assert %{generation: isolated_generation, usage: %{freshness: "loading", windows: []}} =
             CodexUsage.project(cache, isolated_key, :subscription, 103)

    refute isolated_generation == first_session.generation

    assert CodexUsage.project(cache, shared_key, :subscription, 104) == first_session
  end

  test "terminal classification and unavailable reasons follow the typed failure matrix", %{
    cache: cache
  } do
    terminal_fixtures = [
      %{"authMode" => nil, "planType" => nil},
      %{
        "_meta" => %{
          "codex" => %{"accountUpdated" => %{"authMode" => nil, "planType" => nil}}
        }
      }
    ]

    assert Enum.all?(terminal_fixtures, &(CodexHarness.classify_auth_event(&1) == :terminal))

    non_terminal_fixtures = [
      %{"authMode" => "apiKey", "planType" => "plus"},
      %{"authMode" => "chatgpt", "planType" => "plus"},
      %{"authMode" => "chatgptAuthTokens", "planType" => "plus"},
      %{
        "_meta" => %{
          "codex" => %{
            "accountUpdated" => %{"authMode" => "chatgpt", "planType" => "plus"}
          }
        }
      },
      %{"authMode" => "future-mode", "planType" => "plus"},
      %{"authMode" => nil, "planType" => "plus"},
      %{"authMode" => "chatgpt", "planType" => nil},
      %{"authMode" => nil},
      %{"planType" => nil},
      %{"authMode" => ["malformed"], "planType" => %{}},
      "malformed"
    ]

    refute Enum.any?(non_terminal_fixtures, &(CodexHarness.classify_auth_event(&1) == :terminal))

    non_terminal_key = {:codex, "shared", "non-terminal-classification"}
    non_terminal_adapter = spawn_adapter()
    on_exit(fn -> send(non_terminal_adapter, :stop) end)
    CodexUsage.adapter_ready(cache, non_terminal_key, non_terminal_adapter, :subscription)
    assert_receive {:usage_read, ^non_terminal_adapter, _claim}

    before_non_terminal = CodexUsage.project(cache, non_terminal_key, :subscription, 100)

    for fixture <- non_terminal_fixtures do
      classification = CodexHarness.classify_auth_event(fixture)

      CodexUsage.adapter_event(
        cache,
        non_terminal_key,
        non_terminal_adapter,
        {:auth, classification}
      )

      barrier(cache)

      assert CodexUsage.project(cache, non_terminal_key, :subscription, 101) ==
               before_non_terminal
    end

    terminal_key = {:codex, "shared", "terminal-classification"}
    terminal_adapter = spawn_adapter()
    on_exit(fn -> send(terminal_adapter, :stop) end)
    CodexUsage.adapter_ready(cache, terminal_key, terminal_adapter, :subscription)
    assert_receive {:usage_read, ^terminal_adapter, _claim}
    terminal_before = CodexUsage.project(cache, terminal_key, :subscription, 100).generation

    CodexUsage.adapter_event(cache, terminal_key, terminal_adapter, {:auth, :terminal})
    barrier(cache)

    assert %{generation: terminal_after, usage: terminal_usage} =
             CodexUsage.project(cache, terminal_key, :subscription, 101)

    refute terminal_after == terminal_before

    assert terminal_usage == %{
             freshness: "unavailable",
             windows: [],
             unavailableReason: "account_binding_unavailable"
           }

    provider_errors = [
      %{"code" => -32_602, "message" => "missing-auth-sentinel"},
      %{"code" => -32_602, "message" => "non-chatgpt-auth-sentinel"},
      %{"code" => -32_603, "message" => "backend-failure-sentinel"},
      %{"code" => -32_603, "message" => "empty-snapshot-sentinel"}
    ]

    for error <- provider_errors do
      assert CodexUsage.map_read_result({:error, error}, 100) ==
               {:error, :provider_unavailable}
    end

    no_baseline_results = [
      {:timeout, {:error, :timeout}},
      {:provider_unavailable, {:error, :provider_unavailable}},
      {:invalid_usage,
       CodexUsage.map_read_result(
         {:ok,
          %{
            "rateLimits" => %{
              "primary" => %{"usedPercent" => 101, "windowDurationMins" => 300}
            }
          }},
         123
       )}
    ]

    for {{reason, result}, index} <- Enum.with_index(no_baseline_results) do
      key = {:codex, "shared", "no-baseline-#{index}"}
      case_adapter = spawn_adapter()
      on_exit(fn -> send(case_adapter, :stop) end)
      CodexUsage.adapter_ready(cache, key, case_adapter, :subscription)
      assert_receive {:usage_read, ^case_adapter, claim}
      CodexUsage.adapter_event(cache, key, case_adapter, {:full, claim, result})
      barrier(cache)

      assert %{usage: usage} = CodexUsage.project(cache, key, :subscription, 124)
      assert usage.freshness == "unavailable"
      assert usage.windows == []
      assert usage.unavailableReason == Atom.to_string(reason)
      assert_receive {:usage_read, ^case_adapter, _retry_claim}
    end

    non_terminal_failures = [
      {:error, :timeout},
      {:error, :provider_unavailable},
      CodexUsage.map_read_result(
        {:ok,
         %{
           "rateLimits" => %{
             "primary" => %{"usedPercent" => 101, "windowDurationMins" => 300}
           }
         }},
        200
      )
    ]

    for {failure, index} <- Enum.with_index(non_terminal_failures) do
      key = {:codex, "shared", "stale-failure-#{index}"}
      case_adapter = spawn_adapter()
      on_exit(fn -> send(case_adapter, :stop) end)
      CodexUsage.adapter_ready(cache, key, case_adapter, :subscription)
      assert_receive {:usage_read, ^case_adapter, first_claim}

      accepted = CodexUsage.map_read_result({:ok, full_snapshot(25, 1)}, 100)
      CodexUsage.adapter_event(cache, key, case_adapter, {:full, first_claim, accepted})

      assert %{usage: %{freshness: "fresh"}} =
               CodexUsage.project(cache, key, :subscription, 999)

      assert %{usage: %{freshness: "stale", windows: retained}} =
               CodexUsage.project(cache, key, :subscription, 1_000)

      assert_receive {:usage_read, ^case_adapter, refresh_claim}
      CodexUsage.adapter_event(cache, key, case_adapter, {:full, refresh_claim, failure})
      barrier(cache)

      assert %{usage: stale_usage} = CodexUsage.project(cache, key, :subscription, 1_001)
      assert stale_usage.freshness == "stale"
      assert stale_usage.windows == retained
      refute Map.has_key?(stale_usage, :unavailableReason)
    end

    for {ordering, index} <- Enum.with_index([:failure_first, :terminal_first]) do
      key = {:codex, "shared", "terminal-race-#{index}"}
      case_adapter = spawn_adapter()
      on_exit(fn -> send(case_adapter, :stop) end)
      assert_terminal_failure_race(cache, key, case_adapter, ordering)
    end
  end

  defp full_snapshot(used_percent, resets_at) do
    %{
      "rateLimits" => %{
        "primary" => %{
          "usedPercent" => used_percent,
          "windowDurationMins" => 300,
          "resetsAt" => resets_at
        },
        "secondary" => nil
      }
    }
  end

  defp spawn_adapter do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp barrier(cache), do: :sys.get_state(cache)

  defp entry_state(state, key), do: Map.fetch!(state.entries, key)

  defp permutations([]), do: [[]]

  defp permutations(values) do
    for value <- values,
        rest <- permutations(List.delete(values, value)),
        do: [value | rest]
  end

  defp assert_complete_projection(%{generation: generation, usage: usage}, initial_generation) do
    if generation == initial_generation do
      assert usage in [
               %{freshness: "loading", windows: []},
               %{
                 freshness: "fresh",
                 fetchedAt: 100,
                 windows: [%{label: "5h", remaining_percent: 70, reset_at: nil}]
               },
               %{
                 freshness: "fresh",
                 fetchedAt: 101,
                 windows: [%{label: "5h", remaining_percent: 60, reset_at: nil}]
               }
             ]
    else
      assert usage == %{
               freshness: "unavailable",
               windows: [],
               unavailableReason: "account_binding_unavailable"
             }
    end
  end

  defp assert_terminal_failure_race(cache, key, adapter, ordering) do
    CodexUsage.adapter_ready(cache, key, adapter, :subscription)
    assert_receive {:usage_read, ^adapter, claim}

    case ordering do
      :failure_first ->
        CodexUsage.adapter_event(
          cache,
          key,
          adapter,
          {:full, claim, {:error, :provider_unavailable}}
        )

        barrier(cache)
        CodexUsage.adapter_event(cache, key, adapter, {:auth, :terminal})

      :terminal_first ->
        CodexUsage.adapter_event(cache, key, adapter, {:auth, :terminal})
        barrier(cache)

        CodexUsage.adapter_event(
          cache,
          key,
          adapter,
          {:full, claim, {:error, :provider_unavailable}}
        )
    end

    barrier(cache)

    assert %{usage: usage} = CodexUsage.project(cache, key, :subscription, 200)

    assert usage == %{
             freshness: "unavailable",
             windows: [],
             unavailableReason: "account_binding_unavailable"
           }
  end

  defp contains_term?(term, expected) when term === expected, do: true

  defp contains_term?(term, expected) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      contains_term?(key, expected) or contains_term?(value, expected)
    end)
  end

  defp contains_term?(term, expected) when is_list(term) do
    Enum.any?(term, &contains_term?(&1, expected))
  end

  defp contains_term?(term, expected) when is_tuple(term) do
    term |> Tuple.to_list() |> contains_term?(expected)
  end

  defp contains_term?(_term, _expected), do: false

  defp capture_usage_events(fun) do
    filter_id = :codex_usage_test_capture
    owner = self()

    filter = fn event, recipient ->
      if get_in(event, [:meta, :event]) == "codex_usage_capture" do
        send(recipient, {:codex_usage_log_event, event})
      end

      event
    end

    :logger.remove_primary_filter(filter_id)
    :ok = :logger.add_primary_filter(filter_id, {filter, owner})

    try do
      fun.()
      Logger.flush()
      collect_usage_events([])
    after
      :logger.remove_primary_filter(filter_id)
    end
  end

  defp collect_usage_events(events) do
    receive do
      {:codex_usage_log_event, event} -> collect_usage_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp crash_after_sanitized_capture(raw, _sentinels, _reset_seconds, fetched_at) do
    owner = self()
    name = {:global, {__MODULE__, :privacy_crash, make_ref()}}

    capture_log(fn ->
      {wrapper, monitor} =
        spawn_monitor(fn ->
          {:ok, server} =
            CodexUsage.start_link(
              name: name,
              request: fn adapter, claim -> send(owner, {:privacy_crash_read, adapter, claim}) end
            )

          send(owner, {:privacy_crash_server, server})
          Process.sleep(:infinity)
        end)

      assert_receive {:privacy_crash_server, server}
      adapter = spawn_adapter()

      CodexUsage.adapter_ready(
        server,
        {:codex, "shared", "privacy-crash"},
        adapter,
        :subscription
      )

      assert_receive {:privacy_crash_read, ^adapter, claim}

      result = CodexUsage.map_read_result({:ok, raw}, fetched_at)

      CodexUsage.adapter_event(
        server,
        {:codex, "shared", "privacy-crash"},
        adapter,
        {:full, claim, result}
      )

      barrier(server)
      GenServer.cast(server, :forced_privacy_crash)
      assert_receive {:DOWN, ^monitor, :process, ^wrapper, _reason}
      send(adapter, :stop)
      Logger.flush()
    end)
  end
end
