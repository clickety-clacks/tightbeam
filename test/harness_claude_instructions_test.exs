defmodule Tightbeam.Harness.ClaudeInstructionsTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.Claude

  test "session settings exclude only instruction paths strictly above the ACP workspace" do
    config = Claude.session_config(%{cwd: "/users/operator/workspace"}, "served identity")

    assert config.meta == %{
             systemPrompt: %{type: "preset", preset: "claude_code", append: "served identity"},
             claudeCode: %{
               options: %{
                 settings: %{
                   claudeMdExcludes: [
                     "/users/operator/CLAUDE.md",
                     "/users/operator/.claude/CLAUDE.md",
                     "/users/operator/CLAUDE.local.md",
                     "/users/CLAUDE.md",
                     "/users/.claude/CLAUDE.md",
                     "/users/CLAUDE.local.md",
                     "/CLAUDE.md",
                     "/.claude/CLAUDE.md",
                     "/CLAUDE.local.md"
                   ]
                 }
               }
             }
           }

    # No checkout discovery or filesystem presence is needed: files at or
    # below cwd remain eligible, including a checkout created there later.
    exclusions = config.meta.claudeCode.options.settings.claudeMdExcludes
    refute Enum.any?(exclusions, &String.starts_with?(&1, "/users/operator/workspace/"))
    assert config.guidance == "served identity"
    assert config.permission_mode == "bypassPermissions"
  end

  test "root workspace has no outside ancestors and each session uses its own boundary" do
    root = Claude.session_config(%{cwd: "/"}, "root")
    assert root.meta.claudeCode.options.settings == %{claudeMdExcludes: []}

    first = Claude.session_config(%{cwd: "/one/work"}, "one")
    second = Claude.session_config(%{cwd: "/two/work"}, "two")
    assert "/one/CLAUDE.md" in first.meta.claudeCode.options.settings.claudeMdExcludes
    refute "/one/CLAUDE.md" in second.meta.claudeCode.options.settings.claudeMdExcludes
    assert "/two/CLAUDE.md" in second.meta.claudeCode.options.settings.claudeMdExcludes
  end

  test "literal glob characters in ancestor directory names cannot widen the exclusion" do
    config = Claude.session_config(%{cwd: "/users/name[1]/work*(copy)/project"}, "identity")
    exclusions = config.meta.claudeCode.options.settings.claudeMdExcludes
    assert ~S|/users/name\[1\]/work\*\(copy\)/CLAUDE.md| in exclusions
    assert ~S|/users/name\[1\]/.claude/CLAUDE.md| in exclusions
  end

  test "identity rendering without a session cwd keeps the existing preset" do
    config = Claude.session_config(%{identity: true}, "identity body")
    assert config.guidance =~ "identity body"

    assert config.meta == %{
             systemPrompt: %{type: "preset", preset: "claude_code", append: config.guidance}
           }
  end
end
