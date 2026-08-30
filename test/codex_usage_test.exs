defmodule Tightbeam.CodexUsageTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.CodexUsage

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
end
