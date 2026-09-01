defmodule Tightbeam.GithubCredentialsTest do
  use Tightbeam.TestCase, async: true

  alias Tightbeam.{DB, GithubCredentials}

  setup do
    suffix = System.unique_integer([:positive])
    db = String.to_atom("github_credentials_db_#{suffix}")
    base_dir = Path.join(System.tmp_dir!(), "tb-github-credentials-#{suffix}")
    start_supervised!({DB, name: db, path: ":memory:"})
    :ok = GithubCredentials.ensure_schema(db)
    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{db: db, base_dir: base_dir}
  end

  test "profile homes are explicit, disjoint, and contain no credential bytes", ctx do
    assert GithubCredentials.home(ctx.base_dir, "gibson", "work") ==
             Path.join([ctx.base_dir, "credential-homes", "gibson", "github", "work"])

    refute GithubCredentials.home(ctx.base_dir, "gibson", "work") ==
             GithubCredentials.home(ctx.base_dir, "gibson", "personal")

    assert GithubCredentials.projection(ctx.base_dir, "gibson", "work") == [
             {"TIGHTBEAM_GITHUB_PROFILE", "work"},
             {"GH_CONFIG_DIR",
              Path.join([ctx.base_dir, "credential-homes", "gibson", "github", "work"])}
           ]

    for invalid <- ["", "Work", "-work", "work_1", String.duplicate("a", 64)] do
      assert_raise ArgumentError, fn ->
        GithubCredentials.home(ctx.base_dir, "gibson", invalid)
      end
    end
  end

  test "storage validation reads metadata and refuses hollow authorities", ctx do
    home = GithubCredentials.home(ctx.base_dir, "gibson", "default")
    hosts = Path.join(home, "hosts.yml")

    assert GithubCredentials.storage(home) == :absent

    File.mkdir_p!(home)
    ancestors = home |> Stream.iterate(&Path.dirname/1) |> Enum.take(4)
    Enum.each(ancestors, &File.chmod!(&1, 0o700))
    assert GithubCredentials.storage(home) == :absent

    File.write!(hosts, "sentinel-secret")
    File.chmod!(hosts, 0o600)
    assert GithubCredentials.storage(home) == :valid
    assert File.read!(hosts) == "sentinel-secret"

    [_, _, _, credential_homes] = ancestors
    File.chmod!(credential_homes, 0o755)

    assert GithubCredentials.storage(home) ==
             {:hollow, "credential home ancestor_permissions"}

    File.chmod!(credential_homes, 0o700)

    File.chmod!(hosts, 0o644)
    assert GithubCredentials.storage(home) == {:hollow, "hosts_yml_permissions"}

    File.chmod!(hosts, 0o600)
    linked = Path.join(home, "linked")
    File.ln!(hosts, linked)
    assert GithubCredentials.storage(home) == {:hollow, "hosts_yml_link_count"}
    assert File.read!(hosts) == "sentinel-secret"
  end

  test "bindings isolate profiles while the hostname index reveals no identity", ctx do
    for {profile, account} <- [{"work", "octo-work"}, {"personal", "octo-personal"}] do
      assert {:ok, binding} =
               GithubCredentials.upsert_binding(ctx.db, %{
                 machine: "gibson",
                 profile: profile,
                 hostname: "GITHUB.COM.",
                 account: account,
                 state: "live",
                 principal: "user:mike"
               })

      assert binding.profile == profile
      assert binding.account == account
      assert binding.hostname == "github.com"
    end

    assert GithubCredentials.hostname_index(ctx.db, "gibson") == MapSet.new(["github.com"])
    refute inspect(GithubCredentials.hostname_index(ctx.db, "gibson")) =~ "octo-"

    assert GithubCredentials.binding(ctx.db, "gibson", "work", "github.com").account ==
             "octo-work"

    assert GithubCredentials.binding(ctx.db, "gibson", "personal", "github.com").account ==
             "octo-personal"
  end

  test "observations append, redact by construction, and support idempotent mutation receipts",
       ctx do
    attrs = %{
      machine: "gibson",
      profile: "default",
      hostname: "github.com",
      state: "live",
      cause: "provider_api_200",
      principal: "agent:main:test",
      operation_class: "gh",
      phase: "provider",
      rule: "github-network-auth-required",
      dedupe_key: "onboard:gibson:default:github.com:live"
    }

    assert {:ok, first} = GithubCredentials.append_observation(ctx.db, attrs)
    assert {:ok, second} = GithubCredentials.append_observation(ctx.db, attrs)
    assert first.id == second.id

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM github_capability_observations")

    assert {:error, %DB.Error{message: message}} =
             DB.query(
               ctx.db,
               "UPDATE github_capability_observations SET cause = 'changed' WHERE id = ?1",
               [first.id]
             )

    assert message =~ "append-only"
  end

  test "rotation preserves prior authority until one atomic terminal settlement", ctx do
    base = %{
      machine: "gibson",
      profile: "work",
      hostname: "github.com",
      account: "octo-old",
      state: "live",
      principal: "session:producer"
    }

    assert {:ok, _} = GithubCredentials.upsert_binding(ctx.db, base)

    assert {:ok, rotating} =
             GithubCredentials.begin_mutation(
               ctx.db,
               Map.merge(base, %{mutation_attempt: "rotation"})
             )

    assert rotating.state == "live"
    assert rotating.account == "octo-old"
    assert rotating.mutation_attempt == "rotation"

    assert {:ok, outcome} =
             GithubCredentials.commit_outcome(
               ctx.db,
               Map.merge(base, %{mutation_attempt: nil}),
               Map.merge(base, %{
                 operation_class: "rotation",
                 phase: "provider",
                 cause: "provider_login_failed_before_write",
                 dedupe_key: "rotation:gibson:work:github.com:before-write"
               })
             )

    assert outcome.binding.state == "live"
    assert outcome.binding.mutation_attempt == nil

    assert {:ok, [["rotation", "provider_login_failed_before_write"]]} =
             DB.query(
               ctx.db,
               "SELECT operationClass, cause FROM github_capability_observations WHERE id = ?1",
               [outcome.observation.id]
             )
  end

  test "legacy bank remains inert under metadata-only inspection", ctx do
    legacy = Path.join([ctx.base_dir, "auth", "github", "gh"])
    assert GithubCredentials.inert_legacy_residue(ctx.base_dir) == :absent
    File.mkdir_p!(legacy)
    File.chmod!(legacy, 0o700)
    File.write!(Path.join(legacy, "hosts.yml"), "ghp_fixture_must_remain")

    assert {:present, %{type: :directory, mode: 0o700}} =
             GithubCredentials.inert_legacy_residue(ctx.base_dir)

    assert File.read!(Path.join(legacy, "hosts.yml")) == "ghp_fixture_must_remain"
  end

  test "the credential-kind API has no generic byte write", _ctx do
    exports = GithubCredentials.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    refute :write in exports
    refute :put in exports
    refute :store in exports
    refute :read in exports

    source = File.read!("lib/tightbeam/github_credentials.ex")
    refute source =~ "File.read("
    refute source =~ "File.read!("
    refute source =~ "store_harvested"
  end
end
