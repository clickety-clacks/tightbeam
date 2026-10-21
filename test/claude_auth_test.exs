defmodule Tightbeam.ClaudeAuthTest do
  use ExUnit.Case, async: true

  alias Tightbeam.{ClaudeAuth, DB}

  defmodule ParkReceiver do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call({:tightbeam_command, command}, _from, owner) do
      send(owner, {:park, command.decision_id, command.adapter_keys})
      {:reply, :ok, owner}
    end
  end

  setup do
    db = :"claude_auth_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: db, start: {DB, :start_link, [[path: ":memory:", name: db]]}})
    :ok = ClaudeAuth.ensure_schema(db)
    %{db: db, host: "gibson"}
  end

  test "T1 fresh-none-live", c do
    a = ClaudeAuth.trigger(c.db, c.host, "local-none", 1)
    assert a.started?
    assert ClaudeAuth.admission(c.db, c.host, 1) == :held
    assert {:ok, epoch} = ClaudeAuth.fence_acquired(c.db, a.attempt_id, a.instance_id)
    assert is_binary(epoch)
    assert :ok = ClaudeAuth.finish(c.db, a.attempt_id, :success, "http-2xx", 2)
    assert ClaudeAuth.admission(c.db, c.host) == {:eligible, a.instance_id}

    assert q(c.db, "SELECT class,state,resolution FROM claude_auth_incidents") ==
             [["unconfirmed", "resolved", "provider-accepted"]]

    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_decisions") == [[0]]
  end

  test "T2 aged-repeated-none-live", c do
    first = successful_attempt(c, 1)
    second = successful_attempt(c, 50_000)
    refute first.epoch == second.epoch
    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_attempts") == [[2]]
  end

  test "T3 none-unknown", c do
    for reason <-
          ~w(drain-failure reconciliation-failure timeout transport malformed http-403 http-408 http-429 http-500) do
      a = ClaudeAuth.trigger(c.db, c.host, "local-none")
      assert :ok = ClaudeAuth.finish(c.db, a.attempt_id, :unknown, reason)
      assert ClaudeAuth.admission(c.db, c.host) == {:eligible, a.instance_id}
    end

    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_decisions") == [[0]]
    assert q(c.db, "SELECT DISTINCT state FROM claude_auth_incidents") == [["open"]]
  end

  test "T4 burst-single-flight", c do
    attempts = for _ <- 1..3, do: ClaudeAuth.trigger(c.db, c.host, "local-none", 10)
    assert attempts |> Enum.map(& &1.attempt_id) |> Enum.uniq() |> length() == 1
    assert Enum.count(attempts, & &1.started?) == 1
    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_observations") == [[3]]
    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_attempts") == [[1]]
  end

  test "T5 repeated-after-unknown", c do
    a = ClaudeAuth.trigger(c.db, c.host, "local-none", 1)
    assert :ok = ClaudeAuth.finish(c.db, a.attempt_id, :unknown, "timeout", 2)
    b = ClaudeAuth.trigger(c.db, c.host, "local-none", 3)
    assert b.attempt_id != a.attempt_id
    assert {:ok, _} = ClaudeAuth.fence_acquired(c.db, b.attempt_id, b.instance_id)
    assert :ok = ClaudeAuth.finish(c.db, b.attempt_id, :success, nil, 4)
  end

  test "T6 fenced-current-401", c do
    a = ClaudeAuth.trigger(c.db, c.host, "local-none", 1)
    {:ok, epoch} = ClaudeAuth.fence_acquired(c.db, a.attempt_id, a.instance_id)

    assert :stale =
             ClaudeAuth.accept_terminal(c.db, a.attempt_id, a.instance_id, epoch, false, 2)

    decision =
      ClaudeAuth.accept_terminal(c.db, a.attempt_id, a.instance_id, epoch, true, 3)

    assert is_binary(decision)
    assert ClaudeAuth.admission(c.db, c.host) == :terminal

    assert q(
             c.db,
             "SELECT state,resultClass FROM claude_auth_attempts WHERE id='#{a.attempt_id}'"
           ) == [["converted_terminal", "rejected-401"]]

    assert q(c.db, "SELECT class,state,decisionId FROM claude_auth_incidents ORDER BY class") == [
             ["auth-dead", "open", decision],
             ["unconfirmed", "resolved", nil]
           ]

    assert q(c.db, "SELECT epochId FROM claude_auth_decisions") == [[epoch]]
  end

  test "T7 duplicate-401", c do
    {a, epoch, decision} = terminal_attempt(c)
    assert :stale = ClaudeAuth.accept_terminal(c.db, a.attempt_id, a.instance_id, epoch, true)
    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_decisions") == [[1]]
    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_incidents WHERE class='auth-dead'") == [[1]]
    assert is_binary(decision)
  end

  test "T8 onboarding-race", c do
    a = ClaudeAuth.trigger(c.db, c.host, "local-none", 1)
    replacement = ClaudeAuth.activate(c.db, c.host, 2)
    assert replacement != a.instance_id
    assert :stale = ClaudeAuth.fence_acquired(c.db, a.attempt_id, a.instance_id)
    assert ClaudeAuth.admission(c.db, c.host) == {:eligible, replacement}
  end

  test "T9 success-race", c do
    a = ClaudeAuth.trigger(c.db, c.host, "local-none", 1)
    assert :ok = ClaudeAuth.observe_success(c.db, c.host, a.instance_id, 2)
    assert ClaudeAuth.admission(c.db, c.host) == {:eligible, a.instance_id}

    assert q(c.db, "SELECT state,resultClass FROM claude_auth_attempts") == [
             ["stale", "normal-turn-success"]
           ]

    assert q(c.db, "SELECT source,resultClass FROM claude_auth_observations ORDER BY observedAt") ==
             [
               ["local-none", "epoch-unproved"],
               ["normal-turn", "service-observed"]
             ]
  end

  test "T10 spontaneous-close", c do
    a = ClaudeAuth.trigger(c.db, c.host, "local-none", 1)
    assert :ok = ClaudeAuth.finish(c.db, a.attempt_id, :unknown, "adapter-closed", 2)
    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_incidents WHERE class='auth-dead'") == [[0]]
  end

  test "T11 fence-park-order", c do
    {_a, _epoch, decision} = terminal_attempt(c)
    assert :ok = ClaudeAuth.own_park(c.db, decision, 4)
    assert :ok = ClaudeAuth.complete_park(c.db, decision, 5)

    assert q(c.db, "SELECT state,ownedAt,completedAt FROM claude_auth_parks") == [
             ["complete", 4, 5]
           ]

    assert q(c.db, "SELECT projectionState FROM claude_auth_decisions") == [["complete"]]
  end

  test "T12 restart-unconfirmed", c do
    a = ClaudeAuth.trigger(c.db, c.host, "local-none", 1)
    assert :ok = ClaudeAuth.finish(c.db, a.attempt_id, :unknown, "timeout", 2)
    assert ClaudeAuth.admission(c.db, c.host) == {:eligible, a.instance_id}
    assert q(c.db, "SELECT state FROM claude_auth_incidents") == [["open"]]
  end

  test "T13 restart-park-pending", c do
    {_a, _epoch, decision} = terminal_attempt(c)
    assert :ok = ClaudeAuth.own_park(c.db, decision)
    assert :ok = ClaudeAuth.own_park(c.db, decision)
    assert :ok = ClaudeAuth.complete_park(c.db, decision)
    assert :ok = ClaudeAuth.complete_park(c.db, decision)
    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_parks") == [[1]]
  end

  test "T14 replacement-recovery", c do
    {_a, _epoch, decision} = terminal_attempt(c)
    replacement = ClaudeAuth.activate(c.db, c.host, 10)
    assert ClaudeAuth.admission(c.db, c.host) == {:eligible, replacement}
    refute ClaudeAuth.current_decision?(c.db, decision)
    assert ClaudeAuth.pending_decisions(c.db, c.host) == []

    assert q(c.db, "SELECT state,resolution FROM claude_auth_incidents ORDER BY class") == [
             ["resolved", "credential-replaced"],
             ["resolved", "promoted"]
           ]
  end

  test "T15 redaction", c do
    sentinel = "SECRET-SENTINEL-DO-NOT-STORE"
    a = ClaudeAuth.trigger(c.db, c.host, "unfenced-401", 1)
    assert :ok = ClaudeAuth.finish(c.db, a.attempt_id, :unknown, %{raw: sentinel}, 2)

    rows =
      q(
        c.db,
        "SELECT reason FROM claude_auth_attempts UNION ALL SELECT reason FROM claude_auth_observations"
      )

    refute inspect(rows) =~ sentinel
    assert q(c.db, "SELECT id FROM claude_auth_instances") != [[sentinel]]
  end

  test "T16 scope-parity" do
    assert Tightbeam.Harness.Claude.classify_auth_event(%{"authStatus" => %{"kind" => "none"}}) ==
             :unconfirmed

    assert Tightbeam.Harness.Codex.classify_auth_event(%{"authMode" => nil, "planType" => nil}) ==
             :terminal
  end

  test "T17 direct-unfenced-401", c do
    a = ClaudeAuth.trigger(c.db, c.host, "unfenced-401", 1)
    assert ClaudeAuth.admission(c.db, c.host, 1) == :held
    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_decisions") == [[0]]

    assert q(c.db, "SELECT source,resultClass FROM claude_auth_observations") == [
             ["unfenced-401", "epoch-unproved"]
           ]

    assert a.started?
  end

  test "T18 self-rotation-race", c do
    a = ClaudeAuth.trigger(c.db, c.host, "unfenced-401", 1)
    assert {:ok, epoch} = ClaudeAuth.fence_acquired(c.db, a.attempt_id, a.instance_id)
    assert :ok = ClaudeAuth.finish(c.db, a.attempt_id, :success, "http-2xx", 2)
    assert is_binary(epoch)
    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_decisions") == [[0]]
  end

  test "T19 crash-after-terminal-decision", c do
    {_a, _epoch, decision} = terminal_attempt(c)
    assert ClaudeAuth.admission(c.db, c.host) == :terminal

    assert ClaudeAuth.pending_decisions(c.db, c.host) == [
             %{id: decision, step: "incident", error: nil}
           ]
  end

  test "T20 crash-before-park-ownership", c do
    {_a, _epoch, decision} = terminal_attempt(c)
    assert :ok = ClaudeAuth.advance_decision(c.db, decision, "park_ownership")
    assert :ok = ClaudeAuth.own_park(c.db, decision)
    assert :ok = ClaudeAuth.own_park(c.db, decision)
    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_parks") == [[1]]
    assert ClaudeAuth.admission(c.db, c.host) == :terminal
  end

  test "T21 crash-during-fence", c do
    a = ClaudeAuth.trigger(c.db, c.host, "local-none", 1)
    assert {:ok, _epoch} = ClaudeAuth.fence_acquired(c.db, a.attempt_id, a.instance_id)
    assert [fresh] = ClaudeAuth.interrupted_attempts(c.db, c.host, 2)
    refute fresh == a.attempt_id
    assert ClaudeAuth.admission(c.db, c.host, 2) == :held

    assert q(c.db, "SELECT state,resultClass FROM claude_auth_attempts ORDER BY triggerAt,id")
           |> List.flatten()
           |> Enum.member?("interrupted")
  end

  test "an admission hold expires from its durable deadline even if its worker vanished", c do
    attempt = ClaudeAuth.trigger(c.db, c.host, "local-none", 1)
    assert ClaudeAuth.admission(c.db, c.host, 10_000) == :held
    assert ClaudeAuth.admission(c.db, c.host, 10_001) == {:eligible, attempt.instance_id}

    assert q(c.db, "SELECT state,resultClass,reason FROM claude_auth_attempts") == [
             ["unknown", "unknown", "confirmation-deadline"]
           ]
  end

  test "T22 crash-after-uncommitted-401", c do
    old = ClaudeAuth.trigger(c.db, c.host, "local-none", 1)
    assert {:ok, old_epoch} = ClaudeAuth.fence_acquired(c.db, old.attempt_id, old.instance_id)
    assert [fresh_id] = ClaudeAuth.interrupted_attempts(c.db, c.host, 2)

    assert :stale =
             ClaudeAuth.accept_terminal(c.db, old.attempt_id, old.instance_id, old_epoch, true, 3)

    assert {:ok, fresh_epoch} = ClaudeAuth.fence_acquired(c.db, fresh_id, old.instance_id)
    decision = ClaudeAuth.accept_terminal(c.db, fresh_id, old.instance_id, fresh_epoch, true, 4)
    assert is_binary(decision)
    refute fresh_epoch == old_epoch
    assert q(c.db, "SELECT COUNT(*) FROM claude_auth_decisions") == [[1]]
  end

  test "credential owner runs one fenced confirmation and one decision-keyed park" do
    db = :"claude_auth_owner_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: db,
      start: {DB, :start_link, [[path: ":memory:", name: db]]}
    })

    :ok = Tightbeam.Schema.ensure_all(db)

    base = Path.join(System.tmp_dir!(), "tb-claude-auth-owner-#{System.unique_integer()}")
    File.mkdir_p!(Path.join([base, "auth", "claude", ".tightbeam"]))
    File.write!(Path.join([base, "auth", "claude", ".credentials.json"]), "synthetic\n")

    File.write!(
      Path.join([base, "auth", "claude", ".tightbeam", "credential.json"]),
      JSON.encode!(%{
        "provider" => "anthropic",
        "kind" => "subscription",
        "onboarded" => true,
        "terminal" => false,
        "last_health" => "onboarded"
      })
    )

    on_exit(fn -> File.rm_rf!(base) end)
    owner = self()
    {:ok, park} = ParkReceiver.start_link(owner)

    {:ok, credentials} =
      Tightbeam.Credentials.start_link(
        name: nil,
        db: db,
        base_dir: base,
        machine: "owner-host",
        acquire_confirmation_fence: fn :anthropic, _attempt_id, _timeout ->
          send(owner, :fence_acquired)
          {:ok, :synthetic_fence}
        end,
        confirm_subscription: fn :anthropic, epoch, :synthetic_fence, _timeout ->
          send(owner, {:provider_request, epoch})
          :rejected
        end,
        confirmation_fence_live: fn :anthropic -> true end,
        park_edge: Tightbeam.CommandEdge.request_to(park),
        park_targets: %{anthropic: [{:claude, "shared", "owner-host"}]}
      )

    assert :ok = Tightbeam.Credentials.observe_auth(:local_none, %{}, credentials)
    assert_receive first
    assert_receive second
    assert_receive third

    assert first == :fence_acquired
    assert {:provider_request, epoch} = second
    assert {:park, decision, [{:claude, "shared", "owner-host"}]} = third
    assert is_binary(epoch)
    assert is_binary(decision)

    eventually(fn ->
      assert q(db, "SELECT state FROM claude_auth_parks WHERE decisionId='#{decision}'") == [
               ["complete"]
             ]
    end)

    {:ok, metadata} =
      Path.join([base, "auth", "claude", ".tightbeam", "credential.json"])
      |> File.read!()
      |> JSON.decode()

    assert metadata["terminal"]
    assert metadata["last_health"] == "revoked"
    refute metadata["park_pending"]
    refute_receive {:park, ^decision, _keys}, 50
  end

  test "credential owner restart resumes a current terminal decision exactly once" do
    db = :"claude_auth_restart_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!(%{id: db, start: {DB, :start_link, [[path: ":memory:", name: db]]}})
    :ok = Tightbeam.Schema.ensure_all(db)
    host = "restart-host"
    {_attempt, _epoch, decision} = terminal_attempt(%{db: db, host: host})
    base = credential_base("restart-current")
    owner = self()
    {:ok, park} = ParkReceiver.start_link(owner)

    {:ok, credentials} =
      Tightbeam.Credentials.start_link(
        name: nil,
        db: db,
        base_dir: base,
        machine: host,
        park_edge: Tightbeam.CommandEdge.request_to(park),
        park_targets: %{anthropic: [{:claude, "shared", host}]}
      )

    assert_receive {:park, ^decision, [{:claude, "shared", ^host}]}

    eventually(fn ->
      assert q(db, "SELECT projectionState FROM claude_auth_decisions WHERE id='#{decision}'") ==
               [
                 ["complete"]
               ]
    end)

    assert Process.alive?(credentials)
    refute_receive {:park, ^decision, _keys}, 50
  end

  test "restart and direct recovery ignore a superseded instance decision" do
    db = :"claude_auth_stale_restart_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!(%{id: db, start: {DB, :start_link, [[path: ":memory:", name: db]]}})
    :ok = Tightbeam.Schema.ensure_all(db)
    host = "replacement-host"
    {_attempt, _epoch, decision} = terminal_attempt(%{db: db, host: host})
    replacement = ClaudeAuth.activate(db, host, 10)
    base = credential_base("restart-stale")
    owner = self()
    {:ok, park} = ParkReceiver.start_link(owner)

    {:ok, credentials} =
      Tightbeam.Credentials.start_link(
        name: nil,
        db: db,
        base_dir: base,
        machine: host,
        park_edge: Tightbeam.CommandEdge.request_to(park),
        park_targets: %{anthropic: [{:claude, "shared", host}]}
      )

    send(credentials, {:recover_terminal, decision})
    refute_receive {:park, ^decision, _keys}, 100
    assert ClaudeAuth.admission(db, host) == {:eligible, replacement}

    assert {:ok, metadata} =
             base
             |> Path.join("auth/claude/.tightbeam/credential.json")
             |> File.read!()
             |> JSON.decode()

    refute metadata["terminal"]
    refute metadata["park_pending"]
  end

  test "a crashed confirmation worker releases deferred onboarding as unknown" do
    db = :"claude_auth_crash_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!(%{id: db, start: {DB, :start_link, [[path: ":memory:", name: db]]}})
    :ok = Tightbeam.Schema.ensure_all(db)
    base = credential_base("worker-crash")
    owner = self()

    {:ok, credentials} =
      Tightbeam.Credentials.start_link(
        name: nil,
        db: db,
        base_dir: base,
        staging_base_dir: base,
        machine: "crash-host",
        acquire_confirmation_fence: fn :anthropic, _attempt, _timeout ->
          send(owner, {:confirmation_worker, self()})

          receive do
            :crash -> :invalid_fence_result
          end
        end
      )

    assert :ok = Tightbeam.Credentials.observe_auth(:local_none, %{}, credentials)
    assert_receive {:confirmation_worker, worker}

    onboarding =
      Task.async(fn -> Tightbeam.Credentials.begin_onboard(:anthropic, credentials) end)

    assert Task.yield(onboarding, 20) == nil
    send(worker, :crash)

    assert {:ok, staging, lease} = Task.await(onboarding, 1_000)
    assert is_binary(staging)
    assert is_binary(lease)

    assert q(db, "SELECT state,resultClass FROM claude_auth_attempts") == [
             ["unknown", "unknown"]
           ]

    assert match?({:eligible, _}, ClaudeAuth.admission(db, "crash-host"))
  end

  test "secret sentinel is absent from owner logs, durable rows, and metadata" do
    import ExUnit.CaptureLog

    db = :"claude_auth_sentinel_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!(%{id: db, start: {DB, :start_link, [[path: ":memory:", name: db]]}})
    :ok = Tightbeam.Schema.ensure_all(db)
    base = credential_base("sentinel")
    sentinel = "SECRET-SENTINEL-NEVER-PERSIST"

    {:ok, credentials} =
      Tightbeam.Credentials.start_link(
        name: nil,
        db: db,
        base_dir: base,
        machine: "sentinel-host",
        acquire_confirmation_fence: fn :anthropic, _attempt, _timeout -> {:ok, :fence} end,
        confirm_subscription: fn :anthropic, _epoch, :fence, _timeout ->
          {:unknown, %{credential: sentinel}}
        end
      )

    log =
      capture_log(fn ->
        assert :ok =
                 Tightbeam.Credentials.observe_auth(
                   :unfenced_401,
                   %{credential: sentinel, authStatus: %{kind: "none"}},
                   credentials
                 )

        eventually(fn ->
          assert [["unknown"]] = q(db, "SELECT state FROM claude_auth_attempts")
        end)
      end)

    refute log =~ sentinel

    for table <-
          ~w(claude_auth_instances claude_auth_attempts claude_auth_observations claude_auth_incidents claude_auth_decisions claude_auth_parks) do
      {:ok, rows} = DB.query(db, "SELECT * FROM #{table}")
      refute inspect(rows) =~ sentinel
    end

    refute base
           |> Path.join("auth/claude/.tightbeam/credential.json")
           |> File.read!()
           |> String.contains?(sentinel)
  end

  test "credential metadata stays visibly unconfirmed until confirmation succeeds" do
    db = :"claude_auth_visible_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: db,
      start: {DB, :start_link, [[path: ":memory:", name: db]]}
    })

    :ok = Tightbeam.Schema.ensure_all(db)
    base = Path.join(System.tmp_dir!(), "tb-claude-auth-visible-#{System.unique_integer()}")
    File.mkdir_p!(Path.join([base, "auth", "claude", ".tightbeam"]))
    File.write!(Path.join([base, "auth", "claude", ".credentials.json"]), "synthetic\n")

    metadata_path = Path.join([base, "auth", "claude", ".tightbeam", "credential.json"])

    File.write!(
      metadata_path,
      JSON.encode!(%{
        "provider" => "anthropic",
        "kind" => "subscription",
        "onboarded" => true,
        "terminal" => false,
        "last_health" => "onboarded"
      })
    )

    on_exit(fn -> File.rm_rf!(base) end)
    test_pid = self()

    {:ok, credentials} =
      Tightbeam.Credentials.start_link(
        name: nil,
        db: db,
        base_dir: base,
        machine: "visible-host",
        acquire_confirmation_fence: fn :anthropic, _attempt_id, _timeout ->
          {:ok, :synthetic_fence}
        end,
        confirm_subscription: fn :anthropic, _epoch, :synthetic_fence, _timeout ->
          send(test_pid, {:confirmation_waiting, self()})

          receive do
            :accept -> :accepted
          end
        end
      )

    assert :ok = Tightbeam.Credentials.observe_auth(:local_none, %{}, credentials)
    assert_receive {:confirmation_waiting, confirmation}

    assert {:ok, metadata} = metadata_path |> File.read!() |> JSON.decode()
    assert metadata["last_health"] == "unconfirmed"
    assert metadata["auth_unconfirmed"]
    refute metadata["terminal"]

    assert q(db, "SELECT reason FROM claude_auth_observations") == [
             ["probe-binding unobserved source=unknown"]
           ]

    send(confirmation, :accept)

    eventually(fn ->
      assert {:ok, metadata} = metadata_path |> File.read!() |> JSON.decode()
      assert metadata["last_health"] == "service_observed"
      refute metadata["auth_unconfirmed"]
      refute metadata["terminal"]
    end)
  end

  defp successful_attempt(c, at) do
    a = ClaudeAuth.trigger(c.db, c.host, "local-none", at)
    {:ok, epoch} = ClaudeAuth.fence_acquired(c.db, a.attempt_id, a.instance_id)
    :ok = ClaudeAuth.finish(c.db, a.attempt_id, :success, nil, at + 1)
    %{attempt: a, epoch: epoch}
  end

  defp terminal_attempt(c) do
    a = ClaudeAuth.trigger(c.db, c.host, "local-none", 1)
    {:ok, epoch} = ClaudeAuth.fence_acquired(c.db, a.attempt_id, a.instance_id)
    decision = ClaudeAuth.accept_terminal(c.db, a.attempt_id, a.instance_id, epoch, true, 3)
    {a, epoch, decision}
  end

  defp q(db, sql) do
    {:ok, rows} = DB.query(db, sql)
    rows
  end

  defp credential_base(label) do
    base = Path.join(System.tmp_dir!(), "tb-claude-auth-#{label}-#{System.unique_integer()}")
    metadata = Path.join([base, "auth", "claude", ".tightbeam", "credential.json"])
    File.mkdir_p!(Path.dirname(metadata))
    File.write!(Path.join([base, "auth", "claude", ".credentials.json"]), "synthetic\n")

    File.write!(
      metadata,
      JSON.encode!(%{
        "provider" => "anthropic",
        "kind" => "subscription",
        "onboarded" => true,
        "terminal" => false,
        "last_health" => "onboarded"
      })
    )

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(base) end)
    base
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(fun, attempts - 1)
  end
end
