defmodule Tightbeam.EnzoGitHubWorkflowTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, Identity, Model, Org, Rules, Schema}

  @prefix "uncle-enzo/github-watch/"
  @pull "https://github.com/example/widget/pull/"
  @api "https://api.github.com/repos/example/widget/"
  @head String.duplicate("a", 40)
  @merge String.duplicate("b", 40)
  @fixture Path.expand("enzo_github_watch_test.py", __DIR__)
  @cli Path.expand("../cli/target/release/tightbeam", __DIR__)
  @bundles Path.expand("../priv/kungfu", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "enzo-workflow-#{System.unique_integer([:positive])}")
    base = Path.join(root, "org")
    prior = Application.get_env(:tightbeam, :kungfu_bundle_root_dir)
    Application.put_env(:tightbeam, :kungfu_bundle_root_dir, @bundles)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:tightbeam, :kungfu_bundle_root_dir, prior),
        else: Application.delete_env(:tightbeam, :kungfu_bundle_root_dir)

      Rules.load!(Path.join(root, "empty"), [])
      File.rm_rf!(root)
    end)

    assert {:ok, candidate} = Identity.learn!(base, "uncle-enzo", "test")
    assert {:ok, _} = Identity.publish_live!(base, candidate)
    refute "agentic-engineering" in Identity.public_kungfu_names(base)
    elected = "uncle-enzo.deliverator"
    snapshot = Identity.snapshot!(base, elected, :codex)
    assert snapshot.guidance =~ "Use the work item's destination"
    review = Identity.snapshot!(base, "uncle-enzo.generic", :codex)
    for skill <- ~w(change observe integrate release) do
      assert Map.has_key?(snapshot.skills, "enzo-github-" <> skill)
      assert Map.has_key?(review.skills, "enzo-github-" <> skill)
    end
    assert "tightbeam-dispatching" in snapshot.archetype.skills

    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    :ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',1,1)")

    for {session, archetype} <- [
          {"fixture-deliverator", elected},
          {"fixture-reviewer", "uncle-enzo.generic"}
        ] do
      Org.create(db, %{
        session_key: session,
        display_name: session,
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: archetype,
        host: "fixture-host",
        harness: "codex",
        provider: "openai",
        model: Model.new("gpt-6.2-sol")
      })
    end

    handlers = Gateway.handlers(%{db: db, base_dir: base, wake_scheduler: :enzo_fixture})
    Rules.load!(base, Map.keys(handlers))

    router =
      Tightbeam.Wire.Router.init(
        db: db,
        base_dir: base,
        handlers: handlers,
        cli_token: "enzo-fixture-token",
        session_status: fn _ -> nil end
      )

    server =
      start_supervised!(
        {Bandit,
         plug: {Tightbeam.Wire.Router, router}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, [[token]]} = DB.query(db, "SELECT cliToken FROM sessions WHERE sessionKey='fixture-deliverator'")
    url = "http://127.0.0.1:#{port}"

    File.write!(
      Path.join(root, ".tightbeam-session"),
      JSON.encode!(%{url: url, token: token, sessionKey: "fixture-deliverator"})
    )

    bin = Path.join(root, "bin")
    File.mkdir!(bin)
    gh = Path.join(bin, "gh")
    File.write!(gh, "#!/bin/sh\n[ \"$1\" = api ] || exit 2\nexec python3 '#{@fixture}' --gh-fixture \"$2\"\n")
    File.chmod!(gh, 0o700)

    env = [
      {"TIGHTBEAM_URL", url},
      {"TIGHTBEAM_TOKEN", token},
      {"TIGHTBEAM_BASE_DIR", base},
      {"TIGHTBEAM_AS_PROCESS", nil},
      {"GH_CONFIG_DIR", root},
      {"PATH", bin <> ":" <> Path.dirname(@cli) <> ":" <> System.get_env("PATH")},
      {"ENZO_FIXTURE_READS", Path.join(root, "github-reads")}
    ]

    %{db: db, root: root, base: base, env: env, url: url}
  end

  test "Enzo-only trunk queue separates head-check evidence and landing on a linked row", ctx do
    elect_evidence_rule!(ctx, :trunk)
    item = work!(ctx, "Trunk change")
    scope = @pull <> "17"
    attach(ctx, item, "github-target", ~s({"ref":"refs/heads/main","repo":"github.com/example/widget"}))
    attach(ctx, item, "github-pr", scope)
    subscribe(ctx, "pr.checks-completed", scope)
    subscribe(ctx, "pr.observed-checks-terminal", scope)
    run!(ctx, "trunk-open")
    assert [{^scope, @head, "required-checks-terminal"}] = observations(ctx, "pr.checks-completed")
    assert observations(ctx, "pr.merged") == []
    assert observations(ctx, "pr.observed-checks-terminal") == []
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT count(*) FROM sentinel_subscription_wake_matches")

    run!(ctx, "trunk-all-terminal")
    run!(ctx, "trunk-all-terminal")
    assert [{^scope, @head, "observed-checks-terminal"}] =
             observations(ctx, "pr.observed-checks-terminal")

    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT count(*) FROM sentinel_subscription_wake_matches")
    refute File.read!(Path.join(ctx.root, "github-reads")) =~ "/timeline"

    merged = @pull <> "17"
    subscribe(ctx, "pr.merged", merged)
    run!(ctx, "trunk")
    run!(ctx, "trunk")
    assert [{^merged, @merge, "merged"}] = observations(ctx, "pr.merged")
    attach(ctx, item, "github-integration",
      ~s({"oid":"#{@merge}","pr":17,"ref":"refs/heads/main","repo":"github.com/example/widget"}))
    attach(ctx, item, "github-evidence", scope <> "/checks")
    complete_with_evidence!(ctx, item, "code", scope <> "/checks")
    assert_feature_owner(ctx, item)
    assert %{"uncle-enzo/github-pr" => [^scope]} = metadata(ctx, item)
    assert observations(ctx, "release.published") == []
    assert {:ok, [[3]]} = DB.query(ctx.db, "SELECT count(*) FROM sentinel_subscription_wake_matches")
  end

  test "Enzo-only backport keeps advisory failure, integration, and tag publication distinct", ctx do
    elect_evidence_rule!(ctx, :release)
    item = work!(ctx, "Release backport")
    sibling = work!(ctx, "Unrelated follow-up")
    target = ~s({"ref":"refs/heads/release/2.x","repo":"github.com/example/widget"})
    attach(ctx, item, "github-target", target)
    branch = @api <> "git/ref/heads/release%2F2.x"
    tag = @api <> "git/ref/tags/v2.3.1"
    release = @api <> "releases/tags/v2.3.1"
    subscribe(ctx, "branch.check-failed", branch)
    subscribe(ctx, "tag.observed", tag)
    run!(ctx, "backport")
    assert [{^branch, @merge, nil}] = observations(ctx, "branch.check-failed")
    assert [{^tag, @merge, "resolved"}] = observations(ctx, "tag.observed")
    assert observations(ctx, "release.published") == []

    merged = @pull <> "17"
    subscribe(ctx, "pr.merged", merged)
    subscribe(ctx, "release.published", release)
    run!(ctx, "backport")
    run!(ctx, "backport")
    assert [{^merged, @merge, "merged"}] = observations(ctx, "pr.merged")
    assert [{^release, @merge, "published"}] = observations(ctx, "release.published")
    attach(ctx, item, "github-pr", merged)
    attach(ctx, item, "github-evidence", [tag, release])
    complete_with_evidence!(ctx, item, "release", release)
    assert_feature_owner(ctx, item)
    assert %{"uncle-enzo/github-target" => [^target]} = metadata(ctx, item)
    assert metadata(ctx, sibling) == %{}
  end

  defp elect_evidence_rule!(ctx, pattern) do
    identity = Path.join(ctx.base, "identity")
    template = Path.join(identity, "skills/enzo-github-integrate/integration-evidence.toml")
    data = File.read!(template)

    data =
      if pattern == :release do
        String.replace(
          data,
          ~s(  { fact = "attest.kind", op = "eq", value = "completion" },),
          ~s(  { fact = "attest.kind", op = "eq", value = "completion" },) <>
            ~s(\n  { fact = "assignment.effect_kind", op = "eq", value = "release" },)
        )
      else
        data
      end

    File.write!(Path.join(identity, "rules/local-integration-evidence.toml"), data)
    prior = Identity.live_revision!(ctx.base)
    git!(identity, ["add", "-A"])
    git!(identity, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-m", "Elect evidence rule"])
    revision = git!(identity, ["rev-parse", "HEAD"])
    assert {:ok, ^revision} = Identity.publish_live!(ctx.base, %{candidate_revision: revision, expected_prior: prior})

    handlers = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base})
    Rules.load!(ctx.base, Map.keys(handlers))
  end

  defp git!(directory, args) do
    {output, 0} = System.cmd("git", args, cd: directory, stderr_to_stdout: true)
    String.trim(output)
  end

  defp complete_with_evidence!(ctx, item, effect_kind, evidence) do
    target = metadata(ctx, item)["uncle-enzo/github-target"] |> List.first()

    assignment =
      cli!(ctx, [
        "assign", "--subject", "Verify integration", "--session", "fixture-deliverator",
        "--work-item", item, "--effect-kind", effect_kind,
        "--memento", "uncle-enzo/github-target=" <> target
      ])

    id = Map.fetch!(assignment, "id")
    if effect_kind == "release", do: independent_review!(ctx, item, id)
    args = ["attest", id, "--kind", "completion", "--note", "Verified the observed integration"]
    {refusal, status} = run_cli(ctx, args)
    assert status != 0
    assert refusal =~ "integration-evidence-on-completion" or refusal =~ "Attach the repository evidence"
    assert {:ok, [["open"]]} = DB.query(ctx.db, "SELECT state FROM assignments WHERE id=?1", [id])
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM attests WHERE assignmentId=?1", [id])

    filed = cli!(ctx, args ++ ["--memento", "uncle-enzo/github-evidence=" <> evidence])
    attest = filed["attest"]["id"]
    assert {:ok, [["closed"]]} = DB.query(ctx.db, "SELECT state FROM assignments WHERE id=?1", [id])
    assert metadata_for(ctx, "attest:" <> attest)["uncle-enzo/github-evidence"] == [evidence]
  end

  defp independent_review!(ctx, item, integration) do
    revision = "https://github.com/example/widget/commit/" <> @head

    review =
      cli!(ctx, [
        "assign", "--subject", "Independently verify the exact backport revision",
        "--session", "fixture-reviewer", "--work-item", item,
        "--reviews", integration, "--effect-kind", "review"
      ])

    review_id = Map.fetch!(review, "id")
    reviewer = reviewer_context(ctx)
    verdict =
      cli!(reviewer, [
        "attest", review_id, "--kind", "verdict", "--verdict", "reviewed-clean",
        "--note", "The synthetic backport satisfies the bounded compatibility criteria",
        "--memento", "uncle-enzo/github-revision=" <> revision
      ])

    assert metadata_for(ctx, "attest:" <> verdict["attest"]["id"])["uncle-enzo/github-revision"] ==
             [revision]

    assert_feature_owner(ctx, item)
  end

  defp reviewer_context(ctx) do
    key = "fixture-reviewer"
    assert {:ok, [[token]]} = DB.query(ctx.db, "SELECT cliToken FROM sessions WHERE sessionKey=?1", [key])
    root = Path.join(ctx.root, "review")
    File.mkdir!(root)

    File.write!(
      Path.join(root, ".tightbeam-session"),
      JSON.encode!(%{url: ctx.url, token: token, sessionKey: key})
    )

    env = Map.put(Map.new(ctx.env), "TIGHTBEAM_TOKEN", token)
    %{ctx | root: root, env: env}
  end

  defp work!(ctx, title) do
    item = cli!(ctx, ["work-item-create", "--title", title]) |> Map.fetch!("id")
    cli!(ctx, ["work-item-update", item, "--delivery-owner", "fixture-deliverator"])
    assert_feature_owner(ctx, item)
    item
  end

  defp assert_feature_owner(ctx, item) do
    assert {:ok, [["fixture-deliverator"]]} =
             DB.query(ctx.db, "SELECT deliveryOwnerSessionKey FROM work_items WHERE id=?1", [item])
  end

  defp subscribe(ctx, event, scope) do
    assert %{"id" => id} =
             cli!(ctx, ["sentinel", "subscribe", "--event", @prefix <> event, "--where", "scope=" <> scope])
    assert is_binary(id)
  end

  defp attach(ctx, item, name, values) do
    args = ["memento-set", "--record", "work_item:" <> item, "--name", "uncle-enzo/" <> name]
    args = args ++ Enum.flat_map(List.wrap(values), &["--value", &1])
    assert %{"mementos" => %{}} = cli!(ctx, args)
  end

  defp metadata(ctx, item), do: metadata_for(ctx, "work_item:" <> item)
  defp metadata_for(ctx, record), do: cli!(ctx, ["mementos", "--record", record])["mementos"]

  defp run_cli(ctx, args),
    do: System.cmd(@cli, args, cd: ctx.root, env: ctx.env, stderr_to_stdout: true)

  defp cli!(ctx, args) do
    {output, status} = run_cli(ctx, args)
    assert status == 0, output
    JSON.decode!(output)
  end

  defp run!(ctx, pattern) do
    program = Path.join(ctx.base, "identity/kungfu/uncle-enzo/sentinels/github-watch")
    env = Map.new(ctx.env)
    env =
      Map.merge(env, %{
        "TIGHTBEAM_TOKEN" => "enzo-fixture-token",
        "TIGHTBEAM_AS_PROCESS" => "sentinel:uncle-enzo/github-watch",
        "ENZO_FIXTURE_PATTERN" => pattern
      })

    {output, status} =
      System.cmd("python3", [program, "--once"], cd: ctx.root, env: env, stderr_to_stdout: true)

    assert status == 0, output
  end

  defp observations(ctx, suffix) do
    assert {:ok, rows} =
             DB.query(ctx.db, "SELECT origin,payload FROM condition_facts WHERE kind=?1", [@prefix <> suffix])

    for [origin, payload] <- rows do
      assert origin == "process:sentinel:uncle-enzo/github-watch"
      %{"scope" => scope, "revision" => revision, "observation" => observation} = JSON.decode!(payload)
      {scope, revision, JSON.decode!(observation)["state"]}
    end
  end
end
