defmodule Tightbeam.SubagentMarkersTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    ConditionFacts,
    ConnRegistry,
    DB,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    Org,
    Projection,
    Roles,
    SubagentMarkers,
    Wakes
  }

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, session_key}, _from, parent) do
      send(parent, {:lane_nudged, session_key})
      {:reply, :ok, parent}
    end
  end

  setup do
    db = :"subagent_db_#{System.unique_integer([:positive])}"
    scheduler = :"subagent_scheduler_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [
          EventLog,
          Idempotency,
          Ledger,
          Projection,
          Org,
          Roles,
          ConditionFacts,
          Wakes,
          SubagentMarkers
        ],
        do: :ok = module.ensure_schema(db)

    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    start_supervised!(
      {Wakes, db: db, name: scheduler, tick_ms: 60_000, deliver: fn _wake -> :ok end}
    )

    codex = create_parent(db, "parent-codex", "codex", "openai", "sid-codex")
    claude = create_parent(db, "parent-claude", "claude", "anthropic", "sid-claude")

    %{
      db: db,
      scheduler: scheduler,
      codex: codex,
      claude: claude,
      codex_fixture: fixture("codex-acp-1.1.4.jsonc"),
      claude_fixture: fixture("claude-agent-acp-0.59.0.jsonc")
    }
  end

  test "proof 1: codex fixture produces one parent-attributed start and one semantic stop",
       ctx do
    fixture = ctx.codex_fixture
    assert fixture["version"] == Tightbeam.Harness.Codex.adapter_version()
    assert fixture["semantic"]["spawn_operation_terminal"] =~ "child thread remains"
    assert fixture["semantic"]["child_termination_terminal"] =~ "entering idle"

    start = consume(ctx, :codex, "sid-codex", fixture["live_started"])
    assert start.appended
    assert :skip = consume(ctx, :codex, "sid-codex", fixture["live_interacted"])

    completed_spawn =
      consume(ctx, :codex, "sid-codex", fixture["spawn_operation_terminal"])

    refute completed_spawn.appended
    assert completed_spawn.kind == "subagent_start"

    stop = consume(ctx, :codex, "sid-codex", fixture["patched_termination"])
    assert stop.appended
    assert stop.principal == ctx.codex.session_key
    assert stop.subagent_ref == start.subagent_ref

    interrupted = consume(ctx, :codex, "sid-codex", fixture["live_interrupted"])
    refute interrupted.appended

    assert Enum.map(SubagentMarkers.list(ctx.db), & &1.kind) == [
             "subagent_start",
             "subagent_stop"
           ]
  end

  test "proof 4: claude fixture ignores spawn completion and stops at live task settlement",
       ctx do
    fixture = ctx.claude_fixture
    assert fixture["version"] == Tightbeam.Harness.Claude.adapter_version()
    assert fixture["semantic"]["spawn_operation_terminal"] =~ "liveBackgroundTasks"
    assert fixture["semantic"]["child_termination_terminal"] =~ "settlement"

    start = consume(ctx, :claude, "sid-claude", fixture["live_agent_started"])
    assert start.appended
    assert :skip = consume(ctx, :claude, "sid-claude", fixture["spawn_operation_terminal"])

    stop = consume(ctx, :claude, "sid-claude", fixture["patched_termination"])
    assert stop.appended
    assert stop.principal == ctx.claude.session_key
    assert stop.subagent_ref == start.subagent_ref

    assert Enum.map(SubagentMarkers.list(ctx.db), & &1.kind) == [
             "subagent_start",
             "subagent_stop"
           ]
  end

  test "proof 2: parent handle resolves to canonical scope and fires by condition or fallback",
       ctx do
    start =
      consume(ctx, :codex, "sid-codex", ctx.codex_fixture["live_started"])

    condition_wake =
      register_wake(ctx, ctx.codex, "call-codex-1",
        after_ms: 60_000,
        idempotency_key: "condition"
      )

    assert Wakes.get(ctx.db, condition_wake.wake_id).condition_scope == start.subagent_ref

    consume(ctx, :codex, "sid-codex", ctx.codex_fixture["patched_termination"])

    assert %{state: "fired", fired_by: "condition"} =
             Wakes.get(ctx.db, condition_wake.wake_id)

    fallback_start =
      consume(
        ctx,
        :claude,
        "sid-claude",
        ctx.claude_fixture["live_agent_started"]
      )

    fallback_wake =
      register_wake(ctx, ctx.claude, "call-claude-1",
        after_ms: 0,
        idempotency_key: "fallback",
        nudge: false
      )

    assert Wakes.get(ctx.db, fallback_wake.wake_id).condition_scope ==
             fallback_start.subagent_ref

    :ok = Wakes.fire_due(ctx.scheduler)

    assert %{state: "fired", fired_by: "fallback"} =
             Wakes.get(ctx.db, fallback_wake.wake_id)
  end

  test "proof 2 stop-wins order returns subagent_already_stopped and inserts no wake", ctx do
    start = consume(ctx, :codex, "sid-codex", ctx.codex_fixture["live_started"])
    stop = consume(ctx, :codex, "sid-codex", ctx.codex_fixture["patched_termination"])
    assert stop.subagent_ref == start.subagent_ref

    {:ok, [[before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")

    assert %{
             code: "subagent_already_stopped",
             subagent_ref: subagent_ref
           } =
             register_wake(ctx, ctx.codex, "call-codex-1",
               after_ms: 0,
               idempotency_key: "stop-wins"
             )

    assert subagent_ref == start.subagent_ref
    {:ok, [[after_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")
    assert after_count == before_count

    :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db) == 0
  end

  test "proof 2 colliding toolCallIds stay isolated by source session", ctx do
    second =
      create_parent(ctx.db, "parent-codex-two", "codex", "openai", "sid-codex-two")

    first_start = consume(ctx, :codex, "sid-codex", ctx.codex_fixture["live_started"])

    second_start =
      consume(ctx, :codex, "sid-codex-two", ctx.codex_fixture["live_started"])

    refute first_start.subagent_ref == second_start.subagent_ref
    refute first_start.source_event_ref == second_start.source_event_ref

    wake =
      register_wake(ctx, ctx.codex, "call-codex-1",
        after_ms: 60_000,
        idempotency_key: "collision"
      )

    consume(ctx, :codex, "sid-codex-two", ctx.codex_fixture["patched_termination"])
    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"

    consume(ctx, :codex, "sid-codex", ctx.codex_fixture["patched_termination"])
    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, wake.wake_id)

    assert Enum.count(SubagentMarkers.list(ctx.db), &(&1.principal == second.session_key)) == 2
  end

  test "proof 2 public subagent fact is rejected while atomic marker fact succeeds", ctx do
    condition = Gateway.handlers(%{db: ctx.db, wake_scheduler: ctx.scheduler})["condition"]

    assert %{code: "reserved_kind"} =
             condition.(%{
               origin: "user:flynn",
               params: %{kind: "subagent_stop", scope: "forged"}
             })

    start = consume(ctx, :codex, "sid-codex", ctx.codex_fixture["live_started"])
    stop = consume(ctx, :codex, "sid-codex", ctx.codex_fixture["patched_termination"])
    assert stop.subagent_ref == start.subagent_ref

    assert %{kind: "subagent_stop", scope: scope, origin: "process:tightbeam"} =
             ConditionFacts.latest(ctx.db, "subagent_stop", start.subagent_ref)

    assert scope == start.subagent_ref
  end

  test "proof 2 load replay reconstructs START only", ctx do
    replay = ctx.codex_fixture["load_replay_completed_started"]
    start = consume(ctx, :codex, "sid-codex", replay)
    assert start.kind == "subagent_start"

    wake =
      register_wake(ctx, ctx.codex, "call-codex-replayed",
        after_ms: 60_000,
        idempotency_key: "replay"
      )

    assert Enum.map(SubagentMarkers.list(ctx.db), & &1.kind) == ["subagent_start"]
    assert ConditionFacts.latest(ctx.db, "subagent_stop", start.subagent_ref) == nil
    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"
    assert turn_count(ctx.db) == 0
  end

  test "durable consumption retries every insertion failure", ctx do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    captured =
      {:ok,
       %{
         source_event_ref: "source-event-retry",
         subagent_ref: "subagent-retry"
       }}

    consume = fn ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

      if attempt < 3 do
        raise DB.Error, message: "FOREIGN KEY constraint failed"
      else
        %{appended: true}
      end
    end

    assert {:ok, %{appended: true}} =
             SubagentMarkers.consume_captured_with_retry(captured, ctx.db, ctx.scheduler,
               attempts: 3,
               retry_delay_ms: 0,
               consume: consume
             )

    assert Agent.get(attempts, & &1) == 3
    assert EventLog.lifecycle_events(ctx.db) == []
  end

  test "synchronous event-time capture retries database failures before returning", ctx do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    capture = fn ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

      if attempt < 3 do
        raise DB.Error, message: "database unavailable"
      else
        {:ok, %{captured: true}}
      end
    end

    assert {:ok, %{captured: true}} =
             SubagentMarkers.capture_update_with_retry(
               ctx.db,
               :codex,
               "testhost",
               "sid-codex",
               ctx.codex_fixture["live_started"],
               attempts: 3,
               retry_delay_ms: 0,
               capture: capture
             )

    assert Agent.get(attempts, & &1) == 3
  end

  test "exhausted durable-consumption failure records the exact marker for redrive",
       ctx do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    captured =
      {:ok,
       %{
         kind: "subagent_stop",
         principal: "parent-codex",
         source_event_ref: "source-event-exhausted",
         subagent_ref: "subagent-exhausted",
         harness: :codex,
         at: 1_234_567,
         assignment_id: "assignment-at-event"
       }}

    consume = fn ->
      Agent.update(attempts, &(&1 + 1))
      raise DB.Error, message: "FOREIGN KEY constraint failed"
    end

    assert {:error,
            %{
              attempts: 3,
              kind: "subagent_stop",
              principal: "parent-codex",
              source_event_ref: "source-event-exhausted",
              subagent_ref: "subagent-exhausted",
              harness: :codex,
              at: 1_234_567,
              assignment_id: "assignment-at-event"
            }} =
             SubagentMarkers.consume_captured_with_retry(captured, ctx.db, ctx.scheduler,
               attempts: 3,
               consume: consume
             )

    assert Agent.get(attempts, & &1) == 3

    assert [
             %{
               kind: "subagent_event_ingestion_failed",
               subject: "source-event-exhausted",
               detail: detail
             }
           ] =
             EventLog.lifecycle_events(ctx.db)

    decoded = JSON.decode!(detail)
    assert decoded["attempts"] == 3
    assert decoded["stage"] == "consume"

    assert decoded["redrive"] == %{
             "assignment_id" => "assignment-at-event",
             "at" => 1_234_567,
             "harness" => "codex",
             "kind" => "subagent_stop",
             "principal" => "parent-codex",
             "source_event_ref" => "source-event-exhausted",
             "subagent_ref" => "subagent-exhausted"
           }
  end

  defp consume(ctx, harness, sid, update) do
    SubagentMarkers.consume_update(
      ctx.db,
      ctx.scheduler,
      harness,
      "eezo",
      sid,
      update
    )
  end

  defp register_wake(ctx, session, tool_call_id, opts) do
    handler = Gateway.handlers(%{db: ctx.db, wake_scheduler: ctx.scheduler})["wake"]

    handler.(%{
      origin: "process:parent",
      principal: {:session, session.session_key},
      session_key: session.session_key,
      params: %{
        prompt: "continue after child",
        after_ms: Keyword.fetch!(opts, :after_ms),
        condition_kind: "subagent_stop",
        condition_scope: tool_call_id,
        idempotency_key: Keyword.fetch!(opts, :idempotency_key),
        nudge: Keyword.get(opts, :nudge)
      }
    })
  end

  defp create_parent(db, key, harness, provider, sid) do
    session =
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "eezo",
        harness: harness,
        provider: provider,
        model: "fixture"
      })

    Org.append_pointer(db, key, sid, "created")
    session
  end

  defp fixture(name) do
    path = Path.join([__DIR__, "fixtures", "subagent_markers", name])

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&String.starts_with?(&1, "//"))
    |> Enum.join("\n")
    |> JSON.decode!()
  end

  defp turn_count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM turns")
    count
  end
end
