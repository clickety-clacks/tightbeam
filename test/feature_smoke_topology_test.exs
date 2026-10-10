defmodule Tightbeam.FeatureSmokeTopologyTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{DB, FeatureSmokeTopology, Gateway, Model, Org, Roles, Rules, Schema, Wakes}
  alias Tightbeam.Wire.Router

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    base = Path.join(System.tmp_dir!(), "smoke-topology-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "identity/rules"))
    on_exit(fn -> File.rm_rf!(base) end)
    register_hosts(db, %{"testhost" => %{ssh: nil, base_dir: base, cli_bin: nil}})
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',1,1)")

    for {key, archetype} <- [
          {Org.personal_session_key("owner"), "default"},
          {"coordinator", "product-owner"},
          {"parent", "orchestrator"},
          {"worker", "coder"},
          {"replacement", "coder"}
        ] do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "owner",
        origin: "user:owner",
        kind: if(key == Org.personal_session_key("owner"), do: "main", else: "custom"),
        archetype: archetype,
        host: "testhost",
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture")
      })

      Roles.create!(db, key, "owner", key)
    end

    handlers = Gateway.handlers(%{db: db, base_dir: base, cwd: base, wake_tick_ms: 1_000})

    # Exact installed rule snapshot that produced marker77f8's refusal, plus
    # shipped engineering admission. These are loaded, not disabled or stubbed.
    for {source, name} <- [
          {"support/fixtures/feature_smoke_topology.toml", "topology.toml"},
          {"support/fixtures/feature_smoke_engineering.toml", "engineering.toml"},
          {"support/fixtures/feature_smoke_verification.toml", "verification.toml"},
          {"../priv/kungfu/agentic-engineering/rules/delivery.toml", "delivery.toml"}
        ] do
      File.cp!(Path.expand(source, __DIR__), Path.join(base, "identity/rules/#{name}"))
    end

    rules = Rules.load!(base, Map.keys(handlers))
    assert Enum.any?(rules, &(&1.name == "assign-worker-staffing-needs-topology"))
    assert Enum.any?(rules, &(&1.name == "dispatch-worker-staffing-needs-topology"))

    opts = Router.init(db: db, handlers: handlers, cli_token: "tbc_test", base_dir: base)
    %{db: db, opts: opts}
  end

  test "actual fixture setup admits assign and dispatch while another item still refuses", ctx do
    call = fn verb, params -> ok!(ctx, nil, verb, params) end
    call_as = fn key, verb, params -> ok!(ctx, key, verb, params) end
    wi = call.("work-item-create", %{"title" => "synthetic staffing"})["id"]
    other = call.("work-item-create", %{"title" => "unprepared control"})["id"]

    # An owner link alone must not substitute for returned topology.
    for item <- [wi, other] do
      call.("work-item-update", %{
        "workItemId" => item,
        "deliveryOwnerSessionKey" => "coordinator"
      })

      assert_refused(ctx, item)
    end

    FeatureSmokeTopology.prepare!(
      call,
      call_as,
      wi,
      %{"sessionKey" => "coordinator"},
      "One holder per tested staffing verb"
    )

    for verb <- ["assign", "dispatch"] do
      assigned = call.(verb, staffing(wi))
      assert is_binary(assigned["id"])
      assert assigned["holderKey"] == "worker"
      assert assigned["workItemId"] == wi
      assert assigned["effectKind"] != "coordination"
      readback = call.("assignment-get", %{"assignmentId" => assigned["id"]})
      assert readback["id"] == assigned["id"]

      if verb == "dispatch" do
        assert {:ok, [[1]]} =
                 DB.query(
                   ctx.db,
                   "SELECT count(*) FROM turns WHERE assignmentId=?1 AND status='queued'",
                   [
                     assigned["id"]
                   ]
                 )
      end
    end

    assert {:ok, [["coordination", "coordinator", "coordinator", note]]} =
             DB.query(
               ctx.db,
               """
               SELECT e.effectKind,s.holderKey,a.bySession,a.note FROM assignments s
               JOIN assignment_effects e ON e.assignmentId=s.id
               JOIN attests a ON a.assignmentId=s.id
               WHERE s.workItemId=?1 AND a.verdictKind='topology-decided'
               """,
               [wi]
             )

    assert note =~ "not a provider consultation"
    assert_refused(ctx, other)
  end

  test "effort parent keeps its identity, item, and real rumination before both dispatches",
       ctx do
    call = fn verb, params -> ok!(ctx, nil, verb, params) end
    call_as = fn key, verb, params -> ok!(ctx, key, verb, params) end
    wi = call.("work-item-create", %{"title" => "synthetic effort staffing"})["id"]

    FeatureSmokeTopology.prepare!(
      call,
      call_as,
      wi,
      %{"sessionKey" => "coordinator"},
      "One parent replaces its first holder",
      "parent"
    )

    assert %{"ruminationRequired" => true} = call_as.("parent", "dispatch", staffing(wi))

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM assignments WHERE workItemId=?1 AND holderKey='worker'",
               [wi]
             )

    # Own the real normal-path local publication/doorbell dependencies. No
    # provider is started and no topology or wake rows are stamped by SQL.
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         name: nil,
         tick_ms: 60_000,
         deliver: fn _ -> flunk("normal rumination used legacy callback") end}
      )

    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.rumination_exists?(ctx.db, wi, "parent")

    assert {:ok, [[source_id, prompt, "fired"]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId,prompt,state FROM wakes WHERE rumination=1 AND work_item_id=?1 AND creatorSessionKey='parent'",
               [wi]
             )

    assert [%{delivery_wake_id: carrier_id, member_state: "included", batch_state: "delivered"}] =
             Tightbeam.NoticeBatcher.source_refs(ctx.db, source_id)

    assert {:ok, [["parent", "queued", content]]} =
             DB.query(
               ctx.db,
               "SELECT t.sessionKey,t.status,m.content FROM turns t JOIN messages m ON m.id=t.messageId WHERE t.wakeId=?1",
               [carrier_id]
             )

    assert content =~ source_id
    assert content =~ prompt

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM turns WHERE wakeId=?1", [source_id])

    first = call_as.("parent", "dispatch", staffing(wi))
    second = call_as.("parent", "dispatch", Map.put(staffing(wi), "sessionKey", "replacement"))
    assert first["id"] != second["id"]

    for assigned <- [first, second] do
      assert assigned["workItemId"] == wi
      assert assigned["openedBySession"] == "parent"
    end
  end

  test "topology alone does not waive the real coder posture gate", ctx do
    call = fn verb, params -> ok!(ctx, nil, verb, params) end
    wi = call.("work-item-create", %{"title" => "posture negative control"})["id"]

    coordinator =
      call.("assign", %{
        "sessionKey" => "coordinator",
        "workItemId" => wi,
        "subject" => "fixture coordination",
        "effectKind" => "coordination"
      })

    call.("work-item-update", %{"workItemId" => wi, "deliveryOwnerSessionKey" => "coordinator"})

    ok!(ctx, "coordinator", "attest", %{
      "assignmentId" => coordinator["id"],
      "kind" => "verdict",
      "verdictKind" => "topology-decided",
      "note" => "One synthetic worker, no provider claim"
    })

    for verb <- ["assign", "dispatch"] do
      refused = wire(ctx, nil, verb, staffing(wi))
      assert refused["error"]["code"] == "rule_denied"
      assert refused["error"]["message"] =~ "posture"
    end
  end

  test "every smoke staffing fixture prepares topology before its worker call" do
    source = File.read!(Path.expand("../scripts/feature_smoke.exs", __DIR__))

    {_, functions} =
      Macro.prewalk(Code.string_to_quoted!(source), %{}, fn
        {:defp, _, [{name, _, _}, body]} = node, functions ->
          {node, Map.put(functions, name, body)}

        node, functions ->
          {node, functions}
      end)

    for name <- [
          :open_grounded_assignment!,
          :check_work_item_and_assignment_get,
          :check_dispatch_opens_assignment,
          :check_effort_without_effect
        ] do
      {_, calls} =
        Macro.prewalk(Map.fetch!(functions, name), [], fn
          {:prepare_fixture_topology!, meta, _} = node, calls ->
            {node, [{:prepare, meta[:line]} | calls]}

          {:ok!, meta, [_, verb, {:%{}, _, fields}]} = node, calls
          when verb in ["assign", "dispatch"] ->
            assert List.keyfind(fields, "workItemId", 0)
            {node, [{:staff, meta[:line]} | calls]}

          {:dispatch_after_rumination!, meta, [_, _, {:%{}, _, fields}]} = node, calls ->
            assert List.keyfind(fields, "workItemId", 0)
            {node, [{:staff, meta[:line]} | calls]}

          node, calls ->
            {node, calls}
        end)

      assert [{:prepare, prepared_at}] = Enum.filter(calls, &(elem(&1, 0) == :prepare))
      staffing = Enum.filter(calls, &(elem(&1, 0) == :staff))
      assert length(staffing) == if(name == :check_effort_without_effect, do: 2, else: 1)
      assert Enum.all?(staffing, fn {:staff, line} -> prepared_at < line end)
    end
  end

  defp staffing(wi),
    do: %{
      "sessionKey" => "worker",
      "workItemId" => wi,
      "subject" => "exercise worker staffing",
      "brief" => "Synthetic fixture only"
    }

  defp assert_refused(ctx, wi) do
    for verb <- ["assign", "dispatch"] do
      response = wire(ctx, nil, verb, staffing(wi))
      assert response["error"]["code"] == "rule_denied"
      assert response["error"]["message"] =~ "topology"
    end
  end

  defp ok!(ctx, session, verb, params) do
    response = wire(ctx, session, verb, params)
    refute response["error"], inspect(response)
    response["result"] || response
  end

  defp wire(ctx, session, verb, params) do
    {target, params} =
      if verb in ~w(assign dispatch), do: Map.split(params, ["sessionKey"]), else: {%{}, params}

    body = Map.merge(%{"verb" => verb, "params" => params}, target)
    body = if session, do: body, else: Map.put(body, "asUser", "owner")
    token = if session, do: Org.get(ctx.db, session).cli_token, else: "tbc_test"

    conn(:post, "/agent/dispatch", JSON.encode!(body))
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
    |> Router.call(ctx.opts)
    |> Map.fetch!(:resp_body)
    |> JSON.decode!()
  end
end
