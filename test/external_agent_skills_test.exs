defmodule Tightbeam.ExternalAgentSkillsTest do
  use ExUnit.Case, async: true

  @cli_name "tightbeam-cli"
  @cli_description "Work an assigned Tightbeam card through the tightbeam CLI. Use when an external agent holds a Tightbeam session credential in its worktree and must read its assignment, record results, ask its owner for decisions, or contact Main without a served Tightbeam identity."
  @operator_name "tightbeam-operator"
  @operator_description "Operate a Tightbeam organization from outside it on behalf of a named user. Use when an agent that is not a Tightbeam session must inspect work, present or rule on decision requests, file and route work to a delivery owner, or wake sessions through the tightbeam CLI."

  @cli_commands [
    {"--help", ["--help"]},
    {"list", ["list", "--help"]},
    {"assignments", ["assignments", "--help"]},
    {"work-item-get", ["work-item-get", "--help"]},
    {"work-item-trace", ["work-item-trace", "--help"]},
    {"attests", ["attests", "--help"]},
    {"attest", ["attest", "--help"]},
    {"artifacts", ["artifacts", "--help"]},
    {"artifact-record", ["artifact-record", "--help"]},
    {"wake", ["wake", "--help"]},
    {"operator-ask", ["operator-ask", "--help"]},
    {"decision-requests", ["decision-requests", "--help"]}
  ]

  @required_markers [
    "## Records",
    "## Start from the assignment",
    "## Perform only the obligation",
    "## Record the result",
    "## Contact Main and request decisions",
    "## Wait on the real boundary",
    "## Stop on visible failure"
  ]

  test "the external CLI edition ships as an isolated valid skill" do
    assert_skill(@cli_name, @cli_description)

    cli = skill_bytes()

    assert cli =~
             "Do not create or route new work unless the assignment grants coordination authority"

    assert cli =~ "to Main unless the assignment grants that exact operation"

    for marker <- @required_markers do
      assert cli =~ marker
    end

    refute cli =~ "tightbeam kungfu"
    refute cli =~ "INSERT INTO"
    refute cli =~ "UPDATE work_items"
  end

  test "the operator edition ships as an isolated valid skill that acts as a named user" do
    assert_skill(@operator_name, @operator_description)

    operator = skill_bytes(@operator_name)

    for marker <- [
          "## Identity and authority",
          "## Read the organization",
          "## Decision requests",
          "## File and route work",
          "## Wake sessions",
          "## Stop on visible failure"
        ] do
      assert operator =~ marker
    end

    assert operator =~ "Pass `--as-user <userId>` on every command"
    assert operator =~ "tightbeam operator-rule <decisionRequestId> --decision"
    assert operator =~ "tightbeam work-item-handoff --title"
    refute operator =~ "INSERT INTO"
    refute operator =~ "UPDATE work_items"
  end

  test "every shipped external skill names only commands and flags the compiled CLI has" do
    {help, 0} = System.cmd(release_cli(), ["--help"], stderr_to_stdout: true)

    for name <- shipped_skill_names() do
      bytes = skill_bytes(name)

      commands =
        Regex.scan(~r/\btightbeam ([a-z][a-z-]*)/, bytes, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      assert commands != []

      for command <- commands do
        {output, status} = System.cmd(release_cli(), [command, "--help"], stderr_to_stdout: true)

        assert status == 0,
               "#{name} names `tightbeam #{command}`, which the CLI refuses: #{output}"
      end

      for flag <- Regex.scan(~r/(?<![\w-])--[a-z][a-z-]*/, bytes) |> List.flatten() |> Enum.uniq() do
        assert help =~ flag, "#{name} names #{flag}, which `tightbeam --help` does not document"
      end
    end
  end

  test "every shipped external skill is written for this release and names no record" do
    assert shipped_skill_names() == [@cli_name, @operator_name]

    version = Mix.Project.config()[:version]

    for name <- shipped_skill_names() do
      assert skill_bytes(name) =~ "\nWritten for Tightbeam #{version}. "
    end

    {output, status} = System.cmd("python3", [verify_script()], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "written for #{version}"
  end

  @tag :tmp_dir
  test "the release gate refuses a stale stamp and a record identifier", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "cli/src"))
    File.mkdir_p!(Path.join(root, "priv/skills/tightbeam-cli"))
    File.write!(Path.join(root, "cli/Cargo.toml"), ~s([package]\nversion = "9.9.9"\n))

    File.write!(
      Path.join(root, "cli/src/skills.rs"),
      ~s[include_str!("../../priv/skills/tightbeam-cli/SKILL.md")]
    )

    File.write!(
      Path.join(root, "priv/skills/tightbeam-cli/SKILL.md"),
      "---\nname: tightbeam-cli\n---\n\nWritten for Tightbeam 9.9.8. Read wi_0123abcd first.\n"
    )

    {output, status} = System.cmd("python3", [verify_script(), root], stderr_to_stdout: true)
    assert status == 1
    assert output =~ "written for 9.9.8 but this release is 9.9.9"
    assert output =~ "record identifier wi_0123abcd"
  end

  test "the CLI edition names commands that the compiled CLI accepts exactly" do
    cli = skill_bytes()

    for {name, argv} <- @cli_commands do
      marker = if name == "--help", do: "tightbeam --help", else: "tightbeam #{name}"
      assert cli =~ marker

      {output, status} = System.cmd(release_cli(), argv, stderr_to_stdout: true)
      assert status == 0, "compiled CLI refused #{Enum.join(argv, " ")}: #{output}"
    end

    assert cli =~
             ~s(tightbeam operator-ask --question "..." --note "..." --assignment <assignment-id>)

    refute Regex.match?(~r/\btightbeam ask(?:\s|`)/, cli)

    # Agent questions are now supported, but do not replace operator decisions
    # in this external-agent workflow. Help must work; an incomplete ask must
    # still refuse before dispatch.
    {help, status} =
      System.cmd(release_cli(), ["ask", "--help"], stderr_to_stdout: true)

    assert status == 0
    assert help =~ "ask (--session"

    {invalid, status} = System.cmd(release_cli(), ["ask"], stderr_to_stdout: true)
    assert status != 0
    assert invalid =~ "usage: tightbeam ask"
    assert cli =~ "`decision_pending`"
  end

  test "the README installs the matching skills with the CLI before verified-release-only installation" do
    readme = File.read!(Path.join(repo_root(), "README.md"))

    section = "## External-agent operation skill"
    install = "## Install only a verified release package"

    assert {section_offset, _} = :binary.match(readme, section)
    assert {install_offset, _} = :binary.match(readme, install)
    assert section_offset < install_offset
    assert readme =~ "priv/skills/tightbeam-cli/SKILL.md"
    assert readme =~ "priv/skills/tightbeam-operator/SKILL.md"
    assert readme =~ "tightbeam skill install"
    assert readme =~ "~/.claude/skills"
    assert readme =~ "~/.codex/skills"
    assert readme =~ "Keep the directory name"
    assert readme =~ "Start a fresh agent session"
  end

  defp assert_skill(name, expected_description) do
    path = skill_path(name)
    bytes = File.read!(path)
    frontmatter = frontmatter(bytes)

    assert File.ls!(Path.dirname(path)) == ["SKILL.md"]
    assert Map.keys(frontmatter) |> Enum.sort() == ["description", "name"]
    assert frontmatter == %{"description" => expected_description, "name" => name}
    assert length(String.split(bytes, "\n")) < 500
  end

  defp frontmatter(bytes) do
    [yaml] = Regex.run(~r/\A---\n(.*?)\n---\n/s, bytes, capture: :all_but_first)

    yaml
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [key, value] = String.split(line, ": ", parts: 2)
      {key, value}
    end)
  end

  defp skill_bytes(name \\ @cli_name), do: name |> skill_path() |> File.read!()

  defp shipped_skill_names do
    ~r{include_str!\("\.\./\.\./priv/skills/([a-z0-9-]+)/SKILL\.md"\)}
    |> Regex.scan(File.read!(Path.join(repo_root(), "cli/src/skills.rs")),
      capture: :all_but_first
    )
    |> List.flatten()
  end

  defp verify_script, do: Path.join(repo_root(), "scripts/verify_external_skills.py")
  defp skill_path(name), do: Application.app_dir(:tightbeam, "priv/skills/#{name}/SKILL.md")
  defp release_cli, do: Path.join(repo_root(), "cli/target/release/tightbeam")
  defp repo_root, do: Path.expand("..", __DIR__)
end
