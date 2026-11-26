defmodule Tightbeam.WaitLinkScaleTest do
  use Tightbeam.TestCase, async: false

  setup do
    previous = Application.get_env(:tightbeam, :wait_links_enabled)
    Application.put_env(:tightbeam, :wait_links_enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :wait_links_enabled),
        else: Application.put_env(:tightbeam, :wait_links_enabled, previous)
    end)

    :ok
  end

  alias Tightbeam.{DB, Schema, StateResources, WaitLinks}
  @moduletag timeout: 300_000
  @support Path.expand("support/wait_link_scale", __DIR__)

  test "all wait read paths seek without statistics at organization scale" do
    dir = Path.join(System.tmp_dir!(), "wait-scale-#{System.unique_integer([:positive])}")
    prepared = Tightbeam.GuardRuntimeFixture.prepare!(dir, "schema_shape_runtime.exs")
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(prepared.base, "state.db")
    db = :wait_scale_db
    spec = {DB, path: path, name: db, guard_inputs: [], payload_root: prepared.payload}
    start_supervised!(spec)
    :ok = Schema.ensure_all(db)
    stop_supervised!(DB)

    {output, 0} =
      System.cmd("python3", ["-I", Path.join(@support, "seed.py"), path, "base"],
        stderr_to_stdout: true
      )

    info = JSON.decode!(output |> String.split("\n", trim: true) |> List.last())
    assert info["counts"]["assignments"] == 40_800
    assert info["counts"]["wakes"] >= 450_000
    assert info["counts"]["turns"] >= 580_000
    assert info["counts"]["decision_requests"] == 12_000
    assert info["counts"]["assignment_cannot_proceed"] == 12_000
    assert info["counts"]["row_reaction_actions"] == 72_000
    start_supervised!(spec)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM sqlite_master WHERE name='sqlite_stat1'")

    {:ok, [[assignment, item, session]]} =
      DB.query(
        db,
        "SELECT id,workItemId,holderKey FROM assignments WHERE state='open' AND workItemId IS NOT NULL LIMIT 1"
      )

    {:ok, [[decision]]} =
      DB.query(
        db,
        "SELECT id FROM decision_requests WHERE kind='agent' AND status='open' LIMIT 1"
      )

    {:ok, [[wake]]} =
      DB.query(
        db,
        "SELECT wakeId FROM wakes WHERE state='pending' AND resolverKind='assignment' LIMIT 1"
      )

    principal = %{kind: "user", id: "bench", is_admin: true}

    {:ok, [[busy_session, history_count]]} =
      DB.query(
        db,
        "SELECT sessionKey,count(*) n FROM wakes GROUP BY sessionKey ORDER BY n DESC LIMIT 1"
      )

    assert history_count > 20_000
    repro_item = "wi_00000947-0000-4000-8000-000000000947"

    page = fn kind, id ->
      {:ok, request} = WaitLinks.request(%{}, kind, id)
      assert {:ok, _} = WaitLinks.page(db, kind, id, principal, request)
    end

    scenarios =
      [
        {"review-item-page", fn -> page.("work-item", repro_item) end},
        {"review-busy-session", fn -> page.("session", busy_session) end},
        {"summary", fn -> WaitLinks.summaries(db, [item]) end},
        {"waitOn", fn -> StateResources.query_wake(db, %{key: wake, principal: principal}) end},
        {"publish",
         fn ->
           DB.transaction(db, fn txn ->
             {us, result} =
               :timer.tc(fn -> WaitLinks.publish_source_change_in_txn(txn, item, assignment) end)

             IO.puts("WAIT_SCALE_PUBLISH_CALLBACK #{us}us")
             result
           end)
         end},
        {"idle-session",
         fn ->
           id = info["idle_session"]
           {:ok, request} = WaitLinks.request(%{}, "session", id)

           assert {:ok, %{source: %{"running" => false}}} =
                    WaitLinks.page(db, "session", id, principal, request)
         end}
      ] ++
        for {kind, id} <- [
              {"work-item", item},
              {"assignment", assignment},
              {"session", session},
              {"decision", decision}
            ],
            ended <- ["true", "false"] do
          {"#{kind}/#{ended}",
           fn ->
             {:ok, request} = WaitLinks.request(%{"includeEnded" => ended}, kind, id)
             assert {:ok, _} = WaitLinks.page(db, kind, id, principal, request)
           end}
        end

    capture = Path.join(dir, "queries.jsonl")

    for {label, fun} <- scenarios do
      {us, _} = :timer.tc(fun)
      statements = capture(fun)
      {warm_us, _} = :timer.tc(fun)
      IO.puts("WAIT_SCALE_WARM #{label} #{warm_us}us")

      File.write!(
        capture,
        Enum.map(statements, fn {sql, params} ->
          [JSON.encode!(%{scenario: label, sql: sql, params: params}), "\n"]
        end),
        [:append]
      )

      IO.puts("WAIT_SCALE #{label} #{us}us #{length(statements)} statements")
    end

    stop_supervised!(DB)
    library = Path.join(dir, "libscan.so")
    source = Path.expand("deps/exqlite/c_src/sqlite3.c")

    {compile, status} =
      System.cmd(
        "cc",
        [
          "-O2",
          "-shared",
          "-fPIC",
          "-DSQLITE_ENABLE_STMT_SCANSTATUS",
          source,
          "-o",
          library,
          "-lm",
          "-lpthread"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, compile

    {result, status} =
      System.cmd(
        "python3",
        [
          "-I",
          Path.join(@support, "rows.py"),
          library,
          path,
          capture,
          Path.join(dir, "rows.json")
        ],
        stderr_to_stdout: true
      )

    assert status == 0, result <> File.read!(Path.join(dir, "rows.json.plans.txt"))
    IO.puts("WAIT_SCALE_ROWS " <> result)
  end

  defp capture(fun) do
    :erlang.trace_pattern({DB, :run_query, 3}, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    try do
      Task.await(Task.async(fun), :infinity)
      ref = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^ref} -> :ok
      end
    after
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({DB, :run_query, 3}, false, [:local])
    end

    drain([])
  end

  defp drain(acc) do
    receive do
      {:trace, _, :call, {DB, :run_query, [_conn, sql, params]}} ->
        drain([{IO.iodata_to_binary(sql), params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
