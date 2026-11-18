defmodule Tightbeam.RailsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Rails

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-rails-#{System.unique_integer([:positive])}")
    rails_dir = Path.join([base_dir, "identity", "rails"])
    File.mkdir_p!(rails_dir)

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Tightbeam.Rails)
    end)

    %{base_dir: base_dir, rails_dir: rails_dir}
  end

  @valid %{
    "name" => ~s("no-history-rewrites"),
    "on" => ~s("tool-call"),
    "tool" => ~s("Bash"),
    "archetypes" => ~s(["*"]),
    "pattern" => ~s{"git (reset|stash|rebase|checkout \\\\.|restore|clean)"},
    "text" =>
      ~s("History-rewriting git commands are forbidden here: other agents may have uncommitted work in this tree.")
  }

  defp write_statute(ctx, overrides, file \\ "statutes.toml") do
    fields =
      @valid
      |> Map.merge(overrides)
      |> Enum.reject(fn {_k, v} -> v == :omit end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k} = #{v}" end)

    File.write!(Path.join(ctx.rails_dir, file), "[[statute]]\n" <> fields <> "\n")
  end

  defp assert_scope_check(command, statute) do
    assert command =~ "tightbeam rail-scope-check"
    assert command =~ "--statute"
    assert command =~ statute
  end

  test "empty and missing rails dirs are a valid empty set", ctx do
    assert Rails.load!(ctx.base_dir) == []

    # No loaded TOML law means only the code-built observation remains.
    assert Rails.hook_settings(:codex) == %{
             "hooks" => %{"PreToolUse" => [Rails.observation_entry()]}
           }

    File.rm_rf!(ctx.rails_dir)
    assert Rails.load!(ctx.base_dir) == []
  end

  test "Claude and Codex scope checks resolve the caller from hook cwd", ctx do
    write_statute(ctx, %{"archetypes" => ~s(["agentic-engineering.coder"])})
    Rails.load!(ctx.base_dir)

    for harness <- [:claude, :codex] do
      settings = Rails.hook_settings(harness)
      assert [%{"hooks" => [%{"command" => command}]} | _] = settings["hooks"]["PreToolUse"]
      assert_scope_check(command, "no-history-rewrites")
      refute command =~ "TIGHTBEAM_SESSION_WORKDIR"
    end
  end

  test "a valid gate statute loads with mode defaulted", ctx do
    write_statute(ctx, %{"mode" => :omit})

    assert [statute] = Rails.load!(ctx.base_dir)
    assert statute.name == "no-history-rewrites"
    assert statute.on == :tool_call
    assert statute.mode == :gate
    assert statute.tool == "Bash"
    assert Rails.statutes?()
  end

  test "receipt-owned flat kungfu rails load with qualified names", ctx do
    identity = Path.join(ctx.base_dir, "identity")
    bundle = Path.join(identity, "kungfu/agentic-engineering")
    File.mkdir_p!(bundle)

    File.write!(Path.join(bundle, "installed.toml"), """
    name = "agentic-engineering"
    paths = [
      "archetypes/coder.toml",
      "rails/engineering.toml",
    ]
    """)

    statute_path = Path.join(ctx.rails_dir, "engineering.toml")

    File.write!(statute_path, """
    [[statute]]
    name = "no-git-stash"
    on = "tool-call"
    archetypes = ["agentic-engineering.coder"]
    tool = "Bash"
    pattern = "git stash"
    text = "Do not stash this worktree."
    """)

    assert [statute] = Rails.load!(ctx.base_dir)
    assert statute.name == "agentic-engineering.no-git-stash"
    assert statute.archetypes == ["agentic-engineering.coder"]

    %{"hooks" => %{"PreToolUse" => [entry, _observation]}} = Rails.hook_settings(:codex)
    [%{"command" => command}] = entry["hooks"]
    assert_scope_check(command, "agentic-engineering.no-git-stash")

    File.write!(statute_path, """
    [[statute]]
    name = "no-git-stash"
    on = "tool-call"
    archetypes = ["org-example-analyst"]
    tool = "Bash"
    pattern = "git stash"
    text = "Do not stash this worktree."
    """)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert [unavailable] = Rails.load!(ctx.base_dir)
             assert unavailable.name == "agentic-engineering.unavailable-engineering-1"
             assert unavailable.pattern == ".*"
             assert unavailable.archetypes == ["agentic-engineering.coder"]
           end) =~ "org-example-analyst"

    File.write!(statute_path, """
    [[statute]]
    name = "no-git-stash"
    on = "tool-call"
    archetypes = ["*"]
    tool = "Bash"
    pattern = "git stash"
    text = "Do not stash this worktree."
    """)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert [unavailable] = Rails.load!(ctx.base_dir)
             assert unavailable.name == "agentic-engineering.unavailable-engineering-1"
             assert unavailable.archetypes == ["agentic-engineering.coder"]
           end) =~ "out-of-scope archetypes [\"*\"]"
  end

  test "nested receipt-owned kungfu rails load with qualified names", ctx do
    identity = Path.join(ctx.base_dir, "identity")
    bundle = Path.join(identity, "kungfu/agentic-engineering")
    rails_dir = Path.join(bundle, "rails")
    File.mkdir_p!(rails_dir)

    File.write!(Path.join(bundle, "installed.toml"), """
    name = "agentic-engineering"
    paths = [
      "kungfu/agentic-engineering/archetypes/coder.toml",
      "kungfu/agentic-engineering/rails/engineering.toml",
    ]
    """)

    File.write!(Path.join(rails_dir, "engineering.toml"), """
    [[statute]]
    name = "no-git-stash"
    on = "tool-call"
    archetypes = ["agentic-engineering.coder"]
    tool = "Bash"
    pattern = "git stash"
    text = "Do not stash this worktree."
    """)

    assert [statute] = Rails.load!(ctx.base_dir)
    assert statute.name == "agentic-engineering.no-git-stash"
    assert statute.archetypes == ["agentic-engineering.coder"]

    %{"hooks" => %{"PreToolUse" => [entry, _observation]}} = Rails.hook_settings(:codex)
    [%{"command" => command}] = entry["hooks"]
    assert_scope_check(command, "agentic-engineering.no-git-stash")
  end

  test "shipped engineering statutes name the full bundle archetype inventory", ctx do
    names = ~w(
      coder guidance-reviewer guidance-writer integrator orchestrator pdo
      product-owner recon reviewer-code reviewer-spec spec-writer team-planner
    )

    qualified = Enum.map(names, &"agentic-engineering.#{&1}")
    bundle = Path.join([ctx.base_dir, "identity", "kungfu", "agentic-engineering"])
    File.mkdir_p!(bundle)

    paths =
      Enum.map(names, &"archetypes/#{&1}.toml") ++ ["rails/engineering.toml"]

    File.write!(
      Path.join(bundle, "installed.toml"),
      "name = \"agentic-engineering\"\npaths = #{inspect(paths)}\n"
    )

    source = Path.expand("../priv/kungfu/agentic-engineering/rails/engineering.toml", __DIR__)
    File.cp!(source, Path.join(ctx.rails_dir, "engineering.toml"))

    assert statutes = Rails.load!(ctx.base_dir)
    assert length(statutes) == 5
    assert Enum.all?(statutes, &(&1.archetypes == qualified))

    assert Enum.map(statutes, & &1.name) == [
             "agentic-engineering.no-git-stash",
             "agentic-engineering.no-git-reset-hard",
             "agentic-engineering.no-git-clean-force",
             "agentic-engineering.no-git-checkout-discard",
             "agentic-engineering.no-git-restore"
           ]

    scope =
      Rails.session_scope_content("agentic-engineering.pdo")
      |> JSON.decode!()

    assert scope == %{
             "archetype" => "agentic-engineering.pdo",
             "statutes" => Enum.map(statutes, & &1.name) |> Enum.sort()
           }
  end

  test "the invariant refusal: remind is not law", ctx do
    write_statute(ctx, %{"mode" => ~s("remind")})

    assert_unavailable(~r/rails never add guidance; put prose in guidance or a skill/, fn ->
      Rails.load!(ctx.base_dir)
    end)
  end

  test "reserved and malformed statutes fail the boot with named errors", ctx do
    cases = [
      {%{"mode" => ~s("block")}, ~r/mode "block" is reserved for a later stage/},
      {%{"check" => ~s("curl janus")},
       ~r/unsupported check value "curl janus"; allowed values: github-auth, spawn-probe/},
      {%{"check" => ~s("github-auth"), "action" => ~s("git-stash")},
       ~r/cannot combine check value "github-auth" with action "git-stash"; allowed check values: github-auth, spawn-probe/},
      {%{"mode" => ~s("nonsense")}, ~r/unknown statute mode/},
      {%{"on" => ~s("turn-end")}, ~r/unknown statute event/},
      {%{"on" => :omit}, ~r/statute no-history-rewrites is missing "on"/},
      {%{"tool" => :omit}, ~r/is missing "tool"/},
      {%{"pattern" => :omit}, ~r/requires exactly one of "pattern" or "action"/},
      {%{"pattern" => :omit, "action" => ~s("unknown")}, ~r/unknown gate action/},
      {%{"action" => ~s("git-stash")}, ~r/requires exactly one of "pattern" or "action"/},
      {%{"text" => :omit}, ~r/is missing "text"/},
      {%{"text" => ~s("  ")}, ~r/is missing "text"/},
      {%{"name" => :omit}, ~r/statute is missing "name"/},
      {%{"name" => ~s("Bad_Name")}, ~r/invalid statute name/},
      {%{"sevrity" => "1"}, ~r/unknown statute keys.*sevrity/},
      # The compiler's own reason and byte offset survive, not only "invalid".
      {%{"pattern" => ~s{"("}}, ~r/invalid gate pattern: "\(": \S.* at byte \d+$/}
    ]

    for {overrides, error} <- cases do
      write_statute(ctx, overrides)
      assert_unavailable(error, fn -> Rails.load!(ctx.base_dir) end)
    end
  end

  test "a malformed statute keeps its tool closed and retains a healthy sibling", ctx do
    write_statute(ctx, %{"pattern" => :omit})
    path = Path.join(ctx.rails_dir, "statutes.toml")

    File.write!(
      path,
      File.read!(path) <>
        """
        [[statute]]
        name = "healthy-sibling"
        on = "tool-call"
        tool = "Read"
        pattern = "protected"
        text = "Do not read protected files"
        """
    )

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert [bad, good] = Rails.load!(ctx.base_dir)
             assert bad.tool == "Bash"
             assert bad.pattern == ".*"
             assert good.name == "healthy-sibling"
             assert good.tool == "Read"
             assert good.pattern == "protected"
           end) =~ "no-history-rewrites"
  end

  test "an action statute classifies before refusal without a wildcard scope lookup", ctx do
    write_statute(ctx, %{"pattern" => :omit, "action" => ~s("git-stash")})
    assert [statute] = Rails.load!(ctx.base_dir)
    assert statute.action == "git-stash"
    assert statute.pattern == nil

    %{"hooks" => %{"PreToolUse" => [entry, observation]}} = Rails.hook_settings(:codex)
    assert observation == Rails.observation_entry()
    assert [%{"command" => command}] = entry["hooks"]

    assert command =~ "input=$(cat)"
    refute command =~ "rail-scope-check"
    assert command =~ "tightbeam rail-action git-stash"
    {action_index, _} = :binary.match(command, "rail-action")

    {refusal_index, _} =
      :binary.match(command, "History-rewriting git commands are forbidden here")

    assert action_index < refusal_index
    assert command =~ "action classifier failed closed (status $status)."
    assert command =~ "History-rewriting git commands are forbidden here"
  end

  test "a scoped action classifies the call before checking its compiled session scope", ctx do
    write_statute(ctx, %{
      "archetypes" => ~s(["agentic-engineering.coder"]),
      "pattern" => :omit,
      "action" => ~s("git-stash")
    })

    Rails.load!(ctx.base_dir)
    %{"hooks" => %{"PreToolUse" => [entry, _observation]}} = Rails.hook_settings(:codex)
    [%{"command" => command}] = entry["hooks"]

    assert command =~ "input=$(cat)"
    assert_scope_check(command, "no-history-rewrites")
    assert command =~ "tightbeam rail-action git-stash"
    {scope_index, _} = :binary.match(command, "rail-scope-check")
    {action_index, _} = :binary.match(command, "rail-action")
    assert action_index < scope_index
  end

  test "duplicate names across files fail; files load in filename order", ctx do
    write_statute(ctx, %{}, "a.toml")
    write_statute(ctx, %{"name" => ~s("zz-second")}, "b.toml")

    assert Enum.map(Rails.load!(ctx.base_dir), & &1.name) == [
             "no-history-rewrites",
             "zz-second"
           ]

    write_statute(ctx, %{}, "b.toml")

    assert_unavailable(~r/duplicate statute name: no-history-rewrites/, fn ->
      Rails.load!(ctx.base_dir)
    end)
  end

  test "duplicate named checks are quarantined as catch-all refusals", ctx do
    check = %{
      "name" => ~s("github-auth"),
      "check" => ~s("github-auth"),
      "pattern" => ~s(".*")
    }

    write_statute(ctx, check, "a.toml")
    write_statute(ctx, check, "b.toml")

    statutes = Rails.load!(ctx.base_dir)
    assert Enum.all?(statutes, &(&1.check == nil and &1.pattern == ".*"))

    %{"hooks" => %{"PreToolUse" => [first, second, _observation]}} =
      Rails.hook_settings(:codex)

    for entry <- [first, second] do
      [%{"command" => command}] = entry["hooks"]
      assert command =~ "Duplicate statute github-auth requires repair"
      refute command =~ "github-auth-check"
    end
  end

  test "wildcard hook pattern passes unrelated calls before refusing matches", ctx do
    write_statute(ctx, %{})
    Rails.load!(ctx.base_dir)

    # Statutes first, in filename-then-table order; reserved substrate entries
    # follow after operator law.
    assert %{"hooks" => %{"PreToolUse" => [entry, observation]}} =
             Rails.hook_settings(:codex)

    assert observation == Rails.observation_entry()
    assert entry["matcher"] == "Bash"
    assert [%{"type" => "command", "command" => command}] = entry["hooks"]

    assert command =~ "input=$(cat)"
    refute command =~ "rail-scope-check"
    assert command =~ "grep -qE \"git (reset|stash|rebase|checkout"
    {pattern_index, _} = :binary.match(command, "grep -qE")

    {refusal_index, _} =
      :binary.match(command, "History-rewriting git commands are forbidden here")

    assert pattern_index < refusal_index
  end

  test "seed statutes own the GitHub and wiring checks and preserve harness coverage", ctx do
    seed_statutes(ctx)
    assert [github, probe] = Rails.load!(ctx.base_dir)
    assert github.name == "github-auth"
    assert github.check == "github-auth"
    assert github.archetypes == ["*"]
    assert probe.name == "tightbeam-probe"
    assert probe.check == "spawn-probe"
    assert probe.archetypes == ["*"]
    refute Rails.statutes?()

    %{"hooks" => %{"PreToolUse" => [github_entry, probe_entry, observation]}} =
      Rails.hook_settings(:codex)

    pi_entries = get_in(Rails.hook_settings(:pi), ["hooks", "PreToolUse"])

    assert observation == Rails.observation_entry()
    assert [%{"command" => command}] = github_entry["hooks"]

    assert command =~ "input=$(cat)"
    refute command =~ "rail-scope-check"
    assert command =~ "github-auth-check --text-template"

    assert command =~
             "Tightbeam cannot use GitHub from {host} for {hostname}: failed phase {phase}"

    {pattern_index, _} = :binary.match(command, "grep -qE")
    {check_index, _} = :binary.match(command, "github-auth-check")
    assert pattern_index < check_index

    assert [%{"command" => probe_command}] = probe_entry["hooks"]
    assert probe_entry in pi_entries
    assert probe_command =~ "input=$(cat)"
    refute probe_command =~ "rail-scope-check"
    assert probe_command =~ "Spawn wiring-check probe command; always refused by design."
    {pattern_index, _} = :binary.match(probe_command, "grep -qE")
    {refusal_index, _} = :binary.match(probe_command, "Spawn wiring-check probe command")
    assert pattern_index < refusal_index

    claude_entries = get_in(Rails.hook_settings(:claude), ["hooks", "PreToolUse"])
    cursor_entries = get_in(Rails.hook_settings(:cursor), ["hooks", "PreToolUse"])
    refute Enum.any?(claude_entries ++ cursor_entries, &(&1 == probe_entry))
    assert Enum.any?(claude_entries, &(&1 == github_entry))
    assert Enum.any?(cursor_entries, &(&1 == github_entry))

    refute Enum.any?(
             get_in(Rails.hook_settings(:other), ["hooks", "PreToolUse"]),
             &(&1 == probe_entry)
           )
  end

  test "observation_entry compiles the byte-pinned reserved artifact-record observation" do
    assert %{
             "matcher" => "Bash",
             "hooks" => [%{"type" => "command", "command" => command}]
           } = Rails.observation_entry()

    # grep-and-exit-0 first, so a Bash call that is not an artifact-record pays
    # one local grep; and EVERY path exits 0 — this observes, it never refuses.
    assert command ==
             "sh -c 'grep -qE \"tightbeam[^\\\"]*artifact-record\" - || exit 0; " <>
               "tightbeam tool-call-observed >/dev/null 2>&1; exit 0'"
  end

  test "escaping torture: ERE metacharacters and $ in pattern, single quote in text", ctx do
    write_statute(ctx, %{
      "name" => ~s("no-env-dollars"),
      "pattern" => ~s{"echo (\\\\$HOME|\\\\$PATH)\\\\."},
      "text" => ~s("Don't expand env here.")
    })

    Rails.load!(ctx.base_dir)

    %{"hooks" => %{"PreToolUse" => [entry, _observation]}} =
      Rails.hook_settings(:codex)

    [%{"command" => command}] = entry["hooks"]

    refute command =~ "rail-scope-check"
    assert command =~ "echo (\\\\\\$HOME|\\\\\\$PATH)"
    assert command =~ "Don'\\''t expand env here."
  end

  test "session scope compiles matching names and wrappers check scope after pattern matches",
       ctx do
    write_statute(ctx, %{
      "archetypes" => ~s(["agentic-engineering.coder"])
    })

    Rails.load!(ctx.base_dir)

    matched =
      Rails.session_scope_content("agentic-engineering.coder")
      |> JSON.decode!()

    unmatched =
      Rails.session_scope_content("agentic-engineering.reviewer-code")
      |> JSON.decode!()

    assert matched == %{
             "archetype" => "agentic-engineering.coder",
             "statutes" => ["no-history-rewrites"]
           }

    assert unmatched == %{
             "archetype" => "agentic-engineering.reviewer-code",
             "statutes" => []
           }

    %{"hooks" => %{"PreToolUse" => [entry, observation]}} = Rails.hook_settings(:codex)
    [%{"command" => command}] = entry["hooks"]
    assert_scope_check(command, "no-history-rewrites")
    assert command =~ "if [ \"$status\" -eq 1 ]; then exit 0; fi"
    assert command =~ "scope check failed (status $status)"
    assert command =~ "grep -qE"
    {scope_index, _} = :binary.match(command, "rail-scope-check")
    {pattern_index, _} = :binary.match(command, "grep -qE")
    assert pattern_index < scope_index
    assert observation == Rails.observation_entry()
  end

  test "an agentless statute does not cover a session", ctx do
    write_statute(ctx, %{"archetypes" => ~s([])})
    Rails.load!(ctx.base_dir)

    assert %{"archetype" => "agentic-engineering.coder", "statutes" => []} =
             Rails.session_scope_content("agentic-engineering.coder")
             |> JSON.decode!()

    %{"hooks" => %{"PreToolUse" => [entry, _observation]}} = Rails.hook_settings(:codex)
    [%{"command" => command}] = entry["hooks"]
    assert_scope_check(command, "no-history-rewrites")
    assert command =~ "if [ \"$status\" -eq 1 ]; then exit 0; fi"
  end

  test "wildcard rails compile active for every session without an invocation scope check", ctx do
    write_statute(ctx, %{"archetypes" => ~s(["*"])})
    Rails.load!(ctx.base_dir)

    %{"hooks" => %{"PreToolUse" => [entry, _observation]}} = Rails.hook_settings(:codex)
    [%{"command" => command}] = entry["hooks"]

    refute command =~ "rail-scope-check"

    assert %{"archetype" => "agentic-engineering.coder", "statutes" => ["no-history-rewrites"]} =
             Rails.session_scope_content("agentic-engineering.coder")
             |> JSON.decode!()
  end

  test "moduledoc pins permission bypass separately from codex hook trust and version facts" do
    assert {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Rails)
    assert moduledoc =~ "since 0.124.0"
    assert moduledoc =~ "0.144.x is the tested floor"
    assert moduledoc =~ "executable codex-acp selects"
    assert moduledoc =~ "permission bypass"
    assert moduledoc =~ "codex `agent-full-access` and claude `bypassPermissions`"
    assert moduledoc =~ "DISTINCT from permission bypass"
    assert moduledoc =~ ~s(CODEX_CONFIG={"bypass_hook_trust":true})
  end

  defp assert_unavailable(expected \\ nil, load) do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        result = load.()
        assert is_list(result)
        assert Enum.all?(result, &(&1.pattern == ".*" and &1.action == nil))
      end)
      |> String.trim()

    assert log =~ "unavailable"
    if is_struct(expected, Regex), do: assert(log =~ expected)
    if is_binary(expected), do: assert(log =~ expected)
    %{message: log}
  end

  defp seed_statutes(ctx) do
    seed_dir = Path.expand("../priv/seed/rails", __DIR__)

    File.cp!(
      Path.join(seed_dir, "github-auth.toml"),
      Path.join(ctx.rails_dir, "github-auth.toml")
    )

    File.cp!(
      Path.join(seed_dir, "tightbeam-probe.toml"),
      Path.join(ctx.rails_dir, "tightbeam-probe.toml")
    )
  end
end
