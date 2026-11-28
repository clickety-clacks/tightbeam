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
    elected = "uncle-enzo.github-maintainer"
    snapshot = Identity.snapshot!(base, elected, :codex)
    assert snapshot.guidance =~ "Use the work item's destination"
    assert Map.has_key?(snapshot.skills, "enzo-github-observe")

    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    :ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',1,1)")

    Org.create(db, %{
      session_key: "fixture-maintainer",
      display_name: "Fixture maintainer",
      owner_user_id: "owner",
      origin: "user:owner",
      archetype: elected,
      host: "fixture-host",
      harness: "codex",
      provider: "openai",
      model: Model.new("gpt-6.2-sol")
    })

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
    {:ok, [[token]]} = DB.query(db, "SELECT cliToken FROM sessions WHERE sessionKey='fixture-maintainer'")
    url = "http://127.0.0.1:#{port}"

    File.write!(
      Path.join(root, ".tightbeam-session"),
      JSON.encode!(%{url: url, token: token, sessionKey: "fixture-maintainer"})
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

    %{db: db, root: root, base: base, env: env}
  end

  test "Enzo-only trunk queue separates head-check evidence and landing on a linked row", ctx do
    item = work!(ctx, "Trunk change")
    scope = @pull <> "17"
    attach(ctx, item, "github-target", ~s({"ref":"refs/heads/main","repo":"github.com/example/widget"}))
    attach(ctx, item, "github-pr", scope)
    subscribe(ctx, "pr.checks-completed", scope)
    run!(ctx, "trunk-open")
    assert [{^scope, @head, "observed-checks-terminal"}] = observations(ctx, "pr.checks-completed")
    assert observations(ctx, "pr.merged") == []
    refute File.read!(Path.join(ctx.root, "github-reads")) =~ "/timeline"

    merged = @pull <> "17"
    subscribe(ctx, "pr.merged", merged)
    run!(ctx, "trunk")
    run!(ctx, "trunk")
    assert [{^merged, @merge, "merged"}] = observations(ctx, "pr.merged")
    attach(ctx, item, "github-integration",
      ~s({"oid":"#{@merge}","pr":17,"ref":"refs/heads/main","repo":"github.com/example/widget"}))
    attach(ctx, item, "github-evidence", scope <> "/checks")
    assert %{"uncle-enzo/github-pr" => [^scope]} = metadata(ctx, item)
    assert observations(ctx, "release.published") == []
    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT count(*) FROM sentinel_subscription_wake_matches")
  end

  test "Enzo-only backport keeps advisory failure, integration, and tag publication distinct", ctx do
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
    assert %{"uncle-enzo/github-target" => [^target]} = metadata(ctx, item)
    assert metadata(ctx, sibling) == %{}
  end

  defp work!(ctx, title) do
    result = cli!(ctx, ["work-item-create", "--title", title])
    Map.fetch!(result, "id")
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

  defp metadata(ctx, item), do: cli!(ctx, ["mementos", "--record", "work_item:" <> item])["mementos"]

  defp cli!(ctx, args) do
    {output, status} = System.cmd(@cli, args, cd: ctx.root, env: ctx.env, stderr_to_stdout: true)
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
