# Feature smoke — walks each new verb end-to-end against a RUNNING gateway
# (full HTTP + router + dispatch + handler + DB stack; the integration path
# unit tests don't cover). Reads port+token from <base_dir>/gateway.json.
#
#   TIGHTBEAM_BASE_DIR=~/.tightbeam-beam \
#   TIGHTBEAM_SMOKE_MODEL_CLAUDE='claude-sonnet-5' TIGHTBEAM_SMOKE_EFFORT_CLAUDE='medium' \
#   TIGHTBEAM_SMOKE_MODEL_CODEX='gpt-5.6-sol' TIGHTBEAM_SMOKE_EFFORT_CODEX='medium' \
#   mix run --no-start scripts/feature_smoke.exs
#
# Runs one explicit spawn/dispatch leg per SELECTED harness and exits non-zero on
# the first failed assertion. Every new roadmap feature that is user-callable
# should get a check here (see the smoke-coverage practice).
#
# By default the selection is every Harness.all/0 entry, and a model is required
# for each. TIGHTBEAM_SMOKE_LEGS narrows it (tier-map GAP-3):
#
#   TIGHTBEAM_SMOKE_LEGS=codex mix run --no-start scripts/feature_smoke.exs
#
# A narrowed run needs a model only for the legs it selected, which is what makes
# one leg affordable rather than merely shorter. It also reports INCOMPLETE(parity)
# by design and proves nothing about the leg it skipped, so the gibson gate still
# wants both legs green (artifact-carrier-proposal-v1 §7.3); the filter is for
# answering one leg's question quickly, not for satisfying the gate.
#
# The last two groups cover artifact-carrier-proposal-v1 §7.3 as a pair, and the
# split between them is deliberate. `check_gate_chain_enforced/1` proves the LAW —
# each statute denies while its fact is unsatisfied, and the artifact releases the
# last one — driven entirely over HTTP, so the holder's remedy turns are never STARTED
# while it runs, which the group measures rather than assumes.
# `check_carrier_on_real_turn/1` proves the CARRIER: a real CLI artifact-record
# inside a real harness turn, bound to that turn and reading tool-call-observed.
#
# "A REAL AGENT WALKS THE GATES" was proven in the field, not dropped. Both legs
# did the whole lifecycle autonomously and honestly on 2026-07-30 — claude
# 11:19:56 open → 11:20:48 verified → 11:21:02 recorded → 11:21:07 closed, codex
# the same shape at 12:09–12:12, landing art_0f26ec21 tool-call-observed with a
# non-null edge. Driving that chain through a scripted holder is what the split
# gives up, because a capable holder finishes it before any scripted denial can
# fire; the second group keeps the substrate half under assertion every run and
# accepts the holder completing its own assignment rather than calling it a race.
#
# Both groups additionally need the org's identity/rules to carry the shipped
# verification statutes (completion-requires-verification,
# completion-requires-results-artifact) AND a `coder` archetype that admits this
# host. Rules load once at gateway BOOT, so an org whose law changed under a
# running gateway must be rebooted before the run. On shrdlu that means the
# eb0ea2b org-law workaround must be REVERTED first: with it installed the
# artifact statute never denies and the gate-chain group fails at its third
# denial, which is exactly what keeps that leg falsifiable.

