defmodule Tightbeam.BootRecordIsolationTest do
  use Tightbeam.TestCase, async: false
  import ExUnit.CaptureLog
  alias Tightbeam.{AdminProjection, Archetypes, CommandExecutions, DB, Escalation, Identity,
    Ledger, Model, Org, Placement, Rails, Rules, Schema, StateResources, Wakes}

  @moduletag tmp_dir: true
  setup %{tmp_dir: tmp} do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    :ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('owner',1,1)")
    session = Org.create(db, %{session_key: "healthy", display_name: "Healthy", owner_user_id: "owner",
      origin: "user:owner", archetype: "default", harness: "claude", provider: "anthropic", model: Model.new("test-model")})
    on_exit(fn ->
      Rules.load!(Path.join(tmp, "reset"), [])
      Rails.load!(Path.join(tmp, "reset"))
    end)
    %{db: db, base: tmp, session: session}
  end

  test "boot logs an unsupported recognition without inventing its evidence", %{db: db} do
    wake = Wakes.schedule(db, %{session_key: "healthy", origin: "user:owner", prompt: "bad recognition", due_at: 0,
      condition_kind: "ready", condition_scope: "healthy"})
    {:ok, _} = DB.query(db, "UPDATE wakes SET firedBy='condition',recognitionEvidence=NULL WHERE wakeId=?1", [wake.wake_id])
    assert capture_log(fn -> assert :ok = Schema.ensure_all(db) end) =~ wake.wake_id
    assert Wakes.get(db, wake.wake_id).recognition_evidence == nil
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM users WHERE userId='owner'")
  end

  test "identity snapshot reads revisions without decoding unused overrides", %{db: db, base: base} do
    Identity.init!(base)
    revision = Identity.live_revision!(base)
    {:ok, _} = DB.query(db, "UPDATE sessions SET overrides='{',identityRevision=?1 WHERE sessionKey='healthy'", [revision])
    assert %{"sessionRevisions" => %{"healthy" => ^revision}} = StateResources.identity_snapshot(db, base)
    assert :ok = AdminProjection.bootstrap_served(db, base)
  end

  test "orphan toolchain rows leave healthy host placement available", %{db: db, base: base} do
    :ok = DB.execute(db, "INSERT INTO host_toolchain_dirs VALUES('orphan-host',0,'/missing','user:owner',1)")
    assert capture_log(fn ->
      hosts = Placement.hosts(base, db)
      assert Map.has_key?(hosts, Placement.local_host_name())
      refute Map.has_key?(hosts, "orphan-host")
    end) =~ "orphan-host"
  end

  test "malformed command JSON does not stop another execution from reconciling", %{db: db, base: base} do
    attrs = %{holder_session_key: "healthy", assignment_id: "test-assignment", turn_intent: "exact command",
      host: "test-host", cwd: base, command: ["/bin/true"], cause: "test", principal: "user:owner", receipt_root: base}
    bad = CommandExecutions.prepare(db, Map.put(attrs, :idempotency_key, "bad"))
    good = CommandExecutions.prepare(db, Map.put(attrs, :idempotency_key, "good"))
    {:ok, _} = DB.query(db, "UPDATE command_executions SET commandJson='{' WHERE executionId=?1", [bad.execution_id])
    CommandExecutions.mark_not_started(db, good.execution_id, "explicit no-start evidence")
    assert capture_log(fn -> assert :ok = CommandExecutions.reconcile(db) end) =~ bad.execution_id
    assert CommandExecutions.get!(db, good.execution_id).state == "not_started"
    assert {:ok, [["{"]]} = DB.query(db, "SELECT commandJson FROM command_executions WHERE executionId=?1", [bad.execution_id])
  end

  test "a contradictory running turn does not roll back another turn's recovery", %{db: db} do
    {:ok, bad} = Ledger.enqueue(db, %{session_key: "healthy", message_id: "bad-turn", origin: "user:owner", prompt: "bad"})
    {:ok, claimed} = Ledger.claim_next(db, "healthy", "worker")
    :ok = Ledger.finish(db, bad, "delivered", nil, owner_lease: claimed.owner_lease)
    {:ok, _} = DB.query(db, "UPDATE turns SET status='running' WHERE seq=?1", [bad])
    {:ok, good} = Ledger.enqueue(db, %{session_key: "healthy", message_id: "good-turn", origin: "user:owner", prompt: "good"})
    {:ok, _} = DB.query(db, "UPDATE turns SET status='running' WHERE seq=?1", [good])
    assert capture_log(fn -> assert [good] == Ledger.recover_running(db) end) =~ "turn #{bad}"
    assert {:ok, [["running"], ["failed_unknown"]]} = DB.query(db, "SELECT status FROM turns WHERE seq IN (?1,?2) ORDER BY seq", [bad, good])
  end

  test "invalid archetypes and fragment dependencies leave a healthy identity loaded", %{base: base} do
    dir = Path.join(base, "identity/archetypes")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "bad.toml"), "name = [")
    File.write!(Path.join(dir, "missing.toml"), "name='missing'\n[guidance]\ntext='#include \"absent.md\"'")
    File.write!(Path.join(dir, "healthy.toml"), "name='healthy'\nskills=[]")
    log = capture_log(fn ->
      loaded = Archetypes.load!(base)
      assert loaded["healthy"]
      refute loaded["bad"]
      refute loaded["missing"]
    end)
    assert log =~ "bad.toml"
    assert log =~ "missing"
  end

  test "broken rule scripts keep their verb closed while unrelated calls remain usable", %{db: db, base: base} do
    dir = Path.join(base, "identity/rules")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "broken.toml"), """
    [[rule]]
    name = "missing-check"
    verb = "post"
    text = "Check must run"
    [rule.check]
    script = "absent.sh"
    """)
    assert capture_log(fn -> Rules.load!(base, ["post", "status"]) end) =~ "broken.toml"
    assert {:deny, %{code: "rule_unavailable"}} = Rules.evaluate(db, %{verb: "post", params: %{}, origin: "user:owner"})
    assert :ok = Rules.evaluate(db, %{verb: "status", params: %{}, origin: "user:owner"})
  end

  test "missing upstream ref leaves the published identity readable", %{base: base} do
    Identity.init!(base)
    revision = Identity.live_revision!(base)
    {_, 0} = System.cmd("git", ["branch", "-D", "tightbeam/upstream"], cd: Path.join(base, "identity"))
    assert capture_log(fn -> assert :noop = Identity.init!(base) end) =~ "tightbeam/upstream"
    assert Identity.live_revision!(base) == revision
  end

  test "broken installed bundle metadata records its own projection fault", %{db: db, base: base} do
    Identity.init!(base)
    dir = Path.join(base, "identity")
    File.mkdir_p!(Path.join(dir, "kungfu/broken"))
    File.write!(Path.join(dir, "kungfu/broken/manifest.toml"), "root_archetype='broken'")
    {_, 0} = System.cmd("git", ["add", "."], cd: dir)
    {_, 0} = System.cmd("git", ["commit", "-m", "Add malformed metadata"], cd: dir)
    {_, 0} = System.cmd("git", ["branch", "-f", "tightbeam/live", "HEAD"], cd: dir)
    assert capture_log(fn -> assert :ok = AdminProjection.bootstrap_served(db, base) end) =~ "broken"
    assert {:ok, [["broken"]]} = DB.query(db, "SELECT primaryKey FROM admin_projection_faults WHERE resource='kungfu'")
    assert StateResources.query_identity(db, "served")
  end

  test "missing liveness epoch does not stop schema admission or fabricate activation", %{db: db} do
    :ok = DB.execute(db, "DELETE FROM supervision_liveness_epoch")
    assert capture_log(fn -> assert :ok = Schema.ensure_all(db) end) =~ "supervision_liveness_epoch row 0"
    assert {:ok, []} = DB.query(db, "SELECT * FROM supervision_liveness_epoch")
  end

  test "missing cancellation marker preserves evidence and admits unrelated schema", %{db: db} do
    :ok = DB.execute(db, "DELETE FROM supervision_receipt_cancellation_epoch")
    assert capture_log(fn -> assert :ok = Schema.ensure_all(db) end) =~ "supervision_receipt_cancellation_epoch row 0"
    assert {:ok, []} = DB.query(db, "SELECT * FROM supervision_receipt_cancellation_epoch")
  end

  test "unknown decision epoch stays unavailable while other schema work completes", %{db: db} do
    :ok = DB.execute(db, "UPDATE decision_request_terminal_epoch SET schemaVersion='unknown'")
    assert capture_log(fn -> assert :ok = Schema.ensure_all(db) end) =~ "decision_request_terminal_epoch row 0"
    assert {:ok, [["unknown"]]} = DB.query(db, "SELECT schemaVersion FROM decision_request_terminal_epoch")
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM users WHERE userId='owner'")
  end
end
