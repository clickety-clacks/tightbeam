[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions
alias Tightbeam.{DB, Model, Org, Schema, SessionReparent}
{:ok, hub} = Tightbeam.Firehose.Hub.start_link(name: Tightbeam.Firehose.Hub)
opts = [path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks]]
{:ok, db} = DB.start_link(opts)
:ok = Schema.ensure_all(db)
:ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('owner',0,1)")

for key <- ["child", "parent", "next"] do
  Org.create(db, %{
    session_key: key,
    display_name: key,
    owner_user_id: "owner",
    origin: "user:owner",
    archetype: "default",
    host: "fixture-host",
    harness: "fixture",
    provider: "fixture_provider",
    model: Model.new("fixture")
  })
end

:ok =
  DB.execute(db, """
  INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdContextKnown,createdAt)
  VALUES ('item','item','owner','open','owner',0,1);
  INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,state,workItemId)
  VALUES ('assignment','assignment','child','owner',1,'open','item');
  """)

call = %{
  principal: {:user, "owner"},
  params: %{
    session_key: "child",
    parent_session_key: "parent",
    assignment_id: "assignment",
    idempotency_key: "first"
  }
}

first = SessionReparent.handle(db, call)
assert is_binary(first["eventId"])

second =
  SessionReparent.handle(db, %{
    call
    | params: %{call.params | parent_session_key: "next", idempotency_key: "second"}
  })

assert second["session"]["previousCurrentParent"] == "parent"
:ok = GenServer.stop(db)
{:ok, reopened} = DB.start_link(opts)

try do
  :ok = Schema.ensure_all(reopened)
  assert Org.current_parent(reopened, "child") == "next"
  assert Org.get(reopened, "child").spawned_by == nil
  assert SessionReparent.current_coordination_parent(reopened, "assignment") == "next"
  assert SessionReparent.handle(reopened, call) == first
  assert {:ok, [[2]]} = DB.query(reopened, "SELECT COUNT(*) FROM session_reparent_events")

  assert {:ok, [["owner", "child", "open"]]} =
           DB.query(
             reopened,
             "SELECT openedByUser,holderKey,state FROM assignments WHERE id='assignment'"
           )

  IO.puts("reparent-reopen: ok")
after
  GenServer.stop(reopened)
  GenServer.stop(hub)
end
