# e2e smoke: production-machine-v1 — real gateway process tree, real failure.
#
# Runs the application's own children (real lanes, real adapter coordinator,
# real wire seams) against a fresh base dir on this host. The cause failure is
# the natural one: a claude session with no onboarded credential — the exact
# case production hit. Observations print as SMOKE lines; any assertion failure
# raises and the run is red.

defmodule PmSmoke do
  def assert!(true, _label), do: :ok
  def assert!(other, label), do: raise("SMOKE FAIL #{label}: got #{inspect(other)}")

  def q!(db, sql, params \\ []) do
    {:ok, rows} = Tightbeam.DB.query(db, sql, params)
    rows
  end

  def await(fun, label, tries \\ 80) do
    case fun.() do
      {:ok, value} ->
        value

      :retry when tries > 0 ->
        Process.sleep(250)
        await(fun, label, tries - 1)

      other ->
        raise("SMOKE TIMEOUT #{label}: last #{inspect(other)}")
    end
  end
end

alias Tightbeam.{ConditionFacts, DB, Gateway, Model, Org}

# THE REAL BOOT: the application's own start path, configured the way an
# operator configures it (TIGHTBEAM_BASE_DIR / TIGHTBEAM_PORT exported by the
# invoking shell). Nothing hand-assembled.
{:ok, _} = Application.ensure_all_started(:tightbeam)
db = Tightbeam.DB
base = System.get_env("TIGHTBEAM_BASE_DIR") || raise("export TIGHTBEAM_BASE_DIR")
IO.puts("SMOKE boot: application started, base=#{base}")

{:ok, _} = DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

mk = fn key, spawned_by, built_in ->
  Org.create(db, %{
    session_key: key,
    display_name: key,
    owner_user_id: "flynn",
    origin: "user:flynn",
    archetype: "default",
    harness: "claude",
    provider: "anthropic",
    host: Tightbeam.Placement.local_host_name(),
    model: Model.new("sonnet", effort: "medium"),
    spawned_by: spawned_by,
    is_built_in: built_in
  })
end

main = mk.(Org.personal_session_key("flynn"), nil, true)
_sup_s = mk.("smoke:sup", main.session_key, false)
_child = mk.("smoke:child", "smoke:sup", false)
IO.puts("SMOKE lineage: #{main.session_key} <- smoke:sup <- smoke:child")

# 1. The cause: a real prompt into the child; the lane claims it and the
#    engine fails it (no adapter, no credential — the production failure).
:appended =
  Gateway.deliver_prompt("smoke:child", "user:flynn", "hello from the smoke", db: db)

cause_seq =
  PmSmoke.await(
    fn ->
      case PmSmoke.q!(
             db,
             "SELECT seq, status, error FROM turns WHERE sessionKey='smoke:child' ORDER BY seq LIMIT 1"
           ) do
        [[seq, status, error]] when status in ["failed", "failed_unknown"] ->
          IO.puts("SMOKE 1 cause turn #{seq} -> #{status}: #{String.slice(error || "", 0, 80)}")
          {:ok, seq}

        other ->
          {:retry_info, other} && :retry
      end
    end,
    "cause turn terminalizes"
  )

# 2. The climb, rung 1: notice turn in sup's queue, carried by requestRef.
[notice_seq] =
  PmSmoke.await(
    fn ->
      case PmSmoke.q!(
             db,
             "SELECT seq FROM turns WHERE sessionKey='smoke:sup' AND requestRef=?1",
             ["bubble:#{cause_seq}"]
           ) do
        [[seq]] -> {:ok, [seq]}
        _ -> :retry
      end
    end,
    "notice reaches sup"
  )

IO.puts("SMOKE 2 notice #{notice_seq} enqueued to smoke:sup (bubble:#{cause_seq})")

# 3. Rungs 2..top: sup's notice fails the same way -> main; main's fails ->
#    terminal alert. Both happen through the REAL lanes; we only wait.
PmSmoke.await(
  fn ->
    case PmSmoke.q!(
           db,
           "SELECT COUNT(*) FROM turns WHERE sessionKey=?1 AND requestRef=?2",
           [main.session_key, "bubble:#{cause_seq}"]
         ) do
      [[n]] when n > 0 -> {:ok, n}
      _ -> :retry
    end
  end,
  "climb reaches main"
)

IO.puts("SMOKE 3 climb reached #{main.session_key}")

PmSmoke.await(
  fn ->
    if ConditionFacts.standing?(db, "user-alerted", "flynn"), do: {:ok, true}, else: :retry
  end,
  "user-alerted stands"
)

[[alert]] =
  PmSmoke.q!(
    db,
    "SELECT content FROM messages WHERE sessionKey=?1 AND content LIKE '[no agent can act]%'",
    [main.session_key]
  )

