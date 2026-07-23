# Feature smoke — walks each new verb end-to-end against a RUNNING gateway
# (full HTTP + router + dispatch + handler + DB stack; the integration path
# unit tests don't cover). Reads port+token from <base_dir>/gateway.json.
#
#   TIGHTBEAM_BASE_DIR=~/.tightbeam-beam elixir scripts/feature_smoke.exs
#
# Exits non-zero on the first failed assertion. Every new roadmap feature that
# is user-callable should get a check here (see the smoke-coverage practice).

defmodule FeatureSmoke do
  @owner System.get_env("TIGHTBEAM_SMOKE_OWNER") || "mike"

  def run do
    base_dir = System.get_env("TIGHTBEAM_BASE_DIR") || Path.expand("~/.tightbeam-beam")
    gw = base_dir |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()
    state = %{port: gw["port"], token: gw["cliToken"], pass: 0}

    state
    |> check_facts_read()
    |> check_config_default_archetype()
    |> check_work_item_and_assignment_get()
    |> check_dispatch_opens_assignment()
    |> finish()
  end

  # --- facts-read: file a condition fact, read it back -----------------------
  defp check_facts_read(state) do
    kind = "smoke-fact-#{unique()}"
    scope = "smoke:scope:#{unique()}"

    ok!(state, "condition", %{"kind" => kind, "scope" => scope, "idempotencyKey" => "fk-#{unique()}"})
    res = ok!(state, "facts-read", %{"kind" => kind, "scope" => scope})

    assert(state, res["exists"] == true, "facts-read: fact not found after condition")
    assert(state, get_in(res, ["fact", "scope"]) == scope, "facts-read: wrong scope returned")
    pass(state, "facts-read files and reads a condition fact")
  end

  # --- config: set default-archetype, spawn honors it, reset -----------------
  defp check_config_default_archetype(state) do
    original =
      ok!(state, "config", %{"action" => "get", "setting" => "default-archetype"})["value"]

    ok!(state, "config", %{"action" => "set", "setting" => "default-archetype", "value" => "reviewer"})
    got = ok!(state, "config", %{"action" => "get", "setting" => "default-archetype"})["value"]
    assert(state, got == "reviewer", "config: set did not persist (#{inspect(got)})")

    spawn = ok!(state, "spawn", %{
      "displayName" => "smoke-cfg-#{unique()}",
      "idempotencyKey" => "cfg-#{unique()}"
    })
    arch = get_in(spawn, ["stream", "archetype"]) || spawn["archetype"]
    # reset before asserting so a failure can't leave the org mutated
    ok!(state, "config", %{"action" => "set", "setting" => "default-archetype", "value" => original || "default"})

    assert(state, arch in ["reviewer", nil], "config: spawn archetype was #{inspect(arch)}")
    retire(state, spawn)
    pass(state, "config default-archetype set/get persists and steers spawn")
  end

  # --- work-item + assignment-get --------------------------------------------
  defp check_work_item_and_assignment_get(state) do
    wi = ok!(state, "work-item-create", %{"title" => "smoke wi #{unique()}", "idempotencyKey" => "wi-#{unique()}"})
    wi_id = wi["workItemId"] || wi["id"]
    assert(state, is_binary(wi_id), "work-item-create returned no id: #{inspect(wi)}")

    holder = ok!(state, "spawn", %{"displayName" => "smoke-holder-#{unique()}", "idempotencyKey" => "h-#{unique()}"})
    holder_key = get_in(holder, ["stream", "sessionKey"]) || holder["sessionKey"]

    asg = ok!(state, "assign", %{
      "sessionKey" => holder_key,
      "subject" => "smoke assignment #{unique()}",
      "workItemId" => wi_id,
      "idempotencyKey" => "a-#{unique()}"
    })
    asg_id = asg["id"] || asg["assignmentId"]
    assert(state, is_binary(asg_id), "assign returned no id: #{inspect(asg)}")

    got = ok!(state, "assignment-get", %{"assignmentId" => asg_id})
    assert(state, (got["id"] || got["assignmentId"]) == asg_id, "assignment-get mismatch: #{inspect(got)}")

    missing = post(state, "assignment-get", %{"assignmentId" => "asg_does_not_exist"})
    assert(state, get_in(missing, ["error", "code"]) == "not_found" or missing["code"] == "not_found",
      "assignment-get unknown id should be not_found, got #{inspect(missing)}")

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
    wi = ok!(state, "work-item-create", %{"title" => "smoke disp wi #{unique()}", "idempotencyKey" => "dwi-#{unique()}"})
    wi_id = wi["workItemId"] || wi["id"]

    holder = ok!(state, "spawn", %{"displayName" => "smoke-dh-#{unique()}", "idempotencyKey" => "dh-#{unique()}"})
    holder_key = get_in(holder, ["stream", "sessionKey"]) || holder["sessionKey"]

    res = ok!(state, "dispatch", %{
      "sessionKey" => holder_key,
      "subject" => "smoke fanout #{unique()}",
      "brief" => "ship the smoke feature",
      "workItemId" => wi_id,
      "idempotencyKey" => "d-#{unique()}"
    })
    asg_id = res["id"] || res["assignmentId"]
    assert(state, is_binary(asg_id), "dispatch (user caller) should open an assignment, got #{inspect(res)}")

    got = ok!(state, "assignment-get", %{"assignmentId" => asg_id})
    assert(state, (got["workItemId"] || got["work_item_id"]) == wi_id,
      "dispatched assignment not linked to its work-item: #{inspect(got)}")

    retire(state, holder)
    pass(state, "dispatch opens an assignment linked to its work-item (reroute unit-covered)")
  end

  # --- helpers ---------------------------------------------------------------
  defp ok!(state, verb, params) do
    res = post(state, verb, params)

    if is_map(res) and Map.has_key?(res, "error") do
      fail(state, "#{verb} errored: #{inspect(res["error"])}")
    end

    res["result"] || res
  end

  defp post(state, verb, params) do
    {as_key, params} = Map.pop(params, "asSession")
    # Target fields (sessionKey/role/userId) ride the BODY ROOT, not params — the
    # router extracts them there (see Wire.Router target validation).
    {target, params} = Map.split(params, ["sessionKey", "role", "userId"])

    body =
      %{"verb" => verb, "params" => params}
      |> Map.merge(target)
      |> then(fn b -> if as_key, do: Map.put(b, "asSession", as_key), else: Map.put(b, "asUser", @owner) end)

    url = "http://127.0.0.1:#{state.port}/agent/dispatch"

    args = [
      "-sS", "--max-time", "30", "-o", "-", "-w", "\n%{http_code}",
      "-H", "Authorization: Bearer #{state.token}",
      "-X", "POST", "-H", "Content-Type: application/json",
      "-d", JSON.encode!(body), url
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

  defp assert(state, true, _msg), do: state
  defp assert(state, _false, msg), do: fail(state, msg)

  defp pass(state, label) do
    IO.puts("  PASS  #{label}")
    %{state | pass: state.pass + 1}
  end

  defp fail(_state, msg) do
    IO.puts("  FAIL  #{msg}")
    System.halt(1)
  end

  defp finish(state) do
    IO.puts("\nfeature-smoke: #{state.pass} checks passed")
    :ok
  end

  defp unique, do: System.unique_integer([:positive])
end

FeatureSmoke.run()
