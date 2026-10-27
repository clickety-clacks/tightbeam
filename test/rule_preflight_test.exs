defmodule Tightbeam.RulePreflightTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assignments, DB, Gateway, Model, Org, Rules, Schema}

  @legacy_fixture "fixtures/predecessor-verification.toml"
  @legacy_sha "cf2755a6933c8b81fd4beb6b7343e9fc3b0c4a054fcdaecd7fd954d1df4f9241"

  setup do
    db = :"rule_preflight_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    assert :ok = Schema.ensure_all(db)

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-rule-preflight-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf!(base_dir)
      Rules.load!(System.tmp_dir!() <> "/missing-rule-preflight-reset", [])
    end)

    assert :initialized = Tightbeam.Identity.init!(base_dir)
    assert :ok =
             DB.execute(db, "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('flynn',1,1)")

    handlers = Gateway.handlers(%{db: db, base_dir: base_dir})
    %{db: db, base_dir: base_dir, handlers: handlers}
  end

  test "predecessor rules skip retired policies safely and remain visible", ctx do
    legacy = File.read!(Path.expand(@legacy_fixture, __DIR__))
    assert sha256(legacy) == @legacy_sha
    put_rules(ctx, legacy)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert [
                 %{name: "completion-requires-verification"},
                 %{name: "completion-requires-results-artifact"}
               ] = Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
      end)

    assert log =~
             ~s(rules/verification.toml: policy "holder-continuation-coverage": purpose "wait-prod-coverage" is retired in this version; the policy has no effect)

    assert log =~
             ~s(rules/verification.toml: policy "justified-unresolved-dependency": purpose "wait-effort-relief" is retired in this version; the policy has no effect)

    assert length(Regex.scan(~r/rules\/verification\.toml: policy /, log)) == 2

    status = Rules.status()
    assert status.recording_available
    assert status.unavailable_verbs == []
    assert Enum.map(status.skipped_policies, & &1.name) == [
             "holder-continuation-coverage",
             "justified-unresolved-dependency"
           ]

    identity_status =
      ctx.handlers["identity-status"].(%{
        origin: "user:flynn",
        principal: {:user, "flynn"},
        params: %{}
      })

    assert identity_status.recording_available
    assert identity_status.unavailable_verbs == []
    assert Enum.map(identity_status.skipped_policies, & &1.name) == [
             "holder-continuation-coverage",
             "justified-unresolved-dependency"
           ]

    context = %{
      verifier_state: "open",
      verifier_holder_key: "current-holder",
      obligation_holder_key: "different-holder"
    }

    assert {:ok, {:ok, %{name: "accountable-dependency-verifier"}}} =
             DB.transaction(ctx.db, fn txn ->
               Rules.select_policy_in_txn(txn, "wait-verification-admission", context)
             end)

    holder = session(ctx.db, "legacy-fixture-coder", "flynn", archetype: "coder")
    governed = assignment(ctx, holder.session_key)

    assert {:deny, %{rule: "completion-requires-verification"}} =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", {:session, holder.session_key}, %{
                 assignment_id: governed.id,
                 kind: "completion"
               })
             )
  end

  test "release preflight reports findings without changing the learned file", ctx do
    legacy = File.read!(Path.expand(@legacy_fixture, __DIR__))
    assert sha256(legacy) == @legacy_sha
    path = put_rules(ctx, legacy)
    before = File.read!(path)

    report = Tightbeam.RulePreflight.run(ctx.base_dir)

    assert report.complete
    assert report.recording_available
    assert report.unavailable_verbs == []
    assert Enum.map(report.skipped_policies, & &1.name) == [
             "holder-continuation-coverage",
             "justified-unresolved-dependency"
           ]

    assert Enum.any?(report.warnings, &(&1 =~ "policy \"holder-continuation-coverage\""))
    assert Enum.any?(report.warnings, &(&1 =~ "policy \"justified-unresolved-dependency\""))
    assert File.read!(path) == before
  end

  test "an unsupported policy is skipped while a supported sibling remains selectable", ctx do
    contents = """
    [[policy]]
    name = "supported-verifier"
    purpose = "wait-verification-admission"
    when = [{ fact = "verifier.open", op = "eq", value = true }]
    verification = { trigger = "registration", terminal = "bound-verdict-or-obligation-terminal", fallback = "wake-due-at" }

    [[policy]]
    name = "unsupported-policy"
    purpose = "wait-unknown-x"
    when = [{ fact = "verifier.open", op = "eq", value = true }]
    """

    put_rules(ctx, contents, "policy.toml")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) == []
      end)

    assert log =~
             ~s(rules/policy.toml: policy "unsupported-policy": unsupported purpose: "wait-unknown-x")

    assert Rules.status().recording_available

    assert [%{name: "unsupported-policy", reason: ~s(unsupported purpose: "wait-unknown-x")}] =
             Rules.status().skipped_policies

    context = %{
      verifier_state: "open",
      verifier_holder_key: "current-holder",
      obligation_holder_key: "different-holder"
    }

    assert {:ok, {:ok, %{name: "supported-verifier"}}} =
             DB.transaction(ctx.db, fn txn ->
               Rules.select_policy_in_txn(txn, "wait-verification-admission", context)
             end)
  end

  defp put_rules(ctx, contents, filename \\ "verification.toml") do
    path = Path.join([ctx.base_dir, "identity", "rules", filename])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp session(db, key, owner, opts \\ []) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: "custom",
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: Keyword.get(opts, :archetype, "default"),
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp assignment(ctx, holder) do
    params = %{
      subject: "predecessor rule compatibility",
      idempotency_key: nil,
      work_item_id: nil,
      reviews_assignment_id: nil,
      effect_kind: nil,
      files: nil
    }

    call = p3_call("assign", {:session, holder}, params)
    Assignments.__handle__(ctx.db, "assign", %{call | session_key: holder})
  end

  defp p3_call(verb, principal, params) do
    origin =
      case principal do
        {:session, key} -> "agent:#{key}"
        {:user, user} -> "user:#{user}"
        nil -> "process:test"
      end

    %{
      verb: verb,
      origin: origin,
      principal: principal,
      session_key: nil,
      params: params,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000
    }
  end
end