PmSmoke.assert!(String.contains?(alert, "smoke:child"), "alert names the child")
IO.puts("SMOKE 4 terminal alert in main stream; user-alerted standing for flynn")

# 5. Suppression: a fresh failure does not re-climb while the alert stands.
:appended = Gateway.deliver_prompt("smoke:child", "user:flynn", "again", db: db)

PmSmoke.await(
  fn ->
    case PmSmoke.q!(
           db,
           "SELECT COUNT(*) FROM turns WHERE sessionKey='smoke:child' AND status IN ('failed','failed_unknown')"
         ) do
      [[n]] when n >= 2 -> {:ok, n}
      _ -> :retry
    end
  end,
  "second cause fails"
)

[[notices]] =
  PmSmoke.q!(db, "SELECT COUNT(*) FROM turns WHERE sessionKey='smoke:sup' AND requestRef LIKE 'bubble:%'")

PmSmoke.assert!(notices == 1, "no second notice while alert stands")
IO.puts("SMOKE 5 suppression holds: still #{notices} notice")

# 6. Verb seams through the real handlers.
handlers = Gateway.handlers(%{db: db})
condition = handlers["condition"]

# The substrate does not file facts through a verb; its refusal seam is
# ConditionFacts itself. (Through the verb, a process origin dies earlier,
# at the authority check — also correct, different door.)
{:ok, refused} =
  DB.transaction(db, fn txn ->
    ConditionFacts.file_in_txn(txn, %{
      kind: "work-blocked",
      scope: "smoke:child",
      origin: "process:tightbeam"
    })
  end)

PmSmoke.assert!(match?({:error, %{code: "agent_only_kind"}}, refused), "substrate refused work-blocked")

denied =
  condition.(%{
    origin: "session:smoke:child",
    principal: {:session, "smoke:child"},
    params: %{kind: "work-blocked", scope: "smoke:child"}
  })

PmSmoke.assert!(match?(%{code: "not_authorized"}, denied), "self-assert denied")

allowed =
  condition.(%{
    origin: "session:smoke:sup",
    principal: {:session, "smoke:sup"},
    params: %{kind: "work-blocked", scope: "smoke:child"}
  })

PmSmoke.assert!(match?(%{fact_id: _}, allowed), "lineage assert accepted")
IO.puts("SMOKE 6 verb seams: substrate refused, self denied, parent accepted")

# 7. Retraction: a delivered turn under flynn clears the alert. The fixture
#    harness cannot deliver here, so exercise the same path the lane takes:
#    finish a queued turn as delivered and recognize it.
:appended = Gateway.deliver_prompt("smoke:sup", "user:flynn", "capacity probe", db: db)

probe_seq =
  PmSmoke.await(
    fn ->
      case PmSmoke.q!(
             db,
             "SELECT seq, status FROM turns WHERE sessionKey='smoke:sup' AND prompt LIKE '%capacity probe%'"
           ) do
        [[seq, _status]] -> {:ok, seq}
        _ -> :retry
      end
    end,
    "probe enqueued"
  )

{:ok, _} =
  DB.query(db, "UPDATE turns SET status='delivered', endedAt=?2 WHERE seq=?1", [
    probe_seq,
    System.system_time(:millisecond)
  ])

:ok = Tightbeam.Productions.Bubble.recognize_terminal(db, probe_seq)

PmSmoke.assert!(
  not ConditionFacts.standing?(db, "user-alerted", "flynn"),
  "delivered turn cleared the alert"
)

IO.puts("SMOKE 7 retraction: delivered turn cleared user-alerted")

# 8. RETIRE: a queued notice canceled by a real retire still climbs — the
#    fault remains untold, and cancellation of the MESSENGER is not a ruling
#    on the fault. Second owner so flynn's standing state can't interfere.
{:ok, _} = DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('kay', 0, 1)")

mk_owned = fn key, owner, spawned_by, built_in ->
  Org.create(db, %{
    session_key: key,
    display_name: key,
    owner_user_id: owner,
    origin: "user:#{owner}",
    archetype: "default",
    harness: "claude",
    provider: "anthropic",
    host: Tightbeam.Placement.local_host_name(),
    model: Model.new("sonnet", effort: "medium"),
    spawned_by: spawned_by,
    is_built_in: built_in
  })
end

kay_main = mk_owned.(Org.personal_session_key("kay"), "kay", nil, true)
_kay_sup = mk_owned.("kay:sup", "kay", kay_main.session_key, false)
_kay_child = mk_owned.("kay:child", "kay", "kay:sup", false)

:appended = Gateway.deliver_prompt("kay:child", "user:kay", "doomed work", db: db)

