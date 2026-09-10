[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions
alias Tightbeam.{DB, LiveBaseLock, Schema}
alias Exqlite.Sqlite3
File.mkdir_p!(base)
path = Path.join(base, "state.db")
{:ok, seed} = Sqlite3.open(path)

try do
  extension = if match?({:unix, :darwin}, :os.type()), do: ".dylib", else: ".so"
  :ok = Sqlite3.enable_load_extension(seed, true)

  try do
    {:ok, stmt} =
      Sqlite3.prepare(seed, "SELECT load_extension(?1, 'sqlite3_topline_unicode_init')")

    try do
      :ok =
        Sqlite3.bind(stmt, [
          Application.app_dir(:tightbeam, "priv/topline_unicode#{extension}")
        ])

      assert {:row, [nil]} = Sqlite3.step(seed, stmt)
    after
      :ok = Sqlite3.release(seed, stmt)
    end
  after
    :ok = Sqlite3.enable_load_extension(seed, false)
  end

  sql = File.read!("test/fixtures/r1_o2_v1.sql")

  assert Base.encode16(:crypto.hash(:sha256, sql), case: :lower) ==
           "065102fc0394262f6a7f3e71f0a8bc021fe02833875e840739c743f6837797bc"

  :ok = Sqlite3.execute(seed, sql)

  :ok =
    Sqlite3.execute(seed, """
        ALTER TABLE assignments ADD COLUMN reminderState TEXT NULL;
        ALTER TABLE condition_facts ADD COLUMN payload TEXT NULL;
        UPDATE schema_stamp SET shape='row-driven-r1-v1-019';
        CREATE TABLE IF NOT EXISTS assignment_reopenings (
        id                   INTEGER PRIMARY KEY AUTOINCREMENT,
        assignmentId         TEXT    NOT NULL REFERENCES assignments(id),
        ts                   INTEGER NOT NULL,
        reopenedByUser       TEXT    NULL REFERENCES users(userId),
        reopenedBySession    TEXT    NULL REFERENCES sessions(sessionKey),
        reason               TEXT    NOT NULL
        CHECK(length(trim(reason)) BETWEEN 1 AND 2000),
        priorOutcome         TEXT    NOT NULL
        CHECK(priorOutcome IN ('completed', 'surrendered', 'revoked')),
        priorClosedAt        INTEGER NOT NULL,
        priorClosedByUser    TEXT    NULL,
        priorClosedBySession TEXT    NULL,
        priorClosingAttestId TEXT    NULL REFERENCES attests(id),
        CHECK((reopenedByUser IS NOT NULL) != (reopenedBySession IS NOT NULL))
        );
        CREATE INDEX IF NOT EXISTS assignment_reopenings_assignment
        ON assignment_reopenings (assignmentId, id);
        INSERT INTO users(userId,createdAt) VALUES ('owner',1);
        INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
          VALUES ('holder','holder','owner','user:owner','coder','fixture','fixture_provider','fixture-model',1,1);
        INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,state,outcome,closedAt,closedByUser,closedBySession,reminderState)
          VALUES ('initial','initial','holder','owner',1,'closed','revoked',700,'owner',NULL,NULL),
                 ('reopened','reopened','holder','owner',1,'closed','revoked',700,NULL,'holder','{ "phase": "pending" }'),
                 ('open','open','holder','owner',1,'open',NULL,NULL,NULL,NULL,'');
        INSERT INTO assignment_reopenings(assignmentId,ts,reopenedByUser,reason,priorOutcome,priorClosedAt,priorClosedByUser)
          VALUES ('reopened',700,'owner','again','revoked',700,'owner');
    """)
after
  :ok = Sqlite3.close(seed)
end

manifest = payload |> Path.join("build-manifest.json") |> File.read!() |> JSON.decode!()

transition =
  JSON.encode!(%{
    "base" => base,
    "source" => "unmarked",
    "target" => manifest["buildIdentity"],
    "expectedSchema" => "row-driven-r1-v1-019"
  })

{:ok, db} =
  DB.start_link(path: path, name: nil, guard_inputs: [lock_dir: locks, transition: transition])

rows = fn db, sql ->
  {:ok, result} = DB.query(db, sql)
  result
end

try do
  before =
    rows.(
      db,
      "SELECT id,state,outcome,closedAt,closedByUser,closedBySession,reminderState FROM assignments ORDER BY id"
    )

  audit =
    rows.(
      db,
      "SELECT id,assignmentId,ts,reason,priorOutcome,priorClosedAt,priorClosedByUser FROM assignment_reopenings ORDER BY id"
    )

  :ok = Schema.ensure_all(db)
  :ok = DB.assert_base_admitted!(db, base)
  marker = File.read!(Path.join(base, "build-owner.json"))
  provenance = rows.(db, "SELECT * FROM assignment_revocations ORDER BY id")
  assert length(provenance) == 2
  generations = rows.(db, "SELECT * FROM assignment_revocation_generations ORDER BY revocationId")
  :ok = GenServer.stop(db)

  lock_path =
    Path.join(locks, Base.encode16(:crypto.hash(:sha256, base), case: :lower) <> ".lock")

  await = fn recur, remaining ->
    case LiveBaseLock.acquire(lock_path) do
      {:ok, lock} ->
        :ok = LiveBaseLock.release(lock)

      {:error, :lock_busy} when remaining > 0 ->
        Process.sleep(10)
        recur.(recur, remaining - 1)

      other ->
        raise "lock release failed: #{inspect(other)}"
    end
  end

  await.(await, 100)
  {:ok, reopened} = DB.start_link(path: path, name: nil, guard_inputs: [lock_dir: locks])

  try do
    :ok = Schema.ensure_all(reopened)
    :ok = DB.assert_base_admitted!(reopened, base)

    assert rows.(
             reopened,
             "SELECT id,state,outcome,closedAt,closedByUser,closedBySession,reminderState FROM assignments ORDER BY id"
           ) == before

    assert rows.(
             reopened,
             "SELECT id,assignmentId,ts,reason,priorOutcome,priorClosedAt,priorClosedByUser FROM assignment_reopenings ORDER BY id"
           ) == audit

    assert rows.(reopened, "SELECT * FROM assignment_revocations ORDER BY id") == provenance

    assert rows.(
             reopened,
             "SELECT * FROM assignment_revocation_generations ORDER BY revocationId"
           ) == generations

    assert rows.(reopened, "SELECT priorClosedByProcess FROM assignment_reopenings") == [[nil]]
    assert rows.(reopened, "SELECT shape FROM schema_stamp") == [["firehose-r1-v1-019"]]
    assert rows.(reopened, "PRAGMA foreign_key_check") == []
    assert File.read!(Path.join(base, "build-owner.json")) == marker

    assert {:error, %DB.Error{}} =
             DB.query(reopened, "UPDATE assignment_revocations SET reason='invented'")
  after
    GenServer.stop(reopened)
  end

  await.(await, 100)
  IO.puts("guarded-revocation-restart: ok")
after
  if Process.alive?(db), do: GenServer.stop(db)
end
