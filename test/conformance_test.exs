defmodule Tightbeam.ConformanceSupport do
  import ExUnit.Assertions

  alias Tightbeam.{
    Assignments,
    DB,
    Devices,
    Dispatch,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    Org,
    Producers,
    Rails,
    Roles,
    Rules,
    Supervision,
    Wakes,
    WorkItems,
    WorkState
  }

  @fixture_keys MapSet.new(
                  ~w(class name phase blocking_phase kind source legibility shipped_ref pattern rule)
                )
  @case_keys MapSet.new(
               ~w(case kind expect reason emits input script_return world call phase2 note)
             )
  @expects MapSet.new(
             ~w(deny pass refuse run-remedy re-obligate escalate-park none escalate-halt escalate-open escalate-continue load-raise load-clean)
           )
  @world_keys MapSet.new(
                ~w(users sessions roles work_items assignments attests producer_verdict retune producer_job adjudicate adjudication_episode ledger wakes turn)
              )
  @world_shapes %{
    "users" => ~w(id admin),
    "sessions" => ~w(key owner archetype harness provider host model adjudicationHold),
    "roles" => ~w(name session),
    "work_items" => ~w(id title),
    "assignments" => ~w(id holder creator reviews files),
    "attests" => ~w(assignment kind by verdict_kind),
    "producer_verdict" => ~w(assignment verdict_kind producer producerCommand),
    "retune" => ~w(session harness provider),
    "producer_job" => ~w(verb assignment state),
    "adjudicate" => ~w(session hold),
    "adjudication_episode" => ~w(session status),
    "ledger" => ~w(session pending),
    "wakes" => ~w(target creatorSessionKey at),
    "turn" => ~w(session seq window_start)
  }

  def corpus_root do
    case System.argv() do
      argv ->
        case Enum.find_index(argv, &(&1 == "--corpus")) do
          nil -> Path.expand("test/conformance")
          index -> argv |> Enum.fetch!(index + 1) |> Path.expand()
        end
    end
  end

  def load_corpus!(root) do
    manifest = decode_toml!(Path.join(root, "manifest.toml"))
    classes = Map.fetch!(manifest, "class")

    fixtures =
      Enum.flat_map(classes, fn class ->
        dir = Path.join(root, Map.fetch!(class, "dir"))

        ordinary =
          dir
          |> Path.join("*.toml")
          |> Path.wildcard()
          |> Enum.reject(&String.ends_with?(&1, ".load.toml"))
          |> Enum.map(&load_fixture!(&1, class))

        loads =
          dir
          |> Path.join("*.load.toml")
          |> Path.wildcard()
          |> Enum.map(&load_loadset!(&1, class))

        ordinary ++ loads
      end)

    %{classes: classes, fixtures: fixtures}
  end

  defp load_fixture!(path, class) do
    fixture = path |> decode_toml!() |> Map.fetch!("fixture")
    reject_unknown!(fixture, @fixture_keys, "#{path} fixture")

    for key <- ~w(class name phase blocking_phase kind source legibility) do
      assert Map.has_key?(fixture, key), "#{path}: missing fixture.#{key}"
    end

    assert fixture["class"] == class["id"], "#{path}: fixture class does not match manifest"

    assert fixture["phase"] in ~w(green pending pending-unhomed pending-runtime),
           "#{path}: invalid phase"

    cases_path = String.replace_suffix(path, ".toml", ".cases.jsonl")
    cases = load_cases!(cases_path, fixture)

    fixture
    |> Map.put("path", path)
    |> Map.put("cases", cases)
    |> Map.put("runners", applicable_runners(fixture["kind"], class["runners"]))
  end

  defp applicable_runners("dispatch-rule", runners),
    do: Enum.filter(runners, &(&1 == "rules_evaluate"))

  defp applicable_runners("handler-refusal", runners),
    do: Enum.filter(runners, &(&1 == "handler_refusal"))

  defp applicable_runners(_kind, runners), do: runners

  defp load_loadset!(path, class) do
    loadset = path |> decode_toml!() |> Map.fetch!("loadset")
    allowed = MapSet.new(~w(name class phase blocking_phase outcome must_name error_match source))
    reject_unknown!(loadset, allowed, "#{path} loadset")

    for key <- ~w(name class phase blocking_phase outcome source) do
      assert Map.has_key?(loadset, key), "#{path}: missing loadset.#{key}"
    end

    assert loadset["class"] == class["id"]
    assert loadset["outcome"] in ~w(load-raise load-clean)

    loadset
    |> Map.put("kind", "load-rejection")
    |> Map.put("path", path)
    |> Map.put("loadset_dir", String.replace_suffix(path, ".load.toml", ".loadset"))
    |> Map.put("runners", class["runners"])
  end

  defp load_cases!(path, fixture) do
    cases =
      path
      |> File.stream!([], :line)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&JSON.decode!/1)

    assert cases != [], "#{path}: case-based fixture has no cases"
    assert Enum.uniq_by(cases, & &1["case"]) == cases, "#{path}: duplicate case id"

    Enum.each(cases, fn kase ->
      reject_unknown!(kase, @case_keys, "#{path} case")

      for key <- ~w(case kind expect),
          do: assert(Map.has_key?(kase, key), "#{path}: missing #{key}")

      assert kase["kind"] in ~w(positive negative legibility), "#{path}: invalid case kind"
      assert MapSet.member?(@expects, kase["expect"]), "#{path}: invalid expect"

      if kase["kind"] in ~w(positive legibility),
        do: assert(is_binary(kase["reason"]), "#{path}: positive/legibility case needs reason")

      if kase["kind"] == "legibility",
        do: assert(is_binary(kase["emits"]), "#{path}: legibility case needs emits")

      if fixture["kind"] == "harness-gate",
        do: assert(is_binary(kase["input"]), "#{path}: harness case needs input")

      validate_world!(Map.get(kase, "world", %{}), path)
      validate_call!(Map.get(kase, "call"), fixture["kind"], path)
      validate_phase2!(Map.get(kase, "phase2"), path)
    end)

    assert Enum.any?(cases, &(&1["kind"] == "positive")), "#{path}: missing positive case"
    assert Enum.any?(cases, &(&1["kind"] == "negative")), "#{path}: missing negative case"
    assert Enum.any?(cases, &(&1["kind"] == "legibility")), "#{path}: missing legibility case"
    cases
  end

  defp validate_world!(world, path) when is_map(world) do
    reject_unknown!(world, @world_keys, "#{path} world")

    Enum.each(world, fn {key, rows} ->
      rows = if key in ~w(adjudicate ledger turn), do: List.wrap(rows), else: rows
      assert is_list(rows), "#{path}: world.#{key} must be a row or row list"

      Enum.each(rows, fn row ->
        assert is_map(row), "#{path}: world.#{key} row must be an object"
        reject_unknown!(row, MapSet.new(Map.fetch!(@world_shapes, key)), "#{path} world.#{key}")
      end)
    end)
  end

  defp validate_world!(_world, path), do: flunk("#{path}: world must be an object")

  defp validate_call!(nil, "harness-gate", _path), do: :ok
  defp validate_call!(nil, _kind, path), do: flunk("#{path}: non-harness case needs call")

  defp validate_call!(call, _kind, path) when is_map(call) do
    reject_unknown!(call, MapSet.new(~w(verb principal params session_key)), "#{path} call")
    assert is_binary(call["verb"]), "#{path}: call.verb must be a string"
    assert is_map(call["params"]), "#{path}: call.params must be an object"
  end

  defp validate_call!(_call, _kind, path), do: flunk("#{path}: call must be an object")

  defp validate_phase2!(nil, _path), do: :ok

  defp validate_phase2!(phase2, path) when is_map(phase2) do
    reject_unknown!(phase2, MapSet.new(~w(world call expect)), "#{path} phase2")
    if phase2["world"], do: validate_world!(phase2["world"], path)
    if phase2["call"], do: validate_call!(phase2["call"], "dispatch-rule", path)
    if phase2["expect"], do: assert(MapSet.member?(@expects, phase2["expect"]))
  end

  defp validate_phase2!(_phase2, path), do: flunk("#{path}: phase2 must be an object")

  defp reject_unknown!(map, allowed, label) do
    unknown = map |> Map.keys() |> MapSet.new() |> MapSet.difference(allowed) |> Enum.sort()
    assert unknown == [], "#{label}: unknown keys #{Enum.join(unknown, ", ")}"
  end

  defp decode_toml!(path), do: path |> File.read!() |> Toml.decode!()

  def shipped_statutes(root) do
    path = Path.expand("../../priv/kungfu/agentic-engineering/rails/engineering.toml", root)
    path |> decode_toml!() |> Map.fetch!("statute")
  end

  def compiled_shipped_entries(root) do
    source = Path.expand("../../priv/kungfu/agentic-engineering/rails/engineering.toml", root)
    base = temp_dir!("conformance-rails")
    rails_dir = Path.join(base, "identity/rails")
    File.mkdir_p!(rails_dir)
    File.cp!(source, Path.join(rails_dir, "engineering.toml"))
    Rails.load!(base)
    %{"hooks" => %{"PreToolUse" => entries}} = Rails.hook_settings()
    {entries, base}
  end

  def run_compiled_hook_fixture(fixture, root) do
    {entries, base} = compiled_shipped_entries(root)

    try do
      Enum.each(fixture["cases"], fn kase ->
        results = Enum.map(entries, &run_hook(&1, kase["input"]))

        case kase["expect"] do
          "pass" ->
            assert Enum.all?(results, fn {_entry, _output, status} -> status == 0 end),
                   kase["case"]

          "deny" ->
            marker = "[gate: #{kase["reason"]}]"

            assert Enum.any?(results, fn {_entry, output, status} ->
                     status == 2 and output =~ marker
                   end),
                   kase["case"]
        end
      end)
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rails)
    end
  end

  defp run_hook(entry, input) do
    [%{"command" => command}] = entry["hooks"]

    {output, status} =
      System.cmd("sh", ["-c", "printf '%s' \"$TB_CONFORMANCE_INPUT\" | " <> command],
        env: [{"TB_CONFORMANCE_INPUT", input}],
        stderr_to_stdout: true
      )

    {entry, output, status}
  end

  def assert_shipped_parity(fixtures, root) do
    statutes = shipped_statutes(root)

    Enum.each(statutes, fn statute ->
      ref = "engineering.toml:#{statute["name"]}"
      matches = Enum.filter(fixtures, &(&1["shipped_ref"] == ref))
      assert matches != [], "shipped statute #{statute["name"]} has no C1 fixture"
      assert Enum.all?(matches, &(&1["pattern"] == statute["pattern"])), "#{ref} pattern drift"
    end)
  end

  def assert_claude_wiring(root) do
    {entries, base} = compiled_shipped_entries(root)
    probe = Rails.probe_entry()
    settings = %{"hooks" => %{"PreToolUse" => entries ++ [probe]}}

    try do
      assert probe in settings["hooks"]["PreToolUse"]
      {_entry, output, status} = run_hook(probe, "tightbeam-gate-probe")
      assert status == 2
      assert output =~ "[gate: tightbeam-probe]"
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rails)
    end
  end

  def run_rules_fixture(fixture) do
    base = temp_dir!("conformance-rules")
    rules_dir = Path.join(base, "identity/rules")
    File.mkdir_p!(rules_dir)
    File.write!(Path.join(rules_dir, "fixture.toml"), serialize_rules(fixture["rule"]))
    handlers = Gateway.handlers(%{})
    Rules.load!(base, Map.keys(handlers))

    try do
      Enum.each(fixture["cases"], &run_rule_case(fixture, &1, handlers))
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  defp run_rule_case(fixture, kase, handlers) do
    {db, pid} = memory_db!()

    try do
      ids = materialize_world(db, Map.get(kase, "world", %{}))
      assert_fixture_world(fixture, kase, db, ids)
      call = build_call(kase["call"], ids)
      assert_rule_result(kase["case"], kase["expect"], kase["reason"], Rules.evaluate(db, call))

      if kase["kind"] == "legibility" do
        assert {:error, %{rule: reason}} = Dispatch.dispatch(db, handlers, call)
        assert reason == kase["reason"]

        assert {:ok, [["denied", payload]]} =
                 DB.query(db, "SELECT kind, payload FROM events ORDER BY id DESC LIMIT 1")

        assert JSON.decode!(payload)["rule"] == kase["reason"]

        assert [%{rule: rule, edge: "verb", reason: "rule_denied"}] =
                 EventLog.rail_denials(db, 0, 1)

        assert rule == kase["reason"]
      end

      if phase2 = kase["phase2"] do
        ids = materialize_world(db, Map.get(phase2, "world", %{}), ids)
        phase2_call = build_call(phase2["call"] || kase["call"], ids)

        assert_rule_result(
          "#{kase["case"]} phase2",
          phase2["expect"] || kase["expect"],
          kase["reason"],
          Rules.evaluate(db, phase2_call)
        )
      end
    after
      GenServer.stop(pid)
    end
  end

  defp assert_rule_result(_case, "deny", reason, {:deny, %{rule: actual}}),
    do: assert(actual == reason)

  defp assert_rule_result(_case, "pass", _reason, :ok), do: :ok

  defp assert_rule_result(case_id, expect, _reason, actual),
    do: flunk("#{case_id}: expected #{expect}, got #{inspect(actual)}")

  defp assert_fixture_world(%{"name" => "orphaned-running-failed"}, kase, db, ids) do
    :ok = Producers.recover(db)

    Enum.each(ids.producer_jobs, fn {_key, job_id} ->
      job = Producers.get(db, job_id)

      if kase["expect"] == "deny" do
        assert job.state == "failed"
        assert Assignments.list_attests(db, job.assignment_id) == []

        assert Enum.any?(EventLog.lifecycle_events(db), fn event ->
                 event.kind == "producer_failed" and event.subject == job.assignment_id and
                   event.detail =~ "orphaned"
               end)
      else
        assert job.state == "done"
        assert length(Assignments.list_attests(db, job.assignment_id)) == 1
      end
    end)
  end

  defp assert_fixture_world(_fixture, _kase, _db, _ids), do: :ok

  def run_handler_refusal_fixture(fixture) do
    Enum.each(fixture["cases"], fn kase ->
      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, Map.get(kase, "world", %{}))
        call = build_call(kase["call"], ids)
        handlers = Gateway.handlers(%{db: db})
        {:ok, [[before_count]]} = DB.query(db, "SELECT count(*) FROM assignments")
        overlap? = Assignments.open_assignments_touching(db, call.params[:files] || []) != []

        if String.contains?(kase["case"], "concurrent") do
          results =
            1..2
            |> Enum.map(fn _ -> Task.async(fn -> Dispatch.dispatch(db, handlers, call) end) end)
            |> Task.await_many()

          {:ok, [[after_count]]} = DB.query(db, "SELECT count(*) FROM assignments")
          assert Enum.count(results, &match?({:ok, _}, &1)) == 1
          assert Enum.count(results, &match?({:error, %{code: "files_overlap"}}, &1)) == 1
          assert after_count == before_count + 1
        else
          result = Dispatch.dispatch(db, handlers, call)
          {:ok, [[after_count]]} = DB.query(db, "SELECT count(*) FROM assignments")

          case kase["expect"] do
            "refuse" ->
              assert overlap?
              assert {:error, %{code: code}} = result
              assert code == kase["reason"]
              assert after_count == before_count

            "pass" ->
              refute overlap?
              assert {:ok, _} = result
              assert after_count == before_count + 1
          end
        end
      after
        GenServer.stop(pid)
      end
    end)
  end

  def run_load_assert(loadset) do
    base = temp_dir!("conformance-load")
    rules_dir = Path.join(base, "identity/rules")
    File.mkdir_p!(rules_dir)

    loadset["loadset_dir"]
    |> Path.join("*.toml")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "producers.toml"))
    |> Enum.each(&File.cp!(&1, Path.join(rules_dir, Path.basename(&1))))

    try do
      outcome =
        try do
          Rules.load!(base, Map.keys(Gateway.handlers(%{})))
          :clean
        rescue
          error in ArgumentError -> {:raise, Exception.message(error)}
        end

      case {loadset["outcome"], outcome} do
        {"load-clean", :clean} ->
          :ok

        {"load-raise", {:raise, message}} ->
          assert message =~ loadset["error_match"]
          Enum.each(loadset["must_name"], &assert(message =~ &1))

        expected ->
          flunk("load assertion mismatch: #{inspect(expected)}")
      end
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  def run_rules_decide(_fixture),
    do: flunk("rules_decide fixture was enabled before Tightbeam.Rules.decide/2 landed")

  def run_acting_layer(_fixture),
    do: flunk("acting_layer fixture was enabled before the C6/C7 acting APIs landed")

  defp memory_db! do
    name = :"conformance_db_#{System.unique_integer([:positive])}"
    {:ok, pid} = DB.start_link(path: ":memory:", name: name)

    for module <- [
          Devices,
          Idempotency,
          Org,
          Roles,
          WorkItems,
          Assignments,
          WorkState,
          EventLog,
          Producers,
          Ledger,
          Wakes,
          Supervision
        ] do
      :ok = module.ensure_schema(name)
    end

    {name, pid}
  end

  defp materialize_world(
         db,
         world,
         ids \\ %{assignments: %{}, work_items: %{}, producer_jobs: %{}}
       ) do
    Enum.each(Map.get(world, "users", []), fn user ->
      {:ok, _} =
        DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES (?1, ?2, 1)", [
          user["id"],
          if(user["admin"], do: 1, else: 0)
        ])
    end)

    Enum.each(Map.get(world, "sessions", []), fn session ->
      Org.create(db, %{
        session_key: session["key"],
        display_name: session["key"],
        owner_user_id: session["owner"],
        origin: "user:#{session["owner"]}",
        archetype: session["archetype"],
        harness: session["harness"] || "claude",
        provider: session["provider"] || "anthropic",
        model: session["model"] || "fable",
        host: session["host"] || "eezo"
      })

      Roles.create!(db, session["key"], session["owner"], session["key"])
    end)

    Enum.each(Map.get(world, "roles", []), fn role ->
      owner = Org.get(db, role["session"]).owner_user_id

      if Roles.get(db, role["name"]),
        do: Roles.bind(db, role["name"], role["session"]),
        else: Roles.create!(db, role["name"], owner, role["session"])
    end)

    work_items =
      Enum.reduce(Map.get(world, "work_items", []), ids.work_items, fn item, item_ids ->
        result =
          WorkItems.__handle__(db, "work-item-create", %{
            principal: {:user, first_user(world)},
            params: %{title: item["title"]}
          })

        Map.put(item_ids, item["id"], result.id)
      end)

    assignments =
      Enum.reduce(Map.get(world, "assignments", []), ids.assignments, fn assignment,
                                                                         assignment_ids ->
        principal =
          principal(
            assignment["creator"] || ["user", Org.get(db, assignment["holder"]).owner_user_id]
          )

        result =
          Assignments.__handle__(db, "assign", %{
            verb: "assign",
            origin: origin(principal),
            principal: principal,
            session_key: assignment["holder"],
            target_role: nil,
            role_fallback: false,
            params: %{
              subject: assignment["id"],
              idempotency_key: nil,
              reviews_assignment_id: assignment_ids[assignment["reviews"]],
              work_item_id: work_items[assignment["work_item"]],
              files: assignment["files"]
            }
          })

        assert is_binary(result.id),
               "failed to materialize assignment #{assignment["id"]}: #{inspect(result)}"

        Map.put(assignment_ids, assignment["id"], result.id)
      end)

    Enum.each(Map.get(world, "attests", []), fn attest ->
      by = principal(attest["by"])

      result =
        Assignments.__handle__(db, "attest", %{
          verb: "attest",
          origin: origin(by),
          principal: by,
          session_key: nil,
          params: %{
            assignment_id: assignments[attest["assignment"]],
            kind: attest["kind"],
            verdict_kind: attest["verdict_kind"]
          }
        })

      refute Map.has_key?(result, :code), "failed to materialize attest: #{inspect(result)}"
    end)

    Enum.each(Map.get(world, "producer_verdict", []), fn verdict ->
      {:ok, {:ok, _}} =
        DB.transaction(db, fn txn ->
          Assignments.insert_producer_verdict_in_txn(txn, %{
            assignment_id: assignments[verdict["assignment"]],
            verdict_kind: verdict["verdict_kind"],
            producer: verdict["producer"],
            producer_command: verdict["producerCommand"],
            by_session: nil,
            by_user: nil,
            by_harness: nil,
            by_provider: nil
          })
        end)
    end)

    Enum.each(Map.get(world, "retune", []), fn retune ->
      fields =
        Enum.filter(
          [{"harness", retune["harness"]}, {"provider", retune["provider"]}],
          &elem(&1, 1)
        )

      Enum.each(fields, fn {column, value} ->
        {:ok, _} =
          DB.query(db, "UPDATE sessions SET #{column} = ?2 WHERE sessionKey = ?1", [
            retune["session"],
            value
          ])
      end)
    end)

    producer_jobs =
      Enum.reduce(Map.get(world, "producer_job", []), ids.producer_jobs, fn producer_job,
                                                                            job_ids ->
        assignment_id = assignments[producer_job["assignment"]]
        key = {producer_job["verb"], producer_job["assignment"]}

        {:ok, [[holder]]} =
          DB.query(db, "SELECT holderKey FROM assignments WHERE id = ?1", [assignment_id])

        job_id =
          case Map.fetch(job_ids, key) do
            {:ok, existing} ->
              existing

            :error ->
              assert %{queued: queued} =
                       Producers.__handle__(
                         db,
                         producer_job["verb"],
                         %{
                           principal: {:session, holder},
                           params: %{assignment_id: assignment_id}
                         },
                         config: %{tests: "true", smoke: "true", timeout_ms: 5_000}
                       )

              queued
          end

        transition_producer_job(db, job_id, producer_job["state"], holder)
        Map.put(job_ids, key, job_id)
      end)

    Enum.each(List.wrap(Map.get(world, "ledger", [])), fn ledger ->
      if ledger["pending"] > 0 do
        Enum.each(1..ledger["pending"], fn ordinal ->
          assert {:ok, _seq} =
                   Ledger.enqueue(db, %{
                     session_key: ledger["session"],
                     message_id: "conformance-#{ordinal}-#{System.unique_integer([:positive])}",
                     origin: "process:conformance",
                     prompt: "pending",
                     wake_id: nil
                   })
        end)
      end
    end)

    %{assignments: assignments, work_items: work_items, producer_jobs: producer_jobs}
  end

  defp transition_producer_job(_db, _job_id, "queued", _holder), do: :ok

  defp transition_producer_job(db, job_id, "cancelled", holder) do
    assert %{cancelled: ^job_id} =
             Producers.__handle__(db, "cancel-producer-job", %{
               principal: {:session, holder},
               params: %{job_id: job_id}
             })

    assert Producers.get(db, job_id).state == "cancelled"
  end

  defp transition_producer_job(db, job_id, state, _holder)
       when state in ~w(running done failed) do
    job = Producers.get(db, job_id)
    job = if job.state == "queued", do: Producers.claim_next(db), else: job
    assert job.id == job_id

    case state do
      "running" ->
        assert Producers.get(db, job_id).state == "running"

      "failed" ->
        assert Producers.fail_running(db, job_id, "conformance fixture") == :failed
        assert Assignments.list_attests(db, job.assignment_id) == []

      "done" ->
        assert finish_producer_job(db, job) == :done
        assert finish_producer_job(db, job) == :noop
        assert Producers.fail_running(db, job_id, "losing failure") == :noop
        assert [verdict] = Assignments.list_attests(db, job.assignment_id)
        assert verdict.byHarness == job.by_harness
        assert verdict.byProvider == job.by_provider
        assert verdict.producer == job.producer
        assert verdict.producerCommand == job.command
    end
  end

  defp finish_producer_job(db, job) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        Tightbeam.DB.Txn.q(
          txn,
          "UPDATE producer_jobs SET state = 'done' WHERE id = ?1 AND state = 'running'",
          [job.id]
        )

        if Tightbeam.DB.Txn.changes(txn) == 1 do
          {:ok, _} =
            Assignments.insert_producer_verdict_in_txn(txn, %{
              assignment_id: job.assignment_id,
              verdict_kind: job.verdict_kind,
              producer: job.producer,
              producer_command: job.command,
              by_session: job.by_session,
              by_user: job.by_user,
              by_harness: job.by_harness,
              by_provider: job.by_provider
            })

          :done
        else
          :noop
        end
      end)

    result
  end

  defp first_user(world), do: world |> Map.get("users", []) |> List.first() |> Map.fetch!("id")

  defp build_call(raw, ids) do
    principal = principal(raw["principal"])
    params = atomize(raw["params"])

    params =
      if params[:assignment_id],
        do: %{params | assignment_id: ids.assignments[params.assignment_id]},
        else: params

    params =
      if params[:reviews_assignment_id],
        do: %{params | reviews_assignment_id: ids.assignments[params.reviews_assignment_id]},
        else: params

    call = %{
      verb: raw["verb"],
      origin: origin(principal),
      principal: principal,
      session_key: raw["session_key"],
      params: params
    }

    if raw["verb"] == "assign",
      do: Map.merge(call, %{target_role: nil, role_fallback: false}),
      else: call
  end

  defp principal(nil), do: nil
  defp principal(["session", value]), do: {:session, value}
  defp principal(["user", value]), do: {:user, value}
  defp principal(["process", value]), do: {:process, value}

  defp origin({:session, value}), do: "agent:#{value}"
  defp origin({:user, value}), do: "user:#{value}"
  defp origin({:process, value}), do: "process:#{value}"
  defp origin(nil), do: "agent:declared"

  defp atomize(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {String.to_atom(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp serialize_rules(rules) do
    Enum.map_join(rules, "\n", fn rule ->
      conditions = Enum.map_join(rule["deny_when"], ",\n  ", &toml_inline/1)

      """
      [[rule]]
      name = #{toml_value(rule["name"])}
      verb = #{toml_value(rule["verb"])}
      text = #{toml_value(rule["text"])}
      deny_when = [
        #{conditions}
      ]
      """
    end)
  end

  defp toml_inline(map) do
    "{ " <>
      Enum.map_join(map, ", ", fn {key, value} -> "#{key} = #{toml_value(value)}" end) <> " }"
  end

  defp toml_value(value) when is_binary(value), do: inspect(value)
  defp toml_value(value) when is_boolean(value) or is_integer(value), do: to_string(value)

  defp toml_value(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ", ", &toml_value/1) <> "]"

  defp temp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end

defmodule Tightbeam.ConformanceTest do
  use ExUnit.Case, async: false

  alias Tightbeam.ConformanceSupport, as: Corpus

  @root Corpus.corpus_root()
  @corpus Corpus.load_corpus!(@root)
  @fixtures @corpus.fixtures
  @classes @corpus.classes

  test "pending census" do
    green = Enum.count(@fixtures, &(&1["phase"] == "green"))
    pending = length(@fixtures) - green

    structured =
      Enum.count(@fixtures, &(&1["phase"] == "green" and &1["kind"] == "dispatch-rule"))

    class_pending = Enum.count(@classes, &(&1["phase"] == "pending"))

    IO.puts(
      "conformance census: #{green} green fixtures; #{pending} pending fixtures; " <>
        "#{structured} structured-legibility assertion sets active; #{class_pending} pending classes"
    )

    assert green == 23
    assert pending == 3
  end

  test "c1-shipped-parity reads canonical priv law" do
    Corpus.assert_shipped_parity(Enum.filter(@fixtures, &(&1["class"] == "C1")), @root)
  end

  test "c1-wiring-claude compiles and refuses the reserved probe" do
    Corpus.assert_claude_wiring(@root)
  end

  test "containment write-wall dependency is present" do
    assert File.regular?(Path.expand("../containment_test.exs", @root))
  end

  for fixture <- @fixtures do
    name = "#{fixture["class"]}/#{fixture["name"]}"

    if fixture["phase"] == "green" do
      test name do
        fixture = unquote(Macro.escape(fixture))

        Enum.each(fixture["runners"], fn
          "compiled_hook_grep" -> Corpus.run_compiled_hook_fixture(fixture, @root)
          "rules_evaluate" -> Corpus.run_rules_fixture(fixture)
          "handler_refusal" -> Corpus.run_handler_refusal_fixture(fixture)
          "load_assert" -> Corpus.run_load_assert(fixture)
          "rules_decide" -> Corpus.run_rules_decide(fixture)
          "acting_layer" -> Corpus.run_acting_layer(fixture)
        end)
      end

      if fixture["kind"] == "dispatch-rule" do
        test "#{name} structured legibility" do
          fixture = unquote(Macro.escape(fixture))
          Corpus.run_rules_fixture(fixture)
        end
      end
    else
      @tag skip: "#{fixture["phase"]}: #{fixture["blocking_phase"]}"
      test name do
        _fixture = unquote(Macro.escape(fixture))
      end
    end
  end

  for class <- @classes, class["phase"] == "pending" do
    @tag skip: "#{class["blocking_phase"]}: #{class["title"]} fixtures land on their own lane"
    test "#{class["id"]} class registered pending" do
      _class = unquote(Macro.escape(class))
    end
  end
end
