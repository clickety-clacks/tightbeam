defmodule Tightbeam.ExternalAgentSkillsTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{DB, Gateway, Model, Org, Roles, Rules}
  alias Tightbeam.Wire.Router

  @cli_name "tightbeam-cli"
  @rest_name "tightbeam-rest-0-2-0"
  @delegation_sentence "you should probably get main to do what you need it to instead of trying to do it yourself since main knows how to operate tightbeam."

  @cli_description "Operate an existing Tightbeam organization through its current-line CLI. Use when an external agent has the tightbeam executable and must read assigned work, record results, or contact Main without a served Tightbeam identity."
  @rest_description "Operate an existing Tightbeam 0.2.0 organization through its authenticated HTTP dispatch interface. Use when an external agent must read assigned work, record results, or contact Main without invoking the Tightbeam CLI."

  @cli_commands [
    "tightbeam --help",
    "tightbeam list",
    "tightbeam assignments",
    "tightbeam work-item-get",
    "tightbeam work-item-trace",
    "tightbeam attests",
    "tightbeam attest",
    "tightbeam artifacts",
    "tightbeam artifact-record",
    "tightbeam wake",
    "tightbeam ask",
    "tightbeam decision-requests"
  ]

  @required_markers [
    "**Tightbeam:**",
    "**Work item:**",
    "**Assignment:**",
    "**Card:**",
    "**Main:**",
    "**Kungfu:**"
  ]

  setup do
    db = :"external_agent_skills_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:paired, device} =
      claim_org(db, %{
        device_id: "external-skills",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    ensure_main_session(db, device.user_id)

    session =
      Org.create(db, %{
        session_key: "external-skill-session",
        display_name: "External skill fixture",
        owner_user_id: device.user_id,
        origin: "user:#{device.user_id}",
        archetype: "default",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable"),
        host: "eezo"
      })

    Roles.create!(db, "external-skill-agent", device.user_id, session.session_key)

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-external-skills-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(base_dir) end)

    handlers = Gateway.handlers(%{db: db, base_dir: base_dir, wake_tick_ms: 1_000})
    Rules.load!(base_dir, Map.keys(handlers))

    opts = [
      db: db,
      base_dir: base_dir,
      cursor_signing: cursor_signing!(base_dir),
      handlers: handlers,
      cli_token: "tbc_external_agent_skills",
      session_status: fn _ -> nil end
    ]

    work_item =
      dispatch(opts, "tbc_external_agent_skills", %{
        verb: "work-item-create",
        asUser: device.user_id,
        params: %{title: "external skill fixture"}
      })
      |> result!()

    assignment =
      dispatch(opts, "tbc_external_agent_skills", %{
        verb: "assign",
        asUser: device.user_id,
        sessionKey: session.session_key,
        params: %{subject: "exercise the external skill", workItemId: work_item["id"]}
      })
      |> result!()

    %{
      assignment_id: assignment["id"],
      opts: opts,
      owner_id: device.user_id,
      session: session,
      work_item_id: work_item["id"]
    }
  end

  test "the two external editions ship as isolated valid skills" do
    assert external_edition_names() == [@cli_name, @rest_name]

    assert_skill(@cli_name, @cli_description)
    assert_skill(@rest_name, @rest_description)

    for bytes <- [skill_bytes(@cli_name), skill_bytes(@rest_name)] do
      assert bytes =~ @delegation_sentence

      for marker <- @required_markers do
        assert bytes =~ marker
      end

      refute bytes =~ "tightbeam kungfu"
      refute bytes =~ ~s({"verb":"kungfu)
    end
  end

  test "the CLI edition names only the compiled CLI transport" do
    cli = skill_bytes(@cli_name)

    for command <- @cli_commands do
      assert cli =~ command
    end

    assert cli =~ "`decision_pending`"

    {help, 0} = System.cmd(release_cli(), ["--help"], stderr_to_stdout: true)

    for command <- @cli_commands -- ["tightbeam --help"] do
      name = String.replace_prefix(command, "tightbeam ", "")
      assert help =~ name, "compiled help does not contain #{name}"
    end

    refute cli =~ "/agent/dispatch"
    refute cli =~ "Authorization: Bearer"
    refute cli =~ ~s({"verb":)
    refute cli =~ "INSERT INTO"
    refute cli =~ "UPDATE work_items"
  end

  test "the REST edition pins compatibility, request, and response boundaries", ctx do
    rest = skill_bytes(@rest_name)

    for marker <- [
          "GET /version",
          "protocolVersion: 1",
          ~s(version: "0.2.0"),
          "POST /agent/dispatch",
          "Authorization: Bearer <session token>",
          "Content-Type: application/json",
          "x-tightbeam-cli-version: 0.2.0",
          "A 200 response with `result`",
          "A 202 response with `decisionPending`",
          "A non-2xx response with `error.code`",
          "Any other response is malformed"
        ] do
      assert rest =~ marker
    end

    refute rest =~ ~r/^\s*(?:\$\s*)?tightbeam(?:\s|$)/m

    agent_verbs =
      Router.__info__(:attributes)
      |> Keyword.fetch!(:agent_verbs)
      |> List.flatten()

    bodies = rest_request_bodies(rest)
    assert length(bodies) == 12

    for body <- bodies do
      assert body["verb"] in agent_verbs

      body = substitute_fixture_values(body, ctx)
      response = dispatch(ctx.opts, ctx.session.cli_token, body)
      decoded = JSON.decode!(response.resp_body)

      refute get_in(decoded, ["error", "code"]) in [
               "invalid_message",
               "auth_failed",
               "incompatible_cli"
             ]

      assert response.status in [200, 202] or is_binary(get_in(decoded, ["error", "code"]))
    end
  end

  test "the README gives one choose-one installation path before source installation" do
    readme = File.read!(Path.join(repo_root(), "README.md"))

    section = "## External-agent operation skill"
    install = "## Two ways to install"

    assert :binary.match(readme, section) < :binary.match(readme, install)
    assert readme =~ "priv/skills/tightbeam-cli/SKILL.md"
    assert readme =~ "priv/skills/tightbeam-rest-0-2-0/SKILL.md"
    assert readme =~ "Choose one transport edition"
    assert readme =~ ".codex/skills/<skill-name>/"
    assert readme =~ ".claude/skills/<skill-name>/"
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

  defp external_edition_names do
    skills_root()
    |> File.ls!()
    |> Enum.filter(
      &(String.starts_with?(&1, "tightbeam-cli") or String.starts_with?(&1, "tightbeam-rest"))
    )
    |> Enum.sort()
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

  defp rest_request_bodies(rest) do
    rest
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, ~s({"verb":)))
    |> Enum.map(&JSON.decode!/1)
  end

  defp substitute_fixture_values(value, ctx) when is_map(value) do
    Map.new(value, fn {key, child} -> {key, substitute_fixture_values(child, ctx)} end)
  end

  defp substitute_fixture_values(value, ctx) when is_list(value) do
    Enum.map(value, &substitute_fixture_values(&1, ctx))
  end

  defp substitute_fixture_values(value, ctx) when is_binary(value) do
    value
    |> String.replace("wi_example", ctx.work_item_id)
    |> String.replace("asg_example", ctx.assignment_id)
    |> String.replace("owner-id", ctx.owner_id)
    |> String.replace("current-session-key", ctx.session.session_key)
  end

  defp substitute_fixture_values(value, _ctx), do: value

  defp result!(response) do
    assert response.status == 200, "dispatch refused: #{response.resp_body}"
    JSON.decode!(response.resp_body)["result"]
  end

  defp dispatch(opts, bearer, body) do
    conn(:post, "/agent/dispatch", JSON.encode!(Map.put_new(body, :params, %{})))
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
    |> Router.call(Router.init(opts))
  end

  defp skill_bytes(name), do: name |> skill_path() |> File.read!()
  defp skill_path(name), do: Application.app_dir(:tightbeam, "priv/skills/#{name}/SKILL.md")
  defp skills_root, do: Application.app_dir(:tightbeam, "priv/skills")
  defp release_cli, do: Path.join(repo_root(), "cli/target/release/tightbeam")
  defp repo_root, do: Path.expand("..", __DIR__)
end
