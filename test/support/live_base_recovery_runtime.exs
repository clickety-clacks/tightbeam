[payload, base, locks] = System.argv()
payload = Path.expand(payload)
^payload = Application.app_dir(:tightbeam) |> Path.expand()
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
alias Tightbeam.{Boot, DB, Escalation, Model, Org, RuleRuntime, Wakes}
opts = [path: Path.join(base, "state.db"), name: DB, guard_inputs: [lock_dir: locks]]
{:ok, seed} = DB.start_link(opts)
:ignore = Boot.start_link(%{base_dir: base})

for {key, label} <- [{"agent:boot-raiser:app", "raiser"}, {"agent:boot-target:app", "target"}] do
  Org.create(seed, %{
    session_key: key,
    display_name: label,
    owner_user_id: "boot-owner",
    origin: "user:boot-owner",
    archetype: "default",
    host: "testhost",
    harness: "claude",
    provider: "anthropic",
    model: Model.new("fable")
  })
end

call = %{
  verb: "attest",
  origin: "agent:boot-raiser",
  principal: {:session, "agent:boot-raiser:app"},
  session_key: nil,
  params: %{assignment_id: "asg-boot", kind: "completion"}
}

{:decision_pending, request_id} =
  Escalation.escalate(seed, call, %{name: "boot-review", text: "boot review required"}, %{
    question: "Allow boot action?",
    options: nil
  })

# Existing application_test retired-decision fixture: stage only the terminal
# session row; production Boot, not the fixture, must recover its decision.
:ok =
  DB.execute(
    seed,
    "UPDATE sessions SET state='retired' WHERE sessionKey='agent:boot-raiser:app'"
  )

{:ok, [["open"]]} =
  DB.query(seed, "SELECT status FROM decision_requests WHERE id=?1", [request_id])

marker = File.read!(Path.join(base, "build-owner.json"))
[] = Enum.filter(Wakes.list_pending(seed), &(&1.prompt == "boot recovered retired decision"))
:ok = GenServer.stop(seed)
key = :crypto.hash(:sha256, base) |> Base.encode16(case: :lower)
lock_path = Path.join(locks, key <> ".lock")

await = fn recur, remaining ->
  case Tightbeam.LiveBaseLock.acquire(lock_path) do
    {:ok, lock} ->
      :ok = Tightbeam.LiveBaseLock.release(lock)

    {:error, :lock_busy} when remaining > 0 ->
      Process.sleep(10)
      recur.(recur, remaining - 1)

    other ->
      raise "lock did not release: #{inspect(other)}"
  end
end

await.(await, 100)
rules_dir = Path.join(base, "identity/rules")
File.mkdir_p!(rules_dir)

File.write!(Path.join(rules_dir, "boot-decision-recovery.toml"), """
[[rule]]
name = "observe-boot-decision-recovery"
verb = "retire"
edges = ["row-commit"]
effect = "notice"
text = "record recovered decision withdrawal"
deny_when = [{ fact = "decision_request.status", op = "eq", value = "withdrawn" }]
[rule.notice]
target_session = "agent:boot-target:app"
prompt = "boot recovered retired decision"
""")

:persistent_term.erase(RuleRuntime)

{:ok, sup} =
  Supervisor.start_link(
    Tightbeam.Application.children(%{base_dir: base, guard_inputs: [lock_dir: locks]}),
    strategy: :rest_for_one
  )

db = Process.whereis(DB)
true = is_pid(db)

{:ok, [["withdrawn"]]} =
  DB.query(db, "SELECT status FROM decision_requests WHERE id=?1", [request_id])

[wake] = Enum.filter(Wakes.list_pending(db), &(&1.prompt == "boot recovered retired decision"))
"agent:boot-target:app" = wake.session_key
^marker = File.read!(Path.join(base, "build-owner.json"))
:ok = DB.assert_base_admitted!(db, base)
:ok = Supervisor.stop(sup)
await.(await, 100)
IO.puts("guarded-business-recovery: ok")
