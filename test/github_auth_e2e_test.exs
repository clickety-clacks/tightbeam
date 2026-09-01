defmodule Tightbeam.GithubAuthE2ETest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Archetypes, DB, GithubCredentials, Model, Org, Placement, Rails}

  @secret "ghp_fixture_NEVER_PRINT"

  setup do
    root = Path.join(System.tmp_dir!(), "github-kind-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "identity/archetypes"))

    File.write!(Path.join(root, "identity/archetypes/work.toml"), """
    name = "work"
    where = ["testhost"]
    [provisioning]
    class = "workshop"
    [provisioning.credentials.github]
    profile = "work"
    """)

    File.write!(Path.join(root, "identity/archetypes/personal.toml"), """
    name = "personal"
    where = ["testhost"]
    [provisioning]
    class = "workshop"
    [provisioning.credentials.github]
    profile = "personal"
    """)

    Archetypes.load!(root)
    Rails.load!(root)

    db = :"github_kind_e2e_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Org.ensure_schema(db)
    :ok = Placement.ensure_schema(db)
    :ok = GithubCredentials.ensure_schema(db)

    old_advertised = Application.get_env(:tightbeam, :advertised_url)
    Application.put_env(:tightbeam, :advertised_url, "http://fixture-gateway:4000")

    on_exit(fn ->
      File.rm_rf!(root)
      :persistent_term.erase(Tightbeam.Archetypes)
      :persistent_term.erase(Tightbeam.Rails)

      if old_advertised,
        do: Application.put_env(:tightbeam, :advertised_url, old_advertised),
        else: Application.delete_env(:tightbeam, :advertised_url)
    end)

    %{root: root, db: db}
  end

  test "provider homes isolate profiles and metadata checks never copy secret bytes", ctx do
    work = GithubCredentials.home(ctx.root, "testhost", "work")
    personal = GithubCredentials.home(ctx.root, "testhost", "personal")
    legacy = Path.join(ctx.root, "auth/github/gh")

    for home <- [work, personal, legacy] do
      File.mkdir_p!(home)
      File.chmod!(home, 0o700)

      File.write!(
        Path.join(home, "hosts.yml"),
        "github.com:\n  oauth_token: #{@secret}-#{Path.basename(home)}\n"
      )

      File.chmod!(Path.join(home, "hosts.yml"), 0o600)
    end

    assert GithubCredentials.storage(work) == :valid
    assert GithubCredentials.storage(personal) == :valid
    assert GithubCredentials.storage(legacy) == :valid
    assert work != personal

    assert File.read!(Path.join(work, "hosts.yml")) =~ "#{@secret}-work"
    assert File.read!(Path.join(personal, "hosts.yml")) =~ "#{@secret}-personal"
    assert File.read!(Path.join(legacy, "hosts.yml")) =~ "#{@secret}-gh"

    serialized = inspect(GithubCredentials.projection(ctx.root, "testhost", "work"))
    refute serialized =~ @secret
    refute serialized =~ legacy
  end

  test "projection keys partition same-profile principals and different profiles", _ctx do
    base = %{
      harness: "codex",
      host: "testhost",
      state: "active",
      overrides: nil,
      identity_name: "work"
    }

    first = Map.merge(base, %{session_key: "agent:first", archetype: "work"})
    second = Map.merge(base, %{session_key: "agent:second", archetype: "work"})
    personal = Map.merge(base, %{session_key: "agent:third", archetype: "personal"})

    first_key = Placement.adapter_key(first)
    second_key = Placement.adapter_key(second)
    personal_key = Placement.adapter_key(personal)

    assert first_key != second_key
    assert first_key != personal_key
    assert second_key != personal_key

    for {:codex, fingerprint, "testhost"} <- [first_key, second_key, personal_key] do
      assert fingerprint =~ ~r/^projection-[0-9a-f]{24}$/
      refute fingerprint =~ "agent:"
      refute fingerprint =~ "work"
      refute fingerprint =~ "personal"
    end
  end

  test "local and remote adapters receive only their elected host profile", ctx do
    config = %{
      base_dir: ctx.root,
      db: ctx.db,
      cwd: ctx.root,
      cli_bin: Path.join(ctx.root, "bin"),
      default_model: Model.new("fable"),
      projection_principal: "session:agent:first",
      github_profile: "work",
      sh: fn command ->
        if Enum.any?(command, &String.contains?(&1, "credential-harvest")) and
             Enum.any?(command, &String.contains?(&1, "cat")),
           do: {"", 42},
           else: {"", 0}
      end
    }

    local = Placement.adapter_opts(config, {:codex, "projection-fixture", "testhost"})
    local_home = GithubCredentials.home(ctx.root, "testhost", "work")
    assert {"TIGHTBEAM_PRINCIPAL", "session:agent:first"} in local[:env]
    assert {"TIGHTBEAM_GITHUB_PROFILE", "work"} in local[:env]
    assert {"GH_CONFIG_DIR", local_home} in local[:env]
    assert Enum.take(local[:cmd], 2) == ["env", "-u"]

    assert {:ok, _host} =
             Placement.register_host(ctx.db, "worker", %{
               ssh: "fixture@worker",
               base_dir: "/srv/tightbeam",
               cli_bin: "/srv/tightbeam/bin"
             })

    remote = Placement.adapter_opts(config, {:codex, "projection-fixture", "worker"})
    assert "TIGHTBEAM_PRINCIPAL='session:agent:first'" in remote[:cmd]
    assert "TIGHTBEAM_GITHUB_PROFILE='work'" in remote[:cmd]
    assert "GH_CONFIG_DIR='/srv/tightbeam/credential-homes/worker/github/work'" in remote[:cmd]
    refute inspect(remote) =~ local_home

    rendered = inspect([local[:env], local[:cmd], remote[:cmd]])
    refute rendered =~ @secret

    for token <- ~w(GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN) do
      assert token in local[:cmd]
      assert token in remote[:cmd]
    end
  end

  test "hollow storage fixtures fail before provider work", ctx do
    home = GithubCredentials.home(ctx.root, "testhost", "work")
    File.mkdir_p!(home)
    File.chmod!(home, 0o700)
    hosts = Path.join(home, "hosts.yml")

    assert GithubCredentials.storage(home) == :absent
    File.write!(hosts, "")
    File.chmod!(hosts, 0o600)
    assert GithubCredentials.storage(home) == {:hollow, "hosts_yml_empty"}

    File.write!(hosts, "github.com:\n")
    File.chmod!(hosts, 0o644)
    assert GithubCredentials.storage(home) == {:hollow, "hosts_yml_permissions"}

    File.rm!(hosts)
    File.ln_s!("missing", hosts)
    assert GithubCredentials.storage(home) == {:hollow, "hosts_yml_not_regular"}
  end
end
