defmodule Tightbeam.ArtifactLifecycleFirehoseTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{Artifacts, DB, Model, Org, Schema, StateResources}
  alias Tightbeam.Firehose.Hub

  setup do
    db = :"artifact_al_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    :ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn',0,1)")

    Org.create(db, %{
      session_key: "al_owner",
      display_name: "AL",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    :ok =
      DB.execute(
        db,
        "INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt) VALUES ('wi_al','AL','flynn','flynn',1)"
      )

    start_supervised!({Hub, name: Hub})
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: false})

    base =
      Path.join(System.tmp_dir!(), "artifact-al-review-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "work"))
    on_exit(fn -> File.rm_rf(base) end)
    %{db: db, work: Path.join(base, "work"), archive: Path.join(base, "archive")}
  end

  test "AL11 local archive contenders commit one custody change and one no-op", ctx do
    File.write!(Path.join(ctx.work, "result.md"), "custody bytes")
    row = record(ctx.db, "result.md")
    assert_receive {:firehose_notice, %{"class" => "artifact.recorded"}}
    :ok = Hub.delivered(Hub, self())

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE artifact_version_floors SET rowVersion=40 WHERE artifactId=?1",
               [row.artifact_id]
             )

    clock_key = {Artifacts, :test_clock}
    assert {:ok, nil} = DB.transaction(ctx.db, fn _ -> Process.put(clock_key, 700) end)

    on_exit(fn ->
      if Process.whereis(ctx.db),
        do: DB.transaction(ctx.db, fn _ -> Process.delete(clock_key) end)
    end)

    tasks =
      for _ <- 1..2,
          do:
            Task.async(fn ->
              Artifacts.archive_session(ctx.db, "al_owner", ctx.work, ctx.archive)
            end)

    assert Enum.map(tasks, &Task.await/1) == [:ok, :ok]

    canonical =
      StateResources.query_artifact(ctx.db, row.artifact_id) |> StateResources.artifact()

    assert canonical["rowVersion"] == 41
    assert canonical["updatedAt"] == 700
    assert canonical["state"] == "archived"
    assert File.read!(canonical["home"]) == "custody bytes"
    assert_receive {:firehose_notice, %{"class" => "artifact.archived", "payload" => ^canonical}}
    :ok = Hub.delivered(Hub, self())
    refute_receive {:firehose_notice, _}
    assert Artifacts.archive_session(ctx.db, "al_owner", ctx.work, ctx.archive) == :ok

    assert StateResources.artifact(StateResources.query_artifact(ctx.db, row.artifact_id)) ==
             canonical

    assert {:ok, 700} = DB.transaction(ctx.db, fn _ -> Process.put(clock_key, 600) end)
    assert Artifacts.release(ctx.db, row.artifact_id).updated_at == 600
    assert_receive {:firehose_notice, %{"class" => "artifact.released", "payload" => released}}
    assert released["rowVersion"] == 42
    assert released["updatedAt"] == 600
    assert {:ok, 600} = DB.transaction(ctx.db, fn _ -> Process.delete(clock_key) end)
    assert {:ok, nil} = DB.transaction(ctx.db, fn _ -> Process.get(clock_key) end)
  end

  test "test clock is process-local and cleanup restores actual clock fallback", ctx do
    key = {Artifacts, :test_clock}

    tasks =
      for time <- [700, 600] do
        Task.async(fn ->
          Process.put(key, time)

          try do
            row = record(ctx.db, "eezo:/tmp/clock-#{time}")
            assert row.created_at == time
            row
          after
            Process.delete(key)
          end
        end)
      end

    assert tasks |> Enum.map(&Task.await/1) |> Enum.map(& &1.created_at) |> Enum.sort() == [
             600,
             700
           ]

    assert Process.get(key) == nil
    before = System.system_time(:millisecond)
    row = record(ctx.db, "eezo:/tmp/default-clock")
    assert row.created_at >= before
    assert row.created_at <= System.system_time(:millisecond)
    assert {:ok, nil} = DB.transaction(ctx.db, fn _ -> Process.get(key) end)
  end

  test "AL10 final batch failure rolls back prior row and floor writes and all handoffs", ctx do
    File.write!(Path.join(ctx.work, "result.md"), "retained filesystem effect")
    rows = [record(ctx.db, "result.md"), record(ctx.db, "eezo:/tmp/external")]

    for _ <- rows do
      assert_receive {:firehose_notice, %{"class" => "artifact.recorded"}}
      :ok = Hub.delivered(Hub, self())
    end

    final_id = rows |> Enum.map(& &1.artifact_id) |> Enum.max()
    before = Enum.map(rows, &StateResources.query_artifact(ctx.db, &1.artifact_id))

    :ok =
      DB.execute(
        ctx.db,
        "CREATE TRIGGER fail_last_artifact BEFORE UPDATE OF state ON artifacts WHEN NEW.artifactId='#{final_id}' BEGIN SELECT RAISE(ABORT,'final artifact failure'); END"
      )

    assert_raise Tightbeam.DB.Error, ~r/final artifact failure/, fn ->
      Artifacts.archive_session(ctx.db, "al_owner", ctx.work, ctx.archive)
    end

    assert Enum.map(rows, &StateResources.query_artifact(ctx.db, &1.artifact_id)) == before
    refute_receive {:firehose_notice, _}
    # Database rollback does not promise to reverse the prior filesystem move.
  end

  test "AL11 lost floor compare aborts the real release without changing custody", ctx do
    File.write!(Path.join(ctx.work, "result.md"), "retained")
    row = record(ctx.db, "result.md")
    assert_receive {:firehose_notice, _}
    :ok = Hub.delivered(Hub, self())
    :ok = Artifacts.archive_session(ctx.db, "al_owner", ctx.work, ctx.archive)
    assert_receive {:firehose_notice, %{"class" => "artifact.archived"}}
    :ok = Hub.delivered(Hub, self())
    before = StateResources.query_artifact(ctx.db, row.artifact_id)

    :ok =
      DB.execute(
        ctx.db,
        "CREATE TRIGGER lose_artifact_compare BEFORE UPDATE ON artifact_version_floors BEGIN SELECT RAISE(IGNORE); END"
      )

    assert_raise ArgumentError, "artifact_version_compare_failed", fn ->
      Artifacts.release(ctx.db, row.artifact_id)
    end

    assert StateResources.query_artifact(ctx.db, row.artifact_id) == before
    assert File.read!(before.home) == "retained"
    refute_receive {:firehose_notice, _}
  end

  test "AL13 denied visibility never invokes matcher", ctx do
    :ok =
      Hub.register(Hub, self(), %{
        mode: :subscribed,
        db: ctx.db,
        user_id: "denied",
        is_admin: false
      })

    :ok =
      Hub.subscribe(Hub, self(), "matching", %{
        "classes" => ["artifact."],
        "workItemId" => "wi_al"
      })

    hub = Process.whereis(Hub)
    :erlang.trace_pattern({Hub, :matches?, 2}, true, [:local])
    :erlang.trace(hub, true, [:call, {:tracer, self()}])

    try do
      record(ctx.db, "eezo:/tmp/hidden")
      assert Hub.sequence(Hub, self()) == 0
      refute_receive {:trace, ^hub, :call, {Hub, :matches?, _}}
      refute_receive {:firehose_notice, _}
      :ok = Hub.register(Hub, self(), %{user_id: "flynn"})
      :ok = Artifacts.archive_session(ctx.db, "al_owner", ctx.work, ctx.archive)
      assert_receive {:trace, ^hub, :call, {Hub, :matches?, _}}
      assert_receive {:firehose_notice, %{"class" => "artifact.released"}}
    after
      :erlang.trace(hub, false, [:call])
      :erlang.trace_pattern({Hub, :matches?, 2}, false, [:local])
    end
  end

  test "archive caller and contender wait beyond default DB budget for actual completion", ctx do
    File.write!(Path.join(ctx.work, "slow.md"), "custody")
    row = record(ctx.db, "slow.md")
    assert_receive {:firehose_notice, _}
    :ok = Hub.delivered(Hub, self())
    # Hold the existing DB owner deterministically. Both archival calls must
    # wait beyond GenServer.call/2's five seconds, without premature retirement continuation.
    parent = self()

    blocker =
      Task.async(fn ->
        GenServer.call(
          ctx.db,
          {:transaction,
           fn _ ->
             send(parent, {:custody_blocked, self()})

             receive do
               :finish_custody_block -> :ok
             end
           end},
          :infinity
        )
      end)

    assert_receive {:custody_blocked, owner}

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          result = Artifacts.archive_session(ctx.db, "al_owner", ctx.work, ctx.archive)
          send(parent, {:retirement_continued, result})
          result
        end)
      end

    refute_receive {:retirement_continued, _}, 5_200
    assert File.read!(Path.join(ctx.work, "slow.md")) == "custody"
    send(owner, :finish_custody_block)
    assert Task.await(blocker) == {:ok, :ok}
    assert Enum.map(tasks, &Task.await/1) == [:ok, :ok]
    for _ <- tasks, do: assert_receive({:retirement_continued, :ok})
    archived = StateResources.query_artifact(ctx.db, row.artifact_id)
    assert archived.row_version == 2
    assert File.read!(archived.home) == "custody"
    assert_receive {:firehose_notice, %{"class" => "artifact.archived"}}
    :ok = Hub.delivered(Hub, self())
    refute_receive {:firehose_notice, _}
  end

  test "slow recursive custody completes before the retirement caller continues", ctx do
    File.write!(Path.join(ctx.work, "unregistered-file"), "owned bytes")
    parent = self()
    key = {Artifacts, :test_custody_boundary}

    assert {:ok, nil} =
             DB.transaction(ctx.db, fn _ ->
               Process.put(key, fn ->
                 Process.delete(key)
                 send(parent, {:inside_recursive_custody, self()})

                 receive do
                   :complete_recursive_custody -> :ok
                 end
               end)
             end)

    caller =
      Task.async(fn ->
        result = Artifacts.archive_session(ctx.db, "al_owner", ctx.work, ctx.archive)
        send(parent, {:retirement_result, result})
        result
      end)

    assert_receive {:inside_recursive_custody, owner}
    refute_receive {:retirement_result, _}, 5_200
    assert File.exists?(ctx.work)
    send(owner, :complete_recursive_custody)
    assert Task.await(caller) == :ok
    assert_receive {:retirement_result, :ok}
    refute File.exists?(ctx.work)
    assert {:ok, nil} = DB.transaction(ctx.db, fn _ -> Process.get(key) end)
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM artifact_version_floors")
    refute_receive {:firehose_notice, _}
  end

  @tag artifact_history: true
  test "AL14 exact R1 retained rows seed C+1 and reapply preserves 502" do
    db = history_db()
    before = history_rows(db)
    assert :ok = Schema.upgrade_firehose_r1(db)
    assert history_rows(db) == before

    assert {:ok, [[501], [501]]} =
             DB.query(db, "SELECT rowVersion FROM artifact_version_floors ORDER BY artifactId")

    assert Artifacts.release(db, "archived").state == "released"
    assert_receive {:firehose_notice, %{"class" => "artifact.released", "payload" => payload}}
    Hub.delivered(Hub, self())
    assert payload["rowVersion"] == 502
    kept = StateResources.query_artifact(db, "archived")
    assert :ok = Schema.ensure_all(db)
    assert Artifacts.release(db, "archived").state == "released"
    assert StateResources.query_artifact(db, "archived") == kept
    refute_receive {:firehose_notice, _}

    assert {:ok, [[~s({"phase":"pending"})]]} =
             DB.query(db, "SELECT reminderState FROM assignments")
  end

  @tag artifact_history: true
  test "AL14 erased or reused historical version900 cannot be certified by retained-row adoption" do
    db = history_db()
    :ok = DB.execute(db, "UPDATE artifacts SET createdAt=900,updatedAt=900")

    assert {:ok, historical} =
             DB.query(db, "SELECT artifactId,createdAt FROM artifacts ORDER BY artifactId")

    :ok =
      DB.execute(
        db,
        "DELETE FROM artifacts WHERE artifactId='released'; UPDATE artifacts SET createdAt=500,updatedAt=500"
      )

    assert :ok = Schema.upgrade_firehose_r1(db)
    assert StateResources.query_artifact(db, "released") == nil
    assert StateResources.query_artifact(db, "archived").row_version == 501
    assert {:ok, 1} = DB.transaction(db, &Artifacts.reserve_version_in_txn(&1, "released"))

    for [id, historical_version] <- historical do
      assert {:ok, [[proposed]]} =
               DB.query(
                 db,
                 "SELECT rowVersion FROM artifact_version_floors WHERE artifactId=?1",
                 [id]
               )

      refute proposed > historical_version
    end
  end

  @tag artifact_history: true
  test "AL13 exact fresh-upgrade floor guards match and malformed serialization refuses", ctx do
    db = history_db()
    assert :ok = Schema.upgrade_firehose_r1(db)

    assert {:ok, ddl} =
             DB.query(
               ctx.db,
               "SELECT sql FROM sqlite_master WHERE name='artifact_version_floors'"
             )

    assert {:ok, ^ddl} =
             DB.query(db, "SELECT sql FROM sqlite_master WHERE name='artifact_version_floors'")

    raw = StateResources.query_artifact(db, "archived")

    for invalid <- [nil, 0, -1, 1.5] do
      assert_raise ArgumentError, "artifact rowVersion is projection_invalid", fn ->
        StateResources.artifact(Map.put(raw, :row_version, invalid))
      end

      for target <- [ctx.db, db] do
        assert {:error, _} =
                 DB.query(
                   target,
                   "INSERT INTO artifact_version_floors(artifactId,rowVersion) VALUES ('invalid',?1)",
                   [invalid]
                 )
      end
    end
  end

  @tag artifact_history: true
  test "AL14 actual seed interruption rolls back new floor table and retains R1 rows" do
    db = history_db()
    before = history_rows(db)

    assert {:error, %RuntimeError{message: "seed interrupted"}} =
             DB.transaction(db, fn txn ->
               observer = fn {:sql_query, sql, _params} ->
                 if String.contains?(sql, "INSERT INTO artifact_version_floors") do
                   Tightbeam.DB.Txn.q(txn, sql)

                   assert [[2]] =
                            Tightbeam.DB.Txn.q(
                              txn,
                              "SELECT count(*) FROM artifact_version_floors"
                            )

                   raise "seed interrupted"
                 end
               end

               Artifacts.migrate_version_floors_in_txn(
                 Tightbeam.DB.Txn.observe_queries(txn, observer)
               )
             end)

    assert history_rows(db) == before

    assert {:ok, []} =
             DB.query(db, "SELECT name FROM sqlite_master WHERE name='artifact_version_floors'")

    assert {:ok, [["row-driven-r1-v1-019"]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    refute_receive {:firehose_notice, _}
    assert :ok = Schema.upgrade_firehose_r1(db)
    assert history_rows(db) == before
  end

  @tag artifact_remaining: true
  test "artifact floor seeding and final R1 stamp roll back together" do
    db = history_db()
    before = history_rows(db)
    assert {:ok, reminder} = DB.query(db, "SELECT reminderState FROM assignments")

    :ok =
      DB.execute(
        db,
        "CREATE TRIGGER fail_artifact_stamp BEFORE UPDATE ON schema_stamp BEGIN SELECT RAISE(ABORT,'artifact stamp interruption'); END"
      )

    assert_raise Tightbeam.DB.Error, ~r/artifact stamp interruption/, fn ->
      Schema.upgrade_firehose_r1(db)
    end

    assert history_rows(db) == before
    assert {:ok, ^reminder} = DB.query(db, "SELECT reminderState FROM assignments")

    assert {:ok, []} =
             DB.query(db, "SELECT name FROM sqlite_master WHERE name='artifact_version_floors'")

    assert {:ok, [["row-driven-r1-v1-019"]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    :ok = DB.execute(db, "DROP TRIGGER fail_artifact_stamp")
    assert :ok = Schema.upgrade_firehose_r1(db)
    assert StateResources.query_artifact(db, "archived").row_version == 501
    assert history_rows(db) == before
    assert {:ok, ^reminder} = DB.query(db, "SELECT reminderState FROM assignments")
  end

  defp history_db do
    db = start_supervised!({DB, path: ":memory:", name: nil}, id: :artifact_history_db)
    sql = File.read!(Path.join(__DIR__, "fixtures/r1_o2_v1.sql"))

    assert Base.encode16(:crypto.hash(:sha256, sql), case: :lower) ==
             "065102fc0394262f6a7f3e71f0a8bc021fe02833875e840739c743f6837797bc"

    :ok = DB.execute(db, sql)

    :ok =
      DB.execute(db, """
      ALTER TABLE assignments ADD COLUMN reminderState TEXT NULL;
      ALTER TABLE condition_facts ADD COLUMN payload TEXT NULL;
      UPDATE schema_stamp SET shape='row-driven-r1-v1-019';
      INSERT INTO users(userId,createdAt) VALUES ('fixture',1);
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
        VALUES ('holder','holder','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1);
      INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,reminderState)
        VALUES ('retained','synthetic','holder','fixture',1,'{"phase":"pending"}');
      INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt) VALUES ('work','synthetic','fixture','fixture',1);
      INSERT INTO artifacts(artifactId,kind,title,createdBySession,workItemId,originPath,state,home,createdAt,updatedAt)
        VALUES ('released','report','synthetic','holder','work','synthetic:released','released',NULL,500,600),
               ('archived','report','synthetic','holder','work','synthetic:archived','archived','/synthetic/retained',500,900);
      """)

    :ok =
      Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "synthetic-admin", is_admin: true})

    db
  end

  defp history_rows(db) do
    assert {:ok, rows} = DB.query(db, "SELECT * FROM artifacts ORDER BY artifactId")
    rows
  end

  @tag :tmp_dir
  @tag artifact_remaining: true
  test "AL13 guarded restart recovers lost handoff with creator work-owner and admin grants", %{
    tmp_dir: tmp
  } do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "firehose_artifact_restart.exs",
      "guarded-artifact-lost-handoff: ok"
    )
  end

  defp record(db, path) do
    Artifacts.record(db, %{
      principal: {:session, "al_owner"},
      session_key: "al_owner",
      params: %{kind: "report", title: "AL", origin_path: path, work_item_id: "wi_al"}
    })
  end
end
