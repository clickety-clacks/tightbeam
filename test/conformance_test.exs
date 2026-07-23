defmodule Tightbeam.ConformanceProducerRegistry do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, %{})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:register_process, job_id, port, os_pid}, _from, state) do
    {:reply, :ok, Map.put(state, job_id, %{port: port, os_pid: os_pid})}
  end

  @impl true
  def handle_cast({:unregister_process, job_id}, state),
    do: {:noreply, Map.delete(state, job_id)}
end

defmodule Tightbeam.ConformanceSupport do
  import ExUnit.Assertions

  alias Tightbeam.{
    Adjudication,
    Archetypes,
    Assignments,
    ConditionFacts,
    ConnRegistry,
    DB,
    Devices,
    Dispatch,
    Escalation,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    ModelCatalog,
    Org,
    Placement,
    Producers,
    Projection,
    RailRemedy,
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
               ~w(case kind expect reason emits input script_return world call phase2 phase)
             )
  @expects MapSet.new(
             ~w(deny pass refuse run-remedy re-obligate escalate-park none escalate-halt escalate-open escalate-continue load-raise load-clean)
           )
  @case_expects %{
    "harness-gate" => ~w(deny pass),
    "dispatch-rule" => ~w(deny pass),
    "script-guard" => ~w(deny pass),
    "handler-refusal" => ~w(refuse pass),
    "remedy" => ~w(run-remedy none escalate-halt escalate-open escalate-continue),
    "sweep" => ~w(run-remedy re-obligate escalate-park none escalate-continue),
    "capstone" => ~w(deny pass run-remedy re-obligate none)
  }
  @load_twins [
    ~w(remedy-target-missing remedy-target-present),
    ~w(missing-producer-unsatisfiable producer-present-satisfiable),
    ~w(static-blocker-unsatisfiable runtime-conditional-blocker-loads),
    ~w(dead-remedy live-remedy),
    ~w(dead-gate producer-backed-gate),
    ~w(grammar-root-table-rejected grammar-nested-accepted)
  ]
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
  @locked_case_matrix %{
    {"C6", "remedy-episode-idempotent"} =>
      ~w(initial-publication-race live-refire-rewakes changes-requested-keeps-live reviewed-clean-closes reclaim-closed-bumps-occurrence reclaim-stale-claim-preserves-occurrence reclaim-dead-live-bumps-occurrence fresh-occurrence-new-producer episode-transitions-legible),
    {"C6", "remedy-action-breadth"} =>
      ~w(assign-target-role-dispatches wake-target-session-dispatches spawn-identity-dispatches satisfied-gate-fires-no-action action-dispatch-legible),
    {"C6", "escalation-return-dispatch"} =>
      ~w(resolve-deny-halts resolve-needs-request-nil-opens resolve-needs-request-id-rereturns resolve-waiver-allow-continues resolve-ruling-allow-continues decision-request-legible),
    {"C6", "escalation-continue-the-fold"} =>
      ~w(later-statute-still-denies whole-fold-allow-consumes-each-ruling consume-cas-loss-denies later-statute-evaluation-legible),
    {"C6", "stale-claimant-fencing"} =>
      ~w(ttl-reclaim-preserves-occurrence dead-live-replacement-bumps-occurrence claim-token-fences-superseded-worker rewake-key-includes-rewake-count live-claimant-dispatches-once fence-legible),
    {"C6", "denied-dispatch-release-retry"} =>
      ~w(denied-dispatch-deletes-lease next-edge-reclaims-without-timer successful-dispatch-holds-live-lease blocked-retry-legible),
    {"C6", "multi-statute-episode-closure"} =>
      ~w(satisfied-statute-closes-own-episode unsatisfied-statute-remains-live whole-fold-allow-consumes-rulings closure-legible),
    {"C6", "iterate-rewake-target"} =>
      ~w(changes-requested-rewakes-author no-verdict-rewakes-reviewer required-fact-closes-without-wake rewake-legible),
    {"C6", "unbound-reviewer-remedy"} =>
      ~w(owner-main-fallback-refuses-loudly unknown-role-refuses-loudly bound-reviewer-dispatches unbound-is-legible),
    {"C6", "note-digest-exclusion"} =>
      ~w(note-change-dedupes-same-action idempotency-key-change-dedupes material-change-gets-distinct-digest digest-dedupe-legible),
    {"C7", "scheduled-wake-suppression"} =>
      ~w(self-wake-suppresses non-self-user-wake-does-not-suppress supervision-prod-does-not-suppress non-self-wake-sweep-is-legible),
    {"C7", "watermark-nil-duplicate"} =>
      ~w(nil-fallthrough-no-null-write fresh-larger-terminal-acts duplicate-does-not-react),
    {"C7", "retired-holder-no-remedy"} =>
      ~w(retired-with-pending-wake-is-stranded live-holder-runs-rail-step stranded-legible),
    {"C7", "escalation-return-sweep"} =>
      ~w(resolve-deny-reobligates resolve-allow-continues-without-consuming needs-request-nil-opens-and-parks needs-request-id-rereturns-and-reuses-wake no-applicable-escalate-records-none park-legible),
    {"C7", "sweep-never-consumes"} =>
      ~w(sweep-allow-leaves-ruling-ruled verb-edge-consumes-exactly-once no-consume-legible),
    {"Cap", "capstone-reviewer-loop"} =>
      ~w(missing-review-dispatch-remedy changes-requested-iterates-author commissioned-clean-review-releases idle-pre-review-sweep-runs-remedy unbound-reviewer-refuses-loudly loop-legible-no-teardown-claim),
    {"Cap", "capstone-tests-before-success"} =>
      ~w(behind-main-script-denies reconciled-missing-tests-denies produced-tests-release idle-sweep-reobligates tests-loop-legible),
    {"Cap", "capstone-real-run-before-ship"} =>
      ~w(missing-real-run-denies produced-real-run-releases idle-sweep-reobligates real-run-loop-legible),
    {"Cap", "capstone-yagni-judge"} =>
      ~w(missing-yagni-judge-fires-remedy wrong-author-verdict-stays-denied commissioned-yagni-clean-passes yagni-loop-legible),
    {"Cap", "capstone-spec-review"} =>
      ~w(missing-spec-review-fires-remedy wrong-author-verdict-stays-denied commissioned-spec-reviewed-passes spec-review-loop-legible)
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

    validate_load_twins!(fixtures)
    %{classes: classes, fixtures: fixtures}
  end

  defp load_fixture!(path, class) do
    fixture = path |> decode_toml!() |> Map.fetch!("fixture")
    reject_unknown!(fixture, @fixture_keys, "#{path} fixture")

    for key <- ~w(class name phase blocking_phase kind source legibility) do
      assert Map.has_key?(fixture, key), "#{path}: missing fixture.#{key}"
    end

    assert fixture["class"] == class["id"], "#{path}: fixture class does not match manifest"

    assert fixture["phase"] in ~w(green pending pending-unhomed pending-runtime pending-escalation-review),
           "#{path}: invalid phase"

    if fixture["kind"] in ~w(dispatch-rule script-guard remedy sweep capstone) do
      assert is_list(fixture["rule"]) and fixture["rule"] != [],
             "#{path}: #{fixture["kind"]} fixture needs fixture.rule"
    end

    cases_path = String.replace_suffix(path, ".toml", ".cases.jsonl")
    cases = load_cases!(cases_path, fixture)
    runners = applicable_runners(fixture["kind"], class["runners"])
    assert runners != [], "#{path}: no applicable runner registered"

    if fixture["kind"] == "script-guard" do
      validate_fixture_scripts!(fixture, path |> Path.dirname() |> Path.dirname())
    end

    fixture
    |> Map.put("path", path)
    |> Map.put("cases", cases)
    |> Map.put("runners", runners)
    |> Map.put("class_phase", class["phase"])
    |> Map.put("class_blocking_phase", class["blocking_phase"])
  end

  defp applicable_runners("dispatch-rule", runners),
    do: Enum.filter(runners, &(&1 == "rules_evaluate"))

  defp applicable_runners("handler-refusal", runners),
    do: Enum.filter(runners, &(&1 == "handler_refusal"))

  defp applicable_runners("remedy", runners),
    do: Enum.filter(runners, &(&1 in ~w(rules_decide acting_layer)))

  defp applicable_runners("sweep", runners),
    do: Enum.filter(runners, &(&1 in ~w(rules_decide acting_layer)))

  defp applicable_runners("capstone", runners),
    do: Enum.filter(runners, &(&1 in ~w(rules_decide acting_layer)))

  defp applicable_runners("script-guard", runners),
    do: Enum.filter(runners, &(&1 == "rail_exec"))

  defp applicable_runners(_kind, runners), do: runners

  defp load_loadset!(path, class) do
    loadset = path |> decode_toml!() |> Map.fetch!("loadset")
    allowed = MapSet.new(~w(name class phase blocking_phase outcome must_name error_match source))
    reject_unknown!(loadset, allowed, "#{path} loadset")

    for key <- ~w(name class phase blocking_phase outcome source) do
      assert Map.has_key?(loadset, key), "#{path}: missing loadset.#{key}"
    end

    assert loadset["class"] == class["id"]

    assert loadset["phase"] in ~w(green pending pending-unhomed pending-runtime pending-escalation-review)

    assert loadset["outcome"] in ~w(load-raise load-clean)

    if loadset["outcome"] == "load-raise" do
      assert is_list(loadset["must_name"]) and loadset["must_name"] != [],
             "#{path}: load-raise needs must_name"

      assert is_binary(loadset["error_match"]) and loadset["error_match"] != "",
             "#{path}: load-raise needs error_match"
    end

    loadset_dir = String.replace_suffix(path, ".load.toml", ".loadset")
    assert File.dir?(loadset_dir), "#{path}: missing loadset directory"

    statute_paths =
      loadset_dir
      |> Path.join("*.toml")
      |> Path.wildcard()

    assert statute_paths != [], "#{path}: empty loadset directory"
    Enum.each(statute_paths, &decode_toml!/1)

    loadset
    |> Map.put("kind", "load-rejection")
    |> Map.put("path", path)
    |> Map.put("loadset_dir", loadset_dir)
    |> Map.put("runners", Enum.filter(class["runners"], &(&1 == "load_assert")))
    |> Map.put("class_phase", class["phase"])
    |> Map.put("class_blocking_phase", class["blocking_phase"])
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

      assert kase["expect"] in Map.fetch!(@case_expects, fixture["kind"]),
             "#{path}: #{kase["expect"]} is invalid for #{fixture["kind"]}"

      if kase["kind"] in ~w(positive legibility),
        do: assert(is_binary(kase["reason"]), "#{path}: positive/legibility case needs reason")

      if kase["kind"] == "legibility",
        do: assert(is_binary(kase["emits"]), "#{path}: legibility case needs emits")

      if fixture["kind"] == "harness-gate",
        do: assert(is_binary(kase["input"]), "#{path}: harness case needs input")

      if fixture["kind"] == "script-guard",
        do:
          assert(
            is_binary(kase["script_return"]),
            "#{path}: script-guard case needs script_return"
          )

      if Map.has_key?(kase, "phase") do
        assert kase["phase"] in ~w(pending pending-unhomed pending-runtime pending-escalation-review),
               "#{path}: invalid case phase"
      end

      world = Map.get(kase, "world", %{})
      validate_world!(world, path)
      validate_call!(Map.get(kase, "call"), fixture["kind"], path)
      validate_phase2!(Map.get(kase, "phase2"), path)
      validate_behavior_world!(fixture["kind"], world, kase["call"], path)
    end)

    assert Enum.any?(cases, &(&1["kind"] == "positive")), "#{path}: missing positive case"
    assert Enum.any?(cases, &(&1["kind"] == "negative")), "#{path}: missing negative case"
    assert Enum.any?(cases, &(&1["kind"] == "legibility")), "#{path}: missing legibility case"
    assert_locked_case_matrix!(fixture, cases, path)
    cases
  end

  defp assert_locked_case_matrix!(fixture, cases, path) do
    case Map.get(@locked_case_matrix, {fixture["class"], fixture["name"]}) do
      nil ->
        :ok

      required ->
        actual = MapSet.new(cases, & &1["case"])
        missing = Enum.reject(required, &MapSet.member?(actual, &1))
        assert missing == [], "#{path}: missing locked matrix cases #{Enum.join(missing, ", ")}"
    end
  end

  defp validate_world!(world, path) when is_map(world) do
    reject_unknown!(world, @world_keys, "#{path} world")

    Enum.each(world, fn {key, rows} ->
      rows = if key in ~w(adjudicate ledger turn), do: List.wrap(rows), else: rows
      assert is_list(rows), "#{path}: world.#{key} must be a row or row list"

      Enum.each(rows, fn row ->
        assert is_map(row), "#{path}: world.#{key} row must be an object"
        reject_unknown!(row, MapSet.new(Map.fetch!(@world_shapes, key)), "#{path} world.#{key}")
        validate_world_row!(key, row, path)
      end)
    end)
  end

  defp validate_world!(_world, path), do: flunk("#{path}: world must be an object")

  defp validate_behavior_world!("harness-gate", _world, _call, _path), do: :ok

  defp validate_behavior_world!(kind, world, call, path) do
    assert world != %{}, "#{path}: non-harness case needs an observable world"

    if kind in ~w(remedy sweep capstone) do
      for key <- ~w(users sessions assignments) do
        assert Map.get(world, key, []) != [], "#{path}: #{kind} case needs world.#{key}"
      end

      assert is_binary(get_in(call, ["params", "assignment_id"])),
             "#{path}: #{kind} case needs call.params.assignment_id"
    end

    if kind in ~w(sweep capstone) do
      assert Map.has_key?(world, "turn"), "#{path}: #{kind} case needs world.turn"
    end
  end

  defp validate_world_row!("sessions", row, path) do
    for key <- ~w(key owner archetype),
        do: assert(Map.has_key?(row, key), "#{path}: world.sessions row needs #{key}")

    if Map.has_key?(row, "adjudicationHold") do
      hold = row["adjudicationHold"]

      assert is_nil(hold) or hold == "*" or (is_binary(hold) and hold != ""),
             "#{path}: adjudicationHold must be null, '*', or a recovery wake id"
    end
  end

  defp validate_world_row!("adjudication_episode", row, path) do
    assert is_binary(row["session"]), "#{path}: adjudication_episode needs session"

    assert row["status"] in ~w(claimed notified),
           "#{path}: adjudication_episode status must be claimed or notified"
  end

  defp validate_world_row!(_key, _row, _path), do: :ok

  defp validate_call!(nil, "harness-gate", _path), do: :ok
  defp validate_call!(nil, _kind, path), do: flunk("#{path}: non-harness case needs call")

  defp validate_call!(call, _kind, path) when is_map(call) do
    reject_unknown!(call, MapSet.new(~w(verb principal params session_key)), "#{path} call")
    assert is_binary(call["verb"]), "#{path}: call.verb must be a string"
    assert is_map(call["params"]), "#{path}: call.params must be an object"

    assert match?(
             [kind, value] when kind in ~w(session user process) and is_binary(value),
             call["principal"]
           ),
           "#{path}: non-harness call.principal must be [session|user|process, id]"
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

  defp validate_load_twins!(fixtures) do
    loadsets =
      Map.new(Enum.filter(fixtures, &(&1["kind"] == "load-rejection")), &{&1["name"], &1})

    Enum.each(@load_twins, fn [raise_name, clean_name] ->
      assert Map.has_key?(loadsets, raise_name), "missing load-raise twin #{raise_name}"
      assert Map.has_key?(loadsets, clean_name), "missing load-clean twin #{clean_name}"
      assert loadsets[raise_name]["outcome"] == "load-raise"
      assert loadsets[clean_name]["outcome"] == "load-clean"
    end)
  end

  defp validate_fixture_scripts!(fixture, root) do
    fixture["rule"]
    |> Enum.map(&get_in(&1, ["check", "script"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn script ->
      assert Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, script),
             "invalid script identifier #{inspect(script)}"

      path = Path.join([root, "c5_script_guards", "scripts", script])
      assert File.regular?(path), "missing fixture script #{script}"
      assert {:ok, stat} = File.stat(path)
      assert Bitwise.band(stat.mode, 0o111) != 0, "fixture script #{script} is not executable"
    end)
  end

  defp reject_unknown!(map, allowed, label) do
    unknown = map |> Map.keys() |> MapSet.new() |> MapSet.difference(allowed) |> Enum.sort()
    assert unknown == [], "#{label}: unknown keys #{Enum.join(unknown, ", ")}"
  end

  defp decode_toml!(path), do: path |> File.read!() |> Toml.decode!()

  def pending_entries(%{classes: classes, fixtures: fixtures}) do
    class_by_id = Map.new(classes, &{&1["id"], &1})

    fixture_entries =
      fixtures
      |> Enum.reject(&(&1["phase"] == "green" and &1["class_phase"] == "green"))
      |> Enum.map(fn fixture ->
        _class = Map.fetch!(class_by_id, fixture["class"])

        %{
          scope: "fixture",
          id: "#{fixture["class"]}/#{fixture["name"]}",
          phase: fixture["phase"],
          blocker: fixture["blocking_phase"]
        }
      end)

    case_entries =
      for fixture <- fixtures,
          kase <- Map.get(fixture, "cases", []),
          phase = kase["phase"],
          is_binary(phase) do
        %{
          scope: "case",
          id: "#{fixture["class"]}/#{fixture["name"]}/#{kase["case"]}",
          phase: phase,
          blocker: case_blocker(phase, fixture)
        }
      end

    fixture_entries ++ case_entries
  end

  def assert_pending_registration(fixture, blocker) do
    assert fixture["phase"] != "green" or fixture["class_phase"] != "green"
    assert is_binary(blocker) and blocker != ""
    assert fixture["runners"] != []

    if fixture["kind"] != "load-rejection" do
      assert fixture["cases"] != []
    end
  end

  def run_pending_fixture(fixture, fixtures, blocker) do
    assert_pending_registration(fixture, blocker)

    find = fn class, name ->
      Enum.find(fixtures, &(&1["class"] == class and &1["name"] == name)) ||
        flunk("missing pending proof fixture #{class}/#{name}")
    end

    case {fixture["class"], fixture["kind"], fixture["name"]} do
      {class, _, name}
      when {class, name} in [
             {"C2", "handoff-assign"},
             {"C2", "handoff-wake"},
             {"C3", "two-changes-requested-revert"}
           ] ->
        :ok

      {"C4", _, "declared-files-overlap"} ->
        run_handler_refusal_fixture(fixture)

      {"C4", _, "producer-cas-verdict-txn"} ->
        run_producer_cas_races(fixture)

      {"C4", _, _} ->
        run_rules_fixture(fixture)

      {"C5", _, _} ->
        run_rail_exec_fixture(fixture)

      {"C6", "load-rejection", _} ->
        :ok

      {"C6", _, "review-remedy-spawn"} ->
        run_rules_decide(fixture)
        run_acting_layer(fixture)

      {"C6", _, "remedy-action-breadth"} ->
        run_remedy_action_contract(fixture)

      {"C6", _, "script-result-remedy"} ->
        run_rules_decide(fixture)
        run_acting_layer(fixture)

      {"C6", _, name}
      when name in ~w(escalation-return-dispatch escalation-continue-the-fold) ->
        run_escalation_dispatch_contract(
          find.("C6", "escalation-return-dispatch"),
          find.("C6", "escalation-continue-the-fold")
        )

      {"C6", _, _} ->
        run_remedy_episode_contract(find.("C6", "review-remedy-spawn"))

      {"C7", _, "adjudication-hold-order"} ->
        run_rules_decide(fixture)
        run_acting_layer(fixture)

      {"C7", _, name}
      when name in ~w(idle-open-obligation busy-or-queued-no-sweep satisfied-obligation-no-sweep) ->
        run_rules_decide(fixture)
        run_acting_layer(fixture)

      {"C7", _, "turn-end-script-gate"} ->
        run_rules_decide(fixture)
        run_acting_layer(fixture)

      {"C7", _, name}
      when name in ~w(retired-holder-no-remedy watermark-nil-duplicate escalation-return-sweep parkwakeid-reuse schedule-then-check) ->
        run_supervision_state_contract(
          find.("C7", "retired-holder-no-remedy"),
          find.("C7", "watermark-nil-duplicate"),
          find.("C7", "escalation-return-sweep")
        )

      {"C7", _, _} ->
        run_sweep_ruling_contract(find.("C7", "sweep-never-consumes"))

      {"Cap", _, _} ->
        run_capstone_contracts(
          find.("Cap", "capstone-reviewer-loop"),
          find.("Cap", "capstone-yagni-judge"),
          find.("Cap", "capstone-spec-review"),
          find.("Cap", "capstone-tests-before-success"),
          find.("Cap", "capstone-real-run-before-ship")
        )
    end
  end

  defp case_blocker("pending-runtime", _fixture), do: "runtime"
  defp case_blocker("pending-escalation-review", _fixture), do: "escalation-substrate-v1"
  defp case_blocker(_phase, fixture), do: fixture["blocking_phase"]

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
    prepare_rule_base!(base, fixture)
    handlers = Gateway.handlers(%{})
    Rules.load!(base, Map.keys(handlers), %{tests: "fixture", smoke: "fixture"})

    try do
      Enum.each(fixture["cases"], &run_rule_case(fixture, &1, handlers, base))
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  def run_rail_exec_fixture(fixture) do
    ensure_real_rail_exec!()
    base = temp_dir!("conformance-real-rail")
    prepare_rule_base!(base, fixture, real_rail_exec: true)
    handlers = Gateway.handlers(%{})
    Rules.load!(base, Map.keys(handlers), %{})

    try do
      fixture["cases"]
      |> Enum.reject(&is_binary(&1["phase"]))
      |> Enum.each(&run_rule_case(fixture, &1, handlers, base))
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  defp run_rule_case(fixture, kase, handlers, base) do
    {db, pid} = memory_db!()

    try do
      ids = materialize_world(db, Map.get(kase, "world", %{}))
      assert_fixture_world(fixture, kase, db, ids)
      seed_script_checkout!(base, fixture, kase, db)
      call = build_call(kase["call"], ids)
      assert_rule_result(kase["case"], kase["expect"], kase["reason"], Rules.evaluate(db, call))

      if fixture["name"] == "predicate-prefilter-script-laziness" and
           kase["case"] == "predicate-miss-never-invokes-script" do
        refute lifecycle_kind?(db, "rail_script")
      end

      if kase["kind"] == "legibility" do
        assert {:error, %{rule: reason}} = Dispatch.dispatch(db, handlers, call)
        assert reason == kase["reason"]

        assert {:ok, [["denied", payload]]} =
                 DB.query(db, "SELECT kind, payload FROM events ORDER BY id DESC LIMIT 1")

        decoded = JSON.decode!(payload)
        assert decoded["rule"] == kase["reason"]

        for key <- ~w(code rule edge reason script_exit_class ref producer message) do
          assert Map.has_key?(decoded, key), "denied payload missing #{key}"
        end

        assert_declared_records!(kase["emits"], decoded, db)

        assert [%{rule: rule, edge: "verb", reason: event_reason}] =
                 EventLog.rail_denials(db, 0, 1)

        assert rule == kase["reason"]
        assert event_reason == decoded["reason"]
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

  defp assert_declared_records!(emits, payload, db) do
    emits
    |> String.split(";")
    |> Enum.each(fn token ->
      cond do
        String.starts_with?(token, "event:denied") ->
          assert_declared_fields!(declared_fields(token, "event:denied"), payload, token)

        String.starts_with?(token, "lifecycle:") ->
          [kind | _] =
            token
            |> String.trim_leading("lifecycle:")
            |> String.split("(", parts: 2)

          fields = declared_fields(token, "lifecycle:#{kind}")

          assert Enum.any?(EventLog.lifecycle_events(db), fn event ->
                   event.kind == kind and
                     declared_fields_match?(fields, JSON.decode!(event.detail), event.subject)
                 end),
                 "missing declared lifecycle record #{token}"

        true ->
          flunk("unsupported legibility token #{token}")
      end
    end)
  end

  defp declared_fields(token, prefix) do
    token
    |> String.trim_leading(prefix)
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> String.split(",", trim: true)
    |> Map.new(fn pair ->
      [key, value] = String.split(pair, "=", parts: 2)
      {key, value}
    end)
  end

  defp assert_declared_fields!(fields, actual, token) do
    Enum.each(fields, fn {key, value} ->
      assert to_string(Map.fetch!(actual, key)) == value,
             "#{token}: declared #{key}=#{value}, emitted #{inspect(actual[key])}"
    end)
  end

  defp declared_fields_match?(fields, detail, subject) do
    Enum.all?(fields, fn
      {"subject", expected} -> to_string(subject) == expected
      {key, expected} -> to_string(detail[key]) == expected
    end)
  end

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

  def run_producer_cas_races(fixture) do
    Enum.each(fixture["cases"], fn kase ->
      {db, pid} = memory_db!()
      base = temp_dir!("conformance-producer")
      {:ok, runner} = Tightbeam.ConformanceProducerRegistry.start_link()
      config = %{base_dir: base, port: 0}

      try do
        ids = materialize_world(db, kase["world"])
        [{_key, job_id}] = Map.to_list(ids.producer_jobs)
        job = Producers.get(db, job_id)

        case kase["case"] do
          "done-vs-failure-race-one-cas-wins" ->
            [done_result, failed_result] =
              [
                Task.async(fn -> Producers.execute(db, config, job, runner) end),
                Task.async(fn -> Producers.fail_running(db, job.id, "racing failure") end)
              ]
              |> Task.await_many()

            assert Enum.count([done_result, failed_result], &(&1 in [:done, :failed])) == 1
            assert Enum.count([done_result, failed_result], &(&1 == :noop)) == 1

            case Producers.get(db, job.id).state do
              "done" ->
                assert [_verdict] = Assignments.list_attests(db, job.assignment_id)

              "failed" ->
                assert Assignments.list_attests(db, job.assignment_id) == []
            end

          "two-workers-race-done-one-verdict" ->
            results =
              [
                Task.async(fn -> Producers.execute(db, config, job, runner) end),
                Task.async(fn -> Producers.execute(db, config, job, runner) end)
              ]
              |> Task.await_many()

            assert Enum.sort(results) == [:done, :noop]
            assert Producers.get(db, job.id).state == "done"
            assert [_verdict] = Assignments.list_attests(db, job.assignment_id)

          "cancel-before-claim-commits-no-verdict" ->
            assert job.state == "cancelled"
            assert Assignments.list_attests(db, job.assignment_id) == []

          "failed-job-denial-is-legible" ->
            assert job.state == "failed"
            assert Assignments.list_attests(db, job.assignment_id) == []
        end
      after
        GenServer.stop(runner)
        File.rm_rf!(base)
        GenServer.stop(pid)
      end
    end)
  end

  def run_handler_refusal_fixture(fixture) do
    Enum.each(fixture["cases"], fn kase ->
      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, Map.get(kase, "world", %{}))
        call = build_call(kase["call"], ids)
        handlers = Gateway.handlers(%{db: db})
        {:ok, [[before_count]]} = DB.query(db, "SELECT count(*) FROM assignments")
        overlap? = Assignments.open_assignments_touching(db, call.params[:files] || []) != []

        if kase["reason"] in [nil, "files_overlap"] do
          assert_overlap_observation(fixture, db, call, overlap?)
        end

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
              assert {:error, %{code: code}} = result
              assert code == kase["reason"]
              assert after_count == before_count

            "pass" ->
              assert {:ok, _} = result
              assert after_count == before_count + 1
          end
        end
      after
        GenServer.stop(pid)
      end
    end)
  end

  defp assert_overlap_observation(%{"rule" => [_ | _]} = fixture, db, call, overlap?) do
    base = temp_dir!("conformance-overlap-observation")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})), %{})

    try do
      if overlap?,
        do:
          assert(
            match?(
              {:deny, %{rule: "declared-files-overlap-observation"}},
              Rules.evaluate(db, call)
            )
          ),
        else: assert(Rules.evaluate(db, call) == :ok)
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  defp assert_overlap_observation(_fixture, _db, _call, _overlap?), do: :ok

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
          producers =
            case File.read(Path.join(loadset["loadset_dir"], "producers.toml")) do
              {:ok, encoded} ->
                producer_base = temp_dir!("conformance-producers")
                identity = Path.join(producer_base, "identity")
                File.mkdir_p!(identity)
                File.write!(Path.join(identity, "producers.toml"), encoded)

                try do
                  Producers.load!(producer_base)
                after
                  File.rm_rf!(producer_base)
                end

              {:error, :enoent} ->
                %{}
            end

          Rules.load!(base, Map.keys(Gateway.handlers(%{})), producers)
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

  def run_rules_decide(fixture) do
    base = temp_dir!("conformance-decide")
    prepare_rule_base!(base, fixture)
    handlers = Gateway.handlers(%{})
    Rules.load!(base, Map.keys(handlers), %{})

    try do
      Enum.each(fixture["cases"], fn kase ->
        {db, pid} = memory_db!()

        try do
          ids = materialize_world(db, Map.get(kase, "world", %{}))
          seed_script_checkout!(base, fixture, kase, db)
          call = build_call(kase["call"], ids)
          {decision, _to_close, _to_consume} = Rules.decide(db, sweep_call(fixture, call))

          case {kase["expect"], self_wake?(db, call), suppressed_before_decision?(fixture, kase)} do
            {"run-remedy", _, _} ->
              assert {:remedy, %{name: name}, _, _} = decision
              assert name == kase["reason"]

            {"re-obligate", _, _} ->
              assert {:deny, %{rule: name}} = decision
              assert name == (kase["reason"] || fixture_rule_name(fixture))

            {"none", true, _} ->
              assert match?({:remedy, _, _, _}, decision)

            {"none", false, true} ->
              assert decision != nil

            {"none", false, false} ->
              assert decision == :allow
          end
        after
          GenServer.stop(pid)
        end
      end)
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  def run_acting_layer(%{"class" => "C6"} = fixture), do: run_dispatch_actor(fixture)
  def run_acting_layer(%{"class" => "C7"} = fixture), do: run_supervision_actor(fixture)
  def run_acting_layer(%{"class" => "Cap"} = fixture), do: run_capstone_actor(fixture)

  def run_remedy_episode_contract(fixture) do
    base = temp_dir!("conformance-remedy-episode")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})), %{})
    {db, pid} = memory_db!()

    try do
      ids = materialize_world(db, hd(fixture["cases"])["world"])
      handlers = Gateway.handlers(%{db: db})
      original = ids.assignments["work"]
      call = completion_call(original)

      results =
        [
          Task.async(fn -> Dispatch.dispatch(db, handlers, call) end),
          Task.async(fn -> Dispatch.dispatch(db, handlers, call) end)
        ]
        |> Task.await_many()

      producers =
        Enum.flat_map(results, fn
          {:error, %{reason: "remedy_fired", producer: producer}} when is_binary(producer) ->
            [producer]

          {:error, %{reason: "remedy_fired"}} ->
            []
        end)

      assert [producer] = producers
      assert review_effect_count(db, original) == 1

      assert %{status: "live", occurrence: 1, producer_key: ^producer} =
               RailRemedy.episode(db, fixture_rule_name(fixture), original)

      assert {:error, %{producer: ^producer}} = Dispatch.dispatch(db, handlers, call)

      assert %{rewake_count: 1, occurrence: 1} =
               RailRemedy.episode(db, fixture_rule_name(fixture), original)

      assert review_effect_count(db, original) == 1

      attest_verdict!(db, original, "reviewer-session", "reviewed-clean")
      assert {:ok, _} = Dispatch.dispatch(db, handlers, call)
      assert %{status: "closed"} = RailRemedy.episode(db, fixture_rule_name(fixture), original)

      reopened = new_assignment!(db, "holder", "reopen")
      reopen_call = completion_call(reopened)
      assert {:error, %{producer: first}} = Dispatch.dispatch(db, handlers, reopen_call)
      assert RailRemedy.close(db, fixture_rule_name(fixture), reopened)
      assert {:error, %{producer: second}} = Dispatch.dispatch(db, handlers, reopen_call)
      refute second == first

      assert %{status: "live", occurrence: 2, producer_key: ^second} =
               RailRemedy.episode(db, fixture_rule_name(fixture), reopened)

      dead = new_assignment!(db, "holder", "dead-live")
      dead_call = completion_call(dead)
      assert {:error, %{producer: dead_first}} = Dispatch.dispatch(db, handlers, dead_call)
      revoke_assignment!(db, dead_first)
      assert {:error, %{producer: dead_second}} = Dispatch.dispatch(db, handlers, dead_call)
      refute dead_second == dead_first
      assert %{occurrence: 2} = RailRemedy.episode(db, fixture_rule_name(fixture), dead)

      stale = new_assignment!(db, "holder", "stale-claim")
      stale_at = System.system_time(:millisecond) - 60_001

      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO rail_remedy_episodes
            (statute, subject, status, occurrence, rewakeCount, claimToken, openedAt)
          VALUES (?1, ?2, 'claimed', 1, 0, 'stale', ?3)
          """,
          [fixture_rule_name(fixture), stale, stale_at]
        )

      assert {:error, %{producer: stale_producer}} =
               Dispatch.dispatch(db, handlers, completion_call(stale))

      assert is_binary(stale_producer)

      assert %{status: "live", occurrence: 1} =
               RailRemedy.episode(db, fixture_rule_name(fixture), stale)

      fenced = new_assignment!(db, "holder", "fenced")

      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO rail_remedy_episodes
            (statute, subject, status, occurrence, rewakeCount, claimToken, openedAt)
          VALUES (?1, ?2, 'claimed', 1, 0, 'superseded', ?3)
          """,
          [fixture_rule_name(fixture), fenced, stale_at]
        )

      assert {:error, %{producer: fenced_producer}} =
               Dispatch.dispatch(db, handlers, completion_call(fenced))

      {:ok, _} =
        DB.query(
          db,
          """
          UPDATE rail_remedy_episodes SET status='dispatched'
          WHERE statute=?1 AND subject=?2 AND status='claimed' AND claimToken='superseded'
          """,
          [fixture_rule_name(fixture), fenced]
        )

      assert DB.changes(db) == 0
      assert review_effect_count(db, fenced) == 1
      assert is_binary(fenced_producer)

      blocked = new_assignment!(db, "holder", "blocked")
      blocked_call = completion_call(blocked)
      parent = self()

      denied_handlers =
        Map.put(handlers, "assign", fn remedy_call ->
          send(parent, {:blocked_attempt, remedy_call.params.idempotency_key})
          %{code: "runtime_blocker"}
        end)

      for _ <- 1..2 do
        assert {:error, %{reason: "remedy_fired", producer: nil}} =
                 Dispatch.dispatch(db, denied_handlers, blocked_call)

        assert_received {:blocked_attempt, _}
        assert RailRemedy.episode(db, fixture_rule_name(fixture), blocked) == nil
      end

      assert Enum.count(remedy_lifecycle_details(db), &(&1["outcome"] == "blocked")) == 2
    after
      GenServer.stop(pid)
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  def run_escalation_dispatch_contract(return_fixture, fold_fixture) do
    run_escalation_union_contract(return_fixture)
    run_escalation_fold_contract(fold_fixture)
  end

  def run_supervision_state_contract(retired_fixture, watermark_fixture, escalation_fixture) do
    run_retired_holder_contract(retired_fixture)
    run_watermark_contract(watermark_fixture)
    run_sweep_escalation_contract(escalation_fixture)
  end

  def run_sweep_ruling_contract(fixture) do
    base = temp_dir!("conformance-sweep-ruling")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})), %{})
    {db, pid} = memory_db!()

    try do
      sample = Enum.find(fixture["cases"], &(&1["case"] == "sweep-allow-leaves-ruling-ruled"))
      ids = materialize_world(db, sample["world"])
      call = build_call(sample["call"], ids)
      session_key = elem(call.principal, 1)
      terminal_seq = Map.fetch!(ids.turns, session_key)
      handlers = Gateway.handlers(%{db: db})

      assert {:acted, :rail_escalate} =
               Supervision.evaluate(db, handlers, 3, session_key, terminal_seq)

      assert {:ok, [[request_id, "open"]]} =
               DB.query(db, "SELECT id, status FROM decision_requests")

      assert {:ok, [[park_wake_id]]} =
               DB.query(db, "SELECT parkWakeId FROM decision_requests WHERE id=?1", [request_id])

      assert %{status: "ruled"} =
               Escalation.rule(db, escalation_rule_call(request_id, "allow"), authorized: true)

      park_wake = Wakes.get(db, park_wake_id)
      assert Wakes.cancel(db, park_wake_id, park_wake.origin)

      ids =
        materialize_world(
          db,
          %{"turn" => %{"session" => session_key, "seq" => 2, "window_start" => 1}},
          ids
        )

      assert {:prodded, 1} =
               Supervision.evaluate(db, handlers, 3, session_key, ids.turns[session_key])

      assert {:ok, [["ruled"]]} =
               DB.query(db, "SELECT status FROM decision_requests WHERE id=?1", [request_id])

      assert {:ok, %{accepted: true}} =
               Dispatch.dispatch(db, %{"attest" => fn _ -> %{accepted: true} end}, call)

      assert {:ok, [["consumed"]]} =
               DB.query(db, "SELECT status FROM decision_requests WHERE id=?1", [request_id])

      assert {:decision_pending, new_request_id} =
               Dispatch.dispatch(db, %{"attest" => fn _ -> %{accepted: true} end}, call)

      refute new_request_id == request_id
    after
      GenServer.stop(pid)
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  def run_capstone_contracts(
        reviewer_fixture,
        yagni_fixture,
        spec_fixture,
        tests_fixture,
        real_fixture
      ) do
    run_judge_capstone(reviewer_fixture, "reviewed-clean", true)
    run_judge_capstone(yagni_fixture, "yagni-clean", false)
    run_judge_capstone(spec_fixture, "spec-reviewed", false)
    run_produced_capstone(tests_fixture, "produced-tests-release")
    run_produced_capstone(real_fixture, "produced-real-run-releases")
  end

  defp run_judge_capstone(fixture, verdict_kind, iterate?) do
    base = temp_dir!("conformance-capstone-judge")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})), %{})

    try do
      missing =
        Enum.find(fixture["cases"], fn kase ->
          String.starts_with?(kase["case"], "missing-") or
            kase["case"] == "missing-review-dispatch-remedy"
        end)

      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, missing["world"])
        handlers = Gateway.handlers(%{db: db})
        call = build_call(missing["call"], ids)
        assignment_id = ids.assignments["work"]

        assert {:error, %{reason: "remedy_fired", producer: review_id}} =
                 Dispatch.dispatch(db, handlers, call)

        assert is_binary(review_id)
        assert review_effect_count(db, assignment_id) == 1

        if iterate? do
          attest_verdict!(db, review_id, "reviewer-session", "changes-requested")

          assert {:error, %{reason: "remedy_fired", producer: ^review_id}} =
                   Dispatch.dispatch(db, handlers, call)

          assert Enum.any?(Wakes.list_pending(db), &(&1.session_key == "holder"))
        end

        attest_verdict!(db, review_id, "reviewer-session", verdict_kind)
        assert {:ok, _} = Dispatch.dispatch(db, handlers, call)

        assert %{status: "closed"} =
                 RailRemedy.episode(db, fixture_rule_name(fixture), assignment_id)
      after
        GenServer.stop(pid)
      end

      unless iterate? do
        wrong = Enum.find(fixture["cases"], &String.contains?(&1["case"], "wrong-author"))
        {db, pid} = memory_db!()

        try do
          ids = materialize_world(db, wrong["world"])
          call = build_call(wrong["call"], ids)

          assert {:error, %{reason: "remedy_fired"}} =
                   Dispatch.dispatch(db, Gateway.handlers(%{db: db}), call)
        after
          GenServer.stop(pid)
        end
      end

      if iterate? do
        {db, pid} = memory_db!()

        try do
          ids = materialize_world(db, missing["world"])

          assert {:acted, :rail_remedy} =
                   Supervision.evaluate(
                     db,
                     Gateway.handlers(%{db: db}),
                     3,
                     "holder",
                     ids.turns["holder"]
                   )

          assert review_effect_count(db, ids.assignments["work"]) == 1
        after
          GenServer.stop(pid)
        end

        {db, pid} = memory_db!()

        try do
          unbound_world =
            missing["world"]
            |> Map.put("roles", [])
            |> Map.put(
              "sessions",
              Enum.reject(missing["world"]["sessions"], &(&1["key"] == "reviewer-session"))
            )

          ids = materialize_world(db, unbound_world)
          call = build_call(missing["call"], ids)

          assert {:error, %{reason: "remedy_fired", producer: nil}} =
                   Dispatch.dispatch(db, Gateway.handlers(%{db: db}), call)

          assert review_effect_count(db, ids.assignments["work"]) == 0

          assert RailRemedy.episode(db, fixture_rule_name(fixture), ids.assignments["work"]) ==
                   nil

          assert lifecycle_outcome?(db, "rail_remedy", fixture_rule_name(fixture), "unbound")
        after
          GenServer.stop(pid)
        end
      end
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  defp run_produced_capstone(fixture, release_case) do
    base = temp_dir!("conformance-capstone-produced")
    prepare_rule_base!(base, fixture)

    producers =
      if release_case == "produced-tests-release",
        do: %{tests: "true"},
        else: %{smoke: "true"}

    Rules.load!(base, Map.keys(Gateway.handlers(%{})), producers)

    try do
      missing =
        Enum.find(fixture["cases"], fn kase ->
          String.starts_with?(kase["case"], "missing-") and
            not String.contains?(kase["case"], "legible")
        end)

      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, missing["world"])
        seed_script_checkout!(base, fixture, missing, db)
        call = build_call(missing["call"], ids)

        assert {:error, %{code: "rule_denied"}} =
                 Dispatch.dispatch(db, Gateway.handlers(%{db: db}), call)

        assert {:prodded, 1} =
                 Supervision.evaluate(
                   db,
                   Gateway.handlers(%{db: db}),
                   3,
                   "holder",
                   ids.turns["holder"]
                 )
      after
        GenServer.stop(pid)
      end

      release = Enum.find(fixture["cases"], &(&1["case"] == release_case))
      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, release["world"])
        seed_script_checkout!(base, fixture, release, db)
        call = build_call(release["call"], ids)
        assert {:ok, _} = Dispatch.dispatch(db, Gateway.handlers(%{db: db}), call)
      after
        GenServer.stop(pid)
      end
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  defp run_retired_holder_contract(fixture) do
    base = temp_dir!("conformance-retired-holder")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})), %{})

    try do
      sample =
        Enum.find(fixture["cases"], &(&1["case"] == "retired-with-pending-wake-is-stranded"))

      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, sample["world"])
        Org.retire(db, "holder")
        terminal_seq = ids.turns["holder"]

        assert :stranded =
                 Supervision.evaluate(
                   db,
                   Gateway.handlers(%{db: db}),
                   3,
                   "holder",
                   terminal_seq
                 )

        assert %{lastEvaluatedTerminal: ^terminal_seq} = Supervision.watermark(db, "holder")
        assert Wakes.pending_count(db, "holder") == 1
        assert RailRemedy.episode(db, fixture_rule_name(fixture), ids.assignments["work"]) == nil
        refute lifecycle_kind?(db, "rail_sweep")
      after
        GenServer.stop(pid)
      end

      {db, pid} = memory_db!()

      try do
        live = Enum.find(fixture["cases"], &(&1["case"] == "live-holder-runs-rail-step"))
        ids = materialize_world(db, live["world"])

        assert {:acted, :rail_remedy} =
                 Supervision.evaluate(
                   db,
                   Gateway.handlers(%{db: db}),
                   3,
                   "holder",
                   ids.turns["holder"]
                 )

        assert %{status: "live"} =
                 RailRemedy.episode(db, fixture_rule_name(fixture), ids.assignments["work"])
      after
        GenServer.stop(pid)
      end
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  defp run_watermark_contract(fixture) do
    base = temp_dir!("conformance-watermark")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})), %{})

    try do
      nil_case = Enum.find(fixture["cases"], &(&1["case"] == "nil-fallthrough-no-null-write"))
      {db, pid} = memory_db!()

      try do
        materialize_world(db, nil_case["world"])

        assert :idle =
                 Supervision.evaluate(db, Gateway.handlers(%{db: db}), 3, "holder", nil)

        assert Supervision.watermark(db, "holder") == nil
        refute lifecycle_kind?(db, "rail_sweep")
      after
        GenServer.stop(pid)
      end

      fresh = Enum.find(fixture["cases"], &(&1["case"] == "fresh-larger-terminal-acts"))
      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, fresh["world"])
        terminal_seq = ids.turns["holder"]
        handlers = Gateway.handlers(%{db: db})
        assert {:prodded, 1} = Supervision.evaluate(db, handlers, 3, "holder", terminal_seq)
        lifecycle_count = length(EventLog.lifecycle_events(db))
        assert :duplicate = Supervision.evaluate(db, handlers, 3, "holder", terminal_seq)
        assert length(EventLog.lifecycle_events(db)) == lifecycle_count
        assert %{lastEvaluatedTerminal: ^terminal_seq} = Supervision.watermark(db, "holder")
      after
        GenServer.stop(pid)
      end
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  defp run_sweep_escalation_contract(fixture) do
    base = temp_dir!("conformance-sweep-escalation")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})), %{})
    {db, pid} = memory_db!()

    try do
      sample =
        Enum.find(fixture["cases"], &(&1["case"] == "needs-request-nil-opens-and-parks"))

      ids = materialize_world(db, sample["world"])
      handlers = Gateway.handlers(%{db: db})

      assert {:acted, :rail_escalate} =
               Supervision.evaluate(db, handlers, 3, "holder", ids.turns["holder"])

      assert {:ok, [[request_id, "open", park_wake_id]]} =
               DB.query(db, "SELECT id, status, parkWakeId FROM decision_requests")

      assert %{condition_kind: "escalation-ruled", condition_scope: ^request_id} =
               Wakes.get(db, park_wake_id)

      ids =
        materialize_world(
          db,
          %{"turn" => %{"session" => "holder", "seq" => 2, "window_start" => 1}},
          ids
        )

      assert {:acted, :rail_escalate} =
               Supervision.evaluate(db, handlers, 3, "holder", ids.turns["holder"])

      assert {:ok, [[^request_id, ^park_wake_id]]} =
               DB.query(db, "SELECT id, parkWakeId FROM decision_requests")

      assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM decision_requests")
    after
      GenServer.stop(pid)
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  def run_remedy_action_contract(fixture) do
    base = temp_dir!("conformance-remedy-actions")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})), %{})
    {db, pid} = memory_db!()

    try do
      sample = Enum.find(fixture["cases"], &(&1["case"] == "assign-target-role-dispatches"))
      ids = materialize_world(db, sample["world"])
      {handlers, service_pids} = remedy_action_handlers(base, db)
      assignment_id = ids.assignments["work"]

      for {kind, statute, action} <- [
            {"assign-remedy", "remedy-action-breadth", :assign},
            {"wake-remedy", "remedy-action-wake", :wake},
            {"spawn-remedy", "remedy-action-spawn", :spawn}
          ] do
        call =
          sample["call"]
          |> put_in(["params", "kind"], kind)
          |> build_call(ids)

        assert {:error, %{reason: "remedy_fired", rule: ^statute, producer: producer}} =
                 Dispatch.dispatch(db, handlers, call)

        assert is_binary(producer), "#{action} remedy did not dispatch a producer"

        assert %{status: "live", producer_key: ^producer} =
                 RailRemedy.episode(db, statute, assignment_id)

        case action do
          :assign ->
            assert review_effect_count(db, assignment_id) == 1

          :wake ->
            assert Enum.any?(Wakes.list_pending(db), &(&1.session_key == "reviewer-session"))

          :spawn ->
            assert %{harness: "codex", model: "test"} = Org.get(db, producer)
        end
      end

      progress_call =
        sample["call"]
        |> put_in(["params", "kind"], "progress")
        |> build_call(ids)

      assert {:ok, _} = Dispatch.dispatch(db, handlers, progress_call)
      Enum.each(service_pids, &GenServer.stop/1)
    after
      GenServer.stop(pid)
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  defp remedy_action_handlers(base, db) do
    auth_dir = Path.join([base, "auth", "codex"])
    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "auth.json"), "{}")
    Archetypes.load!(base)

    service_pids =
      [
        start_named_service(ConnRegistry, fn -> ConnRegistry.start_link(name: ConnRegistry) end),
        start_named_service(ModelCatalog, fn ->
          ModelCatalog.start_link(
            base_dir: base,
            codex_home: Path.join(base, "codex"),
            claude_fetch: fn _, _ -> {:error, :unused} end,
            codex_read: fn _ ->
              {:ok,
               JSON.encode!(%{
                 models: [
                   %{
                     slug: "test",
                     display_name: "Test",
                     supported_reasoning_levels: []
                   }
                 ]
               })}
            end
          )
        end)
      ]
      |> Enum.reject(&is_nil/1)

    handlers =
      Gateway.handlers(%{
        base_dir: base,
        cwd: System.tmp_dir!(),
        port: 0,
        default_harness: :codex,
        default_model: "test",
        max_live_sessions_per_user: 50,
        wake_tick_ms: 1_000,
        db: db
      })

    {handlers, service_pids}
  end

  defp start_named_service(name, start) do
    case Process.whereis(name) do
      nil ->
        {:ok, pid} = start.()
        pid

      _pid ->
        nil
    end
  end

  defp run_escalation_union_contract(fixture) do
    base = temp_dir!("conformance-escalation-union")
    prepare_rule_base!(base, fixture)
    handlers = Gateway.handlers(%{})
    Rules.load!(base, Map.keys(handlers), %{})
    {db, pid} = memory_db!()

    try do
      ids = materialize_world(db, hd(fixture["cases"])["world"])
      call = build_call(hd(fixture["cases"])["call"], ids)
      statute = %{name: fixture_rule_name(fixture), text: "owner decision required"}

      assert {:needs_request, nil} = Escalation.resolve(db, call, statute)

      ids =
        for _ <- 1..4 do
          Task.async(fn ->
            Escalation.escalate(db, call, statute, %{
              question: "Allow this completion?",
              options: nil
            })
          end)
        end
        |> Task.await_many()
        |> Enum.map(fn {:decision_pending, id} -> id end)

      assert [request_id] = Enum.uniq(ids)

      assert {:ok, [[1]]} =
               DB.query(db, "SELECT COUNT(*) FROM decision_requests WHERE status='open'")

      assert {:needs_request, ^request_id} = Escalation.resolve(db, call, statute)

      assert {:decision_pending, ^request_id} =
               Escalation.escalate(db, call, statute, %{
                 question: "Allow this completion?",
                 options: nil,
                 dr_id: request_id
               })

      assert %{status: "ruled"} =
               Escalation.rule(db, escalation_rule_call(request_id, "allow"), authorized: true)

      assert {:allow, ^request_id} = Escalation.resolve(db, call, statute)
      assert Escalation.consume(db, request_id)
      refute Escalation.consume(db, request_id)
      assert {:needs_request, nil} = Escalation.resolve(db, call, statute)

      {:decision_pending, denied_id} =
        Escalation.escalate(db, call, statute, %{
          question: "Allow this completion?",
          options: nil
        })

      assert %{status: "ruled"} =
               Escalation.rule(db, escalation_rule_call(denied_id, "deny"), authorized: true)

      assert {:deny, %{code: "escalation_denied"}} = Escalation.resolve(db, call, statute)

      annotated =
        put_in(
          call.params,
          Map.merge(call.params, %{note: "annotation", idempotency_key: "wire"})
        )

      assert Escalation.digest(call) == Escalation.digest(annotated)
      progress_call = %{call | params: Map.put(call.params, :kind, "progress")}
      refute Escalation.digest(call) == Escalation.digest(progress_call)

      waiver_call = %{call | params: Map.put(call.params, :kind, "waiver-probe")}

      {:decision_pending, waiver_request} =
        Escalation.escalate(db, waiver_call, statute, %{
          question: "Allow this completion?",
          options: nil
        })

      waiver =
        Escalation.waive(
          db,
          %{
            origin: "user:owner",
            principal: {:user, "owner"},
            params: %{request_id: waiver_request}
          },
          authorized: true
        )

      assert :allow = Escalation.resolve(db, waiver_call, statute)

      assert %{revoked_at: revoked_at} =
               Escalation.revoke_waiver(
                 db,
                 %{
                   origin: "user:owner",
                   principal: {:user, "owner"},
                   params: %{waiver_id: waiver.id}
                 },
                 authorized: true
               )

      assert is_integer(revoked_at)
      assert {:needs_request, nil} = Escalation.resolve(db, waiver_call, statute)
    after
      GenServer.stop(pid)
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  defp run_escalation_fold_contract(fixture) do
    base = temp_dir!("conformance-escalation-fold")
    prepare_rule_base!(base, fixture)
    handlers = Gateway.handlers(%{})
    Rules.load!(base, Map.keys(handlers), %{})

    try do
      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, hd(fixture["cases"])["world"])
        call = build_call(hd(fixture["cases"])["call"], ids)
        assert {:decision_pending, request_id} = Dispatch.dispatch(db, handlers, call)

        assert %{status: "ruled"} =
                 Escalation.rule(db, escalation_rule_call(request_id, "allow"), authorized: true)

        assert {{:deny, %{rule: "later-statute"}}, [], [^request_id]} =
                 Rules.decide(db, call)
      after
        GenServer.stop(pid)
      end

      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, hd(fixture["cases"])["world"])
        call = build_call(hd(fixture["cases"])["call"], ids)
        assert {:decision_pending, request_id} = Dispatch.dispatch(db, handlers, call)

        assert %{status: "ruled"} =
                 Escalation.rule(db, escalation_rule_call(request_id, "allow"), authorized: true)

        {:ok, _} = DB.query(db, "UPDATE users SET isAdmin=1 WHERE userId='owner'")
        assert {:allow, [], [^request_id]} = Rules.decide(db, call)

        assert {:ok, %{accepted: true}} =
                 Dispatch.dispatch(db, %{"attest" => fn _ -> %{accepted: true} end}, call)

        refute Escalation.consume(db, request_id)
      after
        GenServer.stop(pid)
      end

      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, hd(fixture["cases"])["world"])
        call = build_call(hd(fixture["cases"])["call"], ids)
        assert {:decision_pending, request_id} = Dispatch.dispatch(db, handlers, call)

        assert %{status: "ruled"} =
                 Escalation.rule(db, escalation_rule_call(request_id, "allow"), authorized: true)

        {:ok, _} = DB.query(db, "UPDATE users SET isAdmin=1 WHERE userId='owner'")
        [escalate_rule | _] = :persistent_term.get(Rules)
        :persistent_term.put(Rules, [escalate_rule, escalate_rule])

        assert {:error, %{code: "rule_denied", rule: rule}} =
                 Dispatch.dispatch(
                   db,
                   %{"attest" => fn _ -> flunk("CAS loss must deny") end},
                   call
                 )

        assert rule == fixture_rule_name(fixture)
      after
        GenServer.stop(pid)
      end
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  defp escalation_rule_call(request_id, decision) do
    %{
      origin: "user:owner",
      principal: {:user, "owner"},
      params: %{request_id: request_id, decision: decision}
    }
  end

  defp run_dispatch_actor(fixture) do
    base = temp_dir!("conformance-dispatch-actor")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})), %{})

    try do
      Enum.each(fixture["cases"], fn kase ->
        {db, pid} = memory_db!()

        try do
          ids = materialize_world(db, Map.get(kase, "world", %{}))
          seed_script_checkout!(base, fixture, kase, db)
          call = build_call(kase["call"], ids)
          handlers = Gateway.handlers(%{db: db})
          assignment_id = call.params.assignment_id

          case kase["expect"] do
            "run-remedy" ->
              results =
                if kase["case"] == "absent-review-fires-once-and-blocks" do
                  [
                    Task.async(fn -> Dispatch.dispatch(db, handlers, call) end),
                    Task.async(fn -> Dispatch.dispatch(db, handlers, call) end)
                  ]
                  |> Task.await_many()
                else
                  [Dispatch.dispatch(db, handlers, call)]
                end

              assert Enum.all?(results, fn
                       {:error,
                        %{reason: "remedy_fired", rule: actual_rule, producer: producer_id}} ->
                         actual_rule == kase["reason"] and
                           (is_nil(producer_id) or is_binary(producer_id))

                       _ ->
                         false
                     end)

              assert Enum.count(results, fn
                       {:error, %{producer: producer_id}} -> is_binary(producer_id)
                     end) == 1

              {:error, %{rule: rule, producer: producer}} =
                Enum.find(results, fn
                  {:error, %{producer: producer_id}} -> is_binary(producer_id)
                end)

              assert rule == kase["reason"]
              assert is_binary(producer)

              assert %{status: "live", producer_key: ^producer} =
                       RailRemedy.episode(db, rule, assignment_id)

              assert review_effect_count(db, assignment_id) == 1
              assert remedy_principal_recorded?(db, rule)

              if kase["kind"] == "legibility" do
                assert [denial | _] = EventLog.rail_denials(db, 0, 10)
                assert denial.rule == rule
                assert denial.reason == "remedy_fired"
                assert lifecycle_outcome?(db, "rail_remedy", rule, "claimed-dispatched")
                assert_declared_records!(kase["emits"], latest_denied_payload(db), db)
              end

              if phase2 = kase["phase2"] do
                phase2_ids = materialize_world(db, Map.get(phase2, "world", %{}), ids)
                phase2_call = build_call(phase2["call"] || kase["call"], phase2_ids)

                assert {:ok, _} = Dispatch.dispatch(db, handlers, phase2_call)
                assert %{status: "closed"} = RailRemedy.episode(db, rule, assignment_id)
                assert review_effect_count(db, assignment_id) == 1
              end

            "none" ->
              assert {:ok, _} = Dispatch.dispatch(db, handlers, call)
              assert RailRemedy.episode(db, fixture_rule_name(fixture), assignment_id) == nil
              assert review_effect_count(db, assignment_id) == 0
              refute lifecycle_kind?(db, "rail_remedy")
          end
        after
          GenServer.stop(pid)
        end
      end)
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  defp run_supervision_actor(fixture) do
    base = temp_dir!("conformance-supervision-actor")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})), %{})

    try do
      Enum.each(fixture["cases"], fn kase ->
        {db, pid} = memory_db!()

        try do
          ids = materialize_world(db, Map.get(kase, "world", %{}))
          seed_script_checkout!(base, fixture, kase, db)
          call = build_call(kase["call"], ids)
          handlers = Gateway.handlers(%{db: db})
          session_key = call.principal |> elem(1)
          assignment_id = call.params.assignment_id
          terminal_seq = Map.fetch!(ids.turns, session_key)
          result = Supervision.evaluate(db, handlers, 3, session_key, terminal_seq)
          rule = fixture_rule_name(fixture)

          case kase["expect"] do
            "run-remedy" ->
              assert result == {:acted, :rail_remedy}
              assert %{status: "live"} = RailRemedy.episode(db, rule, assignment_id)
              assert review_effect_count(db, assignment_id) == 1
              assert Supervision.prod_state(db, assignment_id) == nil
              assert sweep_decision?(db, session_key, rule, "run-remedy")

            "re-obligate" ->
              assert result == {:prodded, 1}
              assert RailRemedy.episode(db, rule, assignment_id) == nil
              assert Supervision.prod_state(db, assignment_id).prodCount == 1
              assert sweep_decision?(db, session_key, rule, "re-obligate")

            "none" ->
              assert RailRemedy.episode(db, rule, assignment_id) == nil

              cond do
                fixture["name"] == "adjudication-hold-order" and
                    Map.get(kase["world"], "adjudication_episode", []) != [] ->
                  assert result == {:held, :adjudication_hold}

                  assert %{lastEvaluatedTerminal: ^terminal_seq} =
                           Supervision.watermark(db, session_key)

                  assert Supervision.prod_state(db, assignment_id) == nil
                  refute lifecycle_kind?(db, "rail_sweep")

                fixture["name"] == "busy-or-queued-no-sweep" ->
                  assert result == :busy
                  assert Supervision.prod_state(db, assignment_id) == nil
                  refute lifecycle_kind?(db, "rail_sweep")

                self_wake?(db, call) ->
                  assert result == :continuation
                  assert Supervision.prod_state(db, assignment_id) == nil
                  refute lifecycle_kind?(db, "rail_sweep")

                true ->
                  assert sweep_decision?(db, session_key, nil, "none")
              end
          end

          if fixture["name"] == "idle-open-obligation" and kase["kind"] == "positive" do
            effect_count = review_effect_count(db, assignment_id)
            lifecycle_count = length(EventLog.lifecycle_events(db))

            assert Supervision.evaluate(db, handlers, 3, session_key, terminal_seq) == :duplicate
            assert review_effect_count(db, assignment_id) == effect_count
            assert length(EventLog.lifecycle_events(db)) == lifecycle_count
          end

          if kase["kind"] == "legibility" do
            assert lifecycle_kind?(db, "rail_sweep")
            assert_declared_records!(kase["emits"], latest_denied_payload(db), db)
          end
        after
          GenServer.stop(pid)
        end
      end)
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  defp run_capstone_actor(fixture) do
    run_dispatch_actor(Map.put(fixture, "class", "C6"))
  end

  defp memory_db! do
    name = :"conformance_db_#{System.unique_integer([:positive])}"
    {:ok, pid} = DB.start_link(path: ":memory:", name: name)

    for module <- [
          Devices,
          Idempotency,
          Projection,
          Org,
          Roles,
          WorkItems,
          Assignments,
          WorkState,
          EventLog,
          Producers,
          Ledger,
          ConditionFacts,
          Wakes,
          Supervision,
          Adjudication,
          Escalation,
          RailRemedy
        ] do
      :ok = module.ensure_schema(name)
    end

    {name, pid}
  end

  defp materialize_world(
         db,
         world,
         ids \\ %{assignments: %{}, work_items: %{}, producer_jobs: %{}, turns: %{}}
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
        host: session["host"] || Placement.local_host_name()
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

    producer_verdicts = Map.get(world, "producer_verdict", [])

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

    if Map.has_key?(world, "adjudicate") do
      flunk(
        "world.adjudicate cannot bypass the pinned owner verb; " <>
          "the governing spec's {session, hold} shape does not match Gateway adjudicate"
      )
    end

    Enum.each(Map.get(world, "adjudication_episode", []), fn episode ->
      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO adjudication_episodes
            (sessionKey, condition, status, correlationKey, deadlineAt, openedAt)
          VALUES (?1, 'other', ?2, ?3, 4102444800000, 1)
          """,
          [episode["session"], episode["status"], "fixture-#{episode["session"]}"]
        )
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

    Enum.each(producer_verdicts, fn verdict ->
      assignment_id = assignments[verdict["assignment"]]
      kind = Map.fetch!(%{"build" => "tests", "smoke" => "smoke"}, verdict["producer"])

      assert {:ok, [[by_session, by_user, by_harness, by_provider]]} =
               DB.query(
                 db,
                 """
                 SELECT bySession, byUser, byHarness, byProvider
                 FROM producer_jobs
                 WHERE assignmentId=?1 AND kind=?2 AND command=?3
                 """,
                 [assignment_id, kind, verdict["producerCommand"]]
               )

      {:ok, {:ok, _}} =
        DB.transaction(db, fn txn ->
          Assignments.insert_producer_verdict_in_txn(txn, %{
            assignment_id: assignment_id,
            verdict_kind: verdict["verdict_kind"],
            producer: verdict["producer"],
            producer_command: verdict["producerCommand"],
            by_session: by_session,
            by_user: by_user,
            by_harness: by_harness,
            by_provider: by_provider
          })
        end)
    end)

    Enum.each(Map.get(world, "wakes", []), fn wake ->
      Wakes.schedule(db, %{
        session_key: wake["target"],
        target_role: nil,
        origin: "process:conformance",
        prompt: "conformance continuation",
        due_at: wake["at"],
        creator_session_key: wake["creatorSessionKey"]
      })
    end)

    turns =
      Enum.reduce(List.wrap(Map.get(world, "turn", [])), ids.turns, fn turn, turns ->
        if is_nil(turn["seq"]) do
          Map.put(turns, turn["session"], nil)
        else
          message_id = "conformance-terminal-#{System.unique_integer([:positive])}"

          assert {:ok, seq} =
                   Ledger.enqueue(db, %{
                     session_key: turn["session"],
                     message_id: message_id,
                     origin: "user:conformance",
                     prompt: "terminal"
                   })

          assert seq == turn["seq"]
          assert {:ok, %{seq: ^seq}} = Ledger.claim_next(db, turn["session"], "conformance")
          assert :ok = Ledger.finish(db, seq, "delivered")
          Map.put(turns, turn["session"], seq)
        end
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

    Enum.each(Map.get(world, "sessions", []), fn session ->
      if Map.has_key?(session, "adjudicationHold") do
        {:ok, _} =
          DB.query(db, "UPDATE sessions SET adjudicationHold=?2 WHERE sessionKey=?1", [
            session["key"],
            session["adjudicationHold"]
          ])
      end
    end)

    %{
      assignments: assignments,
      work_items: work_items,
      producer_jobs: producer_jobs,
      turns: turns
    }
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
        assert production_finish_producer_job(db, job) == :done
        assert production_finish_producer_job(db, job) == :noop
        assert Producers.fail_running(db, job_id, "losing failure") == :noop
        assert [verdict] = Assignments.list_attests(db, job.assignment_id)
        assert verdict.byHarness == job.by_harness
        assert verdict.byProvider == job.by_provider
        assert verdict.producer == job.producer
        assert verdict.producerCommand == job.command
    end
  end

  defp production_finish_producer_job(db, job) do
    base = temp_dir!("conformance-producer-finish")
    {:ok, runner} = Tightbeam.ConformanceProducerRegistry.start_link()

    try do
      Producers.execute(db, %{base_dir: base, port: 0}, job, runner)
    after
      GenServer.stop(runner)
      File.rm_rf!(base)
    end
  end

  defp first_user(world), do: world |> Map.get("users", []) |> List.first() |> Map.fetch!("id")

  defp prepare_rule_base!(base, fixture, opts \\ []) do
    rules_dir = Path.join(base, "identity/rules")
    File.mkdir_p!(rules_dir)
    File.write!(Path.join(rules_dir, "fixture.toml"), serialize_rules(fixture["rule"]))

    scripts =
      fixture["rule"]
      |> Enum.map(&get_in(&1, ["check", "script"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if scripts != [] do
      scripts_dir = Path.join(base, "identity/rails/scripts")
      bin_dir = Path.join(base, "bin")
      File.mkdir_p!(scripts_dir)
      File.mkdir_p!(bin_dir)

      Enum.each(scripts, fn script ->
        local_source = Path.join([Path.dirname(fixture["path"]), "scripts", script])

        source =
          if File.regular?(local_source) do
            local_source
          else
            Path.join([
              Path.dirname(Path.dirname(fixture["path"])),
              "c5_script_guards",
              "scripts",
              script
            ])
          end

        destination = Path.join(scripts_dir, script)
        File.cp!(source, destination)
        File.chmod!(destination, 0o755)
      end)

      wrapper = Path.join(bin_dir, "tightbeam")
      real_rail_exec? = Keyword.get(opts, :real_rail_exec, false) or scripts != []
      if real_rail_exec?, do: ensure_real_rail_exec!()

      source =
        if real_rail_exec?,
          do: Path.expand("../cli/target/release/tightbeam", __DIR__),
          else: Path.join([__DIR__, "fixtures", "rail_exec", "tightbeam"])

      File.cp!(source, wrapper)
      File.chmod!(wrapper, 0o755)
    end
  end

  defp ensure_real_rail_exec! do
    cli_dir = Path.expand("../cli", __DIR__)
    binary = Path.join(cli_dir, "target/release/tightbeam")

    unless executable?(binary) do
      {output, status} =
        System.cmd("cargo", ["build", "--release"], cd: cli_dir, stderr_to_stdout: true)

      assert status == 0, output
    end

    assert executable?(binary), "real tightbeam rail-exec binary is unavailable"
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, stat} -> Bitwise.band(stat.mode, 0o111) != 0
      {:error, _} -> false
    end
  end

  defp seed_script_checkout!(base, fixture, kase, db) do
    if Enum.any?(fixture["rule"], &get_in(&1, ["check", "script"])) do
      seed_checked_rule_checkout!(base, fixture, kase, db)
    else
      :ok
    end
  end

  defp seed_checked_rule_checkout!(base, fixture, kase, db) do
    holder = Org.get(db, "holder")
    workdir = Placement.holder_workdir(%{base_dir: base, port: 0}, holder)

    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    File.write!(Path.join(workdir, ".tightbeam-conformance-mode"), script_mode(kase))
    git!(workdir, ["init", "-b", "main"])
    git!(workdir, ["config", "user.email", "conformance@tightbeam.test"])
    git!(workdir, ["config", "user.name", "Tightbeam Conformance"])
    File.write!(Path.join(workdir, "README.md"), "base\n")
    git!(workdir, ["add", "README.md"])
    git!(workdir, ["commit", "-m", "base"])

    case fixture["name"] do
      name
      when name in ~w(reconcile-with-main script-result-remedy turn-end-script-gate capstone-tests-before-success) ->
        git!(workdir, ["switch", "-c", "feature"])

        if kase["script_return"] == "behind" do
          git!(workdir, ["switch", "main"])
          File.write!(Path.join(workdir, "README.md"), "base\nmain advanced\n")
          git!(workdir, ["add", "README.md"])
          git!(workdir, ["commit", "-m", "advance main"])
          git!(workdir, ["switch", "feature"])
        end

      "files-touched-observed" ->
        git!(workdir, ["switch", "-c", "feature"])
        changed = if kase["script_return"] == "within-declared", do: "lib/a.ex", else: "lib/b.ex"
        path = Path.join(workdir, changed)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "changed\n")
        git!(workdir, ["add", changed])
        git!(workdir, ["commit", "-m", "feature change"])

      "predicate-prefilter-script-laziness" ->
        :ok
    end
  end

  defp script_mode(%{"script_return" => "out-of-set"}), do: "out-of-set\n"
  defp script_mode(%{"script_return" => "error:13"}), do: "error\n"
  defp script_mode(%{"script_return" => "timeout"}), do: "timeout\n"
  defp script_mode(_kase), do: "git\n"

  defp git!(workdir, args) do
    {output, status} = System.cmd("git", args, cd: workdir, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{output}"
  end

  defp sweep_call(%{"class" => "C7"}, call), do: Map.put(call, :edge, :turn_end)
  defp sweep_call(_fixture, call), do: call

  defp self_wake?(db, %{principal: {:session, session_key}}),
    do: Wakes.self_pending_count(db, session_key) > 0

  defp self_wake?(_db, _call), do: false

  defp suppressed_before_decision?(%{"class" => "C7"}, kase) do
    world = Map.get(kase, "world", %{})

    List.wrap(Map.get(world, "ledger", []))
    |> Enum.any?(&(Map.get(&1, "pending", 0) > 0)) or
      Map.get(world, "adjudication_episode", []) != [] or
      get_in(world, ["turn", "seq"]) == nil
  end

  defp suppressed_before_decision?(_fixture, _kase), do: false

  defp fixture_rule_name(fixture), do: fixture["rule"] |> List.first() |> Map.fetch!("name")

  defp review_effect_count(db, assignment_id) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT COUNT(*) FROM assignments WHERE reviewsAssignmentId = ?1", [
        assignment_id
      ])

    count
  end

  defp completion_call(assignment_id) do
    %{
      verb: "attest",
      origin: "agent:holder",
      principal: {:session, "holder"},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: "completion"}
    }
  end

  defp new_assignment!(db, holder, subject) do
    result =
      Assignments.__handle__(db, "assign", %{
        verb: "assign",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: holder,
        target_role: nil,
        role_fallback: false,
        params: %{subject: subject, idempotency_key: nil}
      })

    assert is_binary(result.id)
    result.id
  end

  defp attest_verdict!(db, assignment_id, by_session, verdict_kind) do
    result =
      Assignments.__handle__(db, "attest", %{
        verb: "attest",
        origin: "agent:#{by_session}",
        principal: {:session, by_session},
        session_key: nil,
        params: %{
          assignment_id: assignment_id,
          kind: "verdict",
          verdict_kind: verdict_kind
        }
      })

    refute Map.has_key?(result, :code)
    result
  end

  defp revoke_assignment!(db, assignment_id) do
    result =
      Assignments.__handle__(db, "revoke-assignment", %{
        verb: "revoke-assignment",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: nil,
        params: %{assignment_id: assignment_id}
      })

    refute Map.has_key?(result, :code)
    result
  end

  defp remedy_lifecycle_details(db) do
    db
    |> EventLog.lifecycle_events()
    |> Enum.filter(&(&1.kind == "rail_remedy"))
    |> Enum.map(&JSON.decode!(&1.detail))
  end

  defp remedy_principal_recorded?(db, rule) do
    {:ok, rows} =
      DB.query(db, "SELECT principal FROM events WHERE kind = 'verb' AND verb = 'assign'")

    Enum.any?(rows, fn [principal] -> principal == "remedy:assign:#{rule}" end)
  end

  defp lifecycle_kind?(db, kind) do
    Enum.any?(EventLog.lifecycle_events(db), &(&1.kind == kind))
  end

  defp latest_denied_payload(db) do
    case DB.query(
           db,
           "SELECT payload FROM events WHERE kind = 'denied' ORDER BY id DESC LIMIT 1"
         ) do
      {:ok, [[payload]]} -> JSON.decode!(payload)
      {:ok, []} -> %{}
    end
  end

  defp lifecycle_outcome?(db, kind, subject, outcome) do
    Enum.any?(EventLog.lifecycle_events(db), fn event ->
      event.kind == kind and event.subject == subject and
        JSON.decode!(event.detail)["outcome"] == outcome
    end)
  end

  defp sweep_decision?(db, session_key, statute, decision) do
    Enum.any?(EventLog.lifecycle_events(db), fn event ->
      detail = JSON.decode!(event.detail)

      event.kind == "rail_sweep" and event.subject == session_key and
        detail["statute"] == statute and detail["decision"] == decision
    end)
  end

  defp build_call(raw, ids) do
    principal = principal(raw["principal"])
    params = atomize(raw["params"])

    params =
      if params[:assignment_id],
        do: %{params | assignment_id: ids.assignments[params.assignment_id]},
        else: params

    params =
      if params[:reviews_assignment_id],
        do: %{
          params
          | reviews_assignment_id:
              Map.get(
                ids.assignments,
                params.reviews_assignment_id,
                params.reviews_assignment_id
              )
        },
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
      conditions = Enum.map_join(Map.get(rule, "deny_when", []), ",\n  ", &toml_inline/1)

      base = """
      [[rule]]
      name = #{toml_value(rule["name"])}
      verb = #{toml_value(rule["verb"])}
      text = #{toml_value(rule["text"])}
      external_producer = #{toml_value(Map.get(rule, "external_producer", false))}
      #{optional_toml("edges", rule["edges"])}
      #{optional_toml("effect", rule["effect"])}
      deny_when = [
        #{conditions}
      ]
      """

      base <> serialize_check(rule["check"]) <> serialize_remedy(rule["remedy"])
    end)
  end

  defp serialize_check(nil), do: ""

  defp serialize_check(check) do
    effects =
      Enum.map_join(check["effects"], "\n", fn {token, effect} ->
        "#{token} = #{toml_value(effect)}"
      end)

    """
    [rule.check]
    script = #{toml_value(check["script"])}
    returns = #{toml_value(check["returns"])}
    timeout_ms = #{toml_value(Map.get(check, "timeout_ms", 5_000))}
    [rule.check.effects]
    #{effects}
    """
  end

  defp serialize_remedy(nil), do: ""

  defp serialize_remedy(remedy) do
    fields =
      remedy
      |> Map.drop(["params"])
      |> Enum.map_join("\n", fn {key, value} -> "#{key} = #{toml_value(value)}" end)

    params =
      remedy
      |> Map.get("params", %{})
      |> Enum.map_join("\n", fn {key, value} -> "#{key} = #{toml_value(value)}" end)

    """
    [rule.remedy]
    #{fields}
    [rule.remedy.params]
    #{params}
    """
  end

  defp optional_toml(_key, nil), do: ""
  defp optional_toml(key, value), do: "#{key} = #{toml_value(value)}"

  defp toml_inline(map) do
    "{ " <>
      Enum.map_join(map, ", ", fn {key, value} -> "#{key} = #{toml_value(value)}" end) <> " }"
  end

  defp toml_value(value) when is_binary(value), do: inspect(value)
  defp toml_value(value) when is_boolean(value) or is_integer(value), do: to_string(value)

  defp toml_value(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ", ", &toml_value/1) <> "]"

  defp temp_dir!(prefix) do
    # Canonicalize the tmp base: on Darwin System.tmp_dir!/0 sits under the /var
    # symlink (/var -> /private/var), and Containment.profile/1 refuses write
    # roots with unresolved symlink components.
    base = to_string(:string.trim(:os.cmd(~c(realpath #{System.tmp_dir!()}))))
    path = Path.join(base, "#{prefix}-#{System.unique_integer([:positive])}")
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
    green =
      Enum.count(
        @fixtures,
        &(&1["phase"] == "green" and &1["class_phase"] == "green")
      )

    pending = length(@fixtures) - green

    structured =
      Enum.count(@fixtures, &(&1["phase"] == "green" and &1["kind"] == "dispatch-rule"))

    class_pending = Enum.count(@classes, &(&1["phase"] == "pending"))

    IO.puts(
      "conformance census: #{green} green fixtures; #{pending} pending fixtures; " <>
        "#{structured} structured-legibility assertion sets active; #{class_pending} pending classes"
    )

    assert green == 13
    assert pending == 59
  end

  test "pending fixtures and case-level blockers are reported exactly" do
    entries = Corpus.pending_entries(@corpus)

    Enum.each(entries, fn entry ->
      IO.puts(
        "conformance pending #{entry.scope}: #{entry.id} " <>
          "phase=#{entry.phase} blocker=#{entry.blocker}"
      )
    end)

    assert Enum.count(entries, &(&1.scope == "fixture")) == 59

    assert %{
             scope: "case",
             id: "C5/reconcile-with-main/contained-refused",
             phase: "pending-runtime",
             blocker: "runtime"
           } in entries

    for id <- [
          "C6/escalation-return-dispatch",
          "C6/escalation-continue-the-fold",
          "C7/escalation-return-sweep"
        ] do
      assert Enum.any?(entries, fn entry ->
               entry == %{
                 scope: "fixture",
                 id: id,
                 phase: "pending-escalation-review",
                 blocker: "escalation-substrate-v1 review-clean"
               }
             end)
    end
  end

  test "C7 claimed and notified adjudication episodes suppress rails and prod before watermark" do
    fixture = fixture!("C7", "adjudication-hold-order")
    Corpus.run_rules_decide(fixture)
    Corpus.run_acting_layer(fixture)
  end

  test "C4 producer completion races commit at most one frozen verdict" do
    Corpus.run_producer_cas_races(fixture!("C4", "producer-cas-verdict-txn"))
  end

  test "C5 real rail-exec drives git state, observed files, exit bands, CWD, and laziness" do
    for name <- [
          "reconcile-with-main",
          "files-touched-observed",
          "predicate-prefilter-script-laziness"
        ] do
      Corpus.run_rail_exec_fixture(fixture!("C5", name))
    end
  end

  test "handler refusal covers all canonical codes and leaves no assignment survivor" do
    Corpus.run_handler_refusal_fixture(fixture!("C4", "declared-files-overlap"))
  end

  test "C6 review remedy claims once, dispatches once, and closes after the verdict" do
    fixture = fixture!("C6", "review-remedy-spawn")
    Corpus.run_rules_decide(fixture)
    Corpus.run_acting_layer(fixture)
  end

  test "C6 remedy episode matrix fences races, reclaims, rewakes, replaces, and retries" do
    Corpus.run_remedy_episode_contract(fixture!("C6", "review-remedy-spawn"))
  end

  test "C6 remedy action matrix dispatches assign, wake, and spawn through target schemas" do
    Corpus.run_remedy_action_contract(fixture!("C6", "remedy-action-breadth"))
  end

  test "C6 escalation union opens, rereturns, denies, continues, consumes, and fences CAS loss" do
    Corpus.run_escalation_dispatch_contract(
      fixture!("C6", "escalation-return-dispatch"),
      fixture!("C6", "escalation-continue-the-fold")
    )
  end

  test "C5 script tokens drive C6 dispatch remedies and C7 turn-end remedies" do
    for {class, name} <- [
          {"C6", "script-result-remedy"},
          {"C7", "turn-end-script-gate"}
        ] do
      fixture = fixture!(class, name)
      Corpus.run_rules_decide(fixture)
      Corpus.run_acting_layer(fixture)
    end
  end

  test "C7 idle obligation acts at most once for the same terminal watermark" do
    fixture = fixture!("C7", "idle-open-obligation")
    Corpus.run_rules_decide(fixture)
    Corpus.run_acting_layer(fixture)
  end

  test "C7 busy ledger state suppresses action and idle state re-obligates" do
    Corpus.run_acting_layer(fixture!("C7", "busy-or-queued-no-sweep"))
  end

  test "C7 satisfied obligation performs no rail action and unsatisfied state re-obligates" do
    fixture = fixture!("C7", "satisfied-obligation-no-sweep")
    Corpus.run_rules_decide(fixture)
    Corpus.run_acting_layer(fixture)
  end

  test "C7 prechecks retired holders, preserves watermark semantics, and reuses escalation park" do
    Corpus.run_supervision_state_contract(
      fixture!("C7", "retired-holder-no-remedy"),
      fixture!("C7", "watermark-nil-duplicate"),
      fixture!("C7", "escalation-return-sweep")
    )
  end

  test "C7 sweep leaves rulings unconsumed and the verb edge consumes exactly once" do
    Corpus.run_sweep_ruling_contract(fixture!("C7", "sweep-never-consumes"))
  end

  test "Cap reviewer, judge, tests, and real-run loops compose dispatch, producer, and sweep actors" do
    Corpus.run_capstone_contracts(
      fixture!("Cap", "capstone-reviewer-loop"),
      fixture!("Cap", "capstone-yagni-judge"),
      fixture!("Cap", "capstone-spec-review"),
      fixture!("Cap", "capstone-tests-before-success"),
      fixture!("Cap", "capstone-real-run-before-ship")
    )
  end

  test "loader rejects a case fixture with no negative direction" do
    with_corpus_copy(fn root ->
      path = Path.join(root, "c2_dispatch_predicates/admin-only-verb.cases.jsonl")

      cases =
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.reject(&(JSON.decode!(&1)["kind"] == "negative"))
        |> Enum.join("\n")

      File.write!(path, cases <> "\n")

      assert_raise ExUnit.AssertionError, ~r/missing negative case/, fn ->
        Corpus.load_corpus!(root)
      end
    end)
  end

  test "loader rejects a sampled complex matrix" do
    with_corpus_copy(fn root ->
      path = Path.join(root, "c6_remedies/remedy-episode-idempotent.cases.jsonl")

      cases =
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.reject(&(JSON.decode!(&1)["case"] == "reclaim-stale-claim-preserves-occurrence"))
        |> Enum.join("\n")

      File.write!(path, cases <> "\n")

      assert_raise ExUnit.AssertionError, ~r/missing locked matrix cases/, fn ->
        Corpus.load_corpus!(root)
      end
    end)
  end

  test "loader rejects empty complex worlds" do
    with_corpus_copy(fn root ->
      path = Path.join(root, "capstone/capstone-reviewer-loop.cases.jsonl")

      [first | rest] =
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)

      encoded =
        [%{first | "world" => %{}} | rest]
        |> Enum.map_join("\n", &JSON.encode!/1)

      File.write!(path, encoded <> "\n")

      assert_raise ExUnit.AssertionError, ~r/needs an observable world/, fn ->
        Corpus.load_corpus!(root)
      end
    end)
  end

  test "loader rejects a missing load-rejection twin" do
    with_corpus_copy(fn root ->
      File.rm!(Path.join(root, "c6_remedies/remedy-target-present.load.toml"))

      assert_raise ExUnit.AssertionError, ~r/missing load-clean twin remedy-target-present/, fn ->
        Corpus.load_corpus!(root)
      end
    end)
  end

  test "loader rejects a non-executable C5 script" do
    with_corpus_copy(fn root ->
      script = Path.join(root, "c5_script_guards/scripts/reconcile-with-main")
      File.chmod!(script, 0o644)

      assert_raise ExUnit.AssertionError, ~r/is not executable/, fn ->
        Corpus.load_corpus!(root)
      end
    end)
  end

  test "the unchanged corpus loads from a generated-rail root" do
    with_corpus_copy(fn root ->
      copied = Corpus.load_corpus!(root)

      assert Enum.map(copied.fixtures, &{&1["class"], &1["name"], &1["phase"]}) ==
               Enum.map(@fixtures, &{&1["class"], &1["name"], &1["phase"]})
    end)
  end

  test "c1-shipped-parity reads canonical priv law" do
    Corpus.assert_shipped_parity(Enum.filter(@fixtures, &(&1["class"] == "C1")), @root)
  end

  test "c1-wiring-claude compiles and refuses the reserved probe" do
    Corpus.assert_claude_wiring(@root)
  end

  test "containment dependencies are named and green" do
    dependency = Path.expand("../containment_test.exs", @root)
    assert File.regular?(dependency)

    {output, status} =
      System.cmd("mix", ["test", dependency, "--trace"],
        cd: Path.expand("."),
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    assert status == 0, output
    assert output =~ "0 failures"
    assert output =~ "sandbox-exec enforces resolved write roots and preserves stdout"
  end

  for fixture <- @fixtures do
    name = "#{fixture["class"]}/#{fixture["name"]}"

    if fixture["phase"] == "green" and fixture["class_phase"] == "green" do
      test name do
        fixture = unquote(Macro.escape(fixture))

        Enum.each(fixture["runners"], fn
          "compiled_hook_grep" -> Corpus.run_compiled_hook_fixture(fixture, @root)
          "rail_exec" -> Corpus.run_rail_exec_fixture(fixture)
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
      blocking_phase = fixture["blocking_phase"]

      @tag skip: "#{fixture["phase"]}: #{blocking_phase}"
      test name do
        fixture = unquote(Macro.escape(fixture))
        Corpus.run_pending_fixture(fixture, @fixtures, unquote(blocking_phase))
      end
    end
  end

  for class <- @classes, class["phase"] == "pending" do
    @tag skip: "#{class["blocking_phase"]}: #{class["title"]} fixtures land on their own lane"
    test "#{class["id"]} class registered pending" do
      class = unquote(Macro.escape(class))
      assert class["phase"] == "pending"
      assert class["blocking_phase"] != ""
    end
  end

  defp fixture!(class, name) do
    Enum.find(@fixtures, &(&1["class"] == class and &1["name"] == name)) ||
      flunk("missing fixture #{class}/#{name}")
  end

  defp with_corpus_copy(fun) do
    root =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-conformance-copy-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.cp_r!(@root, root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
