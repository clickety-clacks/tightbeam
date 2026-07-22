# L0 spawn-path smoke — a DEAD model ref driven through the REAL gateway spawn
# handler yields the loud, CLASSIFIED denial (model_unavailable) against the LIVE
# derived catalog. The dead ref denies at validate_catalog_model, BEFORE spinup
# and before any DB.transaction — so no SSH, no session, no disk mutation.
alias Tightbeam.{DB, Devices, EventLog, Idempotency, Ledger, Org, Projection, Roles, Wakes, Assignments, ConnRegistry, ModelCatalog, Archetypes, Gateway}

real = Path.expand("~/.tightbeam-beam")
scratch = Path.join(System.tmp_dir!(), "l0-spawn-smoke-#{System.unique_integer([:positive])}")
File.mkdir_p!(scratch)
File.cp_r!(Path.join(real, "auth"), Path.join(scratch, "auth"))
File.cp_r!(Path.join(real, "identity"), Path.join(scratch, "identity"))
File.cp!(Path.join(real, "hosts.json"), Path.join(scratch, "hosts.json"))
IO.puts("[l0-spawn] scratch base_dir=#{scratch} (real auth+identity+hosts copied)")

db = :l0_spawn_db
{:ok, _} = DB.start_link(path: ":memory:", name: db)
for m <- [Devices, EventLog, Idempotency, Ledger, Org, Projection, Roles, Wakes, Assignments],
    do: :ok = m.ensure_schema(db)
{:ok, _} = ConnRegistry.start_link(name: Tightbeam.ConnRegistry)
{:ok, _} = ModelCatalog.start_link(base_dir: scratch, name: ModelCatalog)
Archetypes.load!(scratch)

# wait for the live catalog to become fresh
Enum.reduce_while(1..80, nil, fn _, _ ->
  case ModelCatalog.get("claude", ModelCatalog) do
    {_e, :fresh} -> {:halt, :ok}
    _ -> Process.sleep(50); {:cont, nil}
  end
end)

{:ok, _ref, nil} =
  ConnRegistry.register(Tightbeam.ConnRegistry, %{
    pid: self(), user_id: "flynn", device_id: "d1", is_admin: true, subscriptions: MapSet.new(["chat"])
  })

config = %{
  base_dir: scratch, cwd: "/tmp", port: 0,
  default_harness: :claude, default_model: "claude-sonnet-5[medium]",
  max_live_sessions_per_user: 50, wake_tick_ms: 1_000, db: db
}
spawn_fn = Gateway.handlers(config)["spawn"]

{:ok, [[sessions_before]]} = DB.query(db, "SELECT COUNT(*) FROM sessions")

dead = spawn_fn.(%{
  origin: "user:flynn", session_key: nil,
  params: %{display_name: "SmokeDead", handle: "smoke-dead-#{System.unique_integer([:positive])}",
            idempotency_key: "smoke-dead-#{System.unique_integer([:positive])}",
            model: "claude-fable-5"}   # bare ref for a with-efforts model: dead
})

{:ok, [[sessions_after]]} = DB.query(db, "SELECT COUNT(*) FROM sessions")

IO.puts("[l0-spawn] dead-ref spawn result => #{inspect(dead)}")
IO.puts("[l0-spawn] sessions before=#{sessions_before} after=#{sessions_after}")

classified = match?(%{code: "model_unavailable"}, dead)
no_session = sessions_after == sessions_before
pass = classified and no_session
IO.puts("[l0-spawn] classified_deny=#{classified} no_session_created=#{no_session}")
IO.puts(if pass, do: "[l0-spawn] PASS", else: "[l0-spawn] FAIL")
File.rm_rf!(scratch)
System.halt(if pass, do: 0, else: 1)
