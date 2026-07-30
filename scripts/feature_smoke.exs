# Feature smoke — walks each new verb end-to-end against a RUNNING gateway
# (full HTTP + router + dispatch + handler + DB stack; the integration path
# unit tests don't cover). Reads port+token from <base_dir>/gateway.json.
#
#   TIGHTBEAM_BASE_DIR=~/.tightbeam-beam \
#   TIGHTBEAM_SMOKE_MODEL_CLAUDE='claude-sonnet-5[medium]' \
#   TIGHTBEAM_SMOKE_MODEL_CODEX='gpt-5.6-sol[medium]' \
#   mix run --no-start scripts/feature_smoke.exs
#
# Runs one explicit spawn/dispatch leg per Harness.all/0 entry and exits
# non-zero on the first failed assertion. Every new roadmap feature that is
# user-callable should get a check here (see the smoke-coverage practice).
#
# ONE command runs BOTH legs; there is no per-leg invocation (tier-map GAP-3 —
# FeatureSmokePlan.legs/1 maps over the compile-time registry and raises without
# a model for each). That is not a limit for the gibson gate, which requires both
# legs green anyway (artifact-carrier-proposal-v1 §7.3).
#
# The final group, artifact-record + completion-gate closure, additionally needs
# the org's identity/rules to carry the shipped verification statutes
# (completion-requires-verification, completion-requires-results-artifact) AND a
# `coder` archetype. Rules load once at gateway BOOT, so an org whose law changed
# under a running gateway must be rebooted before the run. On shrdlu that means
# the eb0ea2b org-law workaround must be REVERTED first: with it installed the
# artifact statute never denies and the group fails at its third denial, which is
# exactly what keeps that leg falsifiable.

