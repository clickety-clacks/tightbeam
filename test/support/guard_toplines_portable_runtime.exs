defmodule PortableToplinesFixture do
  import ExUnit.Assertions
  alias Tightbeam.{DB, Toplines}

  @tables ~w(toplines topline_work_memberships topline_concerns topline_concern_refs
    topline_events topline_idempotency topline_placement_obligations topline_schema_stamp)

  @actor_tables ~w(toplines topline_work_memberships topline_concerns topline_concern_refs
    topline_events topline_idempotency topline_placement_obligations)

  def snapshot(db) do
    {:ok, schema} = DB.query(db, "SELECT type,name,sql FROM sqlite_schema ORDER BY name")

    rows =
      for table <- @tables, into: %{} do
        {:ok, rows} = DB.query(db, "SELECT rowid,* FROM #{table} ORDER BY rowid")
        {table, rows}
      end

    {schema, rows}
  end

  def actor_tables, do: @actor_tables

  def legacy_rows(db) do
    for table <- @actor_tables, into: %{} do
      {:ok, info} = DB.query(db, "PRAGMA table_info(#{table})")
      columns = Enum.map(info, &Enum.at(&1, 1))

      query =
        if table == "topline_idempotency" and "callerUserId" in columns do
          """
          SELECT rowid, 'user', callerUserId, NULL, 'user', callerUserId,
                 operation, idempotencyKey, requestFingerprint, canonicalResponse
          FROM topline_idempotency ORDER BY rowid
          """
        else
          columns =
            if table == "topline_idempotency" do
              ~w(callerActorKind callerActorRef callerSessionKey callerIdempotencyKind
                callerIdempotencyRef operation idempotencyKey requestFingerprint canonicalResponse)
            else
              Enum.reject(columns, &String.ends_with?(&1, "ActorSessionKey"))
            end

          "SELECT rowid, #{Enum.join(columns, ", ")} FROM #{table} ORDER BY rowid"
        end

      {:ok, rows} = DB.query(db, query)
      {table, rows}
    end
  end

  def call(params, now \\ 10),
    do: %{
      principal: {:user, "synthetic"},
      params: params,
      now: now,
      verb: "test",
      origin: "test",
      session_key: nil
    }

  def populate_legacy_v5!(db) do
    :ok =
      DB.execute(db, """
      INSERT INTO users (userId,isAdmin,createdAt) VALUES ('synthetic',1,1);
      INSERT INTO work_items (id,title,ownerUserId,state,createdByUser,createdContextKnown,createdAt)
        VALUES ('wi_fixture','Work','synthetic','open','synthetic',1,1);
      INSERT INTO work_item_versions (workItemId,rowVersion) VALUES ('wi_fixture',1);
      INSERT INTO wakes (wakeId,sessionKey,origin,prompt,consumer,dueAt,state,createdAt)
        VALUES ('w_fixture','agent:main:clawline:synthetic:main','process:tightbeam',
                'Choose placement','prompt',1,'pending',1);
      INSERT INTO toplines
        (rowid,id,ownerUserId,title,state,createdActorKind,createdActorRef,createdAt,updatedAt,closedAt)
        VALUES (1,'tl_fixture','synthetic','Café','open','user','synthetic',10,10,NULL);
      INSERT INTO toplines
        (rowid,id,ownerUserId,title,state,createdActorKind,createdActorRef,createdAt,updatedAt,closedAt)
        VALUES (99,'tl_closed_fixture','synthetic','Closed','closed','user','synthetic',14,14,14);
      INSERT INTO topline_work_memberships
        (id,toplineId,workItemId,ownerUserId,linkReason,linkedActorKind,linkedActorRef,linkedAt,
         unlinkReason,unlinkedActorKind,unlinkedActorRef,unlinkedAt)
        VALUES ('tlm_fixture','tl_fixture','wi_fixture','synthetic','group','user','synthetic',11,
                NULL,NULL,NULL,NULL);
      INSERT INTO topline_concerns
        (id,toplineId,title,createdActorKind,createdActorRef,createdAt)
        VALUES ('tlc_fixture','tl_fixture','Résumé💩','user','synthetic',12);
      INSERT INTO topline_concern_refs
        (toplineId,concernId,workItemId,tagReason,taggedActorKind,taggedActorRef,taggedAt)
        VALUES ('tl_fixture','tlc_fixture','wi_fixture','tag','user','synthetic',13);
      INSERT INTO topline_events
        (toplineId,seq,kind,membershipId,concernId,actorKind,actorRef,reason,eventAt,detail)
        VALUES
          ('tl_fixture',1,'topline_created',NULL,NULL,'user','synthetic',NULL,10,'{"title":"Café"}'),
          ('tl_fixture',2,'work_linked','tlm_fixture',NULL,'user','synthetic','group',11,
           '{"workItemId":"wi_fixture","linkReason":"group"}'),
          ('tl_fixture',3,'concern_created',NULL,'tlc_fixture','user','synthetic',NULL,12,
           '{"title":"Résumé💩"}'),
          ('tl_fixture',4,'concern_work_tagged',NULL,'tlc_fixture','user','synthetic','tag',13,
           '{"workItemId":"wi_fixture","tagReason":"tag"}'),
          ('tl_closed_fixture',1,'topline_created',NULL,NULL,'user','synthetic',NULL,14,
           '{"title":"Closed"}'),
          ('tl_closed_fixture',2,'topline_closed',NULL,NULL,'user','synthetic','done',14,
           '{"fromState":"open","toState":"closed"}');
      INSERT INTO topline_idempotency
        (callerUserId,operation,idempotencyKey,requestFingerprint,canonicalResponse)
        VALUES ('synthetic','topline-create','legacy-key',
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                '{"legacy":true}'),
               ('synthetic','topline-close','close',
                'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
                '{"topline":{"id":"tl_closed_fixture","state":"closed"}}');
      INSERT INTO topline_placement_obligations
        (id,workItemId,ownerUserId,cause,causeRef,sourceCausalEventSeq,resolutionCausalEventSeq,
         historyCausalSeq,openedActorKind,openedActorRef,state,openedAt,dueAt,promptWakeId,
         resolutionActorKind,resolutionActorRef,resolutionReason,resolvedAt)
        VALUES ('tlp_fixture','wi_fixture','synthetic','created','wi_fixture',NULL,NULL,0,
                'user','synthetic','pending',1,1,'w_fixture',NULL,NULL,NULL,NULL);
      """)

    {%{id: "tl_fixture"}, %{id: "tlc_fixture"}}
  end

  def sqlite!(sqlite, path, command) do
    {output, status} =
      System.cmd(sqlite, ["-init", "/dev/null", "-bail", path, command], stderr_to_stdout: true)

    assert status == 0, output
    output
  end

  def assert_portable!(sqlite, path, target) do
    {out, status} =
      System.cmd(
        sqlite,
        [
          "-init",
          "/dev/null",
          "-readonly",
          "-bail",
          path,
          "VACUUM INTO '#{String.replace(target, "'", "''")}'"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert File.stat!(target).size > 0
    assert sqlite!(sqlite, target, "PRAGMA quick_check; PRAGMA foreign_key_check;") == "ok\n"

    assert sqlite!(
             sqlite,
             target,
             "SELECT count(*) FROM sqlite_schema WHERE sql LIKE '%tightbeam_canonical_title%' OR sql LIKE '%tightbeam_unicode_scalar_length%';"
           ) == "0\n"
  end

  def portable_rows!(sqlite, path) do
    for table <- @tables, into: %{} do
      # Compare durable values, not physical rowids reassigned by .dump.
      {output, status} =
        System.cmd(
          sqlite,
          ["-init", "/dev/null", "-bail", "-json", path, "SELECT * FROM #{table};"],
          stderr_to_stdout: true
        )

      assert status == 0, output
      {table, JSON.decode!(output) |> Enum.sort()}
    end
  end
end

[payload, base] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions
alias Tightbeam.{DB, Schema, Toplines}
alias Tightbeam.Toplines.Schema, as: TS
alias PortableToplinesFixture, as: F

# Apple's CLI can refuse a closed Exqlite WAL database before reading its
# schema (SQLITE_CANTOPEN); use the existing standard SQLite CLI on macOS.
# No extension, UDF registration or installation is part of this proof.
sqlite =
  if :os.type() == {:unix, :darwin} do
    Enum.find_value(
      ["/opt/homebrew/opt/sqlite/bin/sqlite3", "/usr/local/opt/sqlite/bin/sqlite3"],
      &System.find_executable/1
    )
  else
    System.find_executable("sqlite3")
  end

sqlite = sqlite || raise "standard bare sqlite3 CLI is required for portable schema proof"
{version, 0} = System.cmd(sqlite, ["--version"])
IO.puts("bare sqlite3: #{String.trim(version)}")
path = Path.join(base, "state.db")
db = :portable_toplines

start = fn ->
  {:ok, pid} = DB.start_link(path: path, name: db, guard_inputs: [])
  Process.unlink(pid)
  pid
end

stop = fn ->
  # Finish WAL checkpointing explicitly before the independent readonly tool.
  assert {:ok, [[0, _, _]]} = DB.query(db, "PRAGMA wal_checkpoint(TRUNCATE)")
  GenServer.stop(db)
end

start.()

try do
  :ok = Schema.ensure_all(db)
  :ok = DB.assert_base_admitted!(db, base)
  marker = File.read!(Path.join(base, "build-owner.json"))
  # Fresh V7 is externally readable as well as the populated upgraded case.
  stop.()
  F.assert_portable!(sqlite, path, Path.join(base, "fresh-vacuum.db"))
  start.()

  # Start from immutable released V5 DDL, not a fixture inferred from new DDL.
  {:ok, :ok} =
    DB.transaction(db, fn txn ->
      for object <- Enum.reverse(TS.manifest()) do
        :ok = DB.Txn.exec(txn, "DROP #{String.upcase(object.type)} IF EXISTS #{object.name}")
      end

      :ok = DB.Txn.exec(txn, File.read!("test/fixtures/toplines_v5.sql"))
    end)

  {topline, concern} = F.populate_legacy_v5!(db)
  before = F.snapshot(db)
  legacy_rows = F.legacy_rows(db)
  stop.()

  {failure, code} =
    System.cmd(
      sqlite,
      [
        "-init",
        "/dev/null",
        "-readonly",
        "-bail",
        path,
        "VACUUM INTO '#{Path.join(base, "v5-fails.db")}'"
      ],
      stderr_to_stdout: true
    )

  assert code != 0
  assert failure =~ "no such function: tightbeam_canonical_title"
  IO.puts("V5 bare VACUUM reproduces missing function")
  start.()

  for point <- [
        {:dropped, "toplines"},
        {:copied, "toplines"},
        {:dropped, "topline_concerns"},
        {:copied, "topline_concerns"},
        :after_stamp
      ] do
    assert_raise RuntimeError, ~r/activation interrupted/, fn ->
      TS.activate(DB.migration_context(db), 456, interrupt_after: point)
    end

    assert F.snapshot(db) == before
    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
    assert {:ok, [[0]]} = DB.query(db, "PRAGMA defer_foreign_keys")
    assert {:ok, []} = DB.query(db, "SELECT name FROM sqlite_temp_schema")
    assert File.read!(Path.join(base, "build-owner.json")) == marker
    stop.()
    start.()
    assert F.snapshot(db) == before
  end

  # Exercise the production boot ordering, not only the standalone activator.
  assert :ok = Schema.ensure_all(db)
  {old_schema, _old_rows} = before
  {new_schema, new_rows} = F.snapshot(db)

  assert F.legacy_rows(db) == legacy_rows

  assert [[1, 1, "standalone-toplines-v7", activated_at]] = new_rows["topline_schema_stamp"]
  assert is_integer(activated_at) and activated_at > 123

  unaffected = fn rows ->
    Enum.reject(rows, fn [_, name, _] -> name in F.actor_tables() end)
  end

  assert unaffected.(old_schema) == unaffected.(new_schema)
  assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  assert {:ok, [["ok"]]} = DB.query(db, "PRAGMA quick_check")
  assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
  assert {:ok, [[0]]} = DB.query(db, "PRAGMA defer_foreign_keys")

  # Validation is still owned by the actual product API on the migrated base.
  assert %{topline: %{title: "Café"}} =
           Toplines.create(
             db,
             F.call(%{title: " Café ", idempotency_key: "post-migration-create"})
           )

  post_create = F.snapshot(db)

  for invalid <- [1, "", "\u00a0\u3000", <<255>>, String.duplicate("💩", 2001)] do
    params = %{title: invalid, idempotency_key: "invalid"}
    assert %{code: "invalid_message"} = Toplines.create(db, F.call(params))

    assert %{code: "invalid_message"} =
             Toplines.update(
               db,
               F.call(Map.merge(params, %{topline_id: topline.id, reason: "rename"}))
             )

    assert %{code: "invalid_message"} =
             Toplines.create_concern(db, F.call(Map.put(params, :topline_id, topline.id)))
  end

  assert F.snapshot(db) == post_create

  updated =
    Toplines.update(
      db,
      F.call(
        %{
          topline_id: topline.id,
          title: "\u3000Re\u0301vise\u0301\u00a0",
          reason: "rename",
          idempotency_key: "rename"
        },
        20
      )
    )

  assert updated.topline.title == "Révisé"

  assert Toplines.get(db, F.call(%{topline_id: topline.id})).topline.concerns
         |> Enum.any?(&(&1.id == concern.id))

  after_api = F.snapshot(db)
  stop.()
  start.()
  :ok = Schema.ensure_all(db)
  assert F.snapshot(db) == after_api
  assert File.read!(Path.join(base, "build-owner.json")) == marker
  :ok = DB.assert_base_admitted!(db, base)
  stop.()

  vacuum = Path.join(base, "upgraded-vacuum.db")
  F.assert_portable!(sqlite, path, vacuum)
  dump = F.sqlite!(sqlite, path, ".dump")
  dump_path = Path.join(base, "portable.sql")
  File.write!(dump_path, dump)
  restored = Path.join(base, "restored.db")
  F.sqlite!(sqlite, restored, ".read #{dump_path}")
  assert F.sqlite!(sqlite, restored, "PRAGMA quick_check; PRAGMA foreign_key_check;") == "ok\n"
  assert F.portable_rows!(sqlite, path) == F.portable_rows!(sqlite, vacuum)
  assert F.portable_rows!(sqlite, path) == F.portable_rows!(sqlite, restored)
  IO.puts("V7 populated VACUUM and dump/restore: rows, integrity, foreign keys preserved")
after
  if pid = Process.whereis(db), do: GenServer.stop(pid)
end

IO.puts("guarded-toplines-portable: ok")
