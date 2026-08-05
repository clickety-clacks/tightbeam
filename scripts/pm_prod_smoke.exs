# SMOKE §11 step 42 — the prod production over REAL sweep time.
#
# Not the match function (step 40 covers that): actual prod prompts arriving
# in the holder's queue across live ticks, stopping when work-blocked stands,
# resuming when it is retracted. Uncredentialed by design — the holder's prod
# turns fail, and each failure is a new terminal that drives the next cycle,
# which is exactly the engine this step watches.
#
# Isolation: fresh TIGHTBEAM_BASE_DIR, own port.
#   export TIGHTBEAM_BASE_DIR=$HOME/tb-pm-42-$(date +%s) TIGHTBEAM_PORT=11483
#   mkdir -p $TIGHTBEAM_BASE_DIR && mix run --no-start scripts/pm_prod_smoke.exs

defmodule PmProd do
  def q!(db, sql, params \\ []) do
    {:ok, rows} = Tightbeam.DB.query(db, sql, params)
    rows
  end

  def prods(db) do
    [[n]] =
      q!(db, "SELECT COUNT(*) FROM turns WHERE sessionKey='p42:holder' AND prompt LIKE '%This is prod %'")

    n
  end

  def await(fun, label, tries \\ 120) do
    case fun.() do
      {:ok, value} ->
        value

      :retry when tries > 0 ->
        Process.sleep(500)
        await(fun, label, tries - 1)

      other ->
        raise("42 TIMEOUT #{label}: last #{inspect(other)}")
    end
  end
end

alias Tightbeam.{ConditionFacts, DB, Gateway, Model, Org}

{:ok, _} = Application.ensure_all_started(:tightbeam)
db = Tightbeam.DB
IO.puts("42 boot: application started")

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
_holder = mk.("p42:holder", main.session_key, false)

{:ok, _} =
  DB.query(
    db,
    """
    INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt, state)
    VALUES ('asg_42', 'watch the prods', 'p42:holder', 'flynn', 1, 'open')
    """
  )

# Seed the engine: one real turn that fails (no credential) is the first
# terminal the sweep evaluates against the open obligation.
:appended = Gateway.deliver_prompt("p42:holder", "user:flynn", "get to work", db: db)

first =
  PmProd.await(
    fn -> if PmProd.prods(db) >= 1, do: {:ok, PmProd.prods(db)}, else: :retry end,
    "first prod arrives over live ticks"
  )

IO.puts("42a first prod arrived (count=#{first})")

# Each prod turn fails (uncredentialed) making the next terminal; the ladder
# advances on its own clock. Watch it actually move.
grown =
  PmProd.await(
    fn -> if PmProd.prods(db) > first, do: {:ok, PmProd.prods(db)}, else: :retry end,
    "ladder advances unprompted"
  )

IO.puts("42b ladder advancing on its own (count=#{grown})")

# Block: the production stops matching. Give it several real sweep intervals
# and require the count to FREEZE.
handlers = Gateway.handlers(%{db: db})

%{fact_id: _} =
  handlers["condition"].(%{
    origin: "session:#{main.session_key}",
    principal: {:session, main.session_key},
    params: %{kind: "work-blocked", scope: "p42:holder"}
  })

at_block = PmProd.prods(db)
Process.sleep(8_000)
after_wait = PmProd.prods(db)

if after_wait > at_block do
  raise "42 FAIL: prods advanced (#{at_block} -> #{after_wait}) while work-blocked stood"
end

IO.puts("42c blocked: count frozen at #{at_block} across 8s of live ticks")

# Retract: the production matches again from current state.
%{fact_id: _} =
  handlers["condition"].(%{
    origin: "session:#{main.session_key}",
    principal: {:session, main.session_key},
    params: %{kind: "work-unblocked", scope: "p42:holder"}
  })

# A new terminal re-enters the cycle (the block pre-filters the sweep, so
# give the engine a fresh terminal the way real work would).
:appended = Gateway.deliver_prompt("p42:holder", "user:flynn", "try again", db: db)

resumed =
  PmProd.await(
    fn -> if PmProd.prods(db) > after_wait, do: {:ok, PmProd.prods(db)}, else: :retry end,
    "prods resume after retraction"
  )

IO.puts("42d retraction resumed prodding (count=#{resumed})")
IO.puts("42 PASS: prods fire over real time, freeze under the fact, resume on retraction")
