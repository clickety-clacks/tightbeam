defmodule Tightbeam.ConformanceLaneManager do
  use GenServer
  alias Tightbeam.Model

  def start_link, do: GenServer.start_link(__MODULE__, :ok, name: Tightbeam.LaneManager)
  def init(:ok), do: {:ok, :ok}

  def handle_call({:ensure_lane, _session_key}, _from, state),
    do: {:reply, :ok, state}
end

defmodule Tightbeam.ConformanceSupport do
  alias Tightbeam.Model
  import ExUnit.Assertions
  import Tightbeam.TestCase, only: [catalog_reply: 1]

  alias Tightbeam.{
    Archetypes,
    Assignments,
    ConnRegistry,
    DB,
    Dispatch,
    Escalation,
    EventLog,
    Gateway,
    Ledger,
    ModelCatalog,
    Org,
    Placement,
    RailRemedy,
    Rails,
    Roles,
    Rules,
    Supervision,
    Wakes,
    WorkItems
  }

  @fixture_keys MapSet.new(
                  ~w(class name phase blocking_phase kind source legibility shipped_ref pattern rule)
                )
  @case_keys MapSet.new(
               ~w(case kind expect reason emits input script_return world call phase2 phase)
             )
  @expects MapSet.new(
             ~w(deny pass refuse run-remedy re-obligate escalate-park none escalate-halt escalate-open escalate-continue load-raise load-clean digest immediate bypass inhibited unclassed filed gates-nothing answered withdrawn not-rulable page resume unpaged exhausted roster-page)
           )
  @case_expects %{
    "harness-gate" => ~w(deny pass),
    "dispatch-rule" => ~w(deny pass),
    "script-guard" => ~w(deny pass),
    "handler-refusal" => ~w(refuse pass),
    "remedy" => ~w(run-remedy none escalate-halt escalate-open escalate-continue),
    "sweep" => ~w(run-remedy re-obligate escalate-park none escalate-continue),
    "capstone" => ~w(deny pass run-remedy re-obligate none),
    # The five outcomes the delivery policy can reach, plus the one refusal it
    # owes. Named exhaustively so a sixth outcome cannot be smuggled in as a
    # variant of an existing word (coordination-fabric-v1 §5, §7).
    "delivery-policy" => ~w(digest immediate bypass inhibited unclassed refuse),
    # Seam ③. `gates-nothing` is the anti-adjudication outcome and is a WORD OF
    # ITS OWN rather than a flavour of `filed`, so a change that quietly let a
    # question hold a completion would have to delete a named outcome to pass.
    "question-carrier" => ~w(filed gates-nothing answered withdrawn not-rulable refuse),
    # Seam ④. `unpaged` is likewise its own word: the contract that an unlimited
    # read still returns everything is the one a default page size would break.
    "read-cursor" => ~w(page resume unpaged exhausted roster-page refuse),
    # A live engine switch has exactly two outcomes the substrate may reach: it
    # applies, or it says no by name. There is no third word — no "queued", no
    # "applied at the next boundary", no "switched to the nearest available" —
    # because each of those would be the substrate deciding something on the
    # caller's behalf (v0.2 program §4). Enumerated so adding one would have to
    # be written down here first.
    "live-switch" => ~w(refuse pass)
  }
  @load_twins [
    ~w(remedy-target-missing remedy-target-present),
    ~w(static-blocker-unsatisfiable runtime-conditional-blocker-loads),
    ~w(dead-remedy live-remedy),
    ~w(dead-gate artifact-backed-gate),
    ~w(grammar-root-table-rejected grammar-nested-accepted)
  ]
  @world_keys MapSet.new(
                ~w(users sessions roles work_items assignments attests stored_attests retune ledger wakes turn)
              )
  @world_shapes %{
    "users" => ~w(id admin),
    "sessions" => ~w(key owner archetype harness provider host model),
    "roles" => ~w(name session),
    "work_items" => ~w(id title),
    "assignments" => ~w(id holder creator reviews work_item files),
    "attests" => ~w(assignment kind by verdict_kind),
    "stored_attests" => ~w(assignment kind by verdict_kind),
    "retune" => ~w(session harness provider),
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
      ~w(rail-enforcement-precedes-self-pending-wake rail-enforcement-precedes-process-pending-wake allow-falls-through-to-pending-wake-gate schedule-order-legible),
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
      ~w(missing-yagni-judge-fires-remedy wrong-work-item-verdict-stays-denied commissioned-yagni-clean-passes yagni-loop-legible),
    {"Cap", "capstone-spec-review"} =>
      ~w(missing-spec-review-fires-remedy wrong-work-item-verdict-stays-denied commissioned-spec-reviewed-passes spec-review-loop-legible)
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

  defp applicable_runners("delivery-policy", runners),
    do: Enum.filter(runners, &(&1 == "delivery_policy"))

  defp applicable_runners("question-carrier", runners),
    do: Enum.filter(runners, &(&1 == "question_carrier"))

  defp applicable_runners("read-cursor", runners),
    do: Enum.filter(runners, &(&1 == "read_cursor"))

  defp applicable_runners("live-switch", runners),
    do: Enum.filter(runners, &(&1 == "live_switch"))

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
      rows = if key in ~w(ledger turn), do: List.wrap(rows), else: rows
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

  # INVARIANT: every clause below runs the contract for THE FIXTURE IT WAS GIVEN,
  # or names the other fixtures it aggregates explicitly. No `_` catch-all may
  # substitute a foreign fixture's contract — that reports PASS for a fixture
  # whose own cases never ran. A fixture with no runner belongs in
  # `@unsupported_fixtures` with a reason, not in a catch-all.
  def run_pending_fixture(fixture, fixtures, blocker) do
    assert_pending_registration(fixture, blocker)

    find = fn class, name ->
      Enum.find(fixtures, &(&1["class"] == class and &1["name"] == name)) ||
        flunk("missing pending proof fixture #{class}/#{name}")
    end

    case {fixture["class"], fixture["kind"], fixture["name"]} do
      {"C2", _, name} when name in ~w(handoff-assign handoff-wake) ->
        run_rules_fixture(fixture)

      {"C3", _, "two-changes-requested-revert"} ->
        run_rules_fixture(fixture)

      {"C4", _, "declared-files-overlap"} ->
        run_handler_refusal_fixture(fixture)

      {"C4", _, "reopen-assignment-repair"} ->
        run_reopen_assignment_fixture(fixture)

      {"C4", _, _} ->
        run_rules_fixture(fixture)

      {"C5", _, _} ->
        run_rail_exec_fixture(fixture)

      {"C6", "load-rejection", _} ->
        run_load_assert(fixture)

      {"C6", _, "review-remedy-spawn"} ->
        run_rules_decide(fixture)
        run_acting_layer(fixture)

      {"C6", _, "remedy-action-breadth"} ->
        run_remedy_action_contract(fixture)

      {"C6", _, "script-result-remedy"} ->
        run_rules_decide(fixture)
        run_acting_layer(fixture)

      {"C6", _, "escalation-return-dispatch"} ->
        run_escalation_return_dispatch_contract(fixture)

      {"C6", _, "escalation-continue-the-fold"} ->
        run_escalation_dispatch_contract(
          find.("C6", "escalation-return-dispatch"),
          find.("C6", "escalation-continue-the-fold")
        )

      {"C6", _, "remedy-episode-idempotent"} ->
        run_remedy_episode_contract(fixture)

      {"C7", _, name}
      when name in ~w(idle-open-obligation busy-or-queued-no-sweep satisfied-obligation-no-sweep) ->
        run_rules_decide(fixture)
        run_acting_layer(fixture)

      {"C7", _, "turn-end-script-gate"} ->
        run_rules_decide(fixture)
        run_acting_layer(fixture)

      {"C7", _, name}
      when name in ~w(retired-holder-no-remedy watermark-nil-duplicate) ->
        run_supervision_state_contract(
          find.("C7", "retired-holder-no-remedy"),
          find.("C7", "watermark-nil-duplicate"),
          find.("C7", "escalation-return-sweep")
        )

      {"C7", _, "escalation-return-sweep"} ->
        run_escalation_return_sweep_contract(fixture)

      {"C7", _, "parkwakeid-reuse"} ->
        run_park_wake_reuse_contract(fixture)

      {"C7", _, "schedule-then-check"} ->
        run_schedule_then_check_contract(fixture)

      {"C7", _, "reobligate-pure-deny"} ->
        run_rules_decide(fixture)
        run_acting_layer(fixture)

      {"C7", _, "scheduled-wake-suppression"} ->
        run_scheduled_wake_contract(fixture)

      {"C7", _, "sweep-never-consumes"} ->
        run_sweep_ruling_contract(fixture)

      # Aggregates all five capstone fixtures, so every one of them IS executed —
      # but it names them, so a SIXTH capstone fixture fails to match loudly
      # instead of silently inheriting a contract that never covers it.
      {"Cap", _, name}
      when name in ~w(capstone-reviewer-loop capstone-yagni-judge capstone-spec-review
                      capstone-tests-before-success capstone-real-run-before-ship) ->
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
    Rules.load!(base, Map.keys(handlers))

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
    Rules.load!(base, Map.keys(handlers))

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

      assert_rule_result(
        kase["case"],
        kase["expect"],
        expected_denial(kase),
        Rules.evaluate(db, call),
        timeout_ctx(db, fixture)
      )

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
          expected_denial(kase),
          Rules.evaluate(db, phase2_call),
          timeout_ctx(db, fixture)
        )
      end
    after
      GenServer.stop(pid)
    end
  end

  defp assert_rule_result(case_id, "deny", {rule, reason}, {:deny, actual}, ctx) do
    assert actual.rule == rule

    assert actual.reason == reason,
           "#{case_id}: denied under #{rule}, but for #{actual.reason} rather than " <>
             "#{reason} — this case proves nothing about the mechanism it names" <>
             Tightbeam.RailTimeoutEvidence.render({:deny, actual}, ctx)
  end

  defp assert_rule_result(_case, "pass", _denial, :ok, _ctx), do: :ok

  defp assert_rule_result(case_id, expect, _denial, actual, ctx),
    do:
      flunk(
        "#{case_id}: expected #{expect}, got #{inspect(actual)}#{Tightbeam.RailTimeoutEvidence.render(actual, ctx)}"
      )

  # The rule NAME cannot tell a genuine denial from a load-induced one: a rail script that
  # blows its budget denies under the SAME rule with reason `script_timeout`, so a case
  # asserting only the name went green while proving nothing about the mechanism it names
  # (task #38's residual class). The `script_return` a fixture already declares determines
  # the reason its mechanism must produce, so both are pinned and a timeout reads RED.
  defp expected_denial(kase), do: {kase["reason"], deny_reason(kase["script_return"])}

  # No script: the denial can only come from the rule's own effect. With one, the wrapper's
  # exit band decides — see RailScript.classify/4 for the bands these mirror.
  defp deny_reason(nil), do: "rule_denied"
  defp deny_reason("out-of-set"), do: "script_out_of_set"
  defp deny_reason("timeout"), do: "script_timeout"
  defp deny_reason("contained"), do: "script_contained_refused"
  defp deny_reason("error:" <> _code), do: "script_error"
  # An in-set token the script returned normally; the effect table denies on it.
  defp deny_reason(_token), do: "rule_denied"

  defp timeout_ctx(db, fixture) do
    %{db: db, timeout_ms: Enum.find_value(fixture["rule"], &get_in(&1, ["check", "timeout_ms"]))}
  end

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

  defp assert_fixture_world(_fixture, _kase, _db, _ids), do: :ok

  # The delivery-policy contract (coordination-fabric-v1 §5, §7, Invariant 3).
  #
  # Every case goes through `Dispatch.dispatch/3` on the `wake` verb — the same
  # chokepoint the wire router uses — so the sender's election crosses the real
  # boundary rather than being handed straight to `Wakes.schedule`. The
  # assertions below are keyed on the case's DECLARED expect and, for a digest,
  # its declared exit `reason`: there is no shared "and also check whatever
  # happened" tail, because a batching mechanism that quietly took a different
  # exit than the one its case names is exactly the failure worth catching.
  def run_delivery_policy_fixture(fixture) do
    Enum.each(fixture["cases"], fn kase ->
      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, Map.get(kase, "world", %{}))
        call = build_call(kase["call"], ids)
        handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})

        assert_delivery_outcome(kase, db, Dispatch.dispatch(db, handlers, call))
      after
        GenServer.stop(pid)
      end
    end)
  end

  defp assert_delivery_outcome(%{"expect" => "refuse"} = kase, db, result) do
    assert {:error, %{code: code}} = result, "#{kase["case"]}: expected a refusal"
    assert code == kase["reason"]

    # A refused election writes NOTHING. A wake row here would mean the
    # substrate accepted a message it told the sender it had rejected.
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM wakes")

    if kase["kind"] == "legibility",
      do: assert(kase["emits"] == "handler:#{code}")
  end

  defp assert_delivery_outcome(kase, db, result) do
    assert {:ok, %{wake_id: wake_id}} = result, "#{kase["case"]}: expected the wake to land"
    wake = Wakes.get(db, wake_id)

    assert_delivery_policy(kase["expect"], kase, db, wake)
  end

  defp assert_delivery_policy("unclassed", _kase, db, wake) do
    assert wake.class == nil
    assert wake.class_election == nil
    assert wake.delivery_rule == nil
    assert Wakes.materialize_digests(db, wake.due_at + 1) == []
  end

  defp assert_delivery_policy("immediate", _kase, db, wake) do
    assert wake.delivery_rule =~ "immediate-delivery"
    assert wake.due_at <= wake.created_at
    assert Wakes.materialize_digests(db, wake.due_at + 1) == []
  end

  defp assert_delivery_policy("bypass", _kase, db, wake) do
    assert wake.delivery_rule =~ "algedonic-bypass"
    assert wake.due_at <= wake.created_at

    assert Wakes.materialize_digests(db, wake.due_at + 1) == [],
           "an alarm the batcher can absorb is not an alarm"
  end

  defp assert_delivery_policy("inhibited", _kase, db, wake) do
    assert wake.delivery_rule == Wakes.inhibited_rule()
    assert wake.class != nil, "inhibiting the batcher must not erase what was said"
    assert wake.due_at > wake.created_at
    assert Wakes.materialize_digests(db, wake.due_at + 1) == []
  end

  defp assert_delivery_policy("digest", kase, db, wake) do
    policy = Wakes.delivery_policy(wake.class)

    assert wake.delivery_rule == Wakes.digest_rule()
    assert wake.class_election == "sender"
    assert wake.due_at - wake.created_at == policy.ceiling_ms

    if policy.skew do
      assert lifecycle_detail(db, "wake_class_policy_skew", wake.wake_id) =~
               "class=#{wake.class}"
    else
      assert lifecycle_detail(db, "wake_class_policy_skew", wake.wake_id) == nil
    end

    case kase["reason"] do
      "ceiling" -> assert_ceiling_exit(kase, db, wake, policy)
      "turn-boundary" -> assert_turn_boundary_exit(db, wake)
      nil -> :ok
    end
  end

  # INVARIANT 3, the idle half: nobody comes back for this session, and the
  # digest still materializes its own turn at the ceiling.
  defp assert_ceiling_exit(kase, db, wake, policy) do
    assert Wakes.materialize_digests(db, wake.created_at + policy.ceiling_ms - 1) == []
    assert [digest_id] = Wakes.materialize_digests(db, wake.created_at + policy.ceiling_ms)

    digest = Wakes.get(db, digest_id)
    assert digest.digest
    assert digest.class == wake.class
    assert digest.prompt =~ Wakes.digest_signature(1)

    # LAW 2: the source row is still here, and it names where its payload went.
    carried = Wakes.get(db, wake.wake_id)
    assert carried.state == "canceled"
    assert carried.prompt == wake.prompt
    assert [%{wake_id: source}] = Wakes.digest_members(db, digest_id)
    assert source == wake.wake_id

    if kase["kind"] == "legibility" do
      detail = lifecycle_detail(db, "wake_digest_materialized", digest_id)
      assert kase["emits"] == "lifecycle:wake_digest_materialized"
      assert detail =~ "rule=#{Wakes.digest_rule()}"
      assert detail =~ "trigger=ceiling"
    end
  end

  # INVARIANT 3, the boundary half: a turn of the target's own ends, and the
  # digest lands there rather than waiting out the ceiling.
  defp assert_turn_boundary_exit(db, wake) do
    seq = System.unique_integer([:positive, :monotonic])

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO turns
          (seq, sessionKey, messageId, origin, prompt, status, createdAt, endedAt)
        VALUES (?1, ?2, ?3, 'user:owner', 'go', 'delivered', ?4, ?5)
        """,
        [seq, wake.session_key, "m_#{seq}", wake.created_at + 1, wake.created_at + 2]
      )

    assert [digest_id] = Wakes.materialize_digests(db, wake.created_at + 3)
    assert Wakes.get(db, digest_id).due_at < wake.due_at
    assert [%{wake_id: source}] = Wakes.digest_members(db, digest_id)
    assert source == wake.wake_id
  end

  defp lifecycle_detail(db, kind, subject) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT detail FROM lifecycle_events WHERE kind = ?1 AND subject = ?2 ORDER BY id DESC LIMIT 1",
        [kind, subject]
      )

    case rows do
      [[detail]] -> detail
      [] -> nil
    end
  end

  # The agent question-carrier contract (fabric §7, §10; GitHub #11).
  #
  # Every case FILES the question through `Dispatch.dispatch/3` and then, per its
  # declared outcome, takes exactly one more step through the same chokepoint.
  # There is no shared tail: a carrier that reached a different outcome than the
  # one its case names is the failure worth catching.
  def run_question_carrier_fixture(fixture) do
    Enum.each(fixture["cases"], fn kase ->
      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, Map.get(kase, "world", %{}))
        handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
        call = build_call(kase["call"], ids)

        assert_question_outcome(
          kase["expect"],
          kase,
          db,
          handlers,
          ids,
          Dispatch.dispatch(db, handlers, call)
        )
      after
        GenServer.stop(pid)
      end
    end)
  end

  defp assert_question_outcome("refuse", kase, db, _handlers, _ids, result) do
    assert {:error, %{code: code}} = result, "#{kase["case"]}: expected a refusal"
    assert code == kase["reason"]

    # A refused question writes NOTHING: no row, and no notification promising
    # a mind something the substrate told the asker it had rejected.
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM decision_requests")
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM wakes WHERE consumer = 'prompt'")
  end

  defp assert_question_outcome("filed", kase, db, _handlers, _ids, result) do
    request = filed!(kase, result)

    assert request.kind == "agent"
    assert request.status == "open"
    assert request.raiser_id == "session:" <> request.raiser_session_key

    # NO ADJUDICATION VOCABULARY. Each of these is a column a gate would need.
    for {field, value} <-
          Map.take(request, [
            :statute_name,
            :action_key,
            :decision,
            :rationale,
            :ruled_by,
            :ruling_fact_id,
            :consumed_at,
            :park_wake_id,
            :answer
          ]) do
      assert value == nil, "#{kase["case"]}: agent question carries #{field}"
    end

    # The carrier: ONE classed notification at the asked session, elected
    # `input-needed` by the asker, batched by seam ②'s own policy.
    assert [wake] = prompt_wakes(db, request.expecter_session_key)
    # The case DECLARES the class the carrier must elect; nothing here infers it.
    assert wake.class == (kase["reason"] || "input-needed")
    assert wake.class_election == "sender"
    assert wake.delivery_rule == Wakes.digest_rule()
    assert wake.prompt =~ request.id

    if kase["kind"] == "legibility" do
      assert kase["emits"] == "lifecycle:decision_request_asked"
      detail = question_lifecycle(db, "decision_request_asked", request.id)
      assert detail =~ "asker=#{request.raiser_id}"
      assert detail =~ "askedOf=#{request.expecter_session_key}"
    end
  end

  # THE TRIPWIRE (fabric §10). The question names the assignment its asker
  # holds, and the completion of that assignment goes through untouched.
  defp assert_question_outcome("gates-nothing", kase, db, handlers, ids, result) do
    request = filed!(kase, result)
    assignment_id = Map.fetch!(ids.assignments, "a1")
    assert request.assignment_id == assignment_id

    assert {:ok, %{attest: %{kind: "completion"}}} =
             Dispatch.dispatch(db, handlers, %{
               verb: "attest",
               origin: "agent:#{request.raiser_session_key}",
               principal: {:session, request.raiser_session_key},
               session_key: nil,
               params: %{assignment_id: assignment_id, kind: "completion"}
             })

    # Still open. The asker disposed of its obligation by its own choice and the
    # question held nothing while it did.
    assert current_status(db, request.id) == "open"
  end

  defp assert_question_outcome("answered", kase, db, handlers, _ids, result) do
    request = filed!(kase, result)

    # A bystander is refused `not_found`, not a kind/authority-revealing
    # `not_asked` (Sol xhigh review, finding 4): an unauthorized caller must
    # not be able to tell this id apart from a fake one.
    assert {:error, %{code: "not_found"}} =
             Dispatch.dispatch(db, handlers, answer_call("bystander", request.id, "not mine"))

    assert {:ok, %{decision_request: answered}} =
             Dispatch.dispatch(
               db,
               handlers,
               answer_call(request.expecter_session_key, request.id, "behind a flag")
             )

    assert answered.status == "answered"
    assert answered.answer == "behind a flag"
    assert answered.answered_by == "session:" <> request.expecter_session_key

    # AN ANSWER IS NOT A RULING: nothing is spent and no condition fact is filed,
    # so no halted call anywhere can be released by it.
    assert answered.decision == nil
    assert answered.consumed_at == nil
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM condition_facts")

    # The asker hears about it, unclassed — delivered as every wake was before
    # Phase 1, because the substrate elects no class on a mind's behalf.
    assert [reply] = prompt_wakes(db, request.raiser_session_key)
    assert reply.class == nil
    assert reply.prompt =~ "behind a flag"
  end

  defp assert_question_outcome("withdrawn", kase, db, handlers, _ids, result) do
    request = filed!(kase, result)

    # The principal that was ASKED cannot take the question away from its asker.
    assert {:error, %{code: "not_raiser"}} =
             Dispatch.dispatch(db, handlers, %{
               verb: "withdraw",
               origin: "agent:#{request.expecter_session_key}",
               principal: {:session, request.expecter_session_key},
               session_key: nil,
               params: %{request: request.id, reason: "not mine"}
             })

    assert {:ok, %{status: "withdrawn"}} =
             Dispatch.dispatch(db, handlers, %{
               verb: "withdraw",
               origin: "agent:#{request.raiser_session_key}",
               principal: {:session, request.raiser_session_key},
               session_key: nil,
               params: %{request: request.id, reason: "worked it out myself"}
             })

    assert current_status(db, request.id) == "withdrawn"
  end

  defp assert_question_outcome("not-rulable", kase, db, handlers, _ids, result) do
    request = filed!(kase, result)

    for verb <- ~w(rule waive) do
      assert {:error, %{code: "invalid", message: message}} =
               Dispatch.dispatch(db, handlers, %{
                 verb: verb,
                 origin: "user:root",
                 principal: {:user, "root"},
                 session_key: nil,
                 params: %{request: request.id, decision: "allow"}
               }),
             "#{kase["case"]}: #{verb} reached an agent question"

      assert message =~ "answered, not"
    end

    assert current_status(db, request.id) == "open"
  end

  defp filed!(kase, result) do
    assert {:ok, %{decision_request: request}} = result,
           "#{kase["case"]}: expected the question to be filed"

    request
  end

  defp answer_call(session_key, request_id, text) do
    %{
      verb: "answer",
      origin: "agent:#{session_key}",
      principal: {:session, session_key},
      session_key: nil,
      params: %{request: request_id, answer: text}
    }
  end

  defp current_status(db, id) do
    {:ok, [[status]]} = DB.query(db, "SELECT status FROM decision_requests WHERE id = ?1", [id])
    status
  end

  defp prompt_wakes(db, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT wakeId FROM wakes WHERE sessionKey = ?1 AND consumer = 'prompt' AND state = 'pending' ORDER BY createdAt, wakeId",
        [session_key]
      )

    Enum.map(rows, fn [id] -> Wakes.get(db, id) end)
  end

  defp question_lifecycle(db, kind, subject) do
    {:ok, [[detail]]} =
      DB.query(
        db,
        "SELECT detail FROM lifecycle_events WHERE kind = ?1 AND subject = ?2 ORDER BY id DESC LIMIT 1",
        [kind, subject]
      )

    detail
  end

  # The read-cursor contract (fabric §13 Phase 1 seam ④; GitHub #13).
  #
  # Cursor VALUES are not written into the cases: the fixture states the law
  # over pages, and the runner reads the full list to learn the ids. A fixture
  # that hardcoded them would be pinning today's uuids, not the contract.
  def run_read_cursor_fixture(fixture) do
    Enum.each(fixture["cases"], fn kase ->
      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, Map.get(kase, "world", %{}))
        handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
        call = build_call(kase["call"], ids)

        assert_cursor_outcome(kase["expect"], kase, db, handlers, call)
      after
        GenServer.stop(pid)
      end
    end)
  end

  defp assert_cursor_outcome("refuse", kase, db, handlers, call) do
    assert {:error, %{code: code}} = Dispatch.dispatch(db, handlers, call),
           "#{kase["case"]}: expected a refusal"

    assert code == kase["reason"]

    if kase["kind"] == "legibility", do: assert(kase["emits"] == "handler:#{code}")
  end

  defp assert_cursor_outcome("unpaged", kase, db, handlers, call) do
    assert {:ok, page} = Dispatch.dispatch(db, handlers, call)

    # NO DEFAULT LIMIT. Every row the assignment carries. And, since neither
    # `--after` nor `--limit` was named, the response carries ONLY `attests`
    # — no `next_after`/`has_more_after` paging vocabulary added (Sol xhigh
    # review, finding 8: those keys are PAGING vocabulary, and a caller that
    # never asked to page must see zero payload change).
    assert length(page.attests) == length(Map.get(kase["world"], "attests"))
    assert page == %{attests: page.attests}
  end

  defp assert_cursor_outcome("page", kase, db, handlers, call) do
    limit = call.params.limit
    assert kase["reason"] == "limit", "#{kase["case"]}: this page is bounded by its limit"
    assert {:ok, page} = Dispatch.dispatch(db, handlers, call)

    assert length(page.attests) == limit
    assert page.has_more_after, "#{kase["case"]}: a short page must say more follows"
    assert page.next_after == List.last(page.attests).id
  end

  # THE WHOLE LAW, stated over the concatenation rather than any one page: the
  # walk reproduces the unpaged list exactly — no row lost, none repeated, even
  # across attests that share a millisecond.
  defp assert_cursor_outcome("resume", _kase, db, handlers, call) do
    assert {:ok, whole} =
             Dispatch.dispatch(db, handlers, %{call | params: %{call.params | limit: nil}})

    expected = Enum.map(whole.attests, & &1.id)
    assert length(expected) > call.params.limit

    assert walk(db, handlers, call, nil, []) == expected
  end

  defp assert_cursor_outcome("exhausted", _kase, db, handlers, call) do
    assert {:ok, whole} = Dispatch.dispatch(db, handlers, call)
    last = List.last(whole.attests).id

    assert {:ok, past} =
             Dispatch.dispatch(db, handlers, %{
               call
               | params: Map.put(call.params, :after, last)
             })

    assert past.attests == []
    assert past.next_after == nil
    assert past.has_more_after == false
  end

  defp assert_cursor_outcome("roster-page", _kase, db, handlers, call) do
    assert {:ok, whole} = Dispatch.dispatch(db, handlers, %{call | params: %{}})
    expected = Enum.map(whole.items, & &1.id)

    assert {:ok, first} = Dispatch.dispatch(db, handlers, call)
    assert Enum.map(first.items, & &1.id) == Enum.take(expected, call.params.limit)
    assert first.has_more_after

    assert {:ok, second} =
             Dispatch.dispatch(db, handlers, %{
               call
               | params: Map.put(call.params, :after, first.next_after)
             })

    assert Enum.map(first.items, & &1.id) ++ Enum.map(second.items, & &1.id) == expected
    assert second.has_more_after == false
  end

  defp walk(db, handlers, call, cursor, seen) do
    params = if cursor, do: Map.put(call.params, :after, cursor), else: call.params
    assert {:ok, page} = Dispatch.dispatch(db, handlers, %{call | params: params})
    seen = seen ++ Enum.map(page.attests, & &1.id)

    if page.has_more_after, do: walk(db, handlers, call, page.next_after, seen), else: seen
  end

  @doc """
  A live engine switch, driven through the DISPATCH CHOKEPOINT so the election
  crosses the same seam an org would rail, and answered with a NAMED refusal.

  Every case asserts three things, not one: the refusal is named, the session's
  engine identity is byte-identical afterwards, and no transcript row was
  appended. The second and third are what make a refusal free — a "no" that
  still moved the history barrier would satisfy the first assertion alone.
  """
  def run_live_switch_fixture(fixture) do
    Enum.each(fixture["cases"], fn kase ->
      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, Map.get(kase, "world", %{}))
        call = build_call(kase["call"], ids)
        handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
        before = live_switch_identity(db, call.session_key)

        result = Dispatch.dispatch(db, handlers, call)

        case kase["expect"] do
          "refuse" ->
            assert {:error, %{code: code}} = result,
                   "#{kase["case"]}: expected a named refusal, got #{inspect(result)}"

            assert code == kase["reason"],
                   "#{kase["case"]}: the refusal must be named #{kase["reason"]}, got #{code}"

          "pass" ->
            assert {:ok, _} = result, "#{kase["case"]}: expected the switch to apply"
        end

        if kase["expect"] == "refuse" do
          assert live_switch_identity(db, call.session_key) == before,
                 "#{kase["case"]}: a refused switch must leave the session's engine untouched"

          {:ok, [[appended]]} =
            DB.query(db, "SELECT count(*) FROM messages WHERE sessionKey = ?1", [
              call.session_key
            ])

          assert appended == 0,
                 "#{kase["case"]}: a refused switch must append no marker and bury no row"
        end

        # A refusal an operator cannot find afterwards is a refusal that will be
        # argued about. The denial rides the ordinary verb event log, so "who
        # tried to re-engine this session, and what did the substrate say" is a
        # question rows answer.
        if kase["kind"] == "legibility" do
          assert kase["emits"] == "eventlog:denied verb=tune"

          assert Enum.any?(
                   EventLog.events_after(db, 0, 50),
                   &(&1.kind == "denied" and &1.verb == "tune")
                 ),
                 "#{kase["case"]}: the refused switch left no denied verb event"
        end
      after
        GenServer.stop(pid)
      end
    end)
  end

  defp live_switch_identity(db, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT harness, provider, model, thinkingLevel, modelContext, clearedThroughSeq " <>
          "FROM sessions WHERE sessionKey = ?1",
        [session_key]
      )

    rows
  end

  def run_handler_refusal_fixture(fixture) do
    Enum.each(fixture["cases"], fn kase ->
      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, Map.get(kase, "world", %{}))
        call = build_call(kase["call"], ids)
        handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
        {:ok, [[before_count]]} = DB.query(db, "SELECT count(*) FROM assignments")
        files = call.params[:files]

        overlap? =
          is_list(files) and files != [] and
            Enum.all?(files, fn path ->
              is_binary(path) and String.length(String.trim(path)) in 1..2_000
            end) and Assignments.open_assignments_touching(db, Enum.uniq(files)) != []

        assert_overlap_observation(fixture, db, call, overlap?)

        if String.contains?(kase["case"], "concurrent") do
          results =
            1..2
            |> Enum.map(fn _ -> Task.async(fn -> Dispatch.dispatch(db, handlers, call) end) end)
            |> Task.await_many()

          {:ok, [[after_count]]} = DB.query(db, "SELECT count(*) FROM assignments")
          assert Enum.all?(results, &match?({:ok, _}, &1))

          assert results
                 |> Enum.map(fn {:ok, assignment} -> assignment.id end)
                 |> Enum.uniq()
                 |> length() == 2

          assert after_count == before_count + 2
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
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))

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

  # `reopen-assignment`'s own conformance exercise (Sol xhigh review, finding
  # 4). `holder-verdict-wins` calls only `attest`; this fixture routes
  # `reopen-assignment` itself through `Dispatch.dispatch/3` — the same
  # chokepoint the wire router uses, which is also what puts the verb through
  # `Rules.decide`. The case named `earlier-verdict-round-displaces-…`
  # additionally proves the repair itself, not just the reopen, by re-filing a
  # verdict and re-checking the producer's completion against the fixture's
  # own rule.
  def run_reopen_assignment_fixture(fixture) do
    Enum.each(fixture["cases"], fn kase ->
      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, Map.get(kase, "world", %{}))
        call = build_call(kase["call"], ids)
        handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
        assignment_id = call.params[:assignment_id]

        before_row = reopen_fixture_row(db, assignment_id)
        before_reopenings = reopen_fixture_count(db, assignment_id)

        result = Dispatch.dispatch(db, handlers, call)

        case kase["expect"] do
          "refuse" ->
            assert {:error, %{code: code}} = result
            assert code == kase["reason"]
            assert reopen_fixture_row(db, assignment_id) == before_row
            assert reopen_fixture_count(db, assignment_id) == before_reopenings

          "pass" ->
            assert {:ok, reopened} = result
            assert reopened.state == "open"
            assert reopen_fixture_count(db, assignment_id) == before_reopenings + 1

            if kase["case"] ==
                 "earlier-verdict-round-displaces-later-verdictless-round-when-reopened" do
              verify_reopen_repairs_displacement!(fixture, db, handlers, ids)
            end
        end
      after
        GenServer.stop(pid)
      end
    end)
  end

  defp reopen_fixture_row(db, assignment_id) do
    {:ok, [row]} =
      DB.query(
        db,
        "SELECT state, outcome, closedAt, closedByUser, closedBySession, closingAttestId " <>
          "FROM assignments WHERE id = ?1",
        [assignment_id]
      )

    row
  end

  defp reopen_fixture_count(db, assignment_id) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT count(*) FROM assignment_reopenings WHERE assignmentId = ?1", [
        assignment_id
      ])

    count
  end

  # THE REPAIR, proven end to end: r1 — the round `reopen-assignment` just
  # reopened — files the corrected verdict, and the producer's completion,
  # which the fixture's own rule denies without a qualifying `reviewed-clean`,
  # is checked against BOTH the raw `qualifying_review_verdict_kinds` read and
  # a real `Dispatch.dispatch/3` attest call gated by that rule. r2 (later,
  # verdictless, closed) sits in the world throughout and never qualifies.
  defp verify_reopen_repairs_displacement!(fixture, db, handlers, ids) do
    producer_id = ids.assignments["a"]
    r1_id = ids.assignments["r1"]

    verdict_call = %{
      verb: "attest",
      origin: "agent:reviewer",
      principal: {:session, "reviewer"},
      session_key: nil,
      params: %{assignment_id: r1_id, kind: "verdict", verdict_kind: "reviewed-clean"}
    }

    assert {:ok, %{attest: %{verdictKind: "reviewed-clean"}}} =
             Dispatch.dispatch(db, handlers, verdict_call)

    assert Assignments.qualifying_review_verdict_kinds(db, producer_id, "holder") == [
             "reviewed-clean"
           ]

    base = temp_dir!("conformance-reopen-repair")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(handlers))

    try do
      completion_call = %{
        verb: "attest",
        origin: "agent:holder",
        principal: {:session, "holder"},
        session_key: nil,
        params: %{assignment_id: producer_id, kind: "completion"}
      }

      assert {:ok, %{assignment: %{state: "closed"}}} =
               Dispatch.dispatch(db, handlers, completion_call)
    after
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  def run_load_assert(loadset) do
    base = temp_dir!("conformance-load")
    rules_dir = Path.join(base, "identity/rules")
    scripts_dir = Path.join(base, "identity/rails/scripts")
    File.mkdir_p!(rules_dir)
    File.mkdir_p!(scripts_dir)

    loadset["loadset_dir"]
    |> Path.join("*.toml")
    |> Path.wildcard()
    |> Enum.each(&File.cp!(&1, Path.join(rules_dir, Path.basename(&1))))

    loadset["loadset_dir"]
    |> Path.join("scripts/*")
    |> Path.wildcard()
    |> Enum.each(&File.cp!(&1, Path.join(scripts_dir, Path.basename(&1))))

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

  def run_rules_decide(fixture) do
    base = temp_dir!("conformance-decide")
    prepare_rule_base!(base, fixture)
    handlers = Gateway.handlers(%{})
    Rules.load!(base, Map.keys(handlers))

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
              assert {:deny, %{rule: name, reason: "rule_denied"}} = decision
              assert name == (kase["reason"] || fixture_rule_name(fixture))

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

  def run_remedy_episode_contract(%{"name" => "remedy-episode-idempotent"} = fixture) do
    base = temp_dir!("conformance-remedy-episode-matrix")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))

    try do
      Enum.each(fixture["cases"], fn kase ->
        {db, pid} = memory_db!()

        try do
          ids = materialize_world(db, kase["world"])
          call = build_call(kase["call"], ids)
          handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
          statute = fixture_rule_name(fixture)
          assignment_id = call.params.assignment_id

          fire = fn ->
            assert {:error, %{reason: "remedy_fired", rule: ^statute, producer: producer_id}} =
                     Dispatch.dispatch(db, handlers, call)

            assert is_binary(producer_id)
            producer_id
          end

          add_producer_id = fn producer_id ->
            %{ids | assignments: Map.put(ids.assignments, "producer", producer_id)}
          end

          case kase["case"] do
            "first-fire-one-producer" ->
              producer = fire.()
              assert review_effect_count(db, assignment_id) == 1

              assert %{status: "live", occurrence: 1, producer_key: ^producer} =
                       RailRemedy.episode(db, statute, assignment_id)

            "initial-publication-race" ->
              results =
                [
                  Task.async(fn -> Dispatch.dispatch(db, handlers, call) end),
                  Task.async(fn -> Dispatch.dispatch(db, handlers, call) end)
                ]
                |> Task.await_many()

              producers =
                for {:error, %{reason: "remedy_fired", producer: producer}} <- results,
                    is_binary(producer),
                    do: producer

              assert [producer] = producers
              assert review_effect_count(db, assignment_id) == 1

              assert %{status: "live", occurrence: 1, producer_key: ^producer} =
                       RailRemedy.episode(db, statute, assignment_id)

            "live-refire-rewakes" ->
              producer = fire.()
              assert kase["phase2"]["call"] != nil
              assert {:error, %{producer: ^producer}} = Dispatch.dispatch(db, handlers, call)
              assert review_effect_count(db, assignment_id) == 1

              assert %{status: "live", occurrence: 1, rewake_count: 1} =
                       RailRemedy.episode(db, statute, assignment_id)

            "changes-requested-keeps-live" ->
              producer = fire.()

              phase2_ids =
                materialize_world(db, kase["phase2"]["world"], add_producer_id.(producer))

              phase2_call = build_call(kase["phase2"]["call"], phase2_ids)

              assert {:error, %{producer: ^producer}} =
                       Dispatch.dispatch(db, handlers, phase2_call)

              assert %{status: "live", occurrence: 1, rewake_count: 1} =
                       RailRemedy.episode(db, statute, assignment_id)

              assert review_effect_count(db, assignment_id) == 1

            "reviewed-clean-closes" ->
              producer = fire.()

              phase2_ids =
                materialize_world(db, kase["phase2"]["world"], add_producer_id.(producer))

              phase2_call = build_call(kase["phase2"]["call"], phase2_ids)
              assert {:ok, _} = Dispatch.dispatch(db, handlers, phase2_call)
              assert %{status: "closed"} = RailRemedy.episode(db, statute, assignment_id)
              assert review_effect_count(db, assignment_id) == 1

            case_id
            when case_id in ~w(reclaim-closed-bumps-occurrence fresh-occurrence-new-producer) ->
              first = fire.()
              assert RailRemedy.close(db, statute, assignment_id, 1)
              assert kase["phase2"]["call"] != nil
              second = fire.()
              refute second == first

              assert %{status: "live", occurrence: 2, producer_key: ^second} =
                       RailRemedy.episode(db, statute, assignment_id)

              assert review_effect_count(db, assignment_id) == 2

            "reclaim-stale-claim-preserves-occurrence" ->
              original = fire.()
              stale_at = System.system_time(:millisecond) - 60_001

              assert {:ok, 1} =
                       DB.transaction(db, fn txn ->
                         DB.Txn.q(
                           txn,
                           """
                           UPDATE rail_remedy_episodes
                           SET status='claimed', producerKey=NULL, claimToken='stale', openedAt=?3
                           WHERE statute=?1 AND subject=?2 AND status='live'
                           """,
                           [statute, assignment_id, stale_at]
                         )

                         DB.Txn.changes(txn)
                       end)

              reclaimed = fire.()
              assert reclaimed == original

              assert %{status: "live", occurrence: 1, producer_key: ^original} =
                       RailRemedy.episode(db, statute, assignment_id)

              assert review_effect_count(db, assignment_id) == 1

            "reclaim-dead-live-bumps-occurrence" ->
              first = fire.()
              revoke_assignment!(db, first)
              assert kase["phase2"]["call"] != nil
              second = fire.()
              refute second == first

              assert %{status: "live", occurrence: 2, producer_key: ^second} =
                       RailRemedy.episode(db, statute, assignment_id)

              assert review_effect_count(db, assignment_id) == 2

            "episode-transitions-legible" ->
              producer = fire.()

              phase2_ids =
                materialize_world(db, kase["phase2"]["world"], add_producer_id.(producer))

              phase2_call = build_call(kase["phase2"]["call"], phase2_ids)
              assert {:ok, _} = Dispatch.dispatch(db, handlers, phase2_call)
              assert %{status: "closed"} = RailRemedy.episode(db, statute, assignment_id)
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

  def run_remedy_episode_contract(fixture), do: run_aggregate_remedy_episode_contract(fixture)

  defp run_aggregate_remedy_episode_contract(fixture) do
    base = temp_dir!("conformance-remedy-episode")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))
    {db, pid} = memory_db!()

    try do
      ids = materialize_world(db, hd(fixture["cases"])["world"])
      handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
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
      assert RailRemedy.close(db, fixture_rule_name(fixture), reopened, 1)
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

      assert {:ok, 0} =
               DB.transaction(db, fn txn ->
                 DB.Txn.q(
                   txn,
                   """
                   UPDATE rail_remedy_episodes SET status='dispatched'
                   WHERE statute=?1 AND subject=?2 AND status='claimed' AND claimToken='superseded'
                   """,
                   [fixture_rule_name(fixture), fenced]
                 )

                 DB.Txn.changes(txn)
               end)

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
    run_escalation_return_dispatch_contract(return_fixture)
    run_escalation_fold_contract(fold_fixture)
  end

  def run_escalation_return_dispatch_contract(fixture) do
    base = temp_dir!("conformance-escalation-dispatch-matrix")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))

    try do
      Enum.each(fixture["cases"], fn kase ->
        {db, pid} = memory_db!()

        try do
          ids = materialize_world(db, kase["world"])
          call = build_call(kase["call"], ids)
          handler = %{"attest" => fn _ -> %{accepted: true} end}
          statute = fixture_rule_name(fixture)

          open = fn ->
            assert {:decision_pending, request_id} = Dispatch.dispatch(db, handler, call)
            assert is_binary(request_id)
            request_id
          end

          case kase["case"] do
            "allow-with-no-later-gate-proceeds" ->
              assert {:allow, [], []} = Rules.decide(db, call)
              assert {:ok, %{accepted: true}} = Dispatch.dispatch(db, handler, call)
              assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM decision_requests")

            "resolve-needs-request-nil-opens" ->
              assert {{:escalate, %{name: ^statute}, _, nil}, [], []} =
                       Rules.decide(db, call)

              request_id = open.()

              assert {:ok, [[^request_id, "open"]]} =
                       DB.query(db, "SELECT id, status FROM decision_requests")

            "resolve-needs-request-id-rereturns" ->
              request_id = open.()
              assert kase["phase2"]["expect"] == "escalate-open"

              assert {{:escalate, %{name: ^statute}, _, ^request_id}, [], []} =
                       Rules.decide(db, call)

              assert {:decision_pending, ^request_id} = Dispatch.dispatch(db, handler, call)
              assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM decision_requests")

            "resolve-deny-halts" ->
              request_id = open.()
              assert kase["phase2"]["call"]["params"]["decision"] == "deny"

              assert %{status: "ruled"} =
                       Escalation.rule(
                         db,
                         escalation_rule_call(request_id, "deny"),
                         authorized: true
                       )

              assert {{:deny, %{code: "escalation_denied", rule: ^statute}}, [], []} =
                       Rules.decide(db, call)

              assert {:error, %{code: "escalation_denied", rule: ^statute}} =
                       Dispatch.dispatch(
                         db,
                         %{"attest" => fn _ -> flunk("denied escalation must halt") end},
                         call
                       )

            "resolve-waiver-allow-continues" ->
              request_id = open.()
              assert kase["phase2"]["call"]["verb"] == "waive"

              waiver =
                Escalation.waive(
                  db,
                  %{
                    origin: "user:owner",
                    principal: {:user, "owner"},
                    params: %{request_id: request_id}
                  },
                  authorized: true
                )

              assert is_binary(waiver.id)
              assert {:allow, [], []} = Rules.decide(db, call)
              assert {:ok, %{accepted: true}} = Dispatch.dispatch(db, handler, call)

            "resolve-ruling-allow-continues" ->
              request_id = open.()
              assert kase["phase2"]["call"]["params"]["decision"] == "allow"

              assert %{status: "ruled"} =
                       Escalation.rule(
                         db,
                         escalation_rule_call(request_id, "allow"),
                         authorized: true
                       )

              assert {:allow, [], [^request_id]} = Rules.decide(db, call)
              assert {:ok, %{accepted: true}} = Dispatch.dispatch(db, handler, call)

              assert {:ok, [["consumed"]]} =
                       DB.query(db, "SELECT status FROM decision_requests WHERE id=?1", [
                         request_id
                       ])

            "decision-request-legible" ->
              request_id = open.()

              assert {:ok, [[^request_id, "open"]]} =
                       DB.query(db, "SELECT id, status FROM decision_requests")

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

  def run_supervision_state_contract(retired_fixture, watermark_fixture, escalation_fixture) do
    run_retired_holder_contract(retired_fixture)
    run_watermark_contract(watermark_fixture)
    run_sweep_escalation_contract(escalation_fixture)
  end

  def run_escalation_return_sweep_contract(fixture) do
    base = temp_dir!("conformance-escalation-sweep-matrix")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))
    service_pids = start_wake_delivery_services()

    try do
      Enum.each(fixture["cases"], fn kase ->
        {db, pid} = memory_db!()
        scheduler = :"conformance_escalation_scheduler_#{System.unique_integer([:positive])}"

        {:ok, scheduler_pid} =
          Wakes.start_link(
            db: db,
            name: scheduler,
            tick_ms: 60_000,
            deliver: fn _wake -> :ok end
          )

        try do
          ids = materialize_world(db, kase["world"])
          call = build_call(kase["call"], ids)
          turn_call = sweep_call(fixture, call)
          handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
          session_key = elem(call.principal, 1)
          statute = fixture_rule_name(fixture)

          open_and_park = fn ->
            assert {:acted, :rail_escalate} =
                     Supervision.evaluate(
                       db,
                       handlers,
                       3,
                       session_key,
                       ids.turns[session_key]
                     )

            assert {:ok, [[request_id, "open", park_wake_id]]} =
                     DB.query(db, "SELECT id, status, parkWakeId FROM decision_requests")

            assert %{state: "pending", condition_scope: ^request_id} =
                     Wakes.get(db, park_wake_id)

            {request_id, park_wake_id}
          end

          case kase["case"] do
            "no-applicable-escalate-records-none" ->
              assert {:allow, [], []} = Rules.decide(db, turn_call)

              assert :rebased =
                       Supervision.evaluate(
                         db,
                         handlers,
                         3,
                         session_key,
                         ids.turns[session_key]
                       )

              assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM decision_requests")
              assert sweep_decision?(db, session_key, nil, "none")

            "needs-request-nil-opens-and-parks" ->
              assert {{:escalate, %{name: ^statute}, _, nil}, [], []} =
                       Rules.decide(db, turn_call)

              {request_id, park_wake_id} = open_and_park.()
              assert is_binary(request_id)
              assert is_binary(park_wake_id)

            "needs-request-id-rereturns-and-reuses-wake" ->
              {request_id, park_wake_id} = open_and_park.()
              assert kase["phase2"]["expect"] == "escalate-park"

              assert {{:escalate, %{name: ^statute}, _, ^request_id}, [], []} =
                       Rules.decide(db, turn_call)

              phase2_ids = materialize_world(db, kase["phase2"]["world"], ids)

              assert {:acted, :rail_escalate} =
                       Supervision.evaluate(
                         db,
                         handlers,
                         3,
                         session_key,
                         phase2_ids.turns[session_key]
                       )

              assert {:ok, [[^request_id, ^park_wake_id]]} =
                       DB.query(db, "SELECT id, parkWakeId FROM decision_requests")

              assert_one_park_and_one_notification!(db)

            "resolve-deny-reobligates" ->
              {request_id, _park_wake_id} = open_and_park.()
              assert kase["phase2"]["call"]["params"]["decision"] == "deny"

              assert %{status: "ruled"} =
                       Escalation.rule(
                         db,
                         escalation_rule_call(request_id, "deny"),
                         authorized: true,
                         scheduler: scheduler
                       )

              assert {{:deny, %{code: "escalation_denied", rule: ^statute}}, [], []} =
                       Rules.decide(db, turn_call)

              assert {:ok, %{seq: wake_seq}} =
                       Ledger.claim_next(db, session_key, "conformance-ruling-wake")

              assert :ok = Ledger.finish(db, wake_seq, "delivered")

              assert {:prodded, 1} =
                       Supervision.evaluate(
                         db,
                         handlers,
                         3,
                         session_key,
                         wake_seq
                       )

              assert sweep_decision?(db, session_key, statute, "re-obligate")
              assert Supervision.prod_state(db, call.params.assignment_id).prodCount == 1

            "resolve-allow-continues-without-consuming" ->
              {request_id, _park_wake_id} = open_and_park.()
              assert kase["phase2"]["call"]["params"]["decision"] == "allow"

              assert %{status: "ruled"} =
                       Escalation.rule(
                         db,
                         escalation_rule_call(request_id, "allow"),
                         authorized: true,
                         scheduler: scheduler
                       )

              assert {{:deny, %{rule: "later-sweep-statute"}}, [], [^request_id]} =
                       Rules.decide(db, turn_call)

              assert {:ok, %{seq: wake_seq}} =
                       Ledger.claim_next(db, session_key, "conformance-ruling-wake")

              assert :ok = Ledger.finish(db, wake_seq, "delivered")

              assert {:prodded, 1} =
                       Supervision.evaluate(
                         db,
                         handlers,
                         3,
                         session_key,
                         wake_seq
                       )

              assert {:ok, [["ruled"]]} =
                       DB.query(db, "SELECT status FROM decision_requests WHERE id=?1", [
                         request_id
                       ])

              assert sweep_decision?(
                       db,
                       session_key,
                       "later-sweep-statute",
                       "re-obligate"
                     )

            "park-legible" ->
              {_request_id, _park_wake_id} = open_and_park.()
              assert_declared_records!(kase["emits"], latest_denied_payload(db), db)
          end
        after
          GenServer.stop(scheduler_pid)
          GenServer.stop(pid)
        end
      end)
    after
      Enum.each(service_pids, &GenServer.stop/1)
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  # The park wake must not duplicate across re-returns, and the request's owner
  # notification is exactly one durable ungated wake armed by the winning insert
  # (escalation-delivery-v1): a replay arms none, so both counts stay at one.
  defp assert_one_park_and_one_notification!(db) do
    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM wakes WHERE conditionKind IS NOT NULL")

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM wakes WHERE consumer = 'prompt' AND conditionKind IS NULL AND targetGate = 0"
             )

    assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
  end

  def run_park_wake_reuse_contract(fixture) do
    base = temp_dir!("conformance-park-wake-reuse")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))

    try do
      Enum.each(fixture["cases"], fn kase ->
        {db, pid} = memory_db!()

        try do
          ids = materialize_world(db, kase["world"])
          call = build_call(kase["call"], ids)
          handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
          session_key = elem(call.principal, 1)

          assert {:acted, :rail_escalate} =
                   Supervision.evaluate(db, handlers, 3, session_key, ids.turns[session_key])

          assert {:ok, [[request_id, first_wake_id]]} =
                   DB.query(db, "SELECT id, parkWakeId FROM decision_requests")

          assert %{state: "pending", condition_scope: ^request_id} =
                   Wakes.get(db, first_wake_id)

          assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM decision_requests")
          assert_one_park_and_one_notification!(db)

          if kase["phase2"] do
            phase2_ids = materialize_world(db, kase["phase2"]["world"], ids)

            assert {:acted, :rail_escalate} =
                     Supervision.evaluate(
                       db,
                       handlers,
                       3,
                       session_key,
                       phase2_ids.turns[session_key]
                     )

            assert {:ok, [[^request_id, ^first_wake_id]]} =
                     DB.query(db, "SELECT id, parkWakeId FROM decision_requests")

            assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM decision_requests")
            assert_one_park_and_one_notification!(db)
          end

          if kase["kind"] == "legibility" do
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

  def run_scheduled_wake_contract(fixture) do
    assert Supervision.turn_end_schedule() == [
             :rail_enforcement,
             :prod_ladder
           ]

    base = temp_dir!("conformance-r21-pending-wake")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))

    try do
      Enum.each(fixture["cases"], fn kase ->
        {db, pid} = memory_db!()

        try do
          ids = materialize_world(db, kase["world"])
          call = build_call(kase["call"], ids)
          turn_call = sweep_call(fixture, call)
          handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
          session_key = elem(call.principal, 1)
          assignment_id = call.params.assignment_id
          statute = fixture_rule_name(fixture)

          case kase["case"] do
            "rail-enforcement-precedes-self-pending-wake" ->
              assert {{:remedy, %{name: ^statute}, ^assignment_id, _}, [], []} =
                       Rules.decide(db, turn_call)

              # The self wake still suppresses the rail remedy, but it does not
              # suppress the independent prod ladder unless it is an exact
              # assignment checkpoint.
              assert {:prodded, 1} =
                       Supervision.evaluate(
                         db,
                         handlers,
                         3,
                         session_key,
                         ids.turns[session_key]
                       )

              assert RailRemedy.episode(db, statute, assignment_id) == nil
              assert review_effect_count(db, assignment_id) == 0

            "rail-enforcement-precedes-process-pending-wake" ->
              assert {{:remedy, %{name: ^statute}, ^assignment_id, _}, [], []} =
                       Rules.decide(db, turn_call)

              assert {:acted, :rail_remedy} =
                       Supervision.evaluate(
                         db,
                         handlers,
                         3,
                         session_key,
                         ids.turns[session_key]
                       )

              assert %{status: "live"} = RailRemedy.episode(db, statute, assignment_id)
              assert review_effect_count(db, assignment_id) == 1
              assert sweep_decision?(db, session_key, statute, "run-remedy")

            "allow-falls-through-to-pending-wake-gate" ->
              assert {:allow, [], []} = Rules.decide(db, turn_call)

              assert :rebased =
                       Supervision.evaluate(
                         db,
                         handlers,
                         3,
                         session_key,
                         ids.turns[session_key]
                       )

              assert RailRemedy.episode(db, statute, assignment_id) == nil
              assert review_effect_count(db, assignment_id) == 0
              assert %{supervisionState: "armed"} = Supervision.prod_state(db, assignment_id)

            "schedule-order-legible" ->
              assert {:acted, :rail_remedy} =
                       Supervision.evaluate(
                         db,
                         handlers,
                         3,
                         session_key,
                         ids.turns[session_key]
                       )

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

  def run_schedule_then_check_contract(fixture) do
    base = temp_dir!("conformance-schedule-then-check")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))
    service_pids = start_wake_delivery_services()

    try do
      Enum.each(fixture["cases"], fn kase ->
        {db, pid} = memory_db!()
        scheduler = :"conformance_schedule_check_#{System.unique_integer([:positive])}"

        {:ok, scheduler_pid} =
          Wakes.start_link(
            db: db,
            name: scheduler,
            tick_ms: 60_000,
            deliver: fn _wake -> :ok end
          )

        try do
          ids = materialize_world(db, kase["world"])
          call = build_call(kase["call"], ids)
          turn_call = sweep_call(fixture, call)
          handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
          session_key = elem(call.principal, 1)
          statute_name = fixture_rule_name(fixture)

          assert {{:escalate, statute, ctx, nil}, [], []} = Rules.decide(db, turn_call)
          assert statute.name == statute_name

          case kase["case"] do
            "already-ruled-cancels-new-park" ->
              # Public seams can prove a ruling visible before the sweep creates
              # no park. The narrower schedule→recovered-check interleaving has
              # no injection seam and is recorded in HANDOFF.md.
              assert {:decision_pending, request_id} =
                       Escalation.escalate(db, turn_call, statute, Map.put(ctx, :dr_id, nil))

              assert %{status: "ruled"} =
                       Escalation.rule(
                         db,
                         escalation_rule_call(request_id, "allow"),
                         authorized: true,
                         scheduler: scheduler
                       )

              assert {:prodded, 1} =
                       Supervision.evaluate(
                         db,
                         handlers,
                         3,
                         session_key,
                         ids.turns[session_key]
                       )

              assert {:ok, [[0]]} =
                       DB.query(
                         db,
                         "SELECT COUNT(*) FROM wakes WHERE conditionKind='escalation-ruled'"
                       )

              assert {:ok, [["ruled", nil]]} =
                       DB.query(
                         db,
                         "SELECT status, parkWakeId FROM decision_requests WHERE id=?1",
                         [request_id]
                       )

            case_id when case_id in ~w(later-ruling-uses-ordinary-wake ordering-legible) ->
              assert {:acted, :rail_escalate} =
                       Supervision.evaluate(
                         db,
                         handlers,
                         3,
                         session_key,
                         ids.turns[session_key]
                       )

              assert {:ok, [[request_id, park_wake_id]]} =
                       DB.query(db, "SELECT id, parkWakeId FROM decision_requests")

              assert %{state: "pending", condition_scope: ^request_id} =
                       Wakes.get(db, park_wake_id)

              assert %{status: "ruled"} =
                       Escalation.rule(
                         db,
                         escalation_rule_call(request_id, "allow"),
                         authorized: true,
                         scheduler: scheduler
                       )

              assert %{state: "fired", fired_by: "condition"} = Wakes.get(db, park_wake_id)

              if kase["kind"] == "legibility" do
                assert_declared_records!(kase["emits"], latest_denied_payload(db), db)
              end
          end
        after
          GenServer.stop(scheduler_pid)
          GenServer.stop(pid)
        end
      end)
    after
      Enum.each(service_pids, &GenServer.stop/1)
      File.rm_rf!(base)
      :persistent_term.erase(Rules)
    end
  end

  def run_sweep_ruling_contract(fixture) do
    base = temp_dir!("conformance-sweep-ruling")
    prepare_rule_base!(base, fixture)
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))
    {db, pid} = memory_db!()

    try do
      sample = Enum.find(fixture["cases"], &(&1["case"] == "sweep-allow-leaves-ruling-ruled"))
      ids = materialize_world(db, sample["world"])
      call = build_call(sample["call"], ids)
      session_key = elem(call.principal, 1)
      terminal_seq = Map.fetch!(ids.turns, session_key)
      handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})

      assert {:acted, :rail_escalate} =
               Supervision.evaluate(db, handlers, 3, session_key, terminal_seq)

      assert {:ok, [[request_id, "open"]]} =
               DB.query(db, "SELECT id, status FROM decision_requests")

      assert {:ok, [[park_wake_id]]} =
               DB.query(db, "SELECT parkWakeId FROM decision_requests WHERE id=?1", [request_id])

      assert %{status: "ruled"} =
               Escalation.rule(db, escalation_rule_call(request_id, "allow"), authorized: true)

      park_wake = Wakes.get(db, park_wake_id)
      assert {:accepted_in_txn, _event_id, %{canceled: true}} = cancel_wake(db, park_wake)

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
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))

    try do
      missing =
        Enum.find(fixture["cases"], fn kase ->
          String.starts_with?(kase["case"], "missing-") or
            kase["case"] == "missing-review-dispatch-remedy"
        end)

      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, missing["world"])
        handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
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
        wrong_item =
          Enum.find(fixture["cases"], &String.contains?(&1["case"], "wrong-work-item"))

        {db, pid} = memory_db!()

        try do
          ids = materialize_world(db, wrong_item["world"])
          call = build_call(wrong_item["call"], ids)

          assert {:error, %{reason: "remedy_fired"}} =
                   Dispatch.dispatch(db, Gateway.handlers(%{db: db, wake_tick_ms: 1_000}), call)
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
                     Gateway.handlers(%{db: db, wake_tick_ms: 1_000}),
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
                   Dispatch.dispatch(db, Gateway.handlers(%{db: db, wake_tick_ms: 1_000}), call)

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
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))

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
                 Dispatch.dispatch(db, Gateway.handlers(%{db: db, wake_tick_ms: 1_000}), call)

        assert {:prodded, 1} =
                 Supervision.evaluate(
                   db,
                   Gateway.handlers(%{db: db, wake_tick_ms: 1_000}),
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

        assert {:ok, _} =
                 Dispatch.dispatch(db, Gateway.handlers(%{db: db, wake_tick_ms: 1_000}), call)
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
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))

    try do
      sample =
        Enum.find(fixture["cases"], &(&1["case"] == "retired-with-pending-wake-is-stranded"))

      {db, pid} = memory_db!()

      try do
        ids = materialize_world(db, sample["world"])
        Org.retire(db, "holder", "process:tightbeam", 1_000)
        terminal_seq = ids.turns["holder"]

        assert :stranded =
                 Supervision.evaluate(
                   db,
                   Gateway.handlers(%{db: db, wake_tick_ms: 1_000}),
                   3,
                   "holder",
                   terminal_seq
                 )

        assert %{lastEvaluatedTerminal: ^terminal_seq} = Supervision.watermark(db, "holder")
        assert Wakes.pending_count(db, "holder") == 0
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
                   Gateway.handlers(%{db: db, wake_tick_ms: 1_000}),
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
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))

    try do
      nil_case = Enum.find(fixture["cases"], &(&1["case"] == "nil-fallthrough-no-null-write"))
      {db, pid} = memory_db!()

      try do
        materialize_world(db, nil_case["world"])

        assert :idle =
                 Supervision.evaluate(
                   db,
                   Gateway.handlers(%{db: db, wake_tick_ms: 1_000}),
                   3,
                   "holder",
                   nil
                 )

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
        handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
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
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))
    {db, pid} = memory_db!()

    try do
      sample =
        Enum.find(fixture["cases"], &(&1["case"] == "needs-request-nil-opens-and-parks"))

      ids = materialize_world(db, sample["world"])
      handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})

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
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))
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
            assert %{harness: "codex", model: %Model{family: "test"}} = Org.get(db, producer)
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
            db: db,
            credential_status: fn _provider -> :onboarded end,
            credential_kind: fn _provider -> :subscription end,
            claude_fetch: fn _, _ -> {:error, :unused} end,
            sh: fn _command ->
              catalog_reply(
                JSON.encode!(%{
                  models: [
                    %{
                      slug: "test",
                      display_name: "Test",
                      supported_reasoning_levels: []
                    }
                  ]
                })
              )
            end
          )
        end)
      ]
      |> Enum.reject(&is_nil/1)

    await_catalog!("codex", 100)

    handlers =
      Gateway.handlers(%{
        base_dir: base,
        cwd: System.tmp_dir!(),
        port: 0,
        default_harness: :codex,
        default_model: Model.new("test"),
        max_live_sessions_per_user: 50,
        wake_tick_ms: 1_000,
        onboarding_lease_ms: 1_800_000,
        # Adapter patching has its own tests; this contract is about remedy
        # dispatch, and the staged adapter is a stub with no real bundle.
        patch_adapter: fn _harness, _path -> :ok end,
        db: db,
        # Limitation CATALOG-CREDENTIAL-REFUSAL: remedy fixtures force onboarded status,
        # so this support config cannot observe a needs_onboarding refusal.
        credential_status: fn _provider -> :onboarded end,
        credential_kind: fn _provider -> :subscription end
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

  defp start_wake_delivery_services do
    [
      start_named_service(ConnRegistry, fn ->
        ConnRegistry.start_link(name: ConnRegistry)
      end),
      start_named_service(Tightbeam.LaneManager, fn ->
        Tightbeam.ConformanceLaneManager.start_link()
      end)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp run_escalation_fold_contract(fixture) do
    base = temp_dir!("conformance-escalation-fold")
    prepare_rule_base!(base, fixture)
    handlers = Gateway.handlers(%{})
    Rules.load!(base, Map.keys(handlers))

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
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))

    try do
      Enum.each(fixture["cases"], fn kase ->
        {db, pid} = memory_db!()

        try do
          ids = materialize_world(db, Map.get(kase, "world", %{}))
          seed_script_checkout!(base, fixture, kase, db)
          call = build_call(kase["call"], ids)
          handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
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
    Rules.load!(base, Map.keys(Gateway.handlers(%{})))

    try do
      Enum.each(fixture["cases"], fn kase ->
        {db, pid} = memory_db!()

        try do
          ids = materialize_world(db, Map.get(kase, "world", %{}))
          seed_script_checkout!(base, fixture, kase, db)
          call = build_call(kase["call"], ids)
          handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
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
              assert %{supervisionState: "armed"} = Supervision.prod_state(db, assignment_id)
              assert sweep_decision?(db, session_key, rule, "run-remedy")

            "re-obligate" ->
              assert result == {:prodded, 1}
              assert RailRemedy.episode(db, rule, assignment_id) == nil
              assert Supervision.prod_state(db, assignment_id).prodCount == 1
              assert sweep_decision?(db, session_key, rule, "re-obligate")

            "none" ->
              assert RailRemedy.episode(db, rule, assignment_id) == nil

              cond do
                fixture["name"] == "busy-or-queued-no-sweep" ->
                  assert result == :busy
                  assert %{supervisionState: "armed"} = Supervision.prod_state(db, assignment_id)
                  refute lifecycle_kind?(db, "rail_sweep")

                self_wake?(db, call) ->
                  assert result == :continuation
                  assert %{supervisionState: "armed"} = Supervision.prod_state(db, assignment_id)
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

    :ok = Tightbeam.Schema.ensure_all(name)

    {name, pid}
  end

  defp materialize_world(
         db,
         world,
         ids \\ %{assignments: %{}, work_items: %{}, turns: %{}}
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
        model:
          Model.from_params(session) ||
            Model.new("fable"),
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
            supervision_interval_ms: 1_000,
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

    Enum.each(Map.get(world, "stored_attests", []), fn attest ->
      {by_session, by_user} =
        case principal(attest["by"]) do
          {:session, session} -> {session, nil}
          {:user, user} -> {nil, user}
        end

      assert {:ok, _} =
               DB.query(
                 db,
                 """
                 INSERT INTO attests
                   (id, assignmentId, kind, verdictKind, bySession, byUser, ts)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 """,
                 [
                   "stored_attest_#{System.unique_integer([:positive])}",
                   assignments[attest["assignment"]],
                   attest["kind"],
                   attest["verdict_kind"],
                   by_session,
                   by_user,
                   System.unique_integer([:positive])
                 ]
               )
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

    {:ok, _} =
      DB.query(db, "UPDATE supervision_entitlements SET dueAt=0 WHERE state='armed'")

    %{
      assignments: assignments,
      work_items: work_items,
      turns: turns
    }
  end

  defp first_user(world), do: world |> Map.get("users", []) |> List.first() |> Map.fetch!("id")

  defp prepare_rule_base!(base, fixture, opts \\ []) do
    rules_dir = Path.join(base, "identity/rules")
    File.mkdir_p!(rules_dir)

    # Spawn readiness looks for an adapter under this base_dir; it used to resolve
    # to a sibling checkout present on the developer's machine (#46).
    for bin <- ["claude-agent-acp", "codex-acp"] do
      adapter = Path.join([base, "adapters", "node_modules", ".bin", bin])
      File.mkdir_p!(Path.dirname(adapter))
      File.write!(adapter, "#!/bin/sh\nexit 0\n")
      File.chmod!(adapter, 0o755)
    end

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
    workdir = Placement.holder_workdir(%{base_dir: base, db: db, port: 0}, holder)

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
        supervision_interval_ms: 1_000,
        params: %{subject: subject, idempotency_key: nil}
      })

    assert is_binary(result.id)
    result.id
  end

  defp await_catalog!(harness, attempts) when attempts > 0 do
    case ModelCatalog.get(Placement.local_host_name(), harness, ModelCatalog) do
      {[_ | _], :fresh} ->
        :ok

      _ ->
        Process.sleep(5)
        await_catalog!(harness, attempts - 1)
    end
  end

  defp await_catalog!(_harness, 0), do: flunk("model catalog did not become fresh")

  defp cancel_wake(db, wake) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        [[assignment_id]] =
          DB.Txn.q(txn, "SELECT assignmentId FROM wakes WHERE wakeId=?1", [wake.wake_id])

        {:ok, liveness_trigger} =
          Supervision.liveness_trigger_in_txn(txn, {:assignment, assignment_id})

        Wakes.cancel_in_txn(txn, %{
          wake_id: wake.wake_id,
          expected_origin: wake.origin,
          requester: %{kind: "process", id: "conformance"},
          reason_kind: "requester_withdrew",
          causal_source: %{
            kind: "verb_call",
            accepted_event: %{
              origin: wake.origin,
              session_key: nil,
              principal: {:process, "conformance"}
            }
          },
          outcome: %{kind: "no_replacement", liveness_trigger: liveness_trigger}
        })
      end)

    result
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
      if event.kind == "rail_sweep" do
        detail = JSON.decode!(event.detail)

        event.subject == session_key and detail["statute"] == statute and
          detail["decision"] == decision
      else
        false
      end
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
    # symlink (/var -> /private/var), and Containment.rail_profile/1 refuses write
    # roots with unresolved symlink components.
    base = to_string(:string.trim(:os.cmd(~c(realpath #{System.tmp_dir!()}))))
    path = Path.join(base, "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end

defmodule Tightbeam.ConformanceTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.ConformanceSupport, as: Corpus

  @root Corpus.corpus_root()
  @corpus Corpus.load_corpus!(@root)
  @fixtures @corpus.fixtures
  @classes @corpus.classes
  # A fixture listed here is registered, shape-locked and NOT executed, with the
  # reason visible in the skip. That is the honest state for a fixture whose
  # runner does not exist yet.
  #
  # The seven C6 entries below were previously reported PASS by a catch-all that
  # ran `review-remedy-spawn`'s contract instead of their own (35 declared cases,
  # zero executed). A skip that names its gap is strictly better than a green that
  # claims coverage it does not have.
  @unsupported_fixtures %{
    "C2/handoff-assign" =>
      "missing Rules fact registration/evaluator for call.handoff_complete on assign",
    "C2/handoff-wake" =>
      "missing Rules fact registration/evaluator for call.handoff_complete on wake",
    "C3/two-changes-requested-revert" =>
      "missing Rules fact registration/evaluator for assignment.changes_requested_count",
    "C6/denied-dispatch-release-retry" =>
      "no runner contract for the lease release/reclaim assertions (mech r7)",
    "C6/iterate-rewake-target" => "no runner contract for the rewake-target assertions (mech r7)",
    "C6/multi-statute-episode-closure" =>
      "no runner contract for per-statute closure ownership (mech r7)",
    "C6/note-digest-exclusion" =>
      "no runner contract for effect-neutral digest exclusion (mech r7)",
    "C6/stale-claimant-fencing" => "no runner contract for occurrence-keyed fencing (mech r7)",
    "C6/unbound-reviewer-remedy" =>
      "no runner contract for the unbound-reviewer refusal (mech r7)",
    "C6/waiver-revoked-mid-fold" => "no runner contract for mid-fold waiver revocation (mech r8)"
  }

  test "activation census" do
    exact_skips = map_size(@unsupported_fixtures)
    active_fixtures = length(@fixtures) - exact_skips

    structured =
      Enum.count(@fixtures, &(&1["phase"] == "green" and &1["kind"] == "dispatch-rule"))

    activated_fixture_tests =
      Enum.count(@fixtures, fn fixture ->
        name = "#{fixture["class"]}/#{fixture["name"]}"

        (fixture["phase"] != "green" or fixture["class_phase"] != "green") and
          not Map.has_key?(@unsupported_fixtures, name)
      end)

    activated_class_tests = Enum.count(@classes, &(&1["phase"] == "pending"))
    activated_tests = activated_fixture_tests + activated_class_tests

    IO.puts(
      "conformance activation census: #{active_fixtures} active fixture tests; " <>
        "#{exact_skips} exact-mechanism fixture skips; #{activated_tests} formerly skipped tests " <>
        "activated (#{activated_fixture_tests} fixtures + #{activated_class_tests} class registrations); " <>
        "#{structured} structured-legibility assertion sets active"
    )

    # verification-papertrail-v1 removed the producer subsystem and with it
    # seven fixtures: five C4 producer fixtures (producer-cas-verdict-txn,
    # frozen-job-provenance, produced-tests-only, produced-real-run-only,
    # orphaned-running-failed) and the missing-producer/producer-present F1
    # loadset twin; producer-backed-gate was replaced 1:1 by
    # artifact-backed-gate. The ten exact-mechanism skips are untouched.
    #
    # Deleting adjudication (2026-08-05) removed one more: C7's
    # adjudication-hold-order, whose whole subject was a hold freezing the
    # turn-end shift. The shift itself is unchanged minus that first slot.
    #
    # Fabric §13 Phase 0 (2026-08-13) adds one: C4's holder-verdict-wins, which
    # pins review-round selection against the wi_1b0237fe wedge class. It is a
    # pending C4 dispatch-rule fixture with its own cases, so it lands in the
    # active and activated counts, not in the exact-mechanism skips.
    #
    # Sol xhigh review, finding 4 (2026-08-13) adds a second: C4's
    # reopen-assignment-repair, which routes `reopen-assignment` itself
    # through the dispatch chokepoint (holder-verdict-wins only ever calls
    # `attest`) and exercises the defining displacement shape. It is also a
    # pending C4 fixture with its own named runner clause, not a catch-all.
    #
    # Phase 1 of the coordination fabric (2026-08-13) adds the C8 class and two
    # GREEN fixtures — class-delivery-policy and class-election-and-skew. Green
    # on both axes, so they raise the total and the active count and leave the
    # ACTIVATED counts alone: those measure fixtures still waiting on a
    # mechanism, and this mechanism ships on this branch.
    # Second wave (2026-08-13) adds two more GREEN C8 fixtures —
    # agent-question-carrier (seam ③) and read-cursors (seam ④) — on the same
    # both-axes rule as the first two.
    # The live engine switch (2026-08-14) adds the C9 class and one GREEN
    # fixture, live-engine-switch. Green on both axes, so it raises the total
    # and the active count and leaves the ACTIVATED counts alone. The class is
    # green too, so it adds no class registration either.
    assert length(@fixtures) == 71
    assert active_fixtures == 61
    assert exact_skips == 10
    assert activated_fixture_tests == 43
    assert activated_class_tests == 5
    assert activated_tests == 48
  end

  # The structural guard for the defect this file used to carry: a catch-all clause
  # whose fixture NAME is a wildcard, running `find.(...)` to fetch some other
  # fixture's contract. That reports PASS for a fixture whose own cases never ran,
  # and it is invisible from the outside — the suite is green either way.
  #
  # A clause may aggregate other fixtures, but only when it names the fixture it
  # matches, so the substitution is a deliberate declaration and not a default.
  test "no wildcard-name clause substitutes a foreign fixture's contract" do
    source = Path.expand("conformance_test.exs", __DIR__) |> File.read!()

    body =
      source
      |> String.split("def run_pending_fixture(fixture, fixtures, blocker) do", parts: 2)
      |> List.last()
      |> String.split("\n  end\n", parts: 2)
      |> List.first()

    offenders =
      body
      |> String.split(~r/\n      (?=\{")/)
      |> Enum.filter(fn clause ->
        wildcard_name? = Regex.match?(~r/^\{"[A-Za-z0-9]+", [^,]+, _\}\s*->/, clause)
        wildcard_name? and String.contains?(clause, "find.(")
      end)
      |> Enum.map(&(&1 |> String.split("->") |> List.first() |> String.trim()))

    assert offenders == [],
           "these clauses match any fixture name and then run a DIFFERENT fixture's " <>
             "contract, so the matched fixture's own cases never execute: " <>
             Enum.join(offenders, " | ") <>
             ". Give the fixture its own contract, name it explicitly, or register it " <>
             "in @unsupported_fixtures with a reason."
  end

  test "corpus phase annotations and case-level blockers are reported exactly" do
    entries = Corpus.pending_entries(@corpus)

    Enum.each(entries, fn entry ->
      IO.puts(
        "conformance corpus annotation #{entry.scope}: #{entry.id} " <>
          "phase=#{entry.phase} blocker=#{entry.blocker}"
      )
    end)

    # 52 since C4/holder-verdict-wins joined the corpus (fabric §13 Phase 0); 53
    # since C4/reopen-assignment-repair joined it (Sol xhigh review, finding 4).
    assert Enum.count(entries, &(&1.scope == "fixture")) == 53

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

  # ExUnit's per-test default is 60s, a number chosen for the in-memory unit tests that
  # make up most of this suite. This test is the one site in the module that earns a
  # different one: it drives the release rail-exec through the containment layer for
  # three script guards, so it is dozens of OS process creations deep and its cost is
  # fork latency, which scales with the box rather than with anything the test does.
  # Measured end to end: 12.4s at load 19 and 19.6s at load 45 on this box, and 40.8s
  # once and 88.2s an hour later on a loaded dev box — straddling the default, so the
  # test was a coin flip against a budget nobody chose for it. 300s is ~3.4x the worst
  # yet observed.
  #
  # Per-test and not @moduletag: the other 100-odd tests here are unit-scale (the
  # measured distribution drops to ~1.5s below the four script-driving sites), and
  # handing them all 300s would hide a genuine hang in any of them to accommodate this
  # one. This weakens no assertion either — the reason-pinning in assert_rule_result/5
  # is what keeps a slow run from passing falsely; the budget only stops the clock from
  # pre-empting a verdict the layer was still rendering.
  @tag timeout: 300_000
  test "C5 real rail-exec drives git state, observed files, exit bands, CWD, and laziness" do
    for name <- [
          "reconcile-with-main",
          "files-touched-observed",
          "predicate-prefilter-script-laziness"
        ] do
      Corpus.run_rail_exec_fixture(fixture!("C5", name))
    end
  end

  # Tasks #38 and #43: a `script_timeout` deny is produced by BOTH the rail-exec binary
  # enforcing the declared budget and RailScript.await/3 giving up on a wrapper that never
  # reported. They mean opposite things. The duration cannot tell them apart — it is
  # BEAM-side, so starvation makes the windows OVERLAP (reproduced in rail_script_test.exs)
  # — but the exit class can, because `unreported` is a class the wrapper cannot produce.
  #
  # So the two halves asserted here: the class decides the layer, and the duration decides
  # nothing. Crossing the backstop threshold must not move the conclusion by itself.
  test "C5 timeout evidence names the layer from the class, never from the duration" do
    db = :"c5_timeout_evidence_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    budget = 2_000
    ctx = %{db: db, timeout_ms: budget}
    timeout_deny = {:deny, %{rule: "reconcile-with-main", reason: "script_timeout"}}
    genuine_refusal = {:deny, %{rule: "reconcile-with-main", reason: "rule_denied"}}

    # Wrapper-reported, inside the backstop threshold.
    record_rail_script!(db, "timeout", budget + 40)
    inside = Tightbeam.RailTimeoutEvidence.render(timeout_deny, ctx)

    # Wrapper-reported, PAST it — the window an unsound timing rule would call "backstop".
    record_rail_script!(db, "timeout", budget + 2_000 + 15)
    past = Tightbeam.RailTimeoutEvidence.render(timeout_deny, ctx)

    for evidence <- [inside, past] do
      assert evidence =~ "layer: RAIL-EXEC BINARY (enforcement)"
      assert evidence =~ "recorded exit class: timeout"
      assert evidence =~ "declared budget   : 2000ms"
      assert evidence =~ "backstop threshold: 4000ms"
      assert evidence =~ "NOT the discriminator"
      refute evidence =~ "BEAM BACKSTOP"
    end

    # The measurements differ and are reported verbatim...
    assert inside =~ "measured duration : 2040ms"
    assert past =~ "measured duration : 4015ms"

    # ...but crossing the threshold does not change the layer, because the duration is not
    # what names it. Strip the measurement line and the two blocks are identical.
    assert strip_measured(inside) == strip_measured(past)

    # The other layer, at a duration INSIDE the budget — the mirror of the case above, and
    # proof the class is doing the work in both directions.
    record_rail_script!(db, "unreported", budget - 500)
    backstop = Tightbeam.RailTimeoutEvidence.render(timeout_deny, ctx)

    assert backstop =~ "layer: BEAM BACKSTOP (no verdict)"
    assert backstop =~ "recorded exit class: unreported"
    assert backstop =~ "no process group kill was observed"
    refute backstop =~ "RAIL-EXEC BINARY"

    # A genuine refusal must not acquire timeout noise it did not earn.
    assert Tightbeam.RailTimeoutEvidence.render(genuine_refusal, ctx) == ""
  end

  defp strip_measured(evidence) do
    String.replace(evidence, ~r/measured duration : \d+ms/, "measured duration : <n>ms")
  end

  defp record_rail_script!(db, exit_class, duration_ms) do
    Tightbeam.EventLog.lifecycle(
      db,
      "rail_script",
      "reconcile-with-main",
      JSON.encode!(%{
        exit_class: exit_class,
        reason: "script_timeout",
        duration_ms: duration_ms
      })
    )
  end

  test "declared-file fixture preserves advisory overlap and malformed-input refusal" do
    Corpus.run_handler_refusal_fixture(fixture!("C4", "declared-files-overlap"))
  end

  test "C6 review remedy claims once, dispatches once, and closes after the verdict" do
    fixture = fixture!("C6", "review-remedy-spawn")
    Corpus.run_rules_decide(fixture)
    Corpus.run_acting_layer(fixture)
  end

  test "C6 remedy episode matrix fences races, reclaims, rewakes, replaces, and retries" do
    Corpus.run_remedy_episode_contract(fixture!("C6", "remedy-episode-idempotent"))
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

  # The module's other rail-exec driver, and the same reasoning at its own measured
  # scale: 4.5s at load 19 and 13.8s at load 45. That is inside the 60s default today,
  # but the load factor that took the test above from 19.6s to 88.2s puts this one at
  # ~62s — astride the default, which is the coin-flip condition rather than a margin.
  # 180s is ~2.9x the projected worst; it is not the neighbour's 300s, because this
  # site did not measure the neighbour's number.
  @tag timeout: 180_000
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
    assert output =~ "containment enforces resolved write roots and preserves stdout"
  end

  for fixture <- @fixtures do
    name = "#{fixture["class"]}/#{fixture["name"]}"
    missing_mechanism = Map.get(@unsupported_fixtures, name)

    cond do
      missing_mechanism ->
        @tag skip: missing_mechanism
        test name do
          fixture = unquote(Macro.escape(fixture))
          Corpus.run_pending_fixture(fixture, @fixtures, unquote(missing_mechanism))
        end

      fixture["phase"] == "green" and fixture["class_phase"] == "green" ->
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
            "delivery_policy" -> Corpus.run_delivery_policy_fixture(fixture)
            "question_carrier" -> Corpus.run_question_carrier_fixture(fixture)
            "read_cursor" -> Corpus.run_read_cursor_fixture(fixture)
            "live_switch" -> Corpus.run_live_switch_fixture(fixture)
          end)
        end

        if fixture["kind"] == "dispatch-rule" do
          test "#{name} structured legibility" do
            fixture = unquote(Macro.escape(fixture))
            Corpus.run_rules_fixture(fixture)
          end
        end

      true ->
        blocking_phase = fixture["blocking_phase"]

        test name do
          fixture = unquote(Macro.escape(fixture))
          Corpus.run_pending_fixture(fixture, @fixtures, unquote(blocking_phase))
        end
    end
  end

  for class <- @classes, class["phase"] == "pending" do
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