defmodule FeatureSmoke do
  defmodule Failure do
    defexception [:message]
  end

  @owner System.get_env("TIGHTBEAM_SMOKE_OWNER") || "mike"

  # How long the artifact-closure journey waits for the holder's REAL harness turns to
  # land the PROMPTED record.
  #
  # The arithmetic, because it has to cover two turns and not one: the statute's own
  # remedy wake is dispatched before this group's explicit wake, so the prompted turn is
  # QUEUED BEHIND it on the holder's lane and both must finish. At the 180s per-turn
  # worst case the client-e2e driver already budgets (`ClientE2E.@default_turn_timeout_ms`)
  # that is 2 x 180s = 360s, plus 60s of slack for lane queueing and adapter spawn. A
  # budget sized for one turn expires while the substrate is behaving correctly, which is
  # the worst kind of red.
  @artifact_turn_budget_ms 420_000

  # How long a remedy episode gets to reach a status. The transition rides the attest
  # that provoked it, so this covers scheduling, not model time.
  @episode_settle_ms 30_000

  def run do
    base_dir = System.get_env("TIGHTBEAM_BASE_DIR") || Path.expand("~/.tightbeam-beam")
    install_smoke_rule!(base_dir)
    gw = base_dir |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()
    Process.put(:salt, Integer.to_string(System.os_time(:second)) <> "-")

    Tightbeam.FeatureSmokePlan.legs(Tightbeam.Harness.all())
    |> Enum.each(fn leg ->
      IO.puts("\nfeature-smoke leg #{leg.wire_name} model=#{leg.model}")
      preflight!(leg, base_dir)

      %{
        port: gw["port"],
        token: gw["cliToken"],
        base_dir: base_dir,
        pass: 0,
        leg: leg,
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
      |> check_artifact_record_closure()
      |> finish_leg()
    end)
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

    session =
      ok!(state, "spawn", %{
        "archetype" => "reviewer",
        "displayName" => "smoke-local-deploy-#{unique()}",
        "idempotencyKey" => "local-deploy-#{unique()}"
      })

    session_key = get_in(session, ["stream", "sessionKey"]) || session["sessionKey"]
    home = Tightbeam.Homes.home_path(state.base_dir, machine, harness)
    expected_home = MapSet.new(Tightbeam.Homes.owned_entries(harness))
    before_home = if File.dir?(home), do: MapSet.new(leaf_entries(home)), else: MapSet.new()
    sentinel = Path.join(home, ".feature-smoke-durable-#{unique()}")

    cwd =
      Tightbeam.Placement.workdir_path(%{base_dir: state.base_dir}, %{
        session_key: session_key,
        host: machine
      })

    try do
      redeploy!(state, session_key)

      assert(state, File.dir?(home), "local deployment HOME missing: #{home}")

      actual_home = home |> leaf_entries() |> MapSet.new()

      expected_home
      |> MapSet.difference(actual_home)
      |> Enum.each(fn relative ->
        assert(
          state,
          false,
          "local deployment HOME missing owned path: #{Path.join(home, relative)}"
        )
      end)

      actual_home
      |> MapSet.difference(before_home)
      |> MapSet.difference(expected_home)
      |> Enum.each(fn relative ->
        assert(
          state,
          false,
          "local deployment HOME contains stray path: #{Path.join(home, relative)}"
        )
      end)

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
        %{"title" => "smoke agent-created wi #{unique()}", "idempotencyKey" => "awi-#{unique()}"}
      )

      await_turn_boundary!(state, session_key)

      sentinel_bytes = "durable-local-deployment-#{unique()}\n"
      File.write!(sentinel, sentinel_bytes)
      redeploy!(state, session_key)

      assert(
        state,
        File.read(sentinel) == {:ok, sentinel_bytes},
        "local deployment durable state changed during redelivery: #{sentinel}"
      )
    after
      File.rm(sentinel)
      retire(state, session)
    end

    pass(
      state,
      "local deployment HOME path + exact owned projection + cwd skills + no strays + durable redelivery"
    )
  end

  defp install_smoke_rule!(base_dir) do
    source = Path.expand("fixtures/smoke-escalation-probe.toml", __DIR__)
    target = Path.join([base_dir, "identity", "rules", "smoke-escalation-probe.toml"])
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source, target)

    # rules/ lives inside the identity repo, and the identity seam requires a clean
    # working tree. An uncommitted fixture wedges every identity verb, so commit it.
    dir = Path.join(base_dir, "identity")
    {_, 0} = System.cmd("git", ["add", "--", "rules/smoke-escalation-probe.toml"], cd: dir)

    case System.cmd("git", ["diff", "--cached", "--quiet"], cd: dir) do
      {_, 0} ->
        :ok

      _ ->
        {_, 0} = System.cmd("git", ["commit", "-m", "feature-smoke: escalation probe"], cd: dir)
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
  # Proves the whole enforcement spine live over HTTP: a coder attesting completion
  # WITHOUT a reviewed-clean verdict is not denied — the substrate assigns a reviewer
  # (the remedy), blocks the completion, and self-releases once the review lands.
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
      "flagship reviewer-loop enforced end-to-end: blocked → reviewer assigned → verdict → completes"
    )
  end

  # --- T2a final journey: artifact-record + completion-gate closure --------------
  # artifact-carrier-proposal-v1 §7.3, the leg the gibson activation gate names.
  #
  # This is the ONLY place in the tree where `artifact-record` runs from the real CLI
  # inside a real harness turn, which is the only way the substrate-reserved PreToolUse
  # observation (`Tightbeam.Rails.observation_entry/0`) can fire at all. Every other
  # artifact assertion we have drives the writer directly and therefore cannot see the
  # hook.
  #
  # WHICH HALF OF CODEX IS ACTUALLY UNPROVEN. Codex as a verdict FILER is proven on this
  # gateway — the live shrdlu walk filed reviewed-clean over codex twice, cleanly. What has
  # never been proven is codex as the artifact RECORDER: whether a codex-hosted holder's
  # `artifact-record` lands `tool-call-observed`, which rides the trust-gated
  # `CODEX_CONFIG` hook seam and rests on the 0.145.0 spike alone (§5.2). The HOLDER is
  # therefore always the leg's own harness, the evidence class is asserted PER LEG, and
  # the codex leg's class assertion is the single most load-bearing line in this file.
  #
  # The chain, in the order the statutes deny (walked live on shrdlu, 2026-07-30):
  #
  #   attest completion  → rule_denied completion-requires-review
  #   reviewed-clean     ← a session on the OTHER registered harness
  #   attest completion  → rule_denied completion-requires-verification
  #   verified           ← the holder itself; the statute reads `assignment.verdicts`,
  #                        not the independent set, so the holder may file its own
  #   attest completion  → rule_denied completion-requires-results-artifact
  #   REAL CLI turn      → tightbeam artifact-record, over the wire, from the workdir
  #   attest completion  → PASSES; the assignment closes `completed` and the artifact
  #                        statute's remedy episode goes `live` → `closed` on its own
  defp check_artifact_record_closure(state) do
    u = unique()
    # The salted filename is how the prompted record is told apart from anything the
    # statute's own remedy turn may have recorded first. The remedy turn cannot produce it
    # because the prompt carrying the salt has not been delivered when that turn runs.
    marker = "results-#{u}.md"
    reviewer_leg = independent_leg(state)
    preflight_independent!(state, reviewer_leg)

    post(state, "role-create", %{"name" => "reviewer"})

    # Spawning through the OTHER leg is the whole cross-harness move: `post/3` runs every
    # spawn through `FeatureSmokePlan.explicit_spawn/2`, which pins harness and model from
    # `state.leg`, so swapping the leg for this one call is enough. The role is bound
    # because a session acting under its OWN credential needs one for the router to derive
    # an origin, not because anything here waits on the review remedy to target it.
    reviewer =
      ok!(%{state | leg: reviewer_leg}, "spawn", %{
        "displayName" => "smoke-artifact-reviewer-#{u}",
        "idempotencyKey" => "arv-#{u}"
      })

    reviewer_key = get_in(reviewer, ["stream", "sessionKey"]) || reviewer["sessionKey"]
    ok!(state, "role-bind", %{"name" => "reviewer", "sessionKey" => reviewer_key})
    reviewer_tok = session_token(state, reviewer_key)

    wi =
      ok!(state, "work-item-create", %{
        "title" => "artifact closure #{u}",
        "idempotencyKey" => "arwi-#{u}"
      })

    wi_id = wi["workItemId"] || wi["id"]

    # `holder_archetype in ["coder"]` is a deny_when condition on BOTH verification
    # statutes, so the holder must actually BE a coder. A default-archetype holder walks
    # straight past them and the journey would pass while proving nothing.
    coder =
      ok!(state, "spawn", %{
        "archetype" => "coder",
        "displayName" => "smoke-artifact-coder-#{u}",
        "idempotencyKey" => "arcd-#{u}"
      })

    coder_key = get_in(coder, ["stream", "sessionKey"]) || coder["sessionKey"]
    post(state, "role-create", %{"name" => "coder-artifact-#{u}"})
    ok!(state, "role-bind", %{"name" => "coder-artifact-#{u}", "sessionKey" => coder_key})
    coder_tok = session_token(state, coder_key)

    asg =
      ok!(state, "assign", %{
        "sessionKey" => coder_key,
        "subject" => "artifact impl #{u}",
        "workItemId" => wi_id,
        "idempotencyKey" => "aras-#{u}"
      })

    asg_id = asg["id"] || asg["assignmentId"]

    complete = fn ->
      post_as(state, coder_tok, "attest", %{"assignmentId" => asg_id, "kind" => "completion"})
    end

    try do
      # 1. Review gate.
      denied!(state, "completion-requires-review", asg_id, complete)

      # The review assignment is opened EXPLICITLY rather than taken from the statute's
      # remedy. Depending on a remedy-created assignment makes the group hostage to
      # whether `target_role` resolves in the org under test — on shrdlu the reviewer role
      # is bound to a retired session and the remedy silently no-ops — and this group is
      # not here to test the review remedy, which the flagship group already covers.
      #
      # Opened by the OWNER, and that is load-bearing rather than incidental:
      # `Assignments.commissioned_review_authors/3` only counts a verdict when the review's
      # `openedBySession` differs from the holder (a user-principal open leaves it NULL)
      # AND the verdict's author is the review's own holder. A review the coder opened for
      # itself yields no independent verdict and the gate would never release.
      review =
        ok!(state, "assign", %{
          "sessionKey" => reviewer_key,
          "subject" => "review of assignment #{asg_id}",
          "reviews" => asg_id,
          "idempotencyKey" => "arrev-#{u}"
        })

      v =
        post_as(state, reviewer_tok, "attest", %{
          "assignmentId" => review["id"] || review["assignmentId"],
          "kind" => "verdict",
          "verdictKind" => "reviewed-clean"
        })

      assert(
        state,
        not (is_map(v) and Map.has_key?(v, "error")),
        "artifact closure: cross-harness reviewed-clean from #{reviewer_leg.wire_name} failed: #{inspect(v)}"
      )

      # 2. Verification gate, now reachable because the review gate stopped denying.
      denied!(state, "completion-requires-verification", asg_id, complete)

      verified =
        post_as(state, coder_tok, "attest", %{
          "assignmentId" => asg_id,
          "kind" => "verdict",
          "verdictKind" => "verified"
        })

      assert(
        state,
        not (is_map(verified) and Map.has_key?(verified, "error")),
        "artifact closure: holder verified verdict failed: #{inspect(verified)}"
      )

      # 3. The artifact gate — the statute this whole journey exists for. Before the
      # carrier landed, `artifact-record` refused unconditionally from a real CLI client
      # and this deny was unsatisfiable, which is the loop `eb0ea2b` worked around on
      # shrdlu. If that workaround is still installed in the org under test, THIS
      # assertion is what fails, which is what keeps the shrdlu leg falsifiable
      # (§7.3 gate item 4).
      denied!(state, "completion-requires-results-artifact", asg_id, complete)

      # This remedy IS depended on, unlike the review one, and the difference is the target:
      # it wakes `{holder_key}` directly, so there is no `target_role` to resolve and none
      # of the role-binding fragility that makes remedy-created assignments a bad oracle.
      # The episode going live is also the fail-before that makes the closure below mean
      # something.
      await_episode_status!(state, "completion-requires-results-artifact", asg_id, "live")

      # 4. The real turn. The statute's own remedy has already woken the holder, and that
      # wake may satisfy the gate by itself — but its prompt names neither the work item
      # (which `Artifacts.record/2` REQUIRES) nor the direct-invocation constraint the
      # observation depends on, so relying on it would make the leg's central assertion a
      # coin flip on what the agent inferred. This wake queues behind it and says both
      # things exactly. Whichever turn records first, the row is asserted the same way.
      ok!(state, "wake", %{
        "sessionKey" => coder_key,
        "prompt" => artifact_prompt(u, marker, wi_id, asg_id),
        "idempotencyKey" => "arwake-#{u}"
      })

      {prompted, reports} = await_prompted_report!(state, coder_key, wi_id, asg_id, marker)
      classes = Enum.map(reports, & &1["recordedTurnEvidence"])

      # The null-vs-non-null coupling, on EVERY row. Pure substrate: `tool-call-observed`
      # and `session-concurrent` each name a turn and must carry its id, `none` names no
      # turn and must carry NULL. A row that breaks the pairing is a carrier defect
      # regardless of what the agent chose to run.
      Enum.each(reports, fn row ->
        assert(
          state,
          row["recordedTurnEvidence"] in ~w(tool-call-observed session-concurrent none),
          "artifact closure: recordedTurnEvidence outside its closed domain: #{inspect(row)}"
        )

        if row["recordedTurnEvidence"] == "none" do
          assert(
            state,
            is_nil(row["recordedMessageId"]),
            "artifact closure: evidence 'none' must carry a NULL recordedMessageId: #{inspect(row)}"
          )
        else
          assert(
            state,
            is_binary(row["recordedMessageId"]),
            "artifact closure: evidence #{inspect(row["recordedTurnEvidence"])} names a turn but recordedMessageId is NULL: #{inspect(row)}"
          )
        end
      end)

      # THE assertion this journey exists to force, per leg. It is exact twice over: on
      # the CLASS, because both registered harnesses project the observation entry
      # unconditionally (`Rails.hook_settings/0`) and the prompt forbids the
      # script-wrapping that §1.3 names as the legitimate way to miss it; and on the ROW,
      # because it is asserted against the artifact this group's own prompt produced
      # rather than against whichever report happened to exist. "Some row was observed"
      # would green on a remedy-produced record while the prompted one landed
      # `session-concurrent`, which is precisely the outcome the codex leg exists to
      # catch. On that leg this line IS the proof that converts §5.2 from spike evidence
      # into a live one.
      assert(
        state,
        prompted["recordedTurnEvidence"] == "tool-call-observed",
        "artifact closure: the prompted report #{marker} reads " <>
          "#{inspect(prompted["recordedTurnEvidence"])}, not tool-call-observed — the reserved " <>
          "PreToolUse observation did not fire for the #{state.leg.wire_name} holder, so this " <>
          "leg's record rests on concurrency rather than observation. Read it as the RECORDER " <>
          "side of #{state.leg.wire_name} failing; the filer side is a separate question this " <>
          "group does not test. Row: #{inspect(prompted)}. All classes seen: #{inspect(classes)}"
      )

      # NOTHING here asserts artifact lifecycle `state`. Retirement moves rows
      # in-workspace → released, and the gate is state-blind on purpose
      # (`Artifacts.recorded_kinds/3` reads neither state nor the turn edge), so a state
      # assertion would be a brittle oracle for a fact the substrate does not gate on.
      # Kind and provenance are the whole contract. Do not add one.
      #
      # Nor is anything re-asserted that the selection already settled: `createdBySession`
      # and `workItemId` are query filters, and `originPath` is how `prompted` was found —
      # a row carrying this marker at all is the proof that the real CLI carried this
      # group's `--path` argument through to the substrate.

      # 5. Closure. The gate releases, and the assignment reaches `closed`/`completed`
      # whether this attest or the holder's own turn filed the completion — both are the
      # same substrate fact, and neither `surrendered` nor a still-open assignment can be
      # mistaken for it. `surrendered` here is the roadmap 0a2 failure: an agent escaping
      # an unsatisfiable gate by abandoning the work permanently.
      done = complete.()
      final = ok!(state, "assignment-get", %{"assignmentId" => asg_id})

      assert(
        state,
        final["state"] == "closed" and final["outcome"] == "completed",
        "artifact closure: with the report recorded, completion should close #{asg_id} as completed; " <>
          "assignment reads state=#{inspect(final["state"])} outcome=#{inspect(final["outcome"])} " <>
          "(attest returned #{inspect(done)})"
      )

      await_episode_status!(state, "completion-requires-results-artifact", asg_id, "closed")

      pass(
        state,
        "artifact-record + completion-gate closure: review(#{reviewer_leg.wire_name}) → " <>
          "verified → artifact denied → real CLI record #{inspect(classes)} → completes, episode closed"
      )
    after
      # EVERY assertion about an assignment outcome must stay above this line. `retire`
      # REVOKES a session's open assignments, so a retired holder reads `revoked` — which
      # is a distinct outcome from the `surrendered` the 0a2 oracle looks for, and an
      # assertion moved below here would read teardown's revocation as the journey's
      # result. Retirement also moves this holder's artifacts in-workspace → released,
      # which is the other reason nothing above asserts artifact lifecycle state.
      retire(state, reviewer)
      retire(state, coder)
    end
  end

  # The reviewer runs on a DIFFERENT registered harness wherever the registry offers one.
  # This buys no extra enforcement — `assignment.independent_verdict_kinds` reads sessions,
  # never harnesses — and it costs nothing either: `FeatureSmokePlan.legs/1` RAISES unless
  # every registered harness has a model, and T2a already requires a live credential for
  # each, so the other leg's material is a precondition of the run rather than a new one.
  # What it buys is the cross-harness verdict path the live walk exercised.
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
  defp artifact_prompt(u, marker, wi_id, asg_id) do
    """
    Substrate smoke check #{u} on assignment #{asg_id}. Do exactly these two steps.

    1. Write a file named #{marker} in your current working directory containing
       one line: smoke verification results #{u}

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
  # Correlation is by ref plus a watermark taken immediately before the call — the
  # `since_id` shape `EventLog.rail_denials/3` already uses — so an earlier step's denial
  # of the same statute on the same assignment cannot satisfy a later one. Taking the
  # watermark inside this function is what keeps it honest: there is no window in which a
  # caller can drift the two apart.
  defp denied!(state, statute, assignment_id, attempt) when is_function(attempt, 0) do
    watermark = events_watermark(state)
    res = attempt.()

    assert(
      state,
      get_in(res, ["error", "code"]) == "rule_denied",
      "artifact closure: completion should be denied by #{statute}, got #{inspect(res)}"
    )

    recorded = recorded_denial(state, watermark, assignment_id)

    assert(
      state,
      recorded == statute,
      "artifact closure: the denial recorded against #{assignment_id} is #{inspect(recorded)}, " <>
        "not #{inspect(statute)}. The wire said #{inspect(res)}, but the wire cannot name a " <>
        "statute — if `recorded` is nil the denial row is missing entirely (best-effort " <>
        "append, or a non-statute refusal), and if it names another statute the chain is " <>
        "not where this group thinks it is."
    )
  end

  defp events_watermark(state) do
    state |> sqlite("SELECT COALESCE(MAX(id), 0) FROM events") |> String.to_integer()
  end

  defp recorded_denial(state, watermark, assignment_id) do
    case sqlite(state, """
         SELECT json_extract(payload, '$.rule') FROM events
         WHERE kind = 'denied' AND id > #{watermark} AND json_valid(payload)
           AND json_extract(payload, '$.ref') = #{sql_quote(assignment_id)}
         ORDER BY id DESC LIMIT 1
         """) do
      "" -> nil
      rule -> rule
    end
  end

  defp sqlite(state, sql) do
    {out, 0} = System.cmd("sqlite3", [Path.join(state.base_dir, "state.db"), sql])
    String.trim(out)
  end

  # Wait for THE PROMPTED artifact, not for any artifact.
  #
  # The statute's remedy wake runs first and may well record a report of its own. Taking
  # the first report to appear would run the provenance assertions against a row this
  # group never asked for, before the prompted turn has even started — a race whose green
  # and red are both meaningless. The prompted row is identified by the salted marker in
  # its origin path, which the remedy turn cannot know because the prompt carrying it has
  # not been delivered yet.
  #
  # Matched on BASENAME rather than on the exact string. The CLI forwards `--path`
  # verbatim (`dispatch.rs` sends `originPath` as given), so the row holds whatever form
  # the holder typed, and `./results-x.md` or an absolute path is the same artifact by any
  # honest reading. The salt is what makes the match specific; the path's shape is not.
  defp await_prompted_report!(state, session_key, work_item_id, assignment_id, marker) do
    await_prompted_report!(
      state,
      session_key,
      work_item_id,
      assignment_id,
      marker,
      System.monotonic_time(:millisecond) + @artifact_turn_budget_ms
    )
  end

  defp await_prompted_report!(state, session_key, work_item_id, assignment_id, marker, deadline) do
    reports =
      state
      |> ok!("artifacts", %{
        "workItemId" => work_item_id,
        "sessionKey" => session_key,
        "kind" => "report"
      })
      |> Map.get("artifacts", [])
      |> List.wrap()

    prompted =
      Enum.find(reports, fn row -> Path.basename(row["originPath"] || "") == marker end)

    cond do
      prompted ->
        {prompted, reports}

      # An abandoned assignment is DETECTED AND NAMED, never waited out. This loop's
      # deadline is seven minutes of real model time, and a holder that surrendered will
      # never record — so without this the roadmap 0a2 hazard reads as a confusing timeout
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
          "artifact closure: the holder never recorded #{marker} on #{work_item_id} within " <>
            "#{div(@artifact_turn_budget_ms, 1000)}s, with #{assignment_id} still open. Either " <>
            "the real CLI `artifact-record` refused (the §1.1 defect this carrier fixed) or the " <>
            "holder's turns never ran it. Reports seen meanwhile, none of them this group's: " <>
            "#{inspect(Enum.map(reports, & &1["originPath"]))}"
        )

      true ->
        Process.sleep(1_000)

        await_prompted_report!(
          state,
          session_key,
          work_item_id,
          assignment_id,
          marker,
          deadline
        )
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

  defp redeploy!(state, session_key) do
    ok!(state, "tune", %{
      "sessionKey" => session_key,
      "setting" => "set_harness",
      "harness" => state.leg.wire_name,
      "model" => state.leg.model
    })
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

  defp unique, do: "#{Process.get(:salt, "")}#{System.unique_integer([:positive])}"
end

try do
  FeatureSmoke.run()
rescue
  error in FeatureSmoke.Failure ->
    IO.puts("  FAIL  #{error.message}")
    System.halt(1)
end