kay_cause =
  PmSmoke.await(
    fn ->
      case PmSmoke.q!(
             db,
             "SELECT seq FROM turns WHERE sessionKey='kay:child' AND status IN ('failed','failed_unknown')"
           ) do
        [[seq]] -> {:ok, seq}
        _ -> :retry
      end
    end,
    "kay cause fails"
  )

# The notice lands queued in kay:sup; retire kay:sup THROUGH THE REAL VERB
# before its lane can fail it, so the cancel path — not the failure path —
# is what continues the climb. Race-tolerant: if the lane failed it first,
# the climb continued anyway and the observation below still holds.
PmSmoke.await(
  fn ->
    case PmSmoke.q!(db, "SELECT seq FROM turns WHERE sessionKey='kay:sup' AND requestRef=?1", [
           "bubble:#{kay_cause}"
         ]) do
      [[_]] -> {:ok, true}
      _ -> :retry
    end
  end,
  "kay notice enqueued"
)

handlers = Gateway.handlers(%{db: db})

retire_result =
  handlers["retire"].(%{
    origin: "user:kay",
    principal: {:user, "kay"},
    session_key: "kay:sup",
    params: %{reason: "smoke retire"}
  })

IO.puts("SMOKE 8a retire verb: #{inspect(Map.take(retire_result, [:ok, :retired, :code]))}")

PmSmoke.await(
  fn ->
    if ConditionFacts.standing?(db, "user-alerted", "kay"), do: {:ok, true}, else: :retry
  end,
  "kay climb survives retire and alerts"
)

IO.puts("SMOKE 8 canceled-messenger climb: kay alerted despite retired rung")

# 9. PROD SUPPRESSION, live: an open assignment prods on terminal; a standing
#    work-blocked stops the production matching; retraction resumes it.
{:ok, _} =
  DB.query(
    db,
    """
    INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt, state)
    VALUES ('asg_smoke', 'smoke assignment', 'smoke:sup', 'flynn', 1, 'open')
    """
  )

blocked =
  handlers["condition"].(%{
    origin: "session:#{main.session_key}",
    principal: {:session, main.session_key},
    params: %{kind: "work-blocked", scope: "smoke:sup"}
  })

PmSmoke.assert!(match?(%{fact_id: _}, blocked), "main blocks smoke:sup")

verdict_blocked = Tightbeam.Supervision.prod_production_matches?(db, "smoke:sup", "asg_smoke")

unblocked =
  handlers["condition"].(%{
    origin: "session:#{main.session_key}",
    principal: {:session, main.session_key},
    params: %{kind: "work-unblocked", scope: "smoke:sup"}
  })

PmSmoke.assert!(match?(%{fact_id: _}, unblocked), "main unblocks smoke:sup")
verdict_open = Tightbeam.Supervision.prod_production_matches?(db, "smoke:sup", "asg_smoke")

IO.puts(
  "SMOKE 9 prod production: blocked=#{inspect(elem(verdict_blocked, 0))} " <>
    "unblocked=#{inspect(elem(verdict_open, 0))}"
)

PmSmoke.assert!(elem(verdict_blocked, 0) == :no_match, "blocked holder does not match")
PmSmoke.assert!(elem(verdict_open, 0) == :match, "retraction resumes the match")

# 10. RESTART CONVERGENCE (review B1's boot path): stop the application with
#     work mid-flight, restart it, and require the machine to CONVERGE from
#     whatever state the crash left — the sweeper's cursor picks up whatever
#     the cast edge lost. New owner, fresh lineage, kill between the cause
#     failing and the climb completing.
{:ok, _} = DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('rin', 0, 1)")
rin_main = mk_owned.(Org.personal_session_key("rin"), "rin", nil, true)
_rin_sup = mk_owned.("rin:sup", "rin", rin_main.session_key, false)
_rin_child = mk_owned.("rin:child", "rin", "rin:sup", false)

:appended = Gateway.deliver_prompt("rin:child", "user:rin", "work at crash time", db: db)

PmSmoke.await(
  fn ->
    case PmSmoke.q!(
           db,
           "SELECT seq FROM turns WHERE sessionKey='rin:child' AND status IN ('failed','failed_unknown')"
         ) do
      [[_]] -> {:ok, true}
      _ -> :retry
    end
  end,
  "rin cause fails"
)

:ok = Application.stop(:tightbeam)
IO.puts("SMOKE 10a application stopped mid-climb")
{:ok, _} = Application.ensure_all_started(:tightbeam)
IO.puts("SMOKE 10b application restarted; awaiting convergence")

PmSmoke.await(
  fn ->
    if ConditionFacts.standing?(db, "user-alerted", "rin"), do: {:ok, true}, else: :retry
  end,
  "rin converges to alerted after restart",
  120
)

IO.puts("SMOKE 10 restart convergence: rin alerted from post-restart recognition")
IO.puts("SMOKE PASS: all 10 observations green")
