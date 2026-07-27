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

defmodule FeatureSmoke do
  defmodule Failure do
    defexception [:message]
  end

  @owner System.get_env("TIGHTBEAM_SMOKE_OWNER") || "mike"

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
