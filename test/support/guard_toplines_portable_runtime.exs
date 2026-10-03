defmodule PortableToplinesFixture do
  import ExUnit.Assertions
  alias Tightbeam.{DB, Toplines}

  @tables ~w(toplines topline_work_memberships topline_concerns topline_concern_refs
    topline_events topline_idempotency topline_placement_obligations topline_schema_stamp)

  def snapshot(db) do
    {:ok, schema} = DB.query(db, "SELECT type,name,sql FROM sqlite_schema ORDER BY name")

    rows =
      for table <- @tables, into: %{} do
        {:ok, rows} = DB.query(db, "SELECT rowid,* FROM #{table} ORDER BY rowid")
        {table, rows}
      end

    {schema, rows}
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

  def populate!(db) do
    :ok =
      DB.execute(db, """
      INSERT INTO users (userId,isAdmin,createdAt) VALUES ('synthetic',1,1);
      INSERT INTO work_items (id,title,ownerUserId,state,createdByUser,createdContextKnown,createdAt)
        VALUES ('wi_fixture','Work','synthetic','open','synthetic',1,1);
      INSERT INTO work_item_versions (workItemId,rowVersion) VALUES ('wi_fixture',1);
      INSERT INTO wakes (wakeId,sessionKey,origin,prompt,consumer,dueAt,state,createdAt)
        VALUES ('w_fixture','agent:main:clawline:synthetic:main','process:tightbeam',
                'Choose placement','prompt',1,'pending',1);
      """)

    %{topline: topline} =
      Toplines.create(db, call(%{title: "\u3000Cafe\u0301\u00a0", idempotency_key: "create"}))

    assert topline.title == "Café"

    %{membership: _} =
      Toplines.link_work(
        db,
        call(
          %{
            topline_id: topline.id,
            work_item_id: "wi_fixture",
            reason: "group",
            idempotency_key: "link"
          },
          11
        )
      )

    %{concern: concern} =
      Toplines.create_concern(
        db,
        call(
          %{
            topline_id: topline.id,
            title: "\u00a0Re\u0301sume\u0301💩\u3000",
            idempotency_key: "concern"
          },
          12
        )
      )

    assert concern.title == "Résumé💩"

    refute Map.has_key?(
             Toplines.link_concern_work(
               db,
               call(
                 %{
                   concern_id: concern.id,
                   work_item_id: "wi_fixture",
                   reason: "tag",
                   idempotency_key: "tag"
                 },
                 13
               )
             ),
             :code
           )

    %{topline: closed} = Toplines.create(db, call(%{title: "Closed", idempotency_key: "closed"}))

    assert Toplines.close(
             db,
             call(%{topline_id: closed.id, reason: "done", idempotency_key: "close"}, 14)
           ).topline.state == "closed"

    {:ok, _} =
      DB.transaction(db, fn txn ->
        Toplines.open_placement_in_txn(txn, %{
          id: "tlp_fixture",
          work_item_id: "wi_fixture",
          owner_user_id: "synthetic",
          cause: "created",
          cause_ref: "wi_fixture",
          actor_kind: "user",
          actor_ref: "synthetic",
          at: 1,
          prompt_wake_id: "w_fixture"
        })
      end)

    # Non-dense rowids must survive the rebuild, along with stable product IDs.
    {:ok, _} = DB.query(db, "UPDATE toplines SET rowid=99 WHERE id=?1", [closed.id])
    {topline, concern}
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
  # Fresh V6 is externally readable as well as the populated upgraded case.
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

  {topline, concern} = F.populate!(db)
  before = F.snapshot(db)
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
  {old_schema, old_rows} = before
  {new_schema, new_rows} = F.snapshot(db)

  assert Map.delete(new_rows, "topline_schema_stamp") ==
           Map.delete(old_rows, "topline_schema_stamp")

  assert [[1, 1, "standalone-toplines-v6", activated_at]] = new_rows["topline_schema_stamp"]
  assert is_integer(activated_at) and activated_at > 123

  unaffected = fn rows ->
    Enum.reject(rows, fn [_, name, _] -> name in ["toplines", "topline_concerns"] end)
  end

  assert unaffected.(old_schema) == unaffected.(new_schema)
  assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  assert {:ok, [["ok"]]} = DB.query(db, "PRAGMA quick_check")
  assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
  assert {:ok, [[0]]} = DB.query(db, "PRAGMA defer_foreign_keys")

  # Validation is still owned by the actual product API on the migrated base.
  assert Toplines.create(db, F.call(%{title: " Café ", idempotency_key: "create"})).topline ==
           topline

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

  assert F.snapshot(db) == {new_schema, new_rows}

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
  IO.puts("V6 populated VACUUM and dump/restore: rows, integrity, foreign keys preserved")
after
  if pid = Process.whereis(db), do: GenServer.stop(pid)
end

IO.puts("guarded-toplines-portable: ok")