defmodule FeatureSmoke do
  require Record

  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  defmodule Failure do
    defexception [:message]
  end

  @owner System.get_env("TIGHTBEAM_SMOKE_OWNER") || "mike"

  # How long a remedy episode gets to reach a status. The transition rides the attest
  # that provoked it, so this covers scheduling, not model time.
  @episode_settle_ms 30_000

  # This smoke-owned wait stops only the observer. It never reaches runtime execution.
  @turn_observer_wait_ms :timer.minutes(10)

  # Slack over one observer wait: lane queueing, adapter spawn, and the poll interval.
  @lane_slack_ms 60_000

  @home_evidence_schema "tightbeam.feature_smoke.home_evidence.v1"
  @home_evidence_name "feature-smoke-home-evidence.jsonl"
  @home_phase_plan [
    {"all", "run-start"},
    {"claude", "pre-spawn"},
    {"claude", "pre-wake"},
    {"claude", "post-turn"},
    {"codex", "pre-spawn"},
    {"codex", "pre-wake"},
    {"codex", "post-turn"}
  ]
  @home_check_ids ~w(
    phase_order fixture_state clock_order snapshot_acquired baseline_equal path_set_equal
    codex_delta_empty entry_type_equal entry_mode_equal sidecar_size_bounded json_utf8_valid
    json_syntax_valid json_unique_members claude_json_object sidecar_member_set_equal
    sidecar_member_types_equal filename_pid_equal session_id_shape expected_cwd_equal
    proc_start_shape version_shape peer_protocol_equal kind_equal entrypoint_equal
    name_nonempty name_source_equal backup_epoch_in_interval started_at_in_interval
    identity_matches_pre_wake
  )
  @sidecar_members MapSet.new(~w(
    pid sessionId cwd startedAt procStart version peerProtocol kind entrypoint name nameSource
  ))
  @uuid_re ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @positive_decimal_re ~r/\A[1-9][0-9]*\z/
  @semver_re ~r/\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/
  @backup_re ~r/\Abackups\/\.claude\.json\.backup\.([0-9]{13})\z/
  @sidecar_re ~r/\Asessions\/([1-9][0-9]*)\.json\z/
  @implementation_base "bdf0ad2c9ae4078f897a00e8c57767968676477c"
  @contract_provenance {
    "5f4341130419c4bae21bdd6c2278185dcd0f89a5",
    "asg_17a50f66-c32d-42f2-aba5-dd39e072203e",
    [373, 384, 387, 390]
  }

  def run do
    base_dir = System.get_env("TIGHTBEAM_BASE_DIR") || Path.expand("~/.tightbeam-beam")
    install_smoke_rule!(base_dir)
    gw = base_dir |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()
    Process.put(:salt, Integer.to_string(System.os_time(:second)) <> "-")

    selection = Tightbeam.FeatureSmokePlan.selection(Tightbeam.Harness.all())
    announce_selection!(selection)
    legs = Tightbeam.FeatureSmokePlan.legs(Tightbeam.Harness.all())

    with_home_evidence!(base_dir, fn evidence ->
      evidence = validate_run_start!(base_dir, legs, evidence)

      Enum.reduce(legs, evidence, fn leg, evidence ->
        IO.puts("\nfeature-smoke leg #{leg.wire_name} model=#{leg.model}")
        preflight!(leg, base_dir)

        state =
          %{
            port: gw["port"],
            token: gw["cliToken"],
            base_dir: base_dir,
            pass: 0,
            leg: leg,
            evidence: evidence,
            providers: Tightbeam.FeatureSmokePlan.provider_names(Tightbeam.Harness.all())
          }
          |> sweep_open_work_items()
          |> check_local_deployment()
          |> check_identity_surface()
          |> check_onboard_surface()
          |> check_facts_read()
          |> check_config_default_archetype()
          |> check_work_item_and_assignment_get()
          |> check_dispatch_opens_assignment()
          |> check_effort_without_effect()
          |> check_flagship_review_loop()
          |> check_escalation_to_owner()
          |> check_toplines_board()
          |> check_gate_chain_enforced()
          |> check_carrier_on_real_turn()

        finish_leg(state)
        state.evidence
      end)
    end)
  end

  # Pure deterministic coverage for the contract rows. This mode never opens a
  # gateway, creates a fixture, or touches a projected home.
  def run_home_cases! do
    now = 1_786_000_000_000
    cwd = "/fixture/work/0123456789ab"
    entries = synthetic_claude_entries(now, cwd)
    {nil, identity} = runtime_failure(%{}, "claude", "pre-wake", entries, cwd, now, now)
    sidecar_path = "sessions/123.json"

    cases = [
      {"AC-01", candidate_code(run_start_failure(["claude", "codex"], "1|1|0|0|0")), :pass},
      {"AC-02", candidate_code(run_start_failure(["claude", "codex"], "1|1|1|0|0")),
       "FX_FIXTURE_STATE"},
      {"AC-03", snapshot_walk_case(), :pass},
      {"AC-04", runtime_case(%{}, "claude", "pre-wake", entries, cwd, now, now), :pass},
      {"AC-05", runtime_case(%{}, "claude", "pre-wake", entries, cwd, now, now), :pass},
      {"AC-06",
       entries
       |> rename_entry(sidecar_path, "sessions/0123.json")
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_PATH_SET"},
      {"AC-07",
       entries
       |> replace_json(sidecar_path, &Map.put(&1, "pid", 124))
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_SIDECAR_SEMANTIC"},
      {"AC-08",
       entries
       |> replace_bytes(sidecar_path, <<255>>)
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_JSON"},
      {"AC-09",
       entries
       |> replace_bytes(sidecar_path, "{")
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_JSON"},
      {"AC-10",
       entries
       |> replace_bytes(sidecar_path, "{\"pid\":123,\"pid\":123}")
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_JSON"},
      {"AC-11",
       entries
       |> replace_json(sidecar_path, &Map.delete(&1, "name"))
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_SIDECAR_SCHEMA"},
      {"AC-12",
       entries
       |> replace_json(sidecar_path, &Map.put(&1, "extra", true))
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_SIDECAR_SCHEMA"},
      {"AC-13",
       entries
       |> replace_json(sidecar_path, &Map.put(&1, "pid", "123"))
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_SIDECAR_SCHEMA"},
      {"AC-14",
       entries
       |> replace_json(sidecar_path, &Map.put(&1, "cwd", "/wrong"))
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_SIDECAR_SEMANTIC"},
      {"AC-15",
       entries
       |> rename_entry(
         "backups/.claude.json.backup.#{now}",
         "backups/.claude.json.backup.#{now - 1}"
       )
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_FRESHNESS"},
      {"AC-16",
       runtime_case(
         %{},
         "claude",
         "pre-wake",
         entries ++ [synthetic_entry("sessions/124.json", :regular, 0o644, "{}")],
         cwd,
         now,
         now
       ), "FX_PATH_SET"},
      {"AC-17",
       entries
       |> rename_entry(
         "backups/.claude.json.backup.#{now}",
         "backups/.claude.json.backup.#{now + 1}"
       )
       |> runtime_case(%{}, "claude", "post-turn", cwd, now, now + 1, %{
         home_sidecar_identity: identity
       }), :pass},
      {"AC-18",
       entries
       |> replace_json(
         sidecar_path,
         &Map.put(&1, "sessionId", "11111111-1111-1111-1111-111111111111")
       )
       |> runtime_case(%{}, "claude", "post-turn", cwd, now, now, %{
         home_sidecar_identity: identity
       }), "FX_IDENTITY_DRIFT"},
      {"AC-19",
       runtime_case(
         %{},
         "claude",
         "pre-wake",
         entries ++ [synthetic_entry("sessions/nested/2.json", :regular, 0o644, "{}")],
         cwd,
         now,
         now
       ), "FX_PATH_SET"},
      {"AC-20",
       entries
       |> replace_entry(
         sidecar_path,
         &%{&1 | type: :symlink, mode: 0o777, size: nil, sha256: nil, bytes: nil}
       )
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_TYPE"},
      {"AC-21",
       entries
       |> replace_entry(".claude.json", &%{&1 | mode: 0o644})
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_MODE"},
      {"AC-22",
       entries
       |> replace_bytes(sidecar_path, :binary.copy("x", 4097))
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_SIZE"},
      {"AC-23",
       entries
       |> replace_bytes(".claude.json", "[]")
       |> runtime_case(%{}, "claude", "pre-wake", cwd, now, now), "FX_JSON_SHAPE"},
      {"AC-24", codex_runtime_scope_case(cwd, now), :pass},
      {"AC-25", repeated_first_failure(entries, cwd, now), "FX_MODE"},
      {"AC-26", full_evidence_file_case(entries), :pass},
      {"AC-27", cleanup_refusal_case(entries, cwd, now), :pass},
      {"AC-28", implementation_custody_case(), :pass},
      {"AC-29", phase_matrix_case(entries), :pass},
      {"AC-30", retained_blocker_case(entries, cwd, now), :pass},
      {"AC-31", contract_provenance_case(), :pass},
      {"AC-32", wrong_cwd_retained_evidence_case(entries, cwd, now), :pass},
      {"AC-33", evidence_exclusive_create_case(), :pass},
      {"AC-34", evidence_sink_failure_case(), :pass},
      {"AC-35",
       entries
       |> Enum.reject(&(&1.raw_path == "sessions"))
       |> Kernel.++([synthetic_entry("unexpected", :regular, 0o600, "{}")])
       |> repeated_path_set_case(cwd, now), :pass},
      {"AC-36", injected_enumeration_failure_case(), :pass},
      {"AC-37", injected_snapshot_failure_case(:lstat), :pass},
      {"AC-38", injected_snapshot_failure_case(:open), :pass},
      {"AC-39", injected_snapshot_failure_case(:read), :pass},
      {"AC-40", injected_snapshot_failure_case(:opened_type), :pass},
      {"AC-41", injected_snapshot_failure_case(:opened_identity), :pass},
      {"AC-42", injected_snapshot_failure_case(:final_identity), :pass}
    ]

    Enum.each(cases, fn {id, actual, expected} ->
      if actual != expected,
        do: raise(Failure, message: "#{id} expected #{inspect(expected)}, got #{inspect(actual)}")
    end)

    IO.puts("feature-smoke HOME validator deterministic cases: 42/42 PASS")
  end

  defp preflight!(leg, base_dir) do
    row = Tightbeam.ClientE2E.preflight(leg.wire_name, base_dir)
    IO.puts("credential preflight #{row.step}: #{String.upcase(to_string(row.status))}")

    case row.status do
      :pass -> :ok
      :fail -> raise "credential preflight failed: #{row.note}"
      :incomplete -> raise "credential preflight INCOMPLETE/blocker: #{row.note}"
    end
  end

  # --- local deployment: live home + cwd projection and durable redelivery ----
  defp check_local_deployment(state) do
    harness = state.leg.harness.id()
    machine = Tightbeam.Placement.local_host_name()
    home = Tightbeam.Homes.home_path(state.base_dir, machine, harness)
    expected_home = MapSet.new(Tightbeam.Homes.owned_entries(harness))

    state = validate_pre_spawn!(state, home, expected_home)
    spawn_started_at = System.system_time(:millisecond)

    session =
      ok!(state, "spawn", %{
        "archetype" => "reviewer",
        "displayName" => "smoke-local-deploy-#{unique()}",
        "idempotencyKey" => "local-deploy-#{unique()}"
      })

    session_key = get_in(session, ["stream", "sessionKey"]) || session["sessionKey"]
    sentinel = Path.join(home, ".feature-smoke-durable-#{unique()}")

    cwd = local_workdir_path(state.base_dir, session_key)

    state =
      with_required_cleanup(
        fn ->
          redeploy!(state, session_key, session_harness!(state, session_key))

          state =
            validate_runtime_home!(
              state,
              home,
              expected_home,
              session_key,
              cwd,
              spawn_started_at,
              "pre-wake"
            )

          snapshot = Tightbeam.Identity.snapshot!(state.base_dir, "reviewer", harness)

          assert(
            state,
            map_size(snapshot.skills) > 0,
            "local deployment elected no skills for reviewer at #{cwd}"
          )

          ok!(state, "wake", %{
            "sessionKey" => session_key,
            "prompt" => "Reply with exactly: LOCAL DEPLOYMENT READY",
            "idempotencyKey" => "local-deploy-wake-#{unique()}"
          })

          await_materialized_skills!(state, cwd, snapshot.skills)

          # One SESSION-principal work-item create, deliberately placed INSIDE this
          # group's running-turn window (after the wake, before the turn boundary) —
          # the only window in the run where a session lane has a turn in flight.
          # A user-principal create can never be stamped, because only a session lane
          # can have a running turn; this is what gives the toplines board a node whose
          # creation context was actually RECORDED against a turn.
          #
          # WHAT THIS DOES NOT REACH: `linked`. The only running turn in this window
          # comes from a plain `wake`, which carries neither `jobRef` nor
          # `assignmentId`, so derivation finds no candidate and correctly reports
          # `from_turn`. Reaching `linked` live would need the create to happen inside
          # the DISPATCH group, whose holder turn carries `assignmentId` — so read the
          # four accepted statuses below as four accepted, not four proven.
          #
          # A session acting under its OWN credential needs a bound role for the router
          # to derive its origin — an unbound one is refused `no_role` (found by the
          # first live run of this check, not by reading the code).
          role = "local-deploy-#{unique()}"
          post(state, "role-create", %{"name" => role})
          ok!(state, "role-bind", %{"name" => role, "sessionKey" => session_key})

          ok!(
            %{state | token: session_token(state, session_key)} |> Map.put(:as_session, true),
            "work-item-create",
            %{
              "title" => "smoke agent-created wi #{unique()}",
              "idempotencyKey" => "awi-#{unique()}"
            }
          )

          await_turn_boundary!(state, session_key)

          state =
            validate_runtime_home!(
              state,
              home,
              expected_home,
              session_key,
              cwd,
              spawn_started_at,
              "post-turn"
            )

          sentinel_bytes = "durable-local-deployment-#{unique()}\n"
          File.write!(sentinel, sentinel_bytes)
          redeliver!(state, session_key)

          assert(
            state,
            File.read(sentinel) == {:ok, sentinel_bytes},
            "local deployment durable state changed during redelivery: #{sentinel}"
          )
        end,
        fn ->
          File.rm(sentinel)
          retire(state, session)
        end
      )

    pass(
      state,
      "local deployment HOME path + exact owned projection + bounded runtime + cwd skills + durable redelivery"
    )
  end

  # The LOCAL host's workdir, computed without touching the database.
  #
  # WHY THIS IS NOT A CALL TO `Placement.workdir_path/2`. That function resolves the host
  # through `Placement.hosts/2`, which since 42f976b reads the registry with
  # `SELECT ... FROM hosts` — a `GenServer.call` into `Tightbeam.DB`. This script runs
  # under `--no-start` (its header says why: a plain `mix run` boots a second gateway and
  # clobbers the `gateway.json` the run is aimed at), so there is no DB process and that
  # call takes the whole run down before the first group finishes.
  #
  # WHY REPLICATING IT IS FAITHFUL RATHER THAN A GUESS. For the local host the registry
  # read cannot change the answer: `hosts/2` reads the table and then OVERWRITES the local
  # entry with `%{base_dir: base_dir, ...}`, so a registered row for this machine is
  # discarded by construction. This group only ever asks about `local_host_name/0`, which
  # leaves `Path.join([base_dir, "work", <first 12 hex of sha256(sessionKey)>])` — the
  # digest below, and nothing else, is all of `workdir_path/2` that survives for this case.
  #
  # NOT A GENERAL SUBSTITUTE, and the boundary is the whole reason to say so here: a
  # satellite host's workdir really does live under its own registered base_dir, and
  # anything asking about a non-local host must go through Placement with a live DB.
  # If `workdir_path/2` changes shape, this drifts silently — that is the cost, and the
  # citation above is what makes the drift findable.
  defp local_workdir_path(base_dir, session_key) do
    digest =
      :crypto.hash(:sha256, session_key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    Path.join([base_dir, "work", digest])
  end

  # The retained fixture evidence is deliberately outside either projected home.
  # Runtime cleanup may remove a sidecar; this handle is therefore opened once before
  # run-start validation and synced after every phase judgment.
  defp with_home_evidence!(base_dir, fun) do
    with_home_evidence!(base_dir, fun, home_ops())
  end

  defp with_home_evidence!(base_dir, fun, ops) do
    path = Path.join(base_dir, @home_evidence_name)

    case ops.create_evidence.(path) do
      :ok ->
        case ops.open_evidence.(path) do
          {:ok, io} ->
            created? =
              match?(
                {:ok, info}
                when file_info(info, :type) == :regular and
                       Bitwise.band(file_info(info, :mode), 0o7777) == 0o600,
                ops.lstat.(path)
              )

            if created? do
              try do
                fun.(%{io: io, sequence: 1, phase_index: 0, ops: ops})
              after
                ops.close.(io)
              end
            else
              ops.close.(io)
              emit_evidence_refusal!(ops, "all", "run-start", "run-start")
            end

          {:error, _reason} ->
            emit_evidence_refusal!(ops, "all", "run-start", "run-start")
        end

      {:error, _reason} ->
        emit_evidence_refusal!(ops, "all", "run-start", "run-start")
    end
  end

  defp validate_run_start!(base_dir, legs, evidence) do
    selected = Enum.map(legs, & &1.wire_name)

    counts =
      case System.cmd("sqlite3", [
             Path.join(base_dir, "state.db"),
             "SELECT COUNT(*), COALESCE(SUM(isAdmin),0), " <>
               "(SELECT COUNT(*) FROM sessions), " <>
               "(SELECT COUNT(*) FROM work_items), " <>
               "(SELECT COUNT(*) FROM turns) FROM users"
           ]) do
        {out, 0} -> String.trim(out)
        _ -> ""
      end

    candidate =
      phase_candidate(evidence, "all", "run-start") || run_start_failure(selected, counts)

    finish_home_phase!(evidence, "all", "run-start", "run-start", [], candidate)
  end

  defp run_start_failure(["claude", "codex"], "1|1|0|0|0"), do: nil
  defp run_start_failure(_selected, _counts), do: home_failure(2, "FX_FIXTURE_STATE", "C-01", "-")

  defp validate_pre_spawn!(state, home, expected_home) do
    harness = state.leg.wire_name
    phase = "pre-spawn"
    principal = "pre-spawn"

    case phase_candidate(state.evidence, harness, phase) do
      nil ->
        ancestors = baseline_ancestors(expected_home)

        case snapshot_home(home, fn _relative -> false end) do
          {:ok, entries, _finished_at} ->
            evidence_entries = Enum.reject(entries, &MapSet.member?(ancestors, &1.raw_path))
            observed = MapSet.new(evidence_entries, & &1.raw_path)

            candidate =
              if observed == expected_home,
                do: nil,
                else: home_failure(5, "FX_BASELINE", "C-01", "-")

            evidence =
              finish_home_phase!(
                state.evidence,
                harness,
                phase,
                principal,
                evidence_entries,
                candidate
              )

            %{state | evidence: evidence}

          {:error, path, entries, _finished_at} ->
            partial = partial_pre_spawn_entries(entries, ancestors, path)

            finish_home_refusal!(
              state,
              harness,
              phase,
              principal,
              partial,
              home_failure(4, "FX_SNAPSHOT", "C-08", path)
            )
        end

      candidate ->
        finish_home_refusal!(state, harness, phase, principal, [], candidate)
    end
  end

  defp validate_runtime_home!(
         state,
         home,
         expected_home,
         session_key,
         expected_cwd,
         spawn_started_at,
         phase
       ) do
    harness = state.leg.wire_name
    ancestors = baseline_ancestors(expected_home)

    runtime? = fn relative ->
      not MapSet.member?(expected_home, relative) and not MapSet.member?(ancestors, relative)
    end

    case phase_candidate(state.evidence, harness, phase) do
      nil ->
        case snapshot_home(home, runtime?) do
          {:ok, entries, snapshot_finished_at}
          when harness == "claude" and snapshot_finished_at < spawn_started_at ->
            runtime_entries = Enum.filter(entries, &runtime?.(&1.raw_path))

            finish_home_refusal!(
              state,
              harness,
              phase,
              session_key,
              runtime_entries,
              home_failure(3, "FX_CLOCK", "C-05", "-")
            )

          {:error, path, entries, snapshot_finished_at}
          when harness == "claude" and snapshot_finished_at < spawn_started_at ->
            partial = partial_phase_entries(entries, expected_home, ancestors, path)

            finish_home_refusal!(
              state,
              harness,
              phase,
              session_key,
              partial,
              home_failure(3, "FX_CLOCK", "C-05", "-")
            )

          {:ok, entries, snapshot_finished_at} ->
            runtime_entries = Enum.filter(entries, &runtime?.(&1.raw_path))

            {candidate, identity} =
              runtime_failure(
                state,
                harness,
                phase,
                runtime_entries,
                expected_cwd,
                spawn_started_at,
                snapshot_finished_at
              )

            evidence =
              finish_home_phase!(
                state.evidence,
                harness,
                phase,
                session_key,
                runtime_entries,
                candidate
              )

            state
            |> Map.put(:evidence, evidence)
            |> then(fn next ->
              if phase == "pre-wake" and harness == "claude",
                do: Map.put(next, :home_sidecar_identity, identity),
                else: next
            end)

          {:error, path, entries, _snapshot_finished_at} ->
            partial = partial_phase_entries(entries, expected_home, ancestors, path)

            finish_home_refusal!(
              state,
              harness,
              phase,
              session_key,
              partial,
              home_failure(4, "FX_SNAPSHOT", "C-08", path)
            )
        end

      candidate ->
        finish_home_refusal!(state, harness, phase, session_key, [], candidate)
    end
  end

  defp finish_home_refusal!(state, harness, phase, principal, entries, candidate) do
    finish_home_phase!(state.evidence, harness, phase, principal, entries, candidate)
    state
  end

  defp phase_candidate(evidence, harness, phase) do
    if Enum.at(@home_phase_plan, evidence.phase_index) == {harness, phase},
      do: nil,
      else: home_failure(1, "FX_PHASE", "C-01", "-")
  end

  defp runtime_failure(_state, "codex", _phase, entries, _cwd, _started, _finished) do
    candidate =
      if entries == [],
        do: nil,
        else:
          home_failure(
            7,
            "FX_CODEX_RUNTIME_PATH",
            "C-07",
            Enum.min_by(entries, & &1.raw_path).raw_path
          )

    {candidate, nil}
  end

  defp runtime_failure(state, "claude", phase, entries, expected_cwd, started, finished) do
    with {:ok, backup, sidecar} <- claude_path_set(entries),
         sorted <- Enum.sort_by(entries, & &1.raw_path),
         nil <- type_failure(sorted, backup.raw_path, sidecar.raw_path),
         nil <- mode_failure(sorted, backup.raw_path, sidecar.raw_path),
         nil <- size_failure(sidecar),
         json_entries <- Enum.filter(sorted, &(&1.type == :regular)),
         analyses <- Map.new(json_entries, &{&1.raw_path, json_analysis(&1.bytes)}),
         nil <- json_failure(json_entries, analyses),
         nil <- claude_json_shape_failure(analyses[".claude.json"]),
         {:ok, sidecar_json} <- sidecar_schema(analyses[sidecar.raw_path], sidecar.raw_path),
         nil <- sidecar_semantic_failure(sidecar, sidecar_json, expected_cwd),
         nil <- freshness_failure(backup, sidecar, sidecar_json, started, finished),
         identity <- sidecar_identity(sidecar_json),
         nil <- identity_failure(state, phase, identity) do
      {nil, identity}
    else
      {:error, candidate} -> {candidate, nil}
      %{} = candidate -> {candidate, nil}
    end
  end

  defp claude_path_set(entries) do
    paths = Enum.map(entries, & &1.raw_path)
    backups = Enum.filter(entries, &Regex.match?(@backup_re, &1.raw_path))
    sidecars = Enum.filter(entries, &Regex.match?(@sidecar_re, &1.raw_path))

    if length(entries) == 5 and ".claude.json" in paths and "backups" in paths and
         "sessions" in paths and length(backups) == 1 and length(sidecars) == 1 do
      {:ok, hd(backups), hd(sidecars)}
    else
      {:error, home_failure(6, "FX_PATH_SET", "C-02", "-")}
    end
  end

  defp type_failure(entries, backup, sidecar) do
    expected = %{
      ".claude.json" => :regular,
      "backups" => :directory,
      backup => :regular,
      "sessions" => :directory,
      sidecar => :regular
    }

    first_path_failure(entries, fn entry ->
      if entry.type == expected[entry.raw_path],
        do: nil,
        else: home_failure(8, "FX_TYPE", "C-02", entry.raw_path)
    end)
  end

  defp mode_failure(entries, backup, sidecar) do
    expected = %{
      ".claude.json" => 0o600,
      "backups" => 0o755,
      backup => 0o600,
      "sessions" => 0o700,
      sidecar => 0o644
    }

    first_path_failure(entries, fn entry ->
      if entry.mode == expected[entry.raw_path],
        do: nil,
        else: home_failure(9, "FX_MODE", "C-02", entry.raw_path)
    end)
  end

  defp size_failure(sidecar) do
    if is_integer(sidecar.size) and sidecar.size in 1..4096,
      do: nil,
      else: home_failure(10, "FX_SIZE", "C-02", sidecar.raw_path)
  end

  defp json_failure(entries, analyses) do
    first_path_failure(entries, fn entry ->
      analysis = analyses[entry.raw_path]
      clause = if Regex.match?(@sidecar_re, entry.raw_path), do: "C-04", else: "C-02"

      cond do
        not analysis.utf8 -> home_failure(11, "FX_JSON", clause, entry.raw_path)
        not analysis.syntax -> home_failure(12, "FX_JSON", clause, entry.raw_path)
        not analysis.unique -> home_failure(13, "FX_JSON", clause, entry.raw_path)
        true -> nil
      end
    end)
  end

  defp claude_json_shape_failure(%{value: value}) when is_map(value), do: nil

  defp claude_json_shape_failure(_analysis),
    do: home_failure(14, "FX_JSON_SHAPE", "C-02", ".claude.json")

  defp sidecar_schema(%{value: value}, path) when is_map(value) do
    cond do
      MapSet.new(Map.keys(value)) != @sidecar_members ->
        {:error, home_failure(15, "FX_SIDECAR_SCHEMA", "C-04", path)}

      not sidecar_member_types?(value) ->
        {:error, home_failure(16, "FX_SIDECAR_SCHEMA", "C-04", path)}

      true ->
        {:ok, value}
    end
  end

  defp sidecar_schema(_analysis, path),
    do: {:error, home_failure(15, "FX_SIDECAR_SCHEMA", "C-04", path)}

  defp sidecar_member_types?(value) do
    is_integer(value["pid"]) and is_binary(value["sessionId"]) and
      is_binary(value["cwd"]) and is_integer(value["startedAt"]) and
      is_binary(value["procStart"]) and is_binary(value["version"]) and
      is_integer(value["peerProtocol"]) and is_binary(value["kind"]) and
      is_binary(value["entrypoint"]) and is_binary(value["name"]) and
      is_binary(value["nameSource"])
  end

  defp sidecar_semantic_failure(sidecar, value, expected_cwd) do
    [stem] = Regex.run(@sidecar_re, sidecar.raw_path, capture: :all_but_first)

    [
      {17, "C-03",
       is_integer(value["pid"]) and value["pid"] > 0 and Integer.to_string(value["pid"]) == stem},
      {18, "C-04", Regex.match?(@uuid_re, value["sessionId"])},
      {19, "C-04", value["cwd"] == expected_cwd},
      {20, "C-04", Regex.match?(@positive_decimal_re, value["procStart"])},
      {21, "C-04", Regex.match?(@semver_re, value["version"])},
      {22, "C-04", value["peerProtocol"] == 1},
      {23, "C-04", value["kind"] == "interactive"},
      {24, "C-04", value["entrypoint"] == "sdk-ts"},
      {25, "C-04", value["name"] != ""},
      {26, "C-04", value["nameSource"] == "derived"}
    ]
    |> Enum.find_value(fn {check, clause, passed?} ->
      unless passed?, do: home_failure(check, "FX_SIDECAR_SEMANTIC", clause, sidecar.raw_path)
    end)
  end

  defp freshness_failure(backup, sidecar_entry, sidecar, started, finished) do
    [epoch] = Regex.run(@backup_re, backup.raw_path, capture: :all_but_first)
    backup_epoch = String.to_integer(epoch)

    cond do
      backup_epoch < started or backup_epoch > finished ->
        home_failure(27, "FX_FRESHNESS", "C-05", backup.raw_path)

      sidecar["startedAt"] < started or sidecar["startedAt"] > finished ->
        home_failure(28, "FX_FRESHNESS", "C-05", sidecar_entry.raw_path)

      true ->
        nil
    end
  end

  defp sidecar_identity(value) do
    Map.take(value, ~w(pid sessionId cwd startedAt procStart))
  end

  defp identity_failure(_state, "pre-wake", _identity), do: nil

  defp identity_failure(state, "post-turn", identity) do
    if Map.get(state, :home_sidecar_identity) == identity,
      do: nil,
      else: home_failure(29, "FX_IDENTITY_DRIFT", "C-06", "sessions/#{identity["pid"]}.json")
  end

  defp first_path_failure(entries, fun) do
    entries
    |> Enum.sort_by(& &1.raw_path)
    |> Enum.find_value(fun)
  end

  defp runtime_case(state, harness, phase, entries, cwd, started, finished)
       when is_map(state) and is_list(entries) do
    runtime_failure(state, harness, phase, entries, cwd, started, finished)
    |> elem(0)
    |> candidate_code()
  end

  defp runtime_case(entries, state, harness, phase, cwd, started, finished)
       when is_list(entries) and is_map(state) do
    runtime_case(state, harness, phase, entries, cwd, started, finished)
  end

  defp runtime_case(entries, _state, harness, phase, cwd, started, finished, phase_state)
       when is_list(entries) and is_map(phase_state) do
    runtime_case(phase_state, harness, phase, entries, cwd, started, finished)
  end

  defp candidate_code(nil), do: :pass
  defp candidate_code(candidate), do: candidate.code

  defp synthetic_claude_entries(now, cwd) do
    sidecar = %{
      "pid" => 123,
      "sessionId" => "00000000-0000-0000-0000-000000000001",
      "cwd" => cwd,
      "startedAt" => now,
      "procStart" => "1",
      "version" => "2.1.232",
      "peerProtocol" => 1,
      "kind" => "interactive",
      "entrypoint" => "sdk-ts",
      "name" => "fixture",
      "nameSource" => "derived"
    }

    [
      synthetic_entry(".claude.json", :regular, 0o600, "{}"),
      synthetic_entry("backups", :directory, 0o755, nil),
      synthetic_entry("backups/.claude.json.backup.#{now}", :regular, 0o600, "{}"),
      synthetic_entry("sessions", :directory, 0o700, nil),
      synthetic_entry("sessions/123.json", :regular, 0o644, JSON.encode!(sidecar))
    ]
  end

  defp synthetic_entry(path, type, mode, nil) do
    %{
      raw_path: path,
      type: type,
      mode: mode,
      size: if(type == :regular, do: 1, else: nil),
      sha256: nil,
      bytes: nil
    }
  end

  defp synthetic_entry(path, type, mode, bytes) do
    %{
      raw_path: path,
      type: type,
      mode: mode,
      size: byte_size(bytes),
      sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
      bytes: bytes
    }
  end

  defp replace_entry(entries, path, fun) do
    Enum.map(entries, fn entry -> if entry.raw_path == path, do: fun.(entry), else: entry end)
  end

  defp rename_entry(entries, old, new) do
    replace_entry(entries, old, &%{&1 | raw_path: new})
  end

  defp replace_bytes(entries, path, bytes) do
    replace_entry(entries, path, fn entry ->
      if is_binary(bytes) do
        %{
          entry
          | bytes: bytes,
            size: byte_size(bytes),
            sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        }
      else
        %{entry | bytes: nil, sha256: nil}
      end
    end)
  end

  defp replace_json(entries, path, fun) do
    entry = Enum.find(entries, &(&1.raw_path == path))
    replace_bytes(entries, path, entry.bytes |> JSON.decode!() |> fun.() |> JSON.encode!())
  end

  defp repeated_first_failure(entries, cwd, now) do
    invalid =
      entries
      |> replace_entry(".claude.json", &%{&1 | mode: 0o644})
      |> replace_json("sessions/123.json", &Map.put(&1, "cwd", "/wrong"))

    1..3
    |> Enum.map(fn _ -> runtime_case(%{}, "claude", "pre-wake", invalid, cwd, now, now) end)
    |> Enum.uniq()
    |> case do
      [code] -> code
      _ -> :nondeterministic
    end
  end

  defp codex_runtime_scope_case(cwd, now) do
    delta_result =
      runtime_case(
        %{},
        "codex",
        "pre-wake",
        [synthetic_entry("plugin-cache", :regular, 0o600, "x")],
        cwd,
        now,
        now
      )

    if delta_result == "FX_CODEX_RUNTIME_PATH" and codex_clock_scope_case() == :pass,
      do: :pass,
      else: :failed
  end

  defp codex_clock_scope_case do
    with_case_dir(fn root ->
      path = Path.join(root, @home_evidence_name)
      reset_case_trace!()

      result =
        with_home_evidence!(
          root,
          fn evidence ->
            state = %{
              leg: %{wire_name: "codex"},
              evidence: %{evidence | sequence: 6, phase_index: 5}
            }

            try do
              validate_runtime_home!(
                state,
                root,
                MapSet.new([@home_evidence_name]),
                "agent:fixture",
                "/unused",
                System.system_time(:millisecond) + 60_000,
                "pre-wake"
              )
            catch
              {:home_case_refusal, refusal} -> refusal
            end
          end,
          home_ops(%{refusal: &case_refusal!/6})
        )

      record = path |> File.read!() |> String.trim() |> JSON.decode!()
      clock = Enum.at(record["checks"], 2)
      snapshot = Enum.at(record["checks"], 3)
      codex_delta = Enum.at(record["checks"], 6)

      if match?(%{evidence: %{sequence: 7, phase_index: 6}}, result) and
           record["result"] == "pass" and record["cause"] == "validated" and
           record["entries"] == [] and
           clock == %{
             "id" => "clock_order",
             "applicable" => false,
             "evaluated" => false,
             "passed" => nil
           } and snapshot["applicable"] and snapshot["evaluated"] and snapshot["passed"] and
           codex_delta["applicable"] and codex_delta["evaluated"] and codex_delta["passed"],
         do: :pass,
         else: :failed
    end)
  end

  defp full_evidence_file_case(entries) do
    with_passing_evidence(entries, fn path, bytes, records ->
      {:ok, info} = :file.read_link_info(path)
      lines = String.split(bytes, "\n", trim: true)

      canonical? =
        Enum.all?(lines, fn line ->
          Regex.match?(
            ~r/\A\{"schema":"tightbeam\.feature_smoke\.home_evidence\.v1","sequence":[1-7],"harness":"(?:all|claude|codex)","phase":"(?:run-start|pre-spawn|pre-wake|post-turn)","principal":"[^"]+","result":"pass","cause":"validated","entries":\[.*\],"checks":\[/,
            line
          )
        end)

      no_values? =
        Enum.all?(records, fn record ->
          Enum.all?(
            record["entries"],
            &(Map.keys(&1) |> Enum.sort() == ~w(mode path sha256 size type))
          )
        end) and not String.contains?(bytes, "/fixture/work/0123456789ab") and
          not String.contains?(bytes, "\"pid\":123")

      if file_info(info, :type) == :regular and
           Bitwise.band(file_info(info, :mode), 0o7777) == 0o600 and
           count_case({:created_mode, 0o600}) == 1 and
           length(lines) == 7 and String.ends_with?(bytes, "\n") and
           count_case(:write) == 7 and count_case(:sync) == 7 and
           Enum.map(records, & &1["sequence"]) == Enum.to_list(1..7) and
           Enum.all?(records, &(&1["cause"] == "validated")) and canonical? and no_values?,
         do: :pass,
         else: :failed
    end)
  end

  defp phase_matrix_case(entries) do
    with_passing_evidence(entries, fn _path, _bytes, records ->
      phases = Enum.map(records, &{&1["harness"], &1["phase"]})
      claude = Enum.filter(records, &(&1["harness"] == "claude"))
      codex = Enum.filter(records, &(&1["harness"] == "codex"))

      if phases == @home_phase_plan and
           Enum.map(claude, & &1["phase"]) == ["pre-spawn", "pre-wake", "post-turn"] and
           Enum.map(codex, & &1["phase"]) == ["pre-spawn", "pre-wake", "post-turn"] and
           Enum.all?(Enum.filter(claude, &(&1["phase"] != "pre-spawn")), fn record ->
             length(record["entries"]) == 5
           end) and Enum.all?(codex, &(&1["entries"] == [])),
         do: :pass,
         else: :failed
    end)
  end

  defp with_passing_evidence(entries, assertion) do
    with_case_dir(fn root ->
      path = Path.join(root, @home_evidence_name)
      reset_case_trace!()
      default_ops = home_ops()

      ops =
        home_ops(%{
          create_evidence: fn path ->
            case default_ops.create_evidence.(path) do
              :ok ->
                {:ok, info} = :file.read_link_info(path)
                trace_case({:created_mode, Bitwise.band(file_info(info, :mode), 0o7777)})
                :ok

              error ->
                error
            end
          end,
          write: fn io, data ->
            trace_case(:write)
            :file.write(io, data)
          end,
          sync: fn io ->
            trace_case(:sync)
            :file.sync(io)
          end
        })

      with_home_evidence!(
        root,
        fn evidence ->
          Enum.reduce(@home_phase_plan, evidence, fn {harness, phase}, current ->
            phase_entries =
              if harness == "claude" and phase in ["pre-wake", "post-turn"],
                do: entries,
                else: []

            principal =
              if phase in ["run-start", "pre-spawn"], do: phase, else: "agent:fixture"

            finish_home_phase!(current, harness, phase, principal, phase_entries, nil)
          end)
        end,
        ops
      )

      bytes = File.read!(path)
      records = bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      assertion.(path, bytes, records)
    end)
  end

  defp cleanup_refusal_case(entries, cwd, now) do
    with_case_dir(fn root ->
      marker = Path.join(root, "fixture-base-retained")
      File.write!(marker, "retained")
      reset_case_trace!()
      before = :erlang.term_to_binary(entries)
      invalid = replace_json(entries, "sessions/123.json", &Map.put(&1, "cwd", "/wrong"))
      {candidate, _identity} = runtime_failure(%{}, "claude", "pre-wake", invalid, cwd, now, now)

      ops =
        traced_evidence_ops(%{
          write: fn _io, _data ->
            trace_case(:write)
            :ok
          end
        })

      evidence = %{io: :case_io, sequence: 3, phase_index: 2, ops: ops}

      refusal =
        catch_case_refusal(fn ->
          with_required_cleanup(
            fn ->
              trace_case(:spawn)

              finish_home_phase!(
                evidence,
                "claude",
                "pre-wake",
                "agent:fixture",
                invalid,
                candidate
              )

              trace_case(:later_fixture)
            end,
            fn -> trace_case(:cleanup) end
          )
        end)

      if refusal.code == "FX_SIDECAR_SEMANTIC" and count_case(:spawn) == 1 and
           count_case(:cleanup) == 1 and count_case(:later_fixture) == 0 and
           File.read(marker) == {:ok, "retained"} and :erlang.term_to_binary(entries) == before,
         do: :pass,
         else: :failed
    end)
  end

  defp implementation_custody_case do
    repo = __ENV__.file |> Path.dirname() |> Path.expand("..")

    case System.cmd("git", ["diff", "--name-only", @implementation_base, "--"], cd: repo) do
      {paths, 0} ->
        if String.split(paths, "\n", trim: true) == ["scripts/feature_smoke.exs"],
          do: :pass,
          else: :failed

      _ ->
        :failed
    end
  end

  defp retained_blocker_case(entries, cwd, now) do
    invalid = entries ++ [synthetic_entry("new-runtime", :regular, 0o600, "{}")]
    {candidate, _identity} = runtime_failure(%{}, "claude", "pre-wake", invalid, cwd, now, now)
    reset_case_trace!()
    ops = traced_evidence_ops()
    evidence = %{io: :case_io, sequence: 3, phase_index: 2, ops: ops}

    refusal =
      catch_case_refusal(fn ->
        finish_home_phase!(evidence, "claude", "pre-wake", "agent:fixture", invalid, candidate)
        trace_case(:later_admission)
      end)

    if refusal == %{
         code: "FX_PATH_SET",
         harness: "claude",
         phase: "pre-wake",
         principal: "agent:fixture",
         path: "-",
         clause: "C-02"
       } and count_case(:write) == 1 and count_case(:sync) == 1 and
         count_case(:refusal) == 1 and count_case(:later_admission) == 0,
       do: :pass,
       else: :failed
  end

  defp contract_provenance_case do
    repo = __ENV__.file |> Path.dirname() |> Path.expand("..")
    {parent, assignment, facts} = @contract_provenance

    case System.cmd("git", ["merge-base", "--is-ancestor", parent, "HEAD"], cd: repo) do
      {_, 0}
      when assignment == "asg_17a50f66-c32d-42f2-aba5-dd39e072203e" and
             facts == [373, 384, 387, 390] ->
        :pass

      _ ->
        :failed
    end
  end

  defp wrong_cwd_retained_evidence_case(entries, cwd, now) do
    with_case_dir(fn root ->
      reset_case_trace!()
      invalid = replace_json(entries, "sessions/123.json", &Map.put(&1, "cwd", "/wrong"))
      {candidate, _identity} = runtime_failure(%{}, "claude", "pre-wake", invalid, cwd, now, now)
      ops = home_ops(%{refusal: &case_refusal!/6})

      refusal =
        catch_case_refusal(fn ->
          with_home_evidence!(
            root,
            fn evidence ->
              evidence = finish_home_phase!(evidence, "all", "run-start", "run-start", [], nil)
              evidence = finish_home_phase!(evidence, "claude", "pre-spawn", "pre-spawn", [], nil)

              finish_home_phase!(
                evidence,
                "claude",
                "pre-wake",
                "agent:fixture",
                invalid,
                candidate
              )

              trace_case(:later_phase)
            end,
            ops
          )
        end)

      path = Path.join(root, @home_evidence_name)
      lines = path |> File.read!() |> String.split("\n", trim: true)
      current = lines |> List.last() |> JSON.decode!()
      wrong = Enum.at(current["checks"], 18)
      later = Enum.at(current["checks"], 19)

      if refusal.clause == "C-04" and length(lines) == 3 and File.exists?(path) and
           current["result"] == "refused" and current["cause"] == "C-04" and
           wrong == %{
             "id" => "expected_cwd_equal",
             "applicable" => true,
             "evaluated" => true,
             "passed" => false
           } and later["evaluated"] == false and later["passed"] == nil and
           count_case(:later_phase) == 0,
         do: :pass,
         else: :failed
    end)
  end

  defp evidence_exclusive_create_case do
    outcomes = Enum.map([:regular, :fifo], &existing_evidence_path_case/1)
    if outcomes == [:pass, :pass], do: :pass, else: :failed
  end

  defp existing_evidence_path_case(kind) do
    with_case_dir(fn root ->
      path = Path.join(root, @home_evidence_name)

      case kind do
        :regular -> File.write!(path, "preexisting")
        :fifo -> {"", 0} = System.cmd("mkfifo", [path])
      end

      File.chmod!(path, 0o640)
      {:ok, before} = :file.read_link_info(path)
      outcome = bounded_existing_path_refusal(root)

      {:ok, after_info} = :file.read_link_info(path)

      occupant_unchanged? =
        case kind do
          :regular -> File.read(path) == {:ok, "preexisting"}
          :fifo -> file_info(before, :type) == :other and file_info(after_info, :type) == :other
        end

      case outcome do
        {:ok, refusal, trace} ->
          if refusal.code == "FX_EVIDENCE" and refusal.phase == "run-start" and
               occupant_unchanged? and
               regular_identity(before) == regular_identity(after_info) and
               file_info(before, :mode) == file_info(after_info, :mode) and
               Enum.count(trace, &(&1 == :run_start)) == 0 and
               Enum.count(trace, &(&1 == :refusal)) == 1,
             do: :pass,
             else: :failed

        _ ->
          :failed
      end
    end)
  end

  defp bounded_existing_path_refusal(root) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        reset_case_trace!()

        refusal =
          catch_case_refusal(fn ->
            with_home_evidence!(
              root,
              fn _evidence -> trace_case(:run_start) end,
              traced_evidence_ops()
            )
          end)

        send(parent, {ref, refusal, case_trace()})
      end)

    receive do
      {^ref, refusal, trace} ->
        Process.demonitor(monitor, [:flush])
        {:ok, refusal, trace}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, reason}
    after
      2_000 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :timeout
        end
    end
  end

  defp evidence_sink_failure_case do
    outcomes = Enum.map([:append, :sync], &one_evidence_sink_failure_case/1)
    if outcomes == [:pass, :pass], do: :pass, else: :failed
  end

  defp one_evidence_sink_failure_case(kind) do
    reset_case_trace!()

    overrides = %{
      write: fn _io, _data ->
        trace_case(:write)
        if kind == :append, do: {:error, :injected}, else: :ok
      end,
      sync: fn _io ->
        trace_case(:sync)
        if kind == :sync, do: {:error, :injected}, else: :ok
      end
    }

    evidence = %{io: :case_io, sequence: 3, phase_index: 2, ops: traced_evidence_ops(overrides)}

    refusal =
      catch_case_refusal(fn ->
        with_required_cleanup(
          fn ->
            finish_home_phase!(evidence, "claude", "pre-wake", "agent:fixture", [], nil)
            trace_case(:later_action)
          end,
          fn -> trace_case(:cleanup) end
        )
      end)

    expected_sync = if kind == :sync, do: 1, else: 0

    if refusal.code == "FX_EVIDENCE" and count_case(:write) == 1 and
         count_case(:sync) == expected_sync and count_case(:refusal) == 1 and
         count_case(:later_action) == 0 and count_case(:cleanup) == 1,
       do: :pass,
       else: :failed
  end

  defp repeated_path_set_case(entries, cwd, now) do
    results =
      Enum.map(1..3, fn _ ->
        runtime_failure(%{}, "claude", "pre-wake", entries, cwd, now, now) |> elem(0)
      end)

    if Enum.all?(results, &(&1 == home_failure(6, "FX_PATH_SET", "C-02", "-"))),
      do: :pass,
      else: :failed
  end

  defp injected_enumeration_failure_case do
    reset_case_trace!()

    ops =
      home_ops(%{
        list_dir: fn _path ->
          trace_case(:list_dir)
          {:error, :injected}
        end
      })

    case snapshot_home("/virtual", fn _ -> true end, ops) do
      {:error, "-", [], _finished_at} ->
        record = snapshot_failure_record("-", [])
        check = Enum.at(record["checks"], 3)

        if count_case(:list_dir) == 1 and record["result"] == "refused" and
             record["cause"] == "C-08" and check["evaluated"] and check["passed"] == false,
           do: :pass,
           else: :failed

      _ ->
        :failed
    end
  end

  defp injected_snapshot_failure_case(kind) do
    reset_case_trace!()
    target = if kind == :open, do: ".claude.json", else: "sessions/2.json"
    ops = injected_snapshot_ops(kind, target)

    case snapshot_home("/virtual", fn _ -> true end, ops) do
      {:error, ^target, entries, _finished_at} ->
        failed = Enum.find(entries, &(&1.raw_path == target))
        record = snapshot_failure_record(target, entries)
        snapshot_check = Enum.at(record["checks"], 3)
        later_check = Enum.at(record["checks"], 4)
        expected_hash = if kind == :final_identity, do: sha256("{}"), else: nil

        operation_shape? =
          case kind do
            :lstat ->
              count_case({:lstat, target}) == 1 and count_case(:open) == 0 and
                count_case(:read) == 0

            :open ->
              count_case({:lstat, target}) == 1 and count_case(:open) == 1 and
                count_case(:read) == 0 and count_case(:close) == 0

            :read ->
              count_case({:lstat, target}) == 1 and count_case(:open) == 1 and
                count_case(:read) == 1 and count_case(:close) == 1

            :opened_type ->
              count_case({:lstat, target}) == 1 and count_case(:open) == 1 and
                count_case(:read_info) == 1 and count_case(:read) == 0 and
                count_case(:close) == 1

            :opened_identity ->
              count_case({:lstat, target}) == 1 and count_case(:open) == 1 and
                count_case(:read_info) == 1 and count_case(:read) == 0 and
                count_case(:close) == 1

            :final_identity ->
              count_case(:open) == 1 and count_case(:read) == 2 and
                count_case({:lstat, target}) == 2 and count_case(:close) == 1
          end

        metadata_shape? =
          if kind == :lstat,
            do: Enum.all?([failed.type, failed.mode, failed.size, failed.sha256], &is_nil/1),
            else:
              failed.type == :regular and
                failed.mode == if(target == ".claude.json", do: 0o600, else: 0o644) and
                failed.size == 2 and failed.sha256 == expected_hash

        if operation_shape? and metadata_shape? and record["result"] == "refused" and
             record["cause"] == "C-08" and snapshot_check["evaluated"] and
             snapshot_check["passed"] == false and later_check["evaluated"] == false,
           do: :pass,
           else: :failed

      _ ->
        :failed
    end
  end

  defp injected_snapshot_ops(kind, target) do
    initial =
      case_file_info(:regular, if(target == ".claude.json", do: 0o600, else: 0o644), 2, 10)

    opened =
      if kind == :opened_identity, do: case_file_info(:regular, 0o644, 2, 11), else: initial

    home_ops(%{
      list_dir: fn path ->
        trace_case(:list_dir)

        case path do
          "/virtual" when target == ".claude.json" -> {:ok, [~c".claude.json"]}
          "/virtual" -> {:ok, [~c"sessions"]}
          "/virtual/sessions" -> {:ok, [~c"2.json"]}
        end
      end,
      lstat: fn path ->
        trace_case({:lstat, path |> Path.relative_to("/virtual")})

        cond do
          path == "/virtual/sessions" ->
            {:ok, case_file_info(:directory, 0o700, 0, 5)}

          kind == :lstat ->
            {:error, :injected}

          kind == :final_identity and count_case({:lstat, target}) == 2 ->
            {:ok, case_file_info(:symlink, 0o777, 2, 12)}

          true ->
            {:ok, initial}
        end
      end,
      open_read: fn _path ->
        trace_case(:open)
        if kind == :open, do: {:error, :injected}, else: {:ok, :case_io}
      end,
      read_info: fn _io ->
        trace_case(:read_info)

        if kind == :opened_type,
          do: {:ok, case_file_info(:directory, 0o700, 0, 10)},
          else: {:ok, opened}
      end,
      read: fn _io, _size ->
        calls = count_case(:read)
        trace_case(:read)

        cond do
          kind == :read -> {:error, :injected}
          kind == :final_identity and calls == 0 -> {:ok, "{}"}
          kind == :final_identity -> :eof
          true -> {:error, :unexpected_read}
        end
      end,
      close: fn _io ->
        trace_case(:close)
        :ok
      end
    })
  end

  defp snapshot_failure_record(path, entries) do
    home_evidence_record(
      %{sequence: 3},
      "claude",
      "pre-wake",
      "agent:fixture",
      entries,
      home_failure(4, "FX_SNAPSHOT", "C-08", path)
    )
    |> IO.iodata_to_binary()
    |> JSON.decode!()
  end

  defp case_file_info(type, mode, size, inode) do
    file_info(
      type: type,
      mode: mode,
      size: size,
      major_device: 1,
      minor_device: 2,
      inode: inode
    )
  end

  defp traced_evidence_ops(overrides \\ %{}) do
    %{
      write: fn _io, _data ->
        trace_case(:write)
        :ok
      end,
      sync: fn _io ->
        trace_case(:sync)
        :ok
      end
    }
    |> Map.merge(overrides)
    |> Map.put(:refusal, &case_refusal!/6)
    |> home_ops()
  end

  defp case_refusal!(code, harness, phase, principal, path, clause) do
    trace_case(:refusal)

    throw(
      {:home_case_refusal,
       %{
         code: code,
         harness: harness,
         phase: phase,
         principal: principal,
         path: path,
         clause: clause
       }}
    )
  end

  defp catch_case_refusal(fun) do
    try do
      fun.()
      :no_refusal
    catch
      {:home_case_refusal, refusal} -> refusal
    end
  end

  defp reset_case_trace!, do: Process.put(:feature_smoke_home_case_trace, [])

  defp trace_case(event) do
    Process.put(:feature_smoke_home_case_trace, [event | case_trace()])
    :ok
  end

  defp case_trace, do: Process.get(:feature_smoke_home_case_trace, [])
  defp count_case(event), do: Enum.count(case_trace(), &(&1 == event))

  defp with_case_dir(fun) do
    root =
      Path.join(System.tmp_dir!(), "tightbeam-home-case-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp snapshot_walk_case do
    root =
      Path.join(System.tmp_dir!(), "tightbeam-home-case-#{System.unique_integer([:positive])}")

    raw_path = :filename.join(root, <<255>>)

    File.mkdir_p!(Path.join(root, "sessions"))
    File.write!(Path.join(root, ".claude.json"), "{}")
    File.write!(Path.join(root, "sessions/123.json"), "{\"pid\":123}")
    :ok = :file.write_file(raw_path, "{}")

    try do
      case snapshot_home(root, fn relative -> String.ends_with?(relative, ".json") end) do
        {:ok, entries, _finished_at} ->
          paths = Enum.map(entries, & &1.raw_path)

          if paths == [".claude.json", "sessions", "sessions/123.json", <<255>>] and
               evidence_token(List.last(paths)) == "%FF" and
               Enum.find(entries, &(&1.raw_path == <<255>>)).type == :regular and
               entries
               |> Enum.filter(&(&1.type == :regular and &1.raw_path != <<255>>))
               |> Enum.all?(&is_binary(&1.sha256)),
             do: :pass,
             else: :failed

        _ ->
          :failed
      end
    after
      :file.delete(raw_path)
      File.rm_rf!(root)
    end
  end

  defp baseline_ancestors(expected_home) do
    expected_home
    |> Enum.flat_map(fn relative ->
      relative
      |> :filename.split()
      |> Enum.drop(-1)
      |> Enum.scan(fn part, prefix -> prefix <> "/" <> part end)
    end)
    |> MapSet.new()
  end

  defp partial_phase_entries(entries, expected_home, ancestors, failed_path) do
    runtime =
      Enum.filter(entries, fn entry ->
        not MapSet.member?(expected_home, entry.raw_path) and
          not MapSet.member?(ancestors, entry.raw_path)
      end)

    case Enum.find(entries, &(&1.raw_path == failed_path)) do
      nil ->
        runtime

      failed ->
        if Enum.any?(runtime, &(&1.raw_path == failed_path)),
          do: runtime,
          else: runtime ++ [failed]
    end
  end

  defp partial_pre_spawn_entries(entries, ancestors, failed_path) do
    visible = Enum.reject(entries, &MapSet.member?(ancestors, &1.raw_path))

    case Enum.find(entries, &(&1.raw_path == failed_path)) do
      nil ->
        visible

      failed ->
        if Enum.any?(visible, &(&1.raw_path == failed_path)),
          do: visible,
          else: visible ++ [failed]
    end
  end

  defp snapshot_home(home, capture?) do
    snapshot_home(home, capture?, home_ops())
  end

  defp snapshot_home(home, capture?, ops) do
    result = walk_home(home, "", capture?, [], ops)
    finished_at = System.system_time(:millisecond)

    case result do
      {:ok, entries} -> {:ok, entries, finished_at}
      {:error, path, entries} -> {:error, path, entries, finished_at}
    end
  end

  defp walk_home(path, relative, capture?, entries, ops) do
    case ops.list_dir.(path) do
      {:ok, names} ->
        names
        |> Enum.map(&raw_filename/1)
        |> Enum.sort()
        |> Enum.reduce_while({:ok, entries}, fn name, {:ok, acc} ->
          child = :filename.join(path, name)
          child_relative = if relative == "", do: name, else: relative <> "/" <> name

          case inspect_home_entry(child, child_relative, capture?, ops) do
            {:ok, entry} when entry.type == :directory ->
              case walk_home(child, child_relative, capture?, acc ++ [entry], ops) do
                {:ok, nested} -> {:cont, {:ok, nested}}
                {:error, failed, partial} -> {:halt, {:error, failed, partial}}
              end

            {:ok, entry} ->
              {:cont, {:ok, acc ++ [entry]}}

            {:error, entry} ->
              {:halt, {:error, child_relative, acc ++ [entry]}}
          end
        end)

      {:error, _reason} when relative == "" ->
        {:error, "-", entries}

      {:error, _reason} ->
        {:error, relative, entries}
    end
  end

  defp raw_filename(name) when is_binary(name), do: name
  defp raw_filename(name) when is_list(name), do: :unicode.characters_to_binary(name)

  defp home_ops do
    %{
      create_evidence: &create_evidence_file/1,
      open_evidence: fn path -> :file.open(path, [:read, :write, :binary, :raw]) end,
      list_dir: &:file.list_dir_all/1,
      lstat: &:file.read_link_info/1,
      open_read: fn path -> :file.open(path, [:read, :binary, :raw]) end,
      read_info: &:file.read_file_info/1,
      read: &:file.read/2,
      write: &:file.write/2,
      sync: &:file.sync/1,
      close: &:file.close/1
    }
  end

  defp create_evidence_file(path) do
    try do
      case System.cmd(
             "node",
             [
               "-e",
               ~S'const fs=require("fs"); const fd=fs.openSync(process.argv[1], "wx", 0o600); fs.closeSync(fd);',
               path
             ],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {_output, _status} -> {:error, :create_failed}
      end
    rescue
      ErlangError -> {:error, :create_failed}
    end
  end

  defp home_ops(overrides), do: Map.merge(home_ops(), overrides)

  defp inspect_home_entry(path, relative, capture?, ops) do
    case ops.lstat.(path) do
      {:ok, info} ->
        entry = home_entry(relative, info)

        if entry.type == :regular and capture?.(relative) do
          capture_home_file(path, entry, info, ops)
        else
          {:ok, entry}
        end

      {:error, _reason} ->
        {:error, %{raw_path: relative, type: nil, mode: nil, size: nil, sha256: nil, bytes: nil}}
    end
  end

  defp home_entry(relative, info) do
    type =
      case file_info(info, :type) do
        :directory -> :directory
        :regular -> :regular
        :symlink -> :symlink
        _ -> :other
      end

    %{
      raw_path: relative,
      type: type,
      mode: Bitwise.band(file_info(info, :mode), 0o7777),
      size: if(type == :regular, do: file_info(info, :size), else: nil),
      sha256: nil,
      bytes: nil
    }
  end

  defp capture_home_file(path, entry, initial_info, ops) do
    case ops.open_read.(path) do
      {:ok, io} ->
        try do
          with {:ok, opened_info} <- ops.read_info.(io),
               true <- file_info(opened_info, :type) == :regular,
               {:ok, initial_identity} <- regular_identity(initial_info),
               {:ok, ^initial_identity} <- regular_identity(opened_info) do
            case read_home_file(io, [], ops) do
              {:ok, bytes} ->
                captured = %{
                  entry
                  | size: byte_size(bytes),
                    sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
                    bytes: bytes
                }

                with {:ok, final_info} <- ops.lstat.(path),
                     true <- file_info(final_info, :type) == :regular,
                     {:ok, ^initial_identity} <- regular_identity(final_info) do
                  {:ok, captured}
                else
                  _ -> {:error, captured}
                end

              {:error, _reason} ->
                {:error, entry}
            end
          else
            _ -> {:error, entry}
          end
        after
          ops.close.(io)
        end

      {:error, _reason} ->
        {:error, entry}
    end
  end

  defp read_home_file(io, acc, ops) do
    case ops.read.(io, 65_536) do
      {:ok, bytes} -> read_home_file(io, [bytes | acc], ops)
      :eof -> {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, _reason} -> {:error, :read}
    end
  end

  defp regular_identity(info) do
    identity =
      {file_info(info, :major_device), file_info(info, :minor_device), file_info(info, :inode)}

    if identity |> Tuple.to_list() |> Enum.all?(&is_integer/1),
      do: {:ok, identity},
      else: {:error, :identity}
  end

  defp json_analysis(nil), do: %{utf8: false, syntax: false, unique: false, value: nil}

  defp json_analysis(bytes) do
    if String.valid?(bytes) do
      decoders = [
        object_start: fn _old -> [] end,
        object_push: fn key, value, acc -> [{key, value} | acc] end,
        object_finish: fn acc, old -> {{:json_object, Enum.reverse(acc)}, old} end
      ]

      case JSON.decode(bytes, nil, decoders) do
        {value, nil, rest} ->
          if String.trim(rest) == "" do
            case normalize_json(value) do
              {:ok, normalized} -> %{utf8: true, syntax: true, unique: true, value: normalized}
              :duplicate -> %{utf8: true, syntax: true, unique: false, value: nil}
            end
          else
            %{utf8: true, syntax: false, unique: false, value: nil}
          end

        {:error, _reason} ->
          %{utf8: true, syntax: false, unique: false, value: nil}
      end
    else
      %{utf8: false, syntax: false, unique: false, value: nil}
    end
  end

  defp normalize_json({:json_object, pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case normalize_json(value) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
          :duplicate -> {:halt, :duplicate}
        end
      end)
    else
      :duplicate
    end
  end

  defp normalize_json(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_json(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :duplicate -> {:halt, :duplicate}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :duplicate -> :duplicate
    end
  end

  defp normalize_json(value), do: {:ok, value}

  defp home_failure(check, code, clause, path) do
    %{check: check, code: code, clause: clause, path: path}
  end

  defp finish_home_phase!(evidence, harness, phase, principal, entries, candidate) do
    record = home_evidence_record(evidence, harness, phase, principal, entries, candidate)

    case evidence.ops.write.(evidence.io, [record, "\n"]) do
      :ok ->
        case evidence.ops.sync.(evidence.io) do
          :ok ->
            next = %{
              evidence
              | sequence: evidence.sequence + 1,
                phase_index: evidence.phase_index + 1
            }

            if candidate do
              emit_refusal!(
                evidence.ops,
                candidate.code,
                harness,
                phase,
                principal,
                candidate.path,
                candidate.clause
              )
            end

            next

          {:error, _reason} ->
            emit_evidence_refusal!(evidence.ops, harness, phase, principal)
        end

      {:error, _reason} ->
        emit_evidence_refusal!(evidence.ops, harness, phase, principal)
    end
  end

  defp home_evidence_record(evidence, harness, phase, principal, entries, candidate) do
    fields = [
      {"schema", @home_evidence_schema},
      {"sequence", evidence.sequence},
      {"harness", harness},
      {"phase", phase},
      {"principal", evidence_token(principal)},
      {"result", if(candidate, do: "refused", else: "pass")},
      {"cause", if(candidate, do: candidate.clause, else: "validated")},
      {"entries", {:entries, Enum.sort_by(entries, & &1.raw_path)}},
      {"checks", {:checks, home_checks(harness, phase, candidate)}}
    ]

    encode_ordered_object(fields)
  end

  defp home_checks(harness, phase, candidate) do
    applicable = applicable_home_checks(harness, phase)

    Enum.with_index(@home_check_ids, 1)
    |> Enum.map(fn {id, index} ->
      applies? = MapSet.member?(applicable, index)

      {evaluated?, passed} =
        cond do
          not applies? -> {false, nil}
          is_nil(candidate) -> {true, true}
          index < candidate.check -> {true, true}
          index == candidate.check -> {true, false}
          true -> {false, nil}
        end

      %{id: id, applicable: applies?, evaluated: evaluated?, passed: passed}
    end)
  end

  defp applicable_home_checks(_harness, "run-start"), do: MapSet.new(1..2)
  defp applicable_home_checks(_harness, "pre-spawn"), do: MapSet.new([1, 4, 5])

  defp applicable_home_checks("codex", phase) when phase in ["pre-wake", "post-turn"],
    do: MapSet.new([1, 4, 7])

  defp applicable_home_checks("claude", "pre-wake"),
    do: MapSet.new([1, 3, 4] ++ Enum.to_list(6..28))

  defp applicable_home_checks("claude", "post-turn"),
    do: MapSet.new([1, 3, 4] ++ Enum.to_list(6..29))

  defp encode_ordered_object(fields) do
    [
      "{",
      fields
      |> Enum.map(fn {key, value} ->
        [JSON.encode_to_iodata!(key), ":", encode_home_value(value)]
      end)
      |> Enum.intersperse(","),
      "}"
    ]
  end

  defp encode_home_value({:entries, entries}) do
    ["[", entries |> Enum.map(&encode_home_entry/1) |> Enum.intersperse(","), "]"]
  end

  defp encode_home_value({:checks, checks}) do
    ["[", checks |> Enum.map(&encode_home_check/1) |> Enum.intersperse(","), "]"]
  end

  defp encode_home_value(value), do: JSON.encode_to_iodata!(value)

  defp encode_home_entry(entry) do
    encode_ordered_object([
      {"path", evidence_token(entry.raw_path)},
      {"type", if(entry.type, do: Atom.to_string(entry.type), else: nil)},
      {"mode",
       if(entry.mode,
         do: entry.mode |> Integer.to_string(8) |> String.pad_leading(4, "0"),
         else: nil
       )},
      {"size", entry.size},
      {"sha256", entry.sha256}
    ])
  end

  defp encode_home_check(check) do
    encode_ordered_object([
      {"id", check.id},
      {"applicable", check.applicable},
      {"evaluated", check.evaluated},
      {"passed", check.passed}
    ])
  end

  defp evidence_token("-"), do: "-"

  defp evidence_token(bytes) do
    for <<byte <- bytes>>, into: "" do
      if byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in ~c"._/-" do
        <<byte>>
      else
        "%" <> Base.encode16(<<byte>>)
      end
    end
  end

  defp emit_evidence_refusal!(ops, harness, phase, principal) do
    emit_refusal!(
      ops,
      "FX_EVIDENCE",
      harness,
      phase,
      principal,
      @home_evidence_name,
      "C-10"
    )
  end

  defp emit_refusal!(ops, code, harness, phase, principal, path, clause) do
    case Map.get(ops, :refusal) do
      nil -> refusal_line!(code, harness, phase, principal, path, clause)
      refusal -> refusal.(code, harness, phase, principal, path, clause)
    end
  end

  defp refusal_line!(code, harness, phase, principal, path, clause) do
    IO.puts(
      "feature-smoke fixture HOME REFUSED code=#{code} harness=#{harness} phase=#{phase} " <>
        "principal=#{evidence_token(principal)} path=#{evidence_token(path)} clause=#{clause}"
    )

    raise Failure, message: "fixture HOME refused #{code} at #{phase}"
  end

  defp with_required_cleanup(body, cleanup) do
    try do
      body.()
    after
      cleanup.()
    end
  end

  defp install_smoke_rule!(base_dir) do
    source = Path.expand("fixtures/smoke-escalation-probe.toml", __DIR__)
    target = Path.join([base_dir, "identity", "rules", "smoke-escalation-probe.toml"])
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source, target)

    # rules/ lives inside the identity repo, and the identity seam requires a clean
    # working tree. An uncommitted fixture wedges every identity verb, so commit it.
    dir = Path.join(base_dir, "identity")
    smoke_git!(dir, ["add", "--", "rules/smoke-escalation-probe.toml"])

    # `--quiet` reports "nothing staged" as exit 0, so this one reads the status rather
    # than demanding success: a second run of the smoke has nothing to commit.
    case System.cmd("git", ["diff", "--cached", "--quiet"], cd: dir) do
      {_, 0} ->
        :ok

      _ ->
        smoke_git!(dir, ["commit", "-m", "feature-smoke: escalation probe"])
        publish_identity_live!(dir)
    end
  end

  # Advance the identity repo's live ref onto the commit just made.
  #
  # ROADMAP 0a3: `Identity.publish_live!/1` is private and no verb exposes it, so anything
  # that commits to the identity repo from OUTSIDE the Identity module — which is exactly
  # what installing this fixture does — leaves `tightbeam/live` behind `main`. Delete this
  # and call the verb the day one exists.
  #
  # WHAT THE STALENESS DOES AND DOES NOT BREAK, measured on a scratch identity repo rather
  # than reasoned about. Statutes are unaffected: `Rules.load!` globs the WORKING TREE, so
  # the probe arms at boot whatever live says, and the sha it stamps comes from HEAD so it
  # stays consistent with the tree it read. Archetype snapshots are unaffected because
  # rules are not part of one. And `identity-edit` calls `publish_live!` itself, so the
  # identity group heals this partway through a run that gets that far.
  #
  # What is left is a window — and, for a run that stops before that group, a durable
  # state — in which the org's published revision does not contain org law the org is
  # already enforcing. No assertion trips over it today. It is still not a state to walk
  # away from an operator's org in.
  #
  # Same shape as `publish_live!`: refuse rather than force when live cannot fast-forward,
  # and use update-ref's compare-and-swap so a concurrent publisher loses the race
  # visibly instead of being silently overwritten.
  defp publish_identity_live!(dir) do
    live = smoke_git!(dir, ["rev-parse", "tightbeam/live"])
    main = smoke_git!(dir, ["rev-parse", "main"])

    case System.cmd("git", ["merge-base", "--is-ancestor", live, main], cd: dir) do
      {_out, 0} ->
        smoke_git!(dir, ["update-ref", "refs/heads/tightbeam/live", main, live])

      _ ->
        raise Failure,
          message:
            "identity tightbeam/live (#{live}) cannot fast-forward to main (#{main}) in #{dir}"
    end
  end

  # A run-scoped committer identity for the fixture commit, and a failure that names
  # itself.
  #
  # `git commit` refuses outright on a host where the smoke user has no committer
  # identity, and the bare `{_, 0} = System.cmd(...)` this replaces turned that refusal
  # into a MatchError naming neither the command nor the reason. Supplying the identity in
  # the call's own env is what `Tightbeam.Identity.git!/3` already does for every commit
  # the substrate makes, and it keeps the identity scoped to this one commit: no global
  # identity is required or selected, and the org's own git config is not rewritten by the
  # act of smoking it.
  #
  # The address follows `Identity.git_env/1`'s own derivation rather than being chosen
  # freely — it sanitizes the name into the local part, so the name below yields exactly
  # this address. Matching it keeps the two producers of tightbeam commits indistinguishable
  # in the log.
  @smoke_git_env [
    {"GIT_AUTHOR_NAME", "tightbeam feature-smoke"},
    {"GIT_AUTHOR_EMAIL", "tightbeam-feature-smoke@tightbeam.local"},
    {"GIT_COMMITTER_NAME", "tightbeam feature-smoke"},
    {"GIT_COMMITTER_EMAIL", "tightbeam-feature-smoke@tightbeam.local"}
  ]

  defp smoke_git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: @smoke_git_env) do
      {out, 0} ->
        String.trim(out)

      {out, status} ->
        raise Failure,
          message: "git #{Enum.join(args, " ")} failed (#{status}) in #{dir}: #{String.trim(out)}"
    end
  end

  # --- served identity: every public seam shape --------------------------------
  defp check_identity_surface(state) do
    status = ok!(state, "identity-status", %{"archetype" => "default"})
    assert(state, is_binary(status["liveRevision"]), "identity-status returned no live revision")
    assert(state, is_map(status["guidance"]), "identity-status returned no composed guidance")

    guidance_path = Path.join([state.base_dir, "identity", "guidance", "default.md"])
    original_guidance = File.read!(guidance_path)
    marker = "\n\nfeature-smoke #{unique()}\n"

    ok!(state, "identity-edit", %{
      "archetype" => "default",
      "manifest" => false,
      "remove" => false,
      "content" => original_guidance <> marker
    })

    ok!(state, "identity-edit", %{
      "archetype" => "default",
      "manifest" => false,
      "remove" => false,
      "content" => original_guidance
    })

    manifest_path = Path.join([state.base_dir, "identity", "archetypes", "default.toml"])
    original_manifest = File.read!(manifest_path)

    ok!(state, "identity-edit", %{
      "archetype" => "default",
      "manifest" => true,
      "remove" => false,
      "content" => original_manifest <> "\n# feature-smoke #{unique()}\n"
    })

    ok!(state, "identity-edit", %{
      "archetype" => "default",
      "manifest" => true,
      "remove" => false,
      "content" => original_manifest
    })

    skill = "feature-smoke-#{unique()}"

    ok!(state, "identity-edit", %{
      "archetype" => "default",
      "manifest" => false,
      "skill" => skill,
      "remove" => false,
      "content" => "# #{skill}\n"
    })

    ok!(state, "identity-edit", %{
      "archetype" => "default",
      "manifest" => false,
      "skill" => skill,
      "remove" => true
    })

    relearn = ok!(state, "identity-relearn", %{})

    assert(
      state,
      relearn["state"] in ["published", "relearn-conflicted"],
      "identity-relearn returned #{inspect(relearn)}"
    )

    session =
      ok!(state, "spawn", %{
        "displayName" => "smoke-identity-#{unique()}",
        "idempotencyKey" => "identity-#{unique()}"
      })

    session_key = get_in(session, ["stream", "sessionKey"]) || session["sessionKey"]
    applied = ok!(state, "identity-apply", %{"sessionKey" => session_key, "all" => false})
    assert(state, session_key in (applied["applied"] || []), "identity-apply missed its session")
    _all = ok!(state, "identity-apply", %{"all" => true})
    retire(state, session)

    pass(
      state,
      "identity status/edit guidance/edit manifest/skill put+rm/relearn/apply session+all"
    )
  end

  # Exercise the public entry without beginning a credential mutation. The
  # phase-less request must direct the operator to the interactive CLI.
  defp check_onboard_surface(state) do
    for provider <- state.providers do
      # interactive_required is delivered as a wire ERROR envelope, so assert on it
      # directly rather than through ok! (which treats any error as a smoke failure).
      result = post(state, "onboard", %{"provider" => provider})

      assert(
        state,
        get_in(result, ["error", "code"]) == "interactive_required",
        "onboard #{provider} did not direct to the interactive CLI: #{inspect(result)}"
      )
    end

    pass(state, "onboard registered providers interactive entry")
  end

  # --- #3 escalation: a gated verb escalates to the owner for a decision --------
  # Requires the `surrender-escalates-to-owner` rail. Proves the escalate effect live:
  # attest surrender → decision-request opened to the owner → owner rules allow → proceeds.
  defp check_escalation_to_owner(state) do
    u = unique()
    wi = ok!(state, "work-item-create", %{"title" => "esc #{u}", "idempotencyKey" => "ewi-#{u}"})
    wi_id = wi["workItemId"] || wi["id"]

    coder =
      ok!(state, "spawn", %{
        "displayName" => "smoke-esc-coder-#{u}",
        "idempotencyKey" => "ec-#{u}"
      })

    coder_key = get_in(coder, ["stream", "sessionKey"]) || coder["sessionKey"]
    post(state, "role-create", %{"name" => "coder-esc-#{u}"})
    ok!(state, "role-bind", %{"name" => "coder-esc-#{u}", "sessionKey" => coder_key})
    coder_tok = session_token(state, coder_key)

    asg =
      ok!(state, "assign", %{
        "sessionKey" => coder_key,
        "subject" => "esc impl #{u}",
        "workItemId" => wi_id,
        "idempotencyKey" => "ea-#{u}"
      })

    asg_id = asg["id"] || asg["assignmentId"]

    # 1. Coder attests surrender → escalates (does NOT proceed; a decision-request opens).
    _esc = post_as(state, coder_tok, "attest", %{"assignmentId" => asg_id, "kind" => "surrender"})

    # 2. The owner sees an open decision-request for this escalation.
    drs = ok!(state, "decision-requests", %{})

    dr =
      (drs["requests"] || drs["decisionRequests"] || drs)
      |> List.wrap()
      |> Enum.find(fn d ->
        (d["statute"] || d["statuteName"]) == "surrender-escalates-to-owner" or
          (d["ref"] || d["subject"] || "") =~ asg_id
      end)

    assert(
      state,
      is_map(dr),
      "escalation: no decision-request opened for the surrender; got #{inspect(drs)}"
    )

    dr_id = dr["id"] || dr["requestId"] || dr["decisionRequestId"]

    # 3. Owner rules allow.
    ok!(state, "rule", %{"requestId" => dr_id, "decision" => "allow", "rationale" => "smoke ok"})

    # 4. Coder re-attests surrender → the ruling is consumed → the verb proceeds.
    done = post_as(state, coder_tok, "attest", %{"assignmentId" => asg_id, "kind" => "surrender"})

    assert(
      state,
      not (is_map(done) and Map.has_key?(done, "error")),
      "escalation: surrender after the owner's allow should proceed, got #{inspect(done)}"
    )

    retire(state, coder)

    pass(
      state,
      "escalation to owner: surrender → decision-request → owner rules allow → proceeds"
    )
  end

  # --- P7 flagship enforced loop: completion requires an independent review ---
  # Proves the whole enforcement spine live over HTTP with two fresh sessions on this
  # same selected harness: a coder attesting completion WITHOUT a reviewed-clean verdict
  # triggers the remedy, which assigns a reviewer and blocks completion; the gate
  # self-releases once the linked review-holder verdict lands.
  # Requires the `completion-requires-review` rail loaded (identity/rules/engineering.toml).
  defp check_flagship_review_loop(state) do
    u = unique()
    # A reviewer role bound to a live reviewer session (the remedy's assign target).
    post(state, "role-create", %{"name" => "reviewer"})

    reviewer =
      ok!(state, "spawn", %{"displayName" => "smoke-reviewer-#{u}", "idempotencyKey" => "rv-#{u}"})

    reviewer_key = get_in(reviewer, ["stream", "sessionKey"]) || reviewer["sessionKey"]
    ok!(state, "role-bind", %{"name" => "reviewer", "sessionKey" => reviewer_key})
    reviewer_tok = session_token(state, reviewer_key)

    # A coder holding a work assignment.
    wi =
      ok!(state, "work-item-create", %{"title" => "flagship #{u}", "idempotencyKey" => "fwi-#{u}"})

    wi_id = wi["workItemId"] || wi["id"]

    coder =
      ok!(state, "spawn", %{"displayName" => "smoke-coder-#{u}", "idempotencyKey" => "cd-#{u}"})

    coder_key = get_in(coder, ["stream", "sessionKey"]) || coder["sessionKey"]

    assert(
      state,
      coder_key != reviewer_key,
      "flagship: producer and reviewer must be different sessions"
    )

    # A session needs a role bound to act (attest) under its own credential.
    post(state, "role-create", %{"name" => "coder-#{u}"})
    ok!(state, "role-bind", %{"name" => "coder-#{u}", "sessionKey" => coder_key})
    coder_tok = session_token(state, coder_key)

    asg =
      ok!(state, "assign", %{
        "sessionKey" => coder_key,
        "subject" => "impl #{u}",
        "workItemId" => wi_id,
        "idempotencyKey" => "fa-#{u}"
      })

    asg_id = asg["id"] || asg["assignmentId"]

    # 1. Coder attests completion with NO review on record → BLOCKED by the rule.
    # (The wire exposes only code+message; a remedy and a plain deny both carry
    # code=rule_denied — the remedy's `reason=remedy_fired` is stripped. Proof that
    # it was a REMEDY, not a bare deny, is step 2: the reviewer gets assigned.)
    blocked =
      post_as(state, coder_tok, "attest", %{"assignmentId" => asg_id, "kind" => "completion"})

    assert(
      state,
      get_in(blocked, ["error", "rule"]) == "completion-requires-review" or
        (get_in(blocked, ["error", "message"]) || "") =~ "completion-requires-review",
      "flagship: completion without review should be blocked by the rule, got #{inspect(blocked)}"
    )

    # 2. The remedy assigned the reviewer a review of the coder's assignment.
    reviews = ok!(state, "assignments", %{"sessionKey" => reviewer_key})

    review_asg =
      (reviews["assignments"] || reviews)
      |> List.wrap()
      |> Enum.find(fn a -> (a["reviewsAssignmentId"] || a["reviews"]) == asg_id end)

    assert(
      state,
      is_map(review_asg),
      "flagship: remedy did not assign the reviewer a review of #{asg_id}; got #{inspect(reviews)}"
    )

    review_id = review_asg["id"] || review_asg["assignmentId"]

    # 3. Reviewer files the reviewed-clean verdict on the review assignment.
    v =
      post_as(state, reviewer_tok, "attest", %{
        "assignmentId" => review_id,
        "kind" => "verdict",
        "verdictKind" => "reviewed-clean"
      })

    assert(
      state,
      not (is_map(v) and Map.has_key?(v, "error")),
      "flagship: reviewer verdict failed: #{inspect(v)}"
    )

    # 4. Coder re-attests completion → the verdict is present → the gate passes.
    done =
      post_as(state, coder_tok, "attest", %{"assignmentId" => asg_id, "kind" => "completion"})

    assert(
      state,
      not (is_map(done) and Map.has_key?(done, "error")),
      "flagship: completion after review should PASS the gate, got #{inspect(done)}"
    )

    retire(state, reviewer)
    retire(state, coder)

    pass(
      state,
      "flagship reviewer-loop enforced end-to-end on same harness with different sessions: blocked → reviewer assigned → verdict → completes"
    )
  end

  # --- T2a: the gate chain, enforced -------------------------------------------------
  # artifact-carrier-proposal-v1 §7.3, first of two halves.
  #
  # OPERATOR-DRIVEN END TO END, and that is the design rather than a shortcut. Every step
  # here is an HTTP call, so no model turn has to RUN for any of it. A remedy wake still
  # materializes a queued turn — that is unavoidable and expected — but nothing starts it
  # inside the window this group occupies, and the group proves that rather than trusting
  # it.
  #
  # The earlier shape drove this chain through a real holder, and both field runs proved
  # it unassertable that way. Handed grounded work and the statute's own remedy prompt, a
  # competent holder verified, recorded its report and completed before the scripted
  # denials could fire — claude 11:19:56 open → 11:20:48 verified → 11:21:02 recorded →
  # 11:21:07 closed, and codex the same shape at 12:09–12:12. The scripted denial then hit
  # `assignment_closed`. The agents were right and the journey was wrong: it had been
  # asserting that a capable holder would fail to do its job.
  #
  # WHERE THE REAL-AGENT PROOF LIVES NOW, so no one reads this split as a proof dropped
  # rather than relocated. Those two field runs ARE the "a real agent walks the gates"
  # evidence, and they are stronger than the scripted version was: both holders verified
  # with grounded notes of their own, recorded over the real CLI — codex landed
  # art_0f26ec21 `tool-call-observed` with a non-null edge, which is the R7 datum itself —
  # and completed, autonomously and honestly, on both harnesses. What remains under
  # assertion every run is the substrate half, in `check_carrier_on_real_turn/1` below,
  # which accepts the holder completing its own assignment as the legitimate outcome it is
  # rather than as a race to be suppressed.
  #
  # What this half proves is the LAW: each statute denies while its fact is unsatisfied,
  # in order, and the artifact releases the last one. An org carrying the eb0ea2b
  # workaround still fails at the third denial, so falsifiability is untouched.
  #
  # WHY THE HOLDER CANNOT QUIETLY LEAK INTO THIS, stated so it can be attacked rather than
  # trusted. The verification and artifact statutes both remedy by WAKING the holder, so a
  # summons really is issued mid-chain and the holder really is capable of acting on it.
  # Cancelling that summons is NOT available: `RailRemedy` stamps its wake
  # `origin: "remedy:<rule>"` and `Wakes.cancel_in_txn/3` matches `wakeId AND origin`, so
  # the `cancel-wake` verb — which passes the CALLER's origin — cannot touch a remedy's
  # wake. There is no way to make the holder structurally inert, and pretending otherwise
  # would be the "drains and hope" this replaced.
  #
  # So isolation is MEASURED rather than assumed, and every way it could fail is fatal
  # rather than silent:
  #
  #   THE HOLDER'S ACTIONS, not its turn states. Turn rows are expected and so is a turn
  #   reaching `running`: the wake is immediate-due, the gateway fires due wakes
  #   synchronously, delivery inserts the row before the denying request returns, and the
  #   lane claims it in milliseconds. Field evidence settles this rather than argument —
  #   the operator's own row came back `session-concurrent`, a class only reachable when a
  #   turn is already `running`. Turn state tracks the LANE; what takes seconds, and what
  #   this half actually needs not to happen, is the MODEL acting. Both counts are
  #   reported as the margin; neither is asserted.
  #
  #   ONE REPORT, AND IT IS THE OPERATOR'S. Exactly one report artifact may exist on this
  #   work item from this holder. A second row is a holder that recorded, and a strong
  #   class on the one row is a holder that tool-called; either inverts what the negative
  #   control below means, and either fails here instead of being read as a pass.
  #
  # The margin behind those assertions is the lane claiming a queued turn against six HTTP
  # calls, which is why they should never fire. They exist because "should never" is not
  # evidence — and because an earlier version of this same tripwire was itself wrong, in the
  # direction of demanding something the substrate can never provide.
  defp check_gate_chain_enforced(state) do
    u = unique()
    reviewer_leg = independent_leg(state)
    preflight_independent!(state, reviewer_leg)

    post(state, "role-create", %{"name" => "reviewer"})

    # The reviewer is spawned through the other SELECTED leg where this run has one. The
    # `reviewer` bind does double duty: a session acting under its own credential needs a
    # bound role or the router refuses it `no_role`, and `Roles.bind/3` REPLACES
    # `boundSessionKey`, which is what points the review statute's `target_role` at a live
    # session instead of whatever retired one a previous group left behind.
    reviewer =
      ok!(%{state | leg: reviewer_leg}, "spawn", %{
        "displayName" => "smoke-gate-reviewer-#{u}",
        "idempotencyKey" => "grv-#{u}"
      })

    reviewer_key = get_in(reviewer, ["stream", "sessionKey"]) || reviewer["sessionKey"]
    ok!(state, "role-bind", %{"name" => "reviewer", "sessionKey" => reviewer_key})
    reviewer_tok = session_token(state, reviewer_key)

    wi =
      ok!(state, "work-item-create", %{
        "title" => "gate chain #{u}",
        "idempotencyKey" => "gwi-#{u}"
      })

    wi_id = wi["workItemId"] || wi["id"]
    holder = open_grounded_assignment!(state, u, wi_id, "gate chain #{u}", "g")
    asg_id = holder.assignment_id

    complete = fn ->
      post_as(state, holder.token, "attest", %{"assignmentId" => asg_id, "kind" => "completion"})
    end

    try do
      # 1. Review gate. Its remedy assigns the bound reviewer, synchronously inside the
      # attest, so the review exists by the time the denial response returns.
      denied!(state, "completion-requires-review", asg_id, complete)

      reviews = ok!(state, "assignments", %{"sessionKey" => reviewer_key})

      review =
        (reviews["assignments"] || reviews)
        |> List.wrap()
        |> Enum.find(fn a -> (a["reviewsAssignmentId"] || a["reviews"]) == asg_id end)

      assert(
        state,
        is_map(review),
        "gate chain: the review remedy did not assign the #{reviewer_leg.wire_name} reviewer a " <>
          "review of #{asg_id}. The role is rebound to this group's live reviewer, so an " <>
          "unresolved target here is a real remedy failure. Got: #{inspect(reviews)}"
      )

      # Independence is a property of the SESSION, never of the harness:
      # `commissioned_review_authors/3` counts a verdict only when the review's
      # `openedBySession` differs from the holder and the author is the review's own holder.
      # A remedy-opened review has `openedBySession` NULL, so it qualifies, and on a
      # filtered single-leg run a fresh same-harness reviewer qualifies just as fully.
      v =
        post_as(state, reviewer_tok, "attest", %{
          "assignmentId" => review["id"] || review["assignmentId"],
          "kind" => "verdict",
          "verdictKind" => "reviewed-clean"
        })

      assert(
        state,
        not (is_map(v) and Map.has_key?(v, "error")),
        "gate chain: reviewed-clean from the #{reviewer_leg.wire_name} reviewer failed: #{inspect(v)}"
      )

      # 2. Verification gate, reachable now that the review gate stopped denying.
      denied!(state, "completion-requires-verification", asg_id, complete)

      verified =
        post_as(state, holder.token, "attest", %{
          "assignmentId" => asg_id,
          "kind" => "verdict",
          "verdictKind" => "verified",
          "note" => holder.check.note
        })

      assert(
        state,
        not (is_map(verified) and Map.has_key?(verified, "error")),
        "gate chain: the holder-token verified verdict failed: #{inspect(verified)}"
      )

      # 3. The artifact gate.
      denied!(state, "completion-requires-results-artifact", asg_id, complete)
      await_episode_status!(state, "completion-requires-results-artifact", asg_id, "live")

      # 4. The report, recorded BY THE OPERATOR over HTTP on the holder's own token — and
      # its WEAKER evidence class is an assertion here rather than a compromise.
      #
      # No hook can observe an HTTP call, so this row cannot read `tool-call-observed`.
      # Two ruled properties fall out of that, on a row this half needs anyway:
      #
      #   THE GATE IS EVIDENCE-BLIND (§7.2 item 9, R5). `Artifacts.recorded_kinds/3`
      #   selects on workItemId and createdBySession and reads neither the class nor the
      #   edge, so a weak row releases the statute exactly as a strong one would. That was
      #   unit-only until now; the completion below is its live proof.
      #
      #   THE CLASSES ARE NOT SPOOFABLE. If an operator HTTP call could read
      #   `tool-call-observed`, the strongest class would be obtainable without any tool
      #   call, and every conclusion `check_carrier_on_real_turn/1` draws would be void.
      #   This is the standing negative control that says it cannot.
      #
      # The content is the output the operator really observed, written where the holder's
      # own report would go — the same honesty the note carries.
      results = "results-#{u}.md"
      File.write!(Path.join(Path.dirname(holder.check.path), results), holder.check.output)

      recorded =
        ok_as!(state, holder.token, "artifact-record", %{
          "kind" => "report",
          "title" => "operator report #{u}",
          # `originPath`, NOT `path`. `--path` is the CLI's FLAG name; the Rust client
          # serializes it to `originPath` on the wire, and only `originPath` underscores to
          # the `:origin_path` the handler reads. Nothing aliases `path` — the router's
          # alias map carries one entry, for assign — so the flag spelling reaches
          # `Artifacts.record/2` as a missing key and takes the group down before its first
          # assertion. Every CLI-driven record worked all night precisely because the CLI
          # does this translation; an HTTP caller has to do it itself.
          "originPath" => results,
          "workItemId" => wi_id
        })

      assert(
        state,
        is_binary(recorded["artifactId"]),
        "gate chain: the operator's artifact-record did not land a row: #{inspect(recorded)}"
      )

      assert(
        state,
        recorded["recordedTurnEvidence"] in ~w(session-concurrent none),
        "gate chain: an artifact-record made over HTTP, with no tool call to observe, reads " <>
          "#{inspect(recorded["recordedTurnEvidence"])}. `tool-call-observed` here would mean " <>
          "the strongest evidence class is obtainable WITHOUT a tool call, which would void " <>
          "the carrier proof in the other half of this group. Row: #{inspect(recorded)}"
      )

      # 5. Release. The gate had denied three times; with a report on record — a WEAK one —
      # completion passes, which is the evidence-blindness above proven end to end.
      done = complete.()
      final = ok!(state, "assignment-get", %{"assignmentId" => asg_id})

      assert(
        state,
        final["state"] == "closed" and final["outcome"] == "completed",
        "gate chain: with a report recorded, completion should close #{asg_id} as completed; " <>
          "assignment reads state=#{inspect(final["state"])} outcome=#{inspect(final["outcome"])} " <>
          "(attest returned #{inspect(done)})"
      )

      await_episode_status!(state, "completion-requires-results-artifact", asg_id, "closed")

      # 6. The isolation proof. Everything above assumed the holder never acted; this is
      # where that stops being an assumption.
      #
      # A TURN ROW IS NOT ACTION, and conflating the two makes the check unsatisfiable by
      # construction. The denial's remedy wake is immediate-due, the gateway fires due wakes
      # synchronously, and delivery INSERTS the turn row before the denying request returns
      # — so by the time any denial above has a response there is already a row, `queued`,
      # holding a prompt nothing has read. An earlier version of this assertion demanded
      # zero rows and could never have passed.
      #
      # `startedAt` IS NOT THE LINE EITHER, and the field disproved it before it ever ran.
      # The operator's row above came back `session-concurrent`, and that class is returned
      # only when `Ledger.running_turn_message_id/2` finds a turn at `status = 'running'` —
      # the same UPDATE that writes `startedAt`. So on the run that produced art_d968e72a a
      # turn was ALREADY running, and an assertion on `startedAt` would have failed a group
      # that was otherwise behaving exactly as designed.
      #
      # THE LESSON, which is worth more here than any assertion: TURN STATE TRACKS THE
      # LANE, NOT THE AGENT. `running` means the lane claimed the turn and is handing it to
      # an adapter, which happens in milliseconds; the model producing a tool call is what
      # takes seconds. Two tripwires in a row measured the fast half and called it the slow
      # one — first the row's existence, then the lane's claim — and both would have failed
      # healthy runs. Only an action-based check held. If you are tempted to add a third
      # turn-state assertion here, this paragraph is why it will not work either.
      #
      # A terminal-state variant is worse than weak, and was considered and rejected: a
      # turn can act without terminalizing, so it could PASS a contaminated run. Unsound in
      # the direction that matters.
      #
      # So the turn counts are REPORTED, not asserted — they are the margin, and a runner
      # watching them climb learns something before anything breaks — and isolation is
      # asserted where the agent's action actually lands:
      #
      #   EXACTLY ONE DENIAL per bounded window, above, catches a holder that attested.
      #   EXACTLY ONE REPORT, below, catches a holder that recorded.
      #
      # THAT PAIR IS ARGUED COMPLETE, NOT PROVEN COMPLETE, and the distinction is recorded
      # deliberately by an author who got two completeness claims wrong before this one.
      # The argument: a holder cannot close the assignment without a report, that being the
      # gate under test, and a second report fails the check below.
      #
      # What makes the residual risk tolerable is not the argument but a structural
      # backstop. This half's claims are about THE OPERATOR'S OWN SEQUENCE — the denials
      # fired in order, and the operator's weak-class row released the gate — and both stay
      # independently true whatever else happened on that session. So an uncaught third
      # action would make this half prove LESS than advertised; it cannot make it prove
      # something FALSE. A false green is out of reach even where the completeness argument
      # is not.
      started =
        sqlite(
          state,
          "SELECT count(*) FROM turns WHERE sessionKey = #{sql_quote(holder.key)} " <>
            "AND startedAt IS NOT NULL"
        )

      materialized =
        sqlite(state, "SELECT count(*) FROM turns WHERE sessionKey = #{sql_quote(holder.key)}")

      reports =
        state
        |> ok!("artifacts", %{
          "workItemId" => wi_id,
          "sessionKey" => holder.key,
          "kind" => "report"
        })
        |> Map.get("artifacts", [])
        |> List.wrap()

      assert(
        state,
        Enum.map(reports, & &1["artifactId"]) == [recorded["artifactId"]],
        "gate chain: the only report on #{wi_id} should be the operator's #{recorded["artifactId"]}, " <>
          "but the work item carries " <>
          "#{inspect(Enum.map(reports, &{&1["artifactId"], &1["recordedTurnEvidence"]}))}. A second " <>
          "row is the holder having recorded one of its own, which means the release proven above " <>
          "may not be the weak row's doing at all."
      )

      pass(
        state,
        "gate chain enforced: review(#{reviewer_leg.wire_name}) → verification → artifact " <>
          "denied in order, released by a #{recorded["recordedTurnEvidence"]} row (gate is " <>
          "evidence-blind, classes not spoofable), completes, episode closed — holder: " <>
          "#{materialized} turn(s) materialized, #{started} started"
      )
    after
      # EVERY assertion about an assignment outcome stays above this line: `retire` REVOKES
      # a session's open assignments, so a retired holder reads `revoked`, and an assertion
      # moved below would read teardown's revocation as this group's result.
      retire(state, reviewer)
      retire(state, holder.session)
    end
  end

  # --- T2a: the carrier, on a real turn ----------------------------------------------
  # artifact-carrier-proposal-v1 §7.3, second half and the R7 datum.
  #
  # The ONLY place in the tree where `artifact-record` runs from the real CLI inside a real
  # harness turn, which is the only way the substrate-reserved PreToolUse observation
  # (`Tightbeam.Rails.observation_entry/0`) can fire at all. Every other artifact assertion
  # drives the writer directly and therefore cannot see the hook.
  #
  # WHICH HALF OF CODEX THIS PROVES. Codex as a verdict FILER is proven on this gateway —
  # the live walks filed reviewed-clean over codex cleanly. What rests on the trust-gated
  # `CODEX_CONFIG` hook seam is codex as the artifact RECORDER, and until the field runs it
  # had only the 0.145.0 spike behind it (§5.2). The holder is therefore always the leg's
  # own harness and the class is asserted PER LEG, which is what makes a filtered
  # single-leg run a complete answer to that one question.
  #
  # NO GATES ARE DRIVEN HERE, so no remedy wakes fire and there is nothing to serialize
  # against beyond this group's own wake. The holder completing its assignment afterwards
  # is ACCEPTED AND NOT REQUIRED: that is what a capable holder does with grounded work,
  # it is what both field runs did, and a journey that treated it as a failure would be
  # asserting that good agents behave badly.
  defp check_carrier_on_real_turn(state) do
    u = unique()
    marker = "results-#{u}.md"

    wi =
      ok!(state, "work-item-create", %{
        "title" => "carrier proof #{u}",
        "idempotencyKey" => "cwi-#{u}"
      })

    wi_id = wi["workItemId"] || wi["id"]
    holder = open_grounded_assignment!(state, u, wi_id, "carrier proof #{u}", "c")
    asg_id = holder.assignment_id

    try do
      await_lane_idle!(state, holder.key, "before issuing the artifact wake")

      wake =
        ok!(state, "wake", %{
          "sessionKey" => holder.key,
          "prompt" => artifact_prompt(u, marker, holder.check.name, wi_id, asg_id),
          "idempotencyKey" => "cwake-#{u}"
        })

      wake_id = wake["wakeId"]

      proof = %{
        wake_id: wake_id,
        message_id: await_turn_message_id!(state, wake_id),
        marker: marker
      }

      {prompted, reports} = await_prompted_report!(state, holder.key, wi_id, asg_id, proof)
      classes = Enum.map(reports, & &1["recordedTurnEvidence"])

      # The null-vs-non-null coupling, on EVERY row. Pure substrate: `tool-call-observed`
      # and `session-concurrent` each name a turn and must carry its id, `none` names no
      # turn and must carry NULL. A row breaking the pairing is a carrier defect whatever
      # the agent chose to run.
      Enum.each(reports, fn row ->
        assert(
          state,
          row["recordedTurnEvidence"] in ~w(tool-call-observed session-concurrent none),
          "carrier proof: recordedTurnEvidence outside its closed domain: #{inspect(row)}"
        )

        if row["recordedTurnEvidence"] == "none" do
          assert(
            state,
            is_nil(row["recordedMessageId"]),
            "carrier proof: evidence 'none' must carry a NULL recordedMessageId: #{inspect(row)}"
          )
        else
          assert(
            state,
            is_binary(row["recordedMessageId"]),
            "carrier proof: evidence #{inspect(row["recordedTurnEvidence"])} names a turn but " <>
              "recordedMessageId is NULL: #{inspect(row)}"
          )
        end
      end)

      # THE R7 assertion, per leg, and an IDENTITY claim rather than a content one: the row
      # bound to the turn this group prompted must read `tool-call-observed`. Selecting on
      # `recordedMessageId` is what makes the class unspoofable by anything else on the
      # session — a record that inherited another turn's window carries that turn's id and
      # never reaches this line — and the negative control in `check_gate_chain_enforced/1`
      # is what proves the class cannot be reached without a tool call at all.
      assert(
        state,
        prompted["recordedTurnEvidence"] == "tool-call-observed",
        "carrier proof: the record bound to the prompted turn (message #{proof.message_id}) " <>
          "reads #{inspect(prompted["recordedTurnEvidence"])}, not tool-call-observed — the " <>
          "reserved PreToolUse observation did not fire for the #{state.leg.wire_name} holder " <>
          "on a turn that ran with no other turn on its lane, so this leg's record rests on " <>
          "concurrency rather than observation. Read it as the RECORDER side of " <>
          "#{state.leg.wire_name} failing; the filer side is a separate question. " <>
          "Row: #{inspect(prompted)}. All classes seen: #{inspect(classes)}"
      )

      # NOTHING here asserts artifact lifecycle `state`. Retirement moves rows
      # in-workspace → released and the gate is state-blind on purpose, so a state
      # assertion would be a brittle oracle for a fact the substrate does not gate on.
      # Kind and provenance are the whole contract. Do not add one.
      #
      # The outcome is ACCEPTED, not required. A holder that went on to complete did the
      # job; one still working has not failed. Only abandonment is a failure, and
      # `surrendered` is roadmap 0a2 — the escape hatch a holder reaches for when a gate
      # cannot be satisfied, which is exactly what grounding the work is meant to prevent.
      #
      # SAMPLED AFTER THE LANE SETTLES, because the wait above returns the instant the
      # record lands and that is normally MID-TURN. Reading the outcome there would ask the
      # question before the holder had finished answering it: a holder that records and
      # then surrenders in the same turn would have been read as "still working, fine" and
      # the 0a2 oracle — the whole reason this matrix exists — would never fire. The matrix
      # was right; the moment it was sampled was not.
      await_lane_idle!(state, holder.key, "before reading the assignment's outcome")
      final = ok!(state, "assignment-get", %{"assignmentId" => asg_id})

      assert(
        state,
        final["outcome"] in [nil, "completed"],
        "carrier proof: #{asg_id} ended #{inspect(final["outcome"])}. Completing is accepted and " <>
          "still working is fine; abandoning is not. " <> abandonment_note(final["outcome"])
      )

      pass(
        state,
        "carrier on a real #{state.leg.wire_name} turn: CLI artifact-record bound to its own " <>
          "turn, #{prompted["recordedTurnEvidence"]} with a non-null edge; assignment " <>
          "#{inspect(final["outcome"] || "open")}"
      )
    after
      retire(state, holder.session)
    end
  end

  # A host-pinned coder holding grounded work. Both halves need exactly this, and the
  # pieces are load-bearing in ways worth keeping together rather than duplicating.
  #
  # `holder_archetype in ["coder"]` is a deny_when condition on both verification statutes,
  # so a default-archetype holder would walk straight past them and prove nothing.
  #
  # THE HOST IS PINNED, and the seed depends on it. `Placement.resolve/3` reads a nil host
  # as "first of archetype.where" unless the archetype grants `["*"]`, and the shipped coder
  # archetype is `where = ["eezo", "racter"]` — so an unpinned spawn on any other gateway
  # places the holder on a DIFFERENT machine while the seed is written locally. Where an
  # org's coder archetype does not admit this host the spawn is refused `host_not_allowed`
  # by name, which is the right failure: about the org's law, not about a file that
  # mysteriously is not there.
  defp open_grounded_assignment!(state, u, wi_id, subject, tag) do
    session =
      ok!(state, "spawn", %{
        "archetype" => "coder",
        "host" => Tightbeam.Placement.local_host_name(),
        "displayName" => "smoke-#{tag}-coder-#{u}",
        "idempotencyKey" => "#{tag}cd-#{u}"
      })

    key = get_in(session, ["stream", "sessionKey"]) || session["sessionKey"]
    post(state, "role-create", %{"name" => "coder-#{tag}-#{u}"})
    ok!(state, "role-bind", %{"name" => "coder-#{tag}-#{u}", "sessionKey" => key})
    check = seed_verifiable_work!(state, key, u)

    assignment =
      ok!(state, "assign", %{
        "sessionKey" => key,
        "subject" => "run #{check.name} and record its output — #{subject}",
        "workItemId" => wi_id,
        "files" => [check.name],
        "idempotencyKey" => "#{tag}as-#{u}"
      })

    %{
      session: session,
      key: key,
      token: session_token(state, key),
      check: check,
      assignment_id: assignment["id"] || assignment["assignmentId"]
    }
  end

  # Put something real in the holder's workdir, run it, and keep what it said.
  #
  # The smallest thing that satisfies "can be executed and observed": one script with a
  # known output. It is deliberately not a fake diff or a spec pointing at absent code —
  # a holder asked to verify either would be right to refuse again, and this group must
  # never be the thing that provokes the refusal it also asserts against.
  #
  # Seeding before the first turn is safe: `Placement.ensure_workdir/4` does `mkdir -p`,
  # writes `.tightbeam-session`, and appends that name to `.git/info/exclude` when the
  # workdir is a git repo. It touches nothing else, so it forms the directory around this
  # file rather than over it.
  #
  # LOCALITY DEPENDS ON THE HOLDER'S SPAWN BEING HOST-PINNED. This path is derived from the
  # gateway's own base_dir, so a holder placed on another machine would leave the seed on
  # this one. The pin at the spawn is what makes that impossible; do not remove one without
  # the other.
  #
  # The operator runs it HERE, and that run is what makes the verdict's note true rather
  # than decorative — the note quotes output this function actually observed.
  defp seed_verifiable_work!(state, session_key, u) do
    workdir = local_workdir_path(state.base_dir, session_key)
    name = "check-#{u}.sh"
    path = Path.join(workdir, name)

    # BYTE-EXACT, `echo`'s trailing newline included. Trimming before comparing would let
    # stray whitespace pass and then disappear from the note; keeping the newline in the
    # expectation and quoting the observation with `inspect/1` shows it instead of
    # swallowing it.
    expected = "artifact-closure-check #{u}: PASS\n"

    File.mkdir_p!(workdir)

    File.write!(path, """
    #!/bin/sh
    # feature-smoke fixture: the unit of work under assignment #{u}.
    echo 'artifact-closure-check #{u}: PASS'
    """)

    File.chmod!(path, 0o755)

    # Run it the way the note says it was run — same cwd, same command form. Executing an
    # absolute path from the smoke's own directory and then writing "sh <name> in this
    # assignment's workdir" would put a sentence on the record that was only half observed,
    # in the one group whose whole subject is records claiming more than was seen.
    {output, status} = System.cmd("sh", [name], cd: workdir, stderr_to_stdout: true)

    assert(
      state,
      status == 0 and output == expected,
      "artifact closure: the seeded work does not run cleanly — `sh #{name}` in #{workdir} " <>
        "exited #{status} and printed #{inspect(output)}, expected #{inspect(expected)}. The " <>
        "group refuses to hand a holder work it could not verify itself."
    )

    %{
      name: name,
      path: path,
      output: output,
      note:
        "Ran `sh #{name}` in this assignment's workdir (#{workdir}); it exited 0 and printed " <>
          "exactly #{inspect(output)}"
    }
  end

  # The reviewer runs on a different SELECTED leg wherever this run has one, and on the
  # holder's own harness when it does not.
  #
  # On a default run that means cross-harness, which is the verdict path the live walk
  # exercised, and it costs nothing: every selected leg already needs a model and a live
  # credential, so the other leg's material is a precondition rather than a new one.
  #
  # Under TIGHTBEAM_SMOKE_LEGS the selection may be a single leg, and then the reviewer is
  # a FRESH SESSION ON THE SAME HARNESS. That is a legitimate reviewer and not a degraded
  # one: `assignment.independent_verdict_kinds` reads sessions, never harnesses, so
  # independence turns on the review being held and filed by someone other than the holder
  # — which a fresh same-harness session satisfies exactly. What a solo run loses is the
  # cross-harness EVIDENCE, not the statute's satisfaction, and the run already reports
  # itself INCOMPLETE(parity) for saying so.
  defp independent_leg(state) do
    Tightbeam.Harness.all()
    |> Tightbeam.FeatureSmokePlan.legs()
    |> Enum.find(state.leg, &(&1.wire_name != state.leg.wire_name))
  end

  # A missing credential is a NAMED WAIVER, never an onboarding. Onboarding is its own
  # rarely-run runbook and it mints material; a smoke that reaches for it turns a reported
  # gap into a silent repair.
  defp preflight_independent!(state, leg) do
    if leg.wire_name == state.leg.wire_name do
      state
    else
      row = Tightbeam.ClientE2E.preflight(leg.wire_name, state.base_dir)

      assert(
        state,
        row.status == :pass,
        "artifact closure: no usable #{leg.wire_name} credential for the independent reviewer " <>
          "(#{row.step}: #{row.status} — #{row.note}). Do NOT onboard from inside the smoke: file " <>
          "this leg INCOMPLETE with a named waiver for the missing #{leg.wire_name} credential, " <>
          "run the onboarding runbook, and re-run."
      )
    end
  end

  # Everything the holder's turn needs that the statute's own remedy prompt does not say.
  #
  # DIRECT INVOCATION is a substrate requirement, not a style note: the observation greps
  # the tool call's own command text, so a wrapped call is one of §1.3's legitimately
  # hookless calls and would land `session-concurrent` truthfully.
  #
  # KEEPING THE ASSIGNMENT OPEN is the guidance-side mitigation for roadmap 0a2, where an
  # agent meeting a gate it could not satisfy surrendered and closed the work permanently.
  # The gate is satisfiable now; the instruction is here so a leg cannot fail on an agent
  # reaching for the old escape.
  defp artifact_prompt(u, marker, check, wi_id, asg_id) do
    """
    Substrate smoke check #{u} on assignment #{asg_id}. Do exactly these two steps.

    1. Run the script this assignment declares and capture its real output:
       sh #{check} > #{marker} 2>&1
       #{marker} must contain what the script actually printed. Do not write it by hand
       and do not paste an expected value — the point is that the report carries an
       observation, not a claim.

    2. Run this as a single shell command, exactly as written:
       tightbeam artifact-record --kind report --title 'smoke report #{u}' --path #{marker} --work-item #{wi_id}

    Run step 2 DIRECTLY as the shell command. Do not put it in a script file, a Makefile,
    or any wrapper, and do not run it through one — the substrate reads the command text of
    the call itself, and a wrapped invocation records weaker provenance than the real one.

    Keep assignment #{asg_id} OPEN. Do not surrender it, do not revoke it, and do not
    attest completion — the operator files completion. If something denies you, satisfy
    that gate and carry on in order; never abandon the assignment to get out of a gate.
    """
  end

  # Assert WHICH statute denied, from the substrate's own record rather than from the
  # wire's rendering of it.
  #
  # The wire cannot answer this. `Wire.Router` renders a denial as `code` plus `message`
  # only, so `error.rule` never reaches a client, and `message` is
  # `"#{rule.name}: #{rule.text}"` — matching a statute name as a SUBSTRING of that is not
  # statute identity, because any statute whose text quoted the expected name would
  # satisfy it. A false green on the third denial is the one this group cannot afford: it
  # is what makes an org still carrying the eb0ea2b workaround look like a pass.
  #
  # The durable row is exact. Every statute denial goes through
  # `Dispatch.best_effort_denial/6`, which JSON-encodes the whole error before the call
  # returns, so `events` holds the UNSTRIPPED `$.rule` next to `$.ref` (the gated
  # assignment). `EventLog.encode/1` passes an encoded binary through verbatim while a raw
  # map becomes `inspect` output, which is why `json_valid` is in the WHERE clause: it is
  # exactly what separates statute denials from handler denials.
  #
  # Correlation is by ref inside a window BOUNDED ON BOTH SIDES. A watermark alone closes
  # the gap before the call and leaves one after it, so a concurrent writer could land the
  # expected statute against the same assignment while the wire returned a DIFFERENT
  # statute's denial, and newest-row-after-watermark would pass that. The ceiling is read
  # the instant the response returns — `best_effort_denial/6` writes before the call
  # returns — which narrows the window to this one HTTP round trip.
  #
  # An earlier version also DRAINED the holder's lane here. It no longer needs to: the only
  # caller is `check_gate_chain_enforced/1`, which drives every step over HTTP and therefore
  # gives the lane no reason to be waited on. That does not CAUSE the holder's queued turns
  # to stay unstarted — the lane may claim one at any moment — which is exactly why that
  # group measures whether any did rather than asserting none could. Draining was worse than
  # redundant here: it waited for the remedy turn, which is how a capable holder came to
  # satisfy the whole chain before the next denial could be asserted.
  #
  # The window must hold EXACTLY ONE row for this assignment. Requiring one rather than
  # taking the newest is what keeps the correlation exact without the drain: anything else
  # writing a denial against this assignment inside the round trip fails the group loudly
  # instead of being silently picked over.
  defp denied!(state, statute, assignment_id, attempt) when is_function(attempt, 0) do
    watermark = events_watermark(state)
    res = attempt.()
    ceiling = events_watermark(state)

    assert(
      state,
      get_in(res, ["error", "code"]) == "rule_denied",
      "artifact closure: completion should be denied by #{statute}, got #{inspect(res)}"
    )

    recorded = recorded_denials(state, watermark, ceiling, assignment_id)

    assert(
      state,
      recorded == [statute],
      "artifact closure: the denials recorded against #{assignment_id} by this call are " <>
        "#{inspect(recorded)}, not exactly [#{inspect(statute)}]. The wire said #{inspect(res)}, " <>
        "but the wire cannot name a statute — an empty list means the denial row is missing " <>
        "(best-effort append, or a non-statute refusal), another name means the chain is not " <>
        "where this group thinks it is, and more than one means something else filed against " <>
        "this assignment while the call was in flight."
    )
  end

  # ONE turn's worth, because this group serializes: the statute's remedy turn is drained
  # before the prompted wake is issued, so nothing is queued behind the turn being awaited.
  defp turn_observer_budget_ms, do: @turn_observer_wait_ms + @lane_slack_ms

  # Wait for the holder's lane to go quiet.
  #
  # SERIALIZATION IS A CORRECTNESS DEVICE HERE, not tidiness. A turn running concurrently
  # with this group's calls can contaminate every selector it owns: it can read the session
  # transcript and learn a marker the prompt has already persisted, it can file its own
  # attest and land a denial row beside the one being correlated, and it can open an
  # observation window that a later record inherits. Draining the lane first removes the
  # whole class rather than patching each symptom.
  #
  # Deliberately NOT `await_turn_boundary!/2`: that one is scoped to the local-deployment
  # group and its 30s budget is right for what it waits on. This waits on real model turns.
  defp await_lane_idle!(state, session_key, label) do
    await_lane_idle!(
      state,
      session_key,
      label,
      System.monotonic_time(:millisecond) + turn_observer_budget_ms()
    )
  end

  defp await_lane_idle!(state, session_key, label, deadline) do
    [turns, wakes] = lane_pending(state, session_key)

    cond do
      turns == "0" and wakes == "0" ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        assert(
          state,
          false,
          "artifact closure: the holder's lane never went quiet #{label} — #{turns} turn(s) " <>
            "queued or running and #{wakes} wake(s) due but not yet fired, after " <>
            "#{div(turn_observer_budget_ms(), 1000)}s. This group serializes turns on purpose; it will " <>
            "not run its assertions beside one."
        )

      true ->
        Process.sleep(1_000)
        await_lane_idle!(state, session_key, label, deadline)
    end
  end

  # A DUE WAKE IS PENDING WORK EVEN WITH NO TURN ROW YET, and missing that was what made
  # an earlier version of this barrier porous. A live remedy episode re-waking the holder
  # schedules an immediate-due wake without nudging the scheduler
  # (`RailRemedy` rewake path), so between the schedule and the moment something
  # materializes it there is a window with zero queued turns and real work outstanding.
  # Draining on turns alone declares idle inside that window, and the remedy's turn then
  # queues AHEAD of the wake this group is about to issue — which is exactly the
  # concurrency the barrier exists to prevent, reintroduced by the barrier itself.
  #
  # Both counts come from ONE statement so the pair cannot straddle a wake firing.
  # `dueAt` is bounded by a short grace rather than by `<= now`, so a wake that becomes
  # due while the scheduler is between ticks is still counted; a wake genuinely scheduled
  # for later is not, and does not stall the group forever.
  @wake_due_grace_ms 2_000

  defp lane_pending(state, session_key) do
    due_by = System.system_time(:millisecond) + @wake_due_grace_ms

    state
    |> sqlite("""
    SELECT
      (SELECT count(*) FROM turns
        WHERE sessionKey = #{sql_quote(session_key)}
          AND status IN ('queued','running')),
      (SELECT count(*) FROM wakes
        WHERE sessionKey = #{sql_quote(session_key)}
          AND state = 'pending' AND dueAt <= #{due_by})
    """)
    |> String.split("|")
  end

  # Terminal statuses for the prompted turn — the ledger's own closed set minus the two
  # live ones (`Ledger` DDL: queued, running, delivered, canceled, failed, failed_unknown).
  defp prompted_turn_terminal?(state, wake_id) do
    sqlite(state, "SELECT status FROM turns WHERE wakeId = #{sql_quote(wake_id)}") in ~w(delivered canceled failed failed_unknown)
  end

  # The prompted turn's own `messages.id`, which is what makes the artifact assertion an
  # identity claim rather than a content one. A wake is SCHEDULED, then fired, so the turn
  # row appears asynchronously — but `turns.wakeId` is UNIQUE, so once it exists the join
  # is exact and needs no time window.
  defp await_turn_message_id!(state, wake_id) do
    assert(
      state,
      is_binary(wake_id) and wake_id != "",
      "artifact closure: the wake returned no wakeId, so the prompted turn cannot be identified"
    )

    await_turn_message_id!(
      state,
      wake_id,
      System.monotonic_time(:millisecond) + @episode_settle_ms
    )
  end

  defp await_turn_message_id!(state, wake_id, deadline) do
    case sqlite(state, "SELECT messageId FROM turns WHERE wakeId = #{sql_quote(wake_id)}") do
      "" ->
        if System.monotonic_time(:millisecond) >= deadline do
          assert(
            state,
            false,
            "artifact closure: wake #{wake_id} never produced a turn row within " <>
              "#{div(@episode_settle_ms, 1000)}s, so the prompted turn has no identity to bind"
          )
        else
          Process.sleep(250)
          await_turn_message_id!(state, wake_id, deadline)
        end

      message_id ->
        message_id
    end
  end

  defp events_watermark(state) do
    state |> sqlite("SELECT COALESCE(MAX(id), 0) FROM events") |> String.to_integer()
  end

  defp recorded_denials(state, watermark, ceiling, assignment_id) do
    state
    |> sqlite("""
    SELECT json_extract(payload, '$.rule') FROM events
    WHERE kind = 'denied' AND id > #{watermark} AND id <= #{ceiling}
      AND json_valid(payload)
      AND json_extract(payload, '$.ref') = #{sql_quote(assignment_id)}
    ORDER BY id
    """)
    |> String.split("\n", trim: true)
  end

  defp sqlite(state, sql) do
    {out, 0} = System.cmd("sqlite3", [Path.join(state.base_dir, "state.db"), sql])
    String.trim(out)
  end

  # Wait for the record bound to THE PROMPTED TURN, identified by turn identity rather
  # than by content.
  #
  # Content cannot identify it. The salted filename is data, not a secret: the explicit
  # wake persists its prompt to the session transcript while still queued, so a turn
  # running beside it can read the marker, and `u` is already visible in the work-item
  # title and the assignment subject anyway. Serializing the lane removes the concurrent
  # reader, but the selector should not depend on that having worked.
  #
  # `recordedMessageId` is the identity. `turns.wakeId` is UNIQUE, so the wake this group
  # issued names exactly one turn and that turn names exactly one message. A row carrying
  # that message id was bound to THIS turn by the substrate — the same principle the
  # carrier itself rests on, identity from the substrate rather than from content.
  #
  # This is also what closes the stale-window hole. Observation windows are session-scoped,
  # non-consuming, and live for minutes, so a record whose own hook missed can inherit an
  # earlier turn's `tool-call-observed` window — and would then carry that EARLIER turn's
  # message id. Under a content selector such a row reads as a pass; under this one it does
  # not match, and the marker earns its keep as the diagnostic that says so out loud.
  defp await_prompted_report!(state, session_key, work_item_id, assignment_id, proof) do
    await_prompted_report!(
      state,
      session_key,
      work_item_id,
      assignment_id,
      proof,
      System.monotonic_time(:millisecond) + turn_observer_budget_ms()
    )
  end

  defp await_prompted_report!(state, session_key, work_item_id, assignment_id, proof, deadline) do
    # Terminality is sampled BEFORE the rows are read, and the order is the whole
    # correctness of the fast path below: a record committed after this sample is still
    # seen by the read that follows it, so "the turn ended and recorded nothing" can never
    # be a race against a row landing.
    turn_ended? = prompted_turn_terminal?(state, proof.wake_id)

    reports =
      state
      |> ok!("artifacts", %{
        "workItemId" => work_item_id,
        "sessionKey" => session_key,
        "kind" => "report"
      })
      |> Map.get("artifacts", [])
      |> List.wrap()

    prompted = Enum.find(reports, &(&1["recordedMessageId"] == proof.message_id))

    cond do
      prompted ->
        {prompted, reports}

      # Gated on the PROMPTED TURN being over, never on a record's content. An earlier
      # version fired as soon as a row carrying the marker appeared, which let a record
      # from another turn preempt a prompted record still on its way — the marker deciding
      # an outcome again, by the back door. Now the marker only chooses words: the trigger
      # is that the turn this group prompted has ended with nothing bound to it, which is a
      # settled fact whatever any other turn recorded.
      turn_ended? ->
        assert(
          state,
          false,
          "artifact closure: the prompted turn ended with no artifact bound to it " <>
            "(message #{proof.message_id}). #{marker_diagnosis(reports, proof)}"
        )

      # An abandoned assignment is DETECTED AND NAMED, never waited out. The budget here is
      # a full turn ceiling of real model time, and a holder that surrendered will never
      # record — so without this the roadmap 0a2 hazard reads as a confusing timeout
      # instead of the confirmed live failure it is. `revoked` is a different animal
      # (`retire` revokes a session's open assignments), so it is named separately rather
      # than folded in.
      outcome = terminal_outcome(state, assignment_id) ->
        assert(
          state,
          false,
          "artifact closure: assignment #{assignment_id} closed #{inspect(outcome)} before the " <>
            "prompted report artifact was recorded. " <> abandonment_note(outcome)
        )

      System.monotonic_time(:millisecond) >= deadline ->
        assert(
          state,
          false,
          "artifact closure: no artifact was bound to the prompted turn on #{work_item_id} " <>
            "within #{div(turn_observer_budget_ms(), 1000)}s, with #{assignment_id} still open and the " <>
            "turn still going. Either the real CLI `artifact-record` refused (the §1.1 defect " <>
            "this carrier fixed) or the prompted turn never ran it. " <>
            marker_diagnosis(reports, proof)
        )

      true ->
        Process.sleep(1_000)
        await_prompted_report!(state, session_key, work_item_id, assignment_id, proof, deadline)
    end
  end

  # The marker's ONLY job: say which record was found and what it was bound to, so a
  # failure reads as a diagnosis instead of an absence. It decides nothing.
  #
  # Matched on BASENAME because the CLI forwards `--path` verbatim, so the row holds
  # whatever form the holder typed and `./x` or an absolute path is the same file.
  defp marker_diagnosis(reports, proof) do
    case Enum.find(reports, &(Path.basename(&1["originPath"] || "") == proof.marker)) do
      nil ->
        "#{proof.marker} was never recorded at all. Reports seen: " <>
          "#{inspect(Enum.map(reports, &{&1["originPath"], &1["recordedMessageId"]}))}"

      row ->
        "#{proof.marker} WAS recorded, but bound to message " <>
          "#{inspect(row["recordedMessageId"])} rather than the prompted turn's " <>
          "#{inspect(proof.message_id)}, with class #{inspect(row["recordedTurnEvidence"])}. " <>
          "That is the prompted turn's hook failing to fire and the record inheriting an " <>
          "EARLIER turn's window — observation windows are session-scoped and non-consuming. " <>
          "A content-matching oracle would have called this a pass. Row: #{inspect(row)}"
    end
  end

  defp abandonment_note("surrendered") do
    "That is roadmap 0a2: the holder abandoned the assignment rather than satisfying the " <>
      "gate, which closes the work permanently. The gate IS satisfiable here — check " <>
      "whether the holder's turn ever saw this group's prompt."
  end

  defp abandonment_note(_revoked) do
    "Something revoked it mid-journey — a teardown or an operator, not the statute."
  end

  # `surrendered` or `revoked` only — `completed` is not terminal for this loop's purpose,
  # because the only way it can appear is the holder completing after a record this loop
  # has not read yet, and the next poll finds that record.
  defp terminal_outcome(state, assignment_id) do
    case ok!(state, "assignment-get", %{"assignmentId" => assignment_id})["outcome"] do
      outcome when outcome in ["surrendered", "revoked"] -> outcome
      _ -> nil
    end
  end

  # `rail_remedy_episodes` has no wire projection, so this reads the DB directly — the
  # same local-harness shortcut `session_token/2` and `await_turn_boundary!/2` already take.
  defp await_episode_status!(state, statute, subject, want) do
    await_episode_status!(
      state,
      statute,
      subject,
      want,
      System.monotonic_time(:millisecond) + @episode_settle_ms
    )
  end

  defp await_episode_status!(state, statute, subject, want, deadline) do
    got =
      sqlite(
        state,
        "SELECT status FROM rail_remedy_episodes " <>
          "WHERE statute = #{sql_quote(statute)} AND subject = #{sql_quote(subject)}"
      )

    cond do
      got == want ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        assert(
          state,
          false,
          "artifact closure: remedy episode #{statute}/#{subject} should be #{inspect(want)}, " <>
            "reads #{inspect(got)}"
        )

      true ->
        Process.sleep(250)
        await_episode_status!(state, statute, subject, want, deadline)
    end
  end

  # Fetch a session's own CLI bearer token from the state DB (local test harness only).
  defp session_token(state, session_key) do
    db = Path.join(state.base_dir, "state.db")

    {out, 0} =
      System.cmd("sqlite3", [
        db,
        "SELECT cliToken FROM sessions WHERE sessionKey = #{sql_quote(session_key)}"
      ])

    token = String.trim(out)
    if token == "", do: fail(state, "no cliToken for session #{session_key}"), else: token
  end

  defp sql_quote(s), do: "'" <> String.replace(s, "'", "''") <> "'"

  defp post_as(state, token, verb, params) do
    post(state |> Map.put(:token, token) |> Map.put(:as_session, true), verb, params)
  end

  # `post_as/4` is to `post/3` what this is to `ok!/3`. The pair matters because the two
  # halves differ in more than the token: `ok!` raises on an error envelope and UNWRAPS
  # `"result"`, `post_as` does neither. A caller that reads a success field off a raw
  # `post_as` response gets nil from a map whose payload is one key deeper — which is not
  # obvious in the failure message, because the map printed there contains the value that
  # was being looked for.
  #
  # Use this whenever a session-authenticated call's RESULT is read. Keep `post_as/4` for
  # the calls whose error envelope is the thing under test — every attest in this file is
  # one of those, and unwrapping would be meaningless rather than wrong there.
  defp ok_as!(state, token, verb, params) do
    ok!(state |> Map.put(:token, token) |> Map.put(:as_session, true), verb, params)
  end

  defp session_harness!(state, session_key) do
    session =
      state
      |> ok!("inspect", %{})
      |> Map.get("sessions", [])
      |> Enum.find(&(&1["sessionKey"] == session_key))

    case session do
      %{"harness" => harness} when is_binary(harness) -> harness
      _ -> fail(state, "local deployment inspect missed #{session_key}: #{inspect(session)}")
    end
  end

  # This check targets one selected leg, but read the spawn's actual resident harness
  # back rather than assuming placement chose it. Only a real boundary mismatch may send
  # set_harness; an already-resident harness is tuned through its model control.
  defp redeploy!(state, session_key, resident_harness) do
    params =
      if resident_harness == state.leg.wire_name do
        model_tune_params(state, session_key)
      else
        Map.put(model_tune_params(state, session_key), "harness", state.leg.wire_name)
        |> Map.put("setting", "set_harness")
      end

    assert_runtime_readback!(state, ok!(state, "tune", params))
  end

  # The sentinel pass is necessarily resident: the same session just completed a turn
  # on this leg. Redeliver through model+effort without pretending to cross a harness.
  defp redeliver!(state, session_key) do
    assert_runtime_readback!(
      state,
      ok!(state, "tune", model_tune_params(state, session_key))
    )
  end

  defp model_tune_params(state, session_key) do
    %{
      "sessionKey" => session_key,
      "setting" => "set_model",
      "model" => state.leg.model,
      "effort" => state.leg.effort
    }
  end

  defp assert_runtime_readback!(state, result) do
    assert(
      state,
      result["ok"] == true and result["harness"] == state.leg.wire_name and
        result["model"] == state.leg.model and result["effort"] == state.leg.effort,
      "local deployment runtime readback diverged from " <>
        "#{state.leg.wire_name}/#{state.leg.model}/#{state.leg.effort}: #{inspect(result)}"
    )
  end

  # --- facts-read: file a condition fact, read it back -----------------------
  defp check_facts_read(state) do
    kind = "smoke-fact-#{unique()}"
    scope = "smoke:scope:#{unique()}"

    ok!(state, "condition", %{
      "kind" => kind,
      "scope" => scope,
      "idempotencyKey" => "fk-#{unique()}"
    })

    res = ok!(state, "facts-read", %{"kind" => kind, "scope" => scope})

    assert(state, res["exists"] == true, "facts-read: fact not found after condition")
    assert(state, get_in(res, ["fact", "scope"]) == scope, "facts-read: wrong scope returned")
    pass(state, "facts-read files and reads a condition fact")
  end

  # --- config: set default-archetype, spawn honors it, reset -----------------
  defp check_config_default_archetype(state) do
    original =
      ok!(state, "config", %{"action" => "get", "setting" => "default-archetype"})["value"]

    ok!(state, "config", %{
      "action" => "set",
      "setting" => "default-archetype",
      "value" => "reviewer"
    })

    got = ok!(state, "config", %{"action" => "get", "setting" => "default-archetype"})["value"]
    assert(state, got == "reviewer", "config: set did not persist (#{inspect(got)})")

    spawn =
      ok!(state, "spawn", %{
        "displayName" => "smoke-cfg-#{unique()}",
        "idempotencyKey" => "cfg-#{unique()}"
      })

    arch = get_in(spawn, ["stream", "archetype"]) || spawn["archetype"]
    # reset before asserting so a failure can't leave the org mutated
    ok!(state, "config", %{
      "action" => "set",
      "setting" => "default-archetype",
      "value" => original || "default"
    })

    assert(state, arch in ["reviewer", nil], "config: spawn archetype was #{inspect(arch)}")
    retire(state, spawn)
    pass(state, "config default-archetype set/get persists and steers spawn")
  end

  # --- work-item + assignment-get --------------------------------------------
  defp check_work_item_and_assignment_get(state) do
    wi =
      ok!(state, "work-item-create", %{
        "title" => "smoke wi #{unique()}",
        "idempotencyKey" => "wi-#{unique()}"
      })

    wi_id = wi["workItemId"] || wi["id"]
    assert(state, is_binary(wi_id), "work-item-create returned no id: #{inspect(wi)}")

    holder =
      ok!(state, "spawn", %{
        "displayName" => "smoke-holder-#{unique()}",
        "idempotencyKey" => "h-#{unique()}"
      })

    holder_key = get_in(holder, ["stream", "sessionKey"]) || holder["sessionKey"]

    asg =
      ok!(state, "assign", %{
        "sessionKey" => holder_key,
        "subject" => "smoke assignment #{unique()}",
        "workItemId" => wi_id,
        "idempotencyKey" => "a-#{unique()}"
      })

    asg_id = asg["id"] || asg["assignmentId"]
    assert(state, is_binary(asg_id), "assign returned no id: #{inspect(asg)}")

    got = ok!(state, "assignment-get", %{"assignmentId" => asg_id})

    assert(
      state,
      (got["id"] || got["assignmentId"]) == asg_id,
      "assignment-get mismatch: #{inspect(got)}"
    )

    missing = post(state, "assignment-get", %{"assignmentId" => "asg_does_not_exist"})

    assert(
      state,
      get_in(missing, ["error", "code"]) == "not_found" or missing["code"] == "not_found",
      "assignment-get unknown id should be not_found, got #{inspect(missing)}"
    )

    retire(state, holder)
    pass(state, "work-item-create + assign + assignment-get round-trip (and not_found)")
  end

  # --- dispatch (happy path: opens the assignment + wakes the holder) --------
  # NOTE: the rumination REROUTE only fires for a SESSION caller (users don't
  # ruminate), which needs the caller session's own bearer token — session-token
  # plumbing this HTTP smoke doesn't do yet. The reroute is covered by unit tests
  # (assignments_test.exs). Here we drive dispatch as the user and assert it opens
  # the assignment atomically (the verb's wiring through router→dispatch→handler).
  defp check_dispatch_opens_assignment(state) do
    wi =
      ok!(state, "work-item-create", %{
        "title" => "smoke disp wi #{unique()}",
        "idempotencyKey" => "dwi-#{unique()}"
      })

    wi_id = wi["workItemId"] || wi["id"]

    holder =
      ok!(state, "spawn", %{
        "displayName" => "smoke-dh-#{unique()}",
        "idempotencyKey" => "dh-#{unique()}"
      })

    holder_key = get_in(holder, ["stream", "sessionKey"]) || holder["sessionKey"]

    res =
      ok!(state, "dispatch", %{
        "sessionKey" => holder_key,
        "subject" => "smoke fanout #{unique()}",
        "brief" => "ship the smoke feature",
        "workItemId" => wi_id,
        "idempotencyKey" => "d-#{unique()}"
      })

    asg_id = res["id"] || res["assignmentId"]

    assert(
      state,
      is_binary(asg_id),
      "dispatch (user caller) should open an assignment, got #{inspect(res)}"
    )

    got = ok!(state, "assignment-get", %{"assignmentId" => asg_id})

    # work-item-brackets-v1 (F7, amends work-item-v1): dispatch persists workItemId
    # like assign — a dispatched assignment is causally joined to its work item.
    assert(
      state,
      got["workItemId"] == wi_id,
      "dispatch must persist workItemId (work-item-brackets-v1 F7): #{inspect(got)}"
    )

    retire(state, holder)
    pass(state, "dispatch opens an assignment linked to its work item (brackets F7)")
  end

  # --- effort-without-effect: durable parent check-in and reassignment ----------
  # Run the smoke gateway with TIGHTBEAM_EFFORT_CHECKIN_HORIZON_MS=250 (or another
  # short value). The child is never prompted by this probe; its unavailable/idle
  # workdir is adjudicated only by the opening user.
  defp check_effort_without_effect(state) do
    u = unique()

    parent =
      ok!(state, "spawn", %{
        "displayName" => "smoke-effort-parent-#{u}",
        "idempotencyKey" => "effort-parent-#{u}"
      })

    parent_key = get_in(parent, ["stream", "sessionKey"]) || parent["sessionKey"]

    # A session principal needs a role before it may spawn/dispatch (same
    # pattern as the escalation check's coder).
    post(state, "role-create", %{"name" => "effort-parent-#{u}"})
    ok!(state, "role-bind", %{"name" => "effort-parent-#{u}", "sessionKey" => parent_key})

    parent_state =
      %{state | token: session_token(state, parent_key)} |> Map.put(:as_session, true)

    first_holder =
      ok!(parent_state, "spawn", %{
        "displayName" => "smoke-effort-a-#{u}",
        "idempotencyKey" => "effort-a-#{u}"
      })

    first_holder_key =
      get_in(first_holder, ["stream", "sessionKey"]) || first_holder["sessionKey"]

    first =
      ok!(parent_state, "dispatch", %{
        "sessionKey" => first_holder_key,
        "subject" => "effort smoke #{u}",
        "brief" => "Hold position for the parent check-in."
      })

    first_id = first["id"] || first["assignmentId"]
    request1 = await_effort_request!(parent_state, first_id, nil)
    request1_id = request1["id"]

    continued =
      ok!(parent_state, "effort-rule", %{"request" => request1_id, "action" => "continue"})

    assert(
      state,
      continued["decision"] == "continue",
      "effort-rule continue did not rule request: #{inspect(continued)}"
    )

    request2 = await_effort_request!(parent_state, first_id, request1_id)
    request2_id = request2["id"]

    revoked = ok!(parent_state, "revoke-assignment", %{"assignmentId" => first_id})

    assert(
      state,
      (revoked["state"] || get_in(revoked, ["assignment", "state"])) == "closed",
      "effort smoke revoke did not close old assignment: #{inspect(revoked)}"
    )

    old_request = ok!(parent_state, "decision-request", %{"request" => request2_id})

    assert(
      state,
      (old_request["decision_request"] || old_request["decisionRequest"])["status"] ==
        "superseded",
      "effort smoke revoke did not supersede old request: #{inspect(old_request)}"
    )

    second_holder =
      ok!(parent_state, "spawn", %{
        "displayName" => "smoke-effort-b-#{u}",
        "idempotencyKey" => "effort-b-#{u}"
      })

    second_holder_key =
      get_in(second_holder, ["stream", "sessionKey"]) || second_holder["sessionKey"]

    second =
      ok!(parent_state, "dispatch", %{
        "sessionKey" => second_holder_key,
        "subject" => "effort smoke replacement #{u}",
        "brief" => "Take over the reassigned smoke obligation."
      })

    second_id = second["id"] || second["assignmentId"]
    assert(state, second_id != first_id, "effort smoke re-dispatch reused the old assignment")

    replacement_request = await_effort_request!(parent_state, second_id, nil)

    assert(
      state,
      replacement_request["status"] == "open",
      "replacement dispatch did not arm a fresh bracket: #{inspect(replacement_request)}"
    )

    ok!(parent_state, "revoke-assignment", %{"assignmentId" => second_id})
    retire(state, first_holder)
    retire(state, second_holder)
    retire(state, parent)

    pass(
      state,
      "effort check-in: idle request → continue widens → fresh request → revoke supersedes → re-dispatch"
    )
  end

  defp await_effort_request!(state, assignment_id, prior_id) do
    deadline = System.monotonic_time(:millisecond) + 30_000
    await_effort_request!(state, assignment_id, prior_id, deadline)
  end

  defp await_effort_request!(state, assignment_id, prior_id, deadline) do
    requests = ok!(state, "decision-requests", %{})

    request =
      (requests["decision_requests"] || requests["decisionRequests"] || requests)
      |> List.wrap()
      |> Enum.find(fn candidate ->
        candidate["kind"] == "effort" and
          (candidate["assignment_id"] || candidate["assignmentId"]) == assignment_id and
          candidate["id"] != prior_id
      end)

    cond do
      is_map(request) ->
        request

      System.monotonic_time(:millisecond) >= deadline ->
        raise(
          "effort smoke timed out; run the gateway with a short " <>
            "TIGHTBEAM_EFFORT_CHECKIN_HORIZON_MS (2500 works; the deadline " <>
            "shares this config, so 250 rung-rotates requests away from the " <>
            "parent before it can rule)"
        )

      true ->
        Process.sleep(100)
        await_effort_request!(state, assignment_id, prior_id, deadline)
    end
  end

  # --- toplines: the board must reflect the work THIS run just did -----------
  # Runs LAST so every earlier group's material exists: work items, direct and
  # dispatched assignments, the flagship review chain, and their attests. Every
  # expectation is DERIVED — from this run's salt, from `work-item-get`'s DIRECT
  # assignments, and from the `attests` verb — so no number here can rot when an
  # earlier group changes what it does.
  defp check_toplines_board(state) do
    roster = ok!(state, "toplines", %{})

    assert(
      state,
      roster["edgeBasis"] == "concurrent_turn",
      "toplines must state its edge basis: #{inspect(roster["edgeBasis"])}"
    )

    assert(
      state,
      is_integer(get_in(roster, ["coverage", "attributionCutoff"])),
      "toplines must report its coverage cutoff: #{inspect(roster["coverage"])}"
    )

    mine = this_run(roster["items"] || [])

    # Non-vacuous: the earlier groups created work items under this run's salt,
    # so an empty database cannot pass this check.
    assert(
      state,
      mine != [],
      "toplines roster shows none of this run's items; titles were #{inspect(Enum.map(roster["items"] || [], & &1["title"]))}"
    )

    Enum.each(mine, &assert_toplines_node(state, &1))
    assert_toplines_state_filter(state, mine)
    assert_toplines_forest(state, mine)

    pass(
      state,
      "toplines board reflects this run: #{length(mine)} items, resolved membership, live progress clock, recorded creation context"
    )
  end

  defp assert_toplines_node(state, item) do
    id = item["id"]
    direct = ok!(state, "work-item-get", %{"workItemId" => id})["assignments"] || []
    resolved = item["assignments"]["open"] + item["assignments"]["closed"]

    # RESOLVED is a SUPERSET of DIRECT. A review assignment is pinned to no item
    # and reaches its story only through `reviewsAssignmentId`, so the flagship
    # item's resolved count exceeds its direct count — asserted as an inequality
    # rather than a literal so it survives a change to the flagship loop.
    assert(
      state,
      resolved >= length(direct),
      "toplines resolved membership (#{resolved}) is below DIRECT (#{length(direct)}) for #{id}"
    )

    assert(
      state,
      item["jobs"] >= length(Enum.uniq(Enum.map(direct, & &1["holderKey"]))),
      "toplines jobs (#{item["jobs"]}) undercounts the holders that ever held #{id}"
    )

    # The explicit assignment surface must map every DIRECT id back to THIS item
    # — the two surfaces reading the SAME membership function, on live rows.
    Enum.each(direct, fn asg ->
      selected = ok!(state, "topline", %{"assignments" => [asg["id"]]})

      assert(
        state,
        Enum.map(selected["items"] || [], & &1["id"]) == [id],
        "topline --assignments #{asg["id"]} should resolve to #{id}, got #{inspect(selected)}"
      )

      assert(
        state,
        (selected["noItem"] || []) == [],
        "a pinned assignment must not land in noItem: #{inspect(selected)}"
      )
    end)

    # Attests: the DIRECT sum is a FLOOR, not the total. The reviewer's verdict
    # lands on the review assignment, which no direct read of this item returns —
    # only RESOLVED attribution sees it.
    direct_attests =
      Enum.reduce(direct, 0, fn asg, acc ->
        acc + length(ok!(state, "attests", %{"assignmentId" => asg["id"]})["attests"] || [])
      end)

    assert(
      state,
      item["attests"]["total"] >= direct_attests,
      "toplines attests (#{item["attests"]["total"]}) undercounts #{id}'s direct attests (#{direct_attests})"
    )

    # This run just happened, so the progress clock cannot be claiming more quiet
    # time than the run has been alive. A clock anchored at the coverage cutoff
    # instead of at live activity fails here.
    budget = run_elapsed_ms() + 60_000

    assert(
      state,
      item["sinceProgressMs"] <= budget,
      "toplines sinceProgressMs #{item["sinceProgressMs"]} for #{id} exceeds this run's own age (#{budget}ms) — the progress clock is not tracking live activity"
    )

    assert_toplines_creation_context(state, item)
  end

  # THE TEETH. Cross-checks the reader against C1's ACTUAL columns on live rows,
  # read straight out of the gateway's own database — so this is total over all
  # four statuses and cannot go flaky on whether a turn happened to still be
  # running when a create landed.
  #
  # `unrecorded` on a row this run wrote would mean either C1 stopped stamping on
  # the live path or the reader misreads the bit. The old pre-C1 smoke database
  # showed every parent as `unrecorded`; a fresh run must not.
  defp assert_toplines_creation_context(state, item) do
    id = item["id"]
    {known, seq} = item_creation_columns(state, id)
    status = get_in(item, ["parent", "status"])

    assert(
      state,
      known == 1,
      "post-C1 row #{id} was written with createdContextKnown=#{inspect(known)}: C1 is not stamping on the live create path"
    )

    assert(
      state,
      get_in(item, ["creationContext", "recorded"]) == true,
      "row #{id} has known=1 but the reader reports #{inspect(item["creationContext"])}"
    )

    assert(
      state,
      get_in(item, ["creationContext", "turnSeq"]) == seq,
      "row #{id} carries createdInTurnSeq=#{inspect(seq)} but the reader reports #{inspect(get_in(item, ["creationContext", "turnSeq"]))}"
    )

    # The column decides the status, exactly: a null seq is the substrate saying it
    # LOOKED and nothing was running (the root signal, not a root classification),
    # and a stamped seq must yield an edge — `linked` when the recorded turn names
    # a caller-visible item, `from_turn` when it names none.
    expected =
      if is_nil(seq), do: ["no_turn_observed"], else: ["linked", "from_turn"]

    assert(
      state,
      status in expected,
      "row #{id} with createdInTurnSeq=#{inspect(seq)} must report one of #{inspect(expected)}; got #{inspect(status)}"
    )
  end

  # C1's own columns for one item, from the gateway's database — the same direct
  # read `session_token/2` already uses for things the wire does not surface.
  defp item_creation_columns(state, work_item_id) do
    db = Path.join(state.base_dir, "state.db")

    {out, 0} =
      System.cmd("sqlite3", [
        db,
        "SELECT createdContextKnown, COALESCE(createdInTurnSeq, '') FROM work_items " <>
          "WHERE id = #{sql_quote(work_item_id)}"
      ])

    case out |> String.trim() |> String.split("|") do
      [known, ""] -> {String.to_integer(known), nil}
      [known, seq] -> {String.to_integer(known), String.to_integer(seq)}
      _ -> fail(state, "no work_items row for #{work_item_id}")
    end
  end

  # `--state` must select exactly the subset the unfiltered roster already shows
  # in that state, in the same order — derived from the roster, never hardcoded.
  defp assert_toplines_state_filter(state, mine) do
    ids = Enum.map(mine, & &1["id"])

    Enum.each(Enum.uniq(Enum.map(mine, & &1["state"])), fn wanted ->
      expected = mine |> Enum.filter(&(&1["state"] == wanted)) |> Enum.map(& &1["id"])

      got =
        ok!(state, "toplines", %{"state" => wanted})["items"]
        |> Enum.map(& &1["id"])
        |> Enum.filter(&(&1 in ids))

      assert(
        state,
        got == expected,
        "toplines --state #{wanted} returned #{inspect(got)}, expected #{inspect(expected)}"
      )
    end)
  end

  # The forest carries the same nodes as the roster: nesting changes shape, never
  # membership.
  defp assert_toplines_forest(state, mine) do
    forest = ok!(state, "toplines", %{"tree" => true})
    nested = forest["roots"] |> List.wrap() |> Enum.flat_map(&flatten_node/1) |> this_run()

    assert(
      state,
      Enum.sort(Enum.map(nested, & &1["id"])) == Enum.sort(Enum.map(mine, & &1["id"])),
      "--tree node set diverges from the roster: #{inspect(Enum.map(nested, & &1["id"]))}"
    )
  end

  defp flatten_node(node) do
    [node | node["children"] |> List.wrap() |> Enum.flat_map(&flatten_node/1)]
  end

  defp this_run(items) do
    salt = Process.get(:salt, "")
    Enum.filter(items, &String.contains?(&1["title"] || "", salt))
  end

  # The salt IS the run's start second, so the run can bound its own clock
  # assertions without a literal. An unparseable salt yields 0, which only makes
  # the assertion stricter.
  defp run_elapsed_ms do
    case Integer.parse(Process.get(:salt, "")) do
      {started_at_s, _rest} -> max(System.os_time(:second) - started_at_s, 0) * 1000
      :error -> 0
    end
  end

  # --- helpers ---------------------------------------------------------------
  # Brackets hygiene: an open unrouted work item nags its owner's main session
  # (work-item-brackets-v1 bracket 1), so leftovers from a prior partial run flood
  # the main session with nag turns and identity-apply never finds a turn boundary.
  # Dispose anything a previous smoke left open; disposal cancels both bracket wakes.
  defp sweep_open_work_items(state) do
    items = ok!(state, "work-item-list", %{})["workItems"] || []

    items
    |> Enum.filter(&(&1["state"] == "open"))
    |> Enum.each(fn item ->
      got = ok!(state, "work-item-get", %{"workItemId" => item["id"]})

      for asg <- got["assignments"] || [], asg["state"] == "open" do
        ok!(state, "revoke-assignment", %{"assignmentId" => asg["id"]})
      end

      ok!(state, "work-item-close", %{"workItemId" => item["id"]})
    end)

    state
  end

  defp ok!(state, verb, params) do
    res = post(state, verb, params)

    if is_map(res) and Map.has_key?(res, "error") do
      fail(state, "#{verb} errored: #{inspect(res["error"])}")
    end

    res["result"] || res
  end

  # Verbs whose sessionKey/role/userId is a router-extracted BODY-ROOT target.
  # Other verbs (role-bind, role-rm, …) carry sessionKey as a normal param.
  @target_verbs ~w(assign dispatch wake retire critical assignments cancel tune)

  defp post(state, verb, params) do
    params =
      if verb == "spawn",
        do: Tightbeam.FeatureSmokePlan.explicit_spawn(state.leg, params),
        else: params

    {as_key, params} = Map.pop(params, "asSession")

    {target, params} =
      if verb in @target_verbs,
        do: Map.split(params, ["sessionKey", "role", "userId"]),
        else: {%{}, params}

    body =
      %{"verb" => verb, "params" => params}
      |> Map.merge(target)
      |> then(fn b ->
        cond do
          # Session-authenticated: the session's own bearer token IS the principal.
          Map.get(state, :as_session) -> b
          as_key -> Map.put(b, "asSession", as_key)
          true -> Map.put(b, "asUser", @owner)
        end
      end)

    url = "http://127.0.0.1:#{state.port}/agent/dispatch"

    args = [
      "-sS",
      "--max-time",
      "30",
      "-o",
      "-",
      "-w",
      "\n%{http_code}",
      "-H",
      "Authorization: Bearer #{state.token}",
      # The wire refuses a caller that will not say what it is (42f7bd5). This script IS a
      # CLI client, so it states the version the gateway was built from rather than a
      # literal — a pinned string here would pass while claiming something untrue.
      "-H",
      "x-tightbeam-cli-version: #{Tightbeam.CliCompatibility.required_version()}",
      "-X",
      "POST",
      "-H",
      "Content-Type: application/json",
      "-d",
      JSON.encode!(body),
      url
    ]

    case System.cmd("curl", args, stderr_to_stdout: true) do
      {out, 0} ->
        {head, [code]} = out |> String.split("\n") |> Enum.split(-1)
        payload = Enum.join(head, "\n")

        case JSON.decode(payload) do
          {:ok, v} -> v
          _ -> %{"error" => %{"code" => "bad_json", "http" => code, "raw" => payload}}
        end

      {out, rc} ->
        fail(state, "curl failed rc=#{rc}: #{out}")
    end
  end

  defp retire(state, spawn) do
    key = get_in(spawn, ["stream", "sessionKey"]) || spawn["sessionKey"]
    if is_binary(key), do: post(state, "retire", %{"sessionKey" => key})
  end

  defp leaf_entries(root), do: leaf_entries(root, root, [])

  defp leaf_entries(path, root, entries) do
    path
    |> File.ls!()
    |> Enum.reduce(entries, fn name, acc ->
      child = Path.join(path, name)

      case File.lstat!(child).type do
        :directory ->
          case File.ls!(child) do
            [] -> [Path.relative_to(child, root) <> "/" | acc]
            _ -> leaf_entries(child, root, acc)
          end

        _ ->
          [Path.relative_to(child, root) | acc]
      end
    end)
  end

  defp await_materialized_skills!(state, cwd, skills) do
    deadline = System.monotonic_time(:millisecond) + 30_000
    await_materialized_skills!(state, cwd, skills, deadline)
  end

  defp await_materialized_skills!(state, cwd, skills, deadline) do
    observed =
      if(File.dir?(cwd), do: leaf_entries(cwd), else: [])
      |> Enum.filter(fn relative ->
        Path.basename(relative) == "SKILL.md" and
          String.starts_with?(Path.basename(Path.dirname(relative)), "tightbeam__")
      end)
      |> Map.new(fn relative ->
        path = Path.join(cwd, relative)
        {Path.basename(Path.dirname(relative)), {path, File.read!(path)}}
      end)

    missing =
      Enum.reject(skills, fn {name, body} ->
        match?({_, ^body}, observed["tightbeam__#{name}"])
      end)

    cond do
      missing == [] ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        Enum.each(missing, fn {name, _body} ->
          case observed["tightbeam__#{name}"] do
            nil ->
              assert(
                state,
                false,
                "local deployment elected skill missing under #{cwd}: tightbeam__#{name}/SKILL.md"
              )

            {path, _bytes} ->
              assert(state, false, "local deployment elected skill bytes differ: #{path}")
          end
        end)

      true ->
        Process.sleep(100)
        await_materialized_skills!(state, cwd, skills, deadline)
    end
  end

  defp await_turn_boundary!(state, session_key) do
    deadline = System.monotonic_time(:millisecond) + 30_000
    await_turn_boundary!(state, session_key, deadline)
  end

  defp await_turn_boundary!(state, session_key, deadline) do
    db = Path.join(state.base_dir, "state.db")

    {out, 0} =
      System.cmd("sqlite3", [
        db,
        "SELECT count(*) FROM turns WHERE sessionKey = #{sql_quote(session_key)} AND status IN ('queued','running')"
      ])

    cond do
      String.trim(out) == "0" ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        assert(state, false, "local deployment turn did not settle for CWD: #{session_key}")

      true ->
        Process.sleep(100)
        await_turn_boundary!(state, session_key, deadline)
    end
  end

  defp assert(state, true, _msg), do: state
  defp assert(state, _false, msg), do: fail(state, msg)

  defp pass(state, label) do
    IO.puts("  PASS [#{state.leg.wire_name}] #{label}")
    %{state | pass: state.pass + 1}
  end

  defp fail(_state, msg) do
    raise Failure, message: msg
  end

  defp finish_leg(state) do
    IO.puts("feature-smoke leg #{state.leg.wire_name}: #{state.pass} checks PASS")
    :ok
  end

  # Say what this run covers BEFORE it runs, and say it again in the words a scorecard
  # needs. A narrowed run is a legitimate answer to a narrow question, but only while it
  # is legible as narrow — an operator reading "all checks PASS" with no statement of
  # scope has been told a full-coverage story the run did not earn. The tier map's verdict
  # for this shape is INCOMPLETE(parity), so the line names it in those terms.
  defp announce_selection!(%{run: [], filtered: filtered}) do
    raise Failure,
      message: "feature-smoke selected no legs (all filtered: #{Enum.join(filtered, ", ")})"
  end

  defp announce_selection!(%{run: run, filtered: []}) do
    IO.puts("feature-smoke legs: #{Enum.join(run, ", ")} (every registered leg — full parity)")
  end

  defp announce_selection!(%{run: run, filtered: filtered}) do
    IO.puts(
      "feature-smoke legs: #{Enum.join(run, ", ")} — FILTERED, holding back " <>
        "#{Enum.join(filtered, ", ")}. This run is INCOMPLETE(parity) by design and proves " <>
        "nothing about the leg(s) it did not run."
    )
  end

  defp unique, do: "#{Process.get(:salt, "")}#{System.unique_integer([:positive])}"
end

try do
  if System.get_env("TIGHTBEAM_SMOKE_HOME_CASES_ONLY") == "1",
    do: FeatureSmoke.run_home_cases!(),
    else: FeatureSmoke.run()
rescue
  error in FeatureSmoke.Failure ->
    IO.puts("  FAIL  #{error.message}")
    System.halt(1)
end
