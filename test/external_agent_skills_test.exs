defmodule Tightbeam.ExternalAgentSkillsTest do
  use ExUnit.Case, async: true

  @cli_name "tightbeam-cli"
  @delegation_sentence "you should probably get main to do what you need it to instead of trying to do it yourself since main knows how to operate tightbeam."

  @cli_description "Operate an existing Tightbeam organization through its current-line CLI. Use when an external agent has the tightbeam executable and must read assigned work, record results, or contact Main without a served Tightbeam identity."

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
    "**Tightbeam:**",
    "**Work item:**",
    "**Assignment:**",
    "**Card:**",
    "**Main:**",
    "**Kungfu:**"
  ]

  test "the external CLI edition ships as an isolated valid skill" do
    assert_skill(@cli_name, @cli_description)

    cli = skill_bytes()
    assert cli =~ @delegation_sentence

    for marker <- @required_markers do
      assert cli =~ marker
    end

    refute cli =~ "tightbeam kungfu"
    refute cli =~ "INSERT INTO"
    refute cli =~ "UPDATE work_items"
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
             ~s(tightbeam operator-ask --question "..." --assignment <assignment-id>)

    refute Regex.match?(~r/\btightbeam ask(?:\s|`)/, cli)

    {unsupported, status} =
      System.cmd(release_cli(), ["ask", "--help"], stderr_to_stdout: true)

    assert status != 0
    assert unsupported =~ "no such command: ask"
    assert cli =~ "`decision_pending`"
  end

  test "the README installs only the CLI skill before source installation" do
    readme = File.read!(Path.join(repo_root(), "README.md"))

    section = "## External-agent operation skill"
    install = "## Two ways to install"

    assert :binary.match(readme, section) < :binary.match(readme, install)
    assert readme =~ "priv/skills/tightbeam-cli/SKILL.md"
    assert readme =~ ".codex/skills/tightbeam-cli/"
    assert readme =~ ".claude/skills/tightbeam-cli/"
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

  defp skill_bytes, do: @cli_name |> skill_path() |> File.read!()
  defp skill_path(name), do: Application.app_dir(:tightbeam, "priv/skills/#{name}/SKILL.md")
  defp release_cli, do: Path.join(repo_root(), "cli/target/release/tightbeam")
  defp repo_root, do: Path.expand("..", __DIR__)
end
