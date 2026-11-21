defmodule Tightbeam.HolderProdFloodTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    ConnRegistry,
    DB,
    HarnessProcess,
    HolderProd,
    Ledger,
    Model,
    NoticeBatcher,
    Org
  }

  alias Tightbeam.DB.Txn

  @hour 60 * 60 * 1_000
  @cap 16
  @holders 240
  @settings %{cap: @cap, report_only: false}

  defmodule LaneStub do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(:ok), do: {:ok, :ok}
    def handle_call({:ensure_lane, _session_key}, _from, state), do: {:reply, :ok, state}
  end

  @tag timeout: 180_000
  test "a large scratch org meters first and repeat nudges through a harness outage" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = ensure_all_schemas(db)
    query!(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('fixture-owner',0,1)")
    parent = ensure_main_session(db, "fixture-owner").session_key

    start_supervised!({ConnRegistry, name: :holder_prod_flood_registry})
    start_supervised!({LaneStub, :holder_prod_flood_lane})

    delivery_opts = [
      conn_registry: :holder_prod_flood_registry,
      lane_manager: :holder_prod_flood_lane
    ]

    start = System.system_time(:millisecond) - 20 * @hour
    restored = start + 6 * @hour
    seed_org(db, start, parent)

    affected = {"codex", "shared", "fixture-fenced"}

    query!(
      db,
      "INSERT INTO harness_park_fences(adapterKey,requestedAt,generation) VALUES (?1,?2,1)",
      ["codex:shared@fixture-fenced", start]
    )

    assert HarnessProcess.parked?(db, affected)
    assert [[@holders * 5]] == query!(db, "SELECT COUNT(*) FROM assignments")

    assert [[@holders]] ==
             query!(
               db,
               "SELECT COUNT(*) FROM sessions WHERE host IN ('fixture-ready','fixture-fenced')"
             )

    {elapsed_us, peak_queued} =
      :timer.tc(fn ->
        0..56
        |> Enum.map(fn step ->
          at = start + div(step * @hour, 4)
          if at == restored, do: HarnessProcess.complete_park(db, affected)
          admit(db, at)
          pending = max_outstanding(db)
          NoticeBatcher.recover(db, at, delivery_opts)
          admit(db, at)
          queued = max_outstanding(db)
          finish_carriers(db, at)
          max(pending, queued)
        end)
        |> Enum.max()
      end)

    assert peak_queued == 1

    rows =
      query!(db, """
      SELECT n.assignmentId, s.host, n.repeatNumber, w.firedAt
      FROM assignment_holder_prod_attempts n
      JOIN wakes w ON w.wakeId=n.wakeId
      JOIN sessions s ON s.sessionKey=n.holderKey
      WHERE w.deliveredTurnSeq IS NOT NULL
      ORDER BY w.firedAt, n.id
      """)

    assert [[0]] =
             query!(db, """
             SELECT COUNT(*) FROM assignment_holder_prod_attempts
             WHERE assignmentId NOT LIKE 'fixture-possible-%'
             """)

    peak_hour =
      rows
      |> Enum.map(fn [_, _, _, sent] ->
        Enum.count(rows, fn [_, _, _, other] -> sent - @hour < other and other <= sent end)
      end)
      |> Enum.max()

    assert peak_hour == @cap

    affected_rows = Enum.filter(rows, &match?([_, "fixture-fenced", _, _], &1))
    during_outage = Enum.count(affected_rows, fn [_, _, _, sent] -> sent < restored end)
    assert during_outage == 0

    first_hour_after_recovery =
      Enum.filter(rows, fn [_, _, _, sent] -> restored <= sent and sent < restored + @hour end)

    assert length(first_hour_after_recovery) == @cap
    assert Enum.all?(first_hour_after_recovery, &match?([_, "fixture-fenced", 0, _], &1))
    assert length(Enum.filter(affected_rows, &match?([_, _, 0, _], &1))) == 60

    {first, repeats} = Enum.split_with(rows, &match?([_, _, 0, _], &1))
    assert length(first) == 120
    assert length(repeats) > 0
    assert Enum.any?(rows, &match?([_, "fixture-ready", 1, sent] when sent < restored, &1))

    spacings =
      rows
      |> Enum.group_by(&hd/1)
      |> Enum.flat_map(fn {_assignment, attempts} ->
        attempts
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [[_, _, previous, first_at], [_, _, current, next_at]] ->
          assert current == previous + 1
          next_at - first_at
        end)
      end)

    assert Enum.min(spacings) >= div(@hour, 2)
    assert Enum.max(spacings) > @hour

    IO.puts(
      "Holder nudge flood #{JSON.encode!(%{sessions: @holders, assignments: @holders * 5, simulated_hours: 14, delivered_first: length(first), delivered_repeats: length(repeats), peak_rolling_hour: peak_hour, peak_holder_outstanding: peak_queued, fenced_during_outage: during_outage, first_nudges_in_first_recovery_hour: length(first_hour_after_recovery), nudges_for_excluded_states: 0, min_repeat_spacing_minutes: div(Enum.min(spacings), 60_000), max_repeat_spacing_minutes: div(Enum.max(spacings), 60_000), exercise_ms: div(elapsed_us, 1_000)})}"
    )
  end

  defp seed_org(db, start, parent) do
    for holder <- 1..@holders do
      key = "fixture-holder-#{holder}"

      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "fixture-owner",
        origin: "user:fixture-owner",
        archetype: "default",
        harness: "codex",
        provider: "openai",
        model: Model.new("fixture"),
        host: if(rem(holder, 2) == 0, do: "fixture-ready", else: "fixture-fenced")
      })
    end

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               for holder <- 1..@holders,
                   {state, number} <-
                     Enum.with_index([
                       if(holder <= 72, do: :possible, else: :moving),
                       if(holder <= 48, do: :possible, else: :moving),
                       :waiting,
                       if(rem(holder, 4) < 2, do: :failed, else: :impossible),
                       :done
                     ]) do
                 key = "fixture-holder-#{holder}"
                 id = "fixture-#{state}-#{holder}-#{number}"
                 since = start - @hour + holder * 1_000 + number * 500

                 Txn.q(
                   txn,
                   """
                   INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state)
                   VALUES (?1,'Synthetic flood work',?2,?3,?4,'open')
                   """,
                   [id, key, parent, since]
                 )

                 place_in_state(txn, state, id, key, parent, since, start + 30 * @hour)
               end

               :ok
             end)
  end

  defp place_in_state(_txn, :possible, _id, _holder, _opener, _since, _due), do: :ok

  defp place_in_state(txn, :moving, id, holder, _opener, since, due) do
    Txn.q(
      txn,
      """
      INSERT INTO wakes(wakeId,sessionKey,creatorSessionKey,origin,prompt,dueAt,createdAt,assignmentId)
      VALUES ('wait-' || ?1,?2,?2,'session:' || ?2,'Waiting for fixture fact',?4,?3,?1)
      """,
      [id, holder, since, due]
    )
  end

  defp place_in_state(txn, :waiting, id, holder, opener, since, _due) do
    Txn.q(
      txn,
      """
      INSERT INTO decision_requests
        (id,kind,raiserId,raiserSessionKey,ownerUserId,expecterSessionKey,expecterUserId,
         assignmentId,raisedAt,question,context,status)
      VALUES ('dr-' || ?1,'agent','session:' || ?3,?3,'fixture-owner',?2,'fixture-owner',
         ?1,?4,'What should happen next?','{}','open')
      """,
      [id, holder, opener, since]
    )
  end

  defp place_in_state(txn, :failed, id, holder, _opener, since, _due) do
    Txn.q(
      txn,
      """
      INSERT INTO turns(sessionKey,messageId,origin,prompt,assignmentId,status,createdAt,startedAt,endedAt)
      VALUES (?2,'turn-' || ?1,'user:fixture-owner','Fixture attempt',?1,'failed',?3,?3,?3)
      """,
      [id, holder, since + 1]
    )
  end

  defp place_in_state(txn, :impossible, id, holder, opener, since, due) do
    Txn.q(
      txn,
      """
      INSERT INTO attests(id,assignmentId,kind,note,bySession,ts)
      VALUES ('attest-' || ?1,?1,'cannot-proceed','Waiting for a fixture decision',?2,?3)
      """,
      [id, holder, since]
    )

    Txn.q(
      txn,
      """
      INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt,assignmentId)
      VALUES ('decision-' || ?1,?2,'session:' || ?3,'Fixture cannot proceed',?5,?4,?1)
      """,
      [id, opener, holder, since, due]
    )

    Txn.q(
      txn,
      """
      INSERT INTO assignment_cannot_proceed
        (id,assignmentId,attestId,decisionRequestId,decisionWakeId,openerRef,disposerRef,reason,state,createdAt)
      VALUES ('impossible-' || ?1,?1,'attest-' || ?1,'dr-' || ?1,'decision-' || ?1,
        'session:' || ?2,'session:' || ?2,'Waiting for a fixture decision','standing',?3)
      """,
      [id, opener, since]
    )
  end

  defp place_in_state(txn, :done, id, holder, _opener, since, _due) do
    Txn.q(
      txn,
      """
      INSERT INTO attests(id,assignmentId,kind,bySession,ts)
      VALUES ('attest-' || ?1,?1,'completion',?2,?3)
      """,
      [id, holder, since]
    )

    Txn.q(
      txn,
      """
      UPDATE assignments SET state='closed',outcome='completed',closedAt=?3,
        closedBySession=?2,closingAttestId='attest-' || ?1 WHERE id=?1
      """,
      [id, holder, since]
    )
  end

  defp admit(db, at) do
    assert {:ok, :ok} = DB.transaction(db, &HolderProd.admit_due_in_txn(&1, at, 100, @settings))
  end

  defp max_outstanding(db) do
    [[count]] =
      query!(db, """
      SELECT COALESCE(MAX(count),0) FROM (
        SELECT COUNT(*) AS count
        FROM assignment_holder_prod_attempts n
        JOIN wakes w ON w.wakeId=n.wakeId
        LEFT JOIN turns t ON t.seq=w.deliveredTurnSeq
        WHERE w.state='pending' OR t.status='queued'
        GROUP BY n.holderKey
      )
      """)

    count
  end

  defp finish_carriers(db, at) do
    for [holder, seq] <-
          query!(
            db,
            """
            SELECT DISTINCT n.holderKey,t.seq FROM assignment_holder_prod_attempts n
            JOIN wakes w ON w.wakeId=n.wakeId JOIN turns t ON t.seq=w.deliveredTurnSeq
            WHERE t.status='queued' AND w.firedAt=?1
            """,
            [at]
          ) do
      assert {:ok, %{seq: ^seq} = turn} = Ledger.claim_next(db, holder, "flood-test")
      assert :ok = Ledger.finish(db, seq, "delivered", nil, owner_lease: turn.owner_lease)
    end
  end

  defp query!(db, sql, params \\ []) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end
end
