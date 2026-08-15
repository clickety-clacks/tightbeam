defmodule Mix.Tasks.Tightbeam.DoctorTest do
  use ExUnit.Case, async: true

  import Tightbeam.TestCase, only: [catalog_reply: 1]

  alias Mix.Tasks.Tightbeam.Doctor

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-doctor-#{System.unique_integer([:positive])}")

    identity_dir = Path.join(base_dir, "identity")
    File.mkdir_p!(Path.join(identity_dir, ".git"))
    File.write!(Path.join([identity_dir, ".git", "HEAD"]), "ref: refs/heads/main\n")
    File.write!(Path.join(identity_dir, "README.md"), "identity")
    on_exit(fn -> File.rm_rf!(base_dir) end)

    inputs = [
      base_dir: base_dir,
      default_model: Tightbeam.Model.new("claude-live", effort: "medium"),
      default_harness: :claude,
      advertised_url: "https://tightbeam.example",
      hosts: %{"local-test" => %{ssh: nil, base_dir: base_dir, cli_bin: nil}},
      local_host_name: "local-test",
      cli_bin: Path.join(base_dir, "bin"),
      harness_binary_probe: fn harness, _cli_bin ->
        {:ok, %{bin: "/fake/#{harness}", version: "#{harness} 1.0"}}
      end
    ]

    catalog =
      {:ok,
       %{
         "claude" => [entry("claude-live", ["medium"])],
         "codex" => [entry("codex-live", ["high"])],
         "fixture" => [entry("fixture-model", [])]
       }}

    %{base_dir: base_dir, catalog: catalog, inputs: inputs}
  end

  test "all bootstrap checks pass with hermetic inputs", ctx do
    assert {0, %{ready: true, checks: checks}} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert Enum.all?(checks, & &1.ok)
  end

  # The ENTRY decides whether an effort is required. Rejecting `nil` out of hand
  # failed a perfectly valid default on an untiered model — a false readiness
  # verdict on a selection the gateway and the catalog both accept.
  test "an untiered default model is live without an effort, and a tiered one names its levels",
       ctx do
    catalog =
      {:ok,
       %{
         "claude" => [entry("claude-flat", [])],
         "codex" => [entry("codex-tiered", ["low", "high"])],
         "fixture" => []
       }}

    untiered = put(ctx.inputs, :default_model, Tightbeam.Model.new("claude-flat"))
    {_status, report} = Doctor.evaluate(catalog, untiered)
    assert find(report, "default_model").ok

    # …and an effort on a model that has none is refused, by name.
    with_effort =
      put(ctx.inputs, :default_model, Tightbeam.Model.new("claude-flat", effort: "high"))

    {_status, report} = Doctor.evaluate(catalog, with_effort)
    check = find(report, "default_model")
    refute check.ok
    assert check.detail =~ "has no effort tiers"

    # A TIERED model with no effort fails, and says which levels it has rather
    # than sending the operator to re-pick a model that was never the problem.
    tiered =
      ctx.inputs
      |> put(:default_harness, :codex)
      |> put(:default_model, Tightbeam.Model.new("codex-tiered"))

    {_status, report} = Doctor.evaluate(catalog, tiered)
    check = find(report, "default_model")
    refute check.ok
    assert check.detail =~ "offers low|high"
  end

  test "injected default model passes when live and fails when invalid", ctx do
    {_status, passing} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert find(passing, "default_model").ok

    # nil: unset. Bare family: no effort chosen. Unknown family: not offered.
    # A context variant of a live model is NOT the live model, which is exactly
    # what a stripped suffix used to hide.
    for model <- [
          nil,
          Tightbeam.Model.new("claude-live"),
          Tightbeam.Model.new("claude-dead", effort: "medium"),
          Tightbeam.Model.new("claude-live", effort: "medium", context: "1m")
        ] do
      {_status, report} = Doctor.evaluate(ctx.catalog, put(ctx.inputs, :default_model, model))
      check = find(report, "default_model")

      refute check.ok
      assert check.fix =~ "TIGHTBEAM_DEFAULT_MODEL"
      assert check.fix =~ "mix tightbeam.catalog.diff"
    end
  end

  test "fetch_live preserves ready harnesses and doctor warns for one dead credential", ctx do
    {_status, passing} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert find(passing, "harness_auth:claude").ok
    assert find(passing, "harness_auth:codex").ok

    fixture = Path.expand("../fixtures/model_catalog/codex_models.jsonc", __DIR__)
    codex_json = fixture_body(fixture)

    # fetch_live blocks in await_fresh until every harness inventory reports a
    # settled health, so it returns as soon as the async refreshes land and this
    # number is only a ceiling on pathology. It has to stay well clear of real
    # scheduling delay: at 1_000 the deadline expired under four concurrent full
    # suites and the call returned {:error, %{"claude" => {:unavailable,
    # :not_derived}, "codex" => {:unavailable, :not_derived}}}.
    catalog =
      Mix.Tasks.Tightbeam.Catalog.Diff.fetch_live(ctx.base_dir, 20_000,
        name: :"doctor_catalog_#{System.unique_integer([:positive])}",
        credential_status: fn
          :anthropic -> {:needs_onboarding, :dead_credential}
          _provider -> :onboarded
        end,
        sh: fn _command -> catalog_reply(codex_json) end
      )

    assert {:ok, %{"claude" => [], "codex" => [_ | _]}, %{"claude" => reason}} = catalog
    assert reason == {:unavailable, {:needs_onboarding, :dead_credential}}

    inputs =
      ctx.inputs
      |> put(:default_harness, :codex)
      |> put(:default_model, Tightbeam.Model.new("gpt-5.6-sol", effort: "medium"))

    {0, report} = Doctor.evaluate(catalog, inputs)
    failed = find(report, "harness_auth:claude")

    assert report.ready
    refute failed.ok
    assert failed.level == :warn
    assert failed.detail =~ "dead_sign_in: harness=claude"
    assert failed.detail =~ "dead_credential"
    assert failed.fix =~ "Re-onboard the claude"
    assert find(report, "base_dir_identity").ok
    assert find(report, "advertised_url").ok
    assert find(report, "hosts_registered").ok
  end

  test "one fully ready harness passes while the unavailable harness warns", ctx do
    probe = fn
      :claude, _cli_bin -> {:ok, %{bin: "/fake/claude", version: "claude 1.0"}}
      :codex, _cli_bin -> {:error, :not_found}
      :fixture, _cli_bin -> {:error, :not_found}
    end

    {0, report} =
      Doctor.evaluate(ctx.catalog, put(ctx.inputs, :harness_binary_probe, probe))

    assert report.ready
    assert find(report, "harness_binary:claude").level == :pass
    assert find(report, "harness_binary:codex").level == :warn
    assert find(report, "harness_binary:codex").fix =~ "Install the codex CLI"
    assert Doctor.format(report, :human) =~ "WARN"
  end

  test "zero usable harnesses fails with the non-default harness as WARN", ctx do
    probe = fn _harness, _cli_bin -> {:error, :not_found} end

    {1, report} =
      Doctor.evaluate(ctx.catalog, put(ctx.inputs, :harness_binary_probe, probe))

    refute report.ready
    assert find(report, "harness_binary:claude").level == :fail
    assert find(report, "harness_binary:codex").level == :warn
  end

  test "no credential makes doctor nonzero and prints the readiness remedy", ctx do
    inputs = Keyword.put(ctx.inputs, :credential_state, fn _provider -> :missing end)

    {1, report} = Doctor.evaluate(ctx.catalog, inputs)

    refute report.ready
    auth = find(report, "harness_auth:claude")
    refute auth.ok
    assert auth.detail =~ "Tightbeam has no credential for anthropic on local-test"
    assert auth.detail =~ "normal claude CLI login"
    assert auth.detail =~ Path.join(ctx.base_dir, "auth")
    assert auth.detail =~ "tightbeam onboard anthropic --as-user <userId>"
    assert auth.fix == "tightbeam onboard anthropic --as-user <userId>"
    assert Doctor.format(report, :human) =~ "Tightbeam has no credential"
  end

  # The exit code is the contract a deploy script gates on, so the difference
  # between "this credential is dead" and "this task cannot see credentials"
  # has to be visible THERE, not only in the prose.
  test "an unverifiable credential is informational and does not fail the run", ctx do
    unverifiable = {:unavailable, {:needs_onboarding, :credential_server_unavailable}}

    catalog =
      {:ok, %{"claude" => [], "codex" => []},
       %{"claude" => unverifiable, "codex" => unverifiable}}

    {status, report} = Doctor.evaluate(catalog, ctx.inputs)

    assert status == 0, "a check that could not be performed must not fail the run"
    assert report.ready

    auth = find(report, "harness_auth:claude")
    assert auth.unverifiable
    assert auth.level == :info
    refute auth.ok, "it is still not a PASS — nothing was verified"
    assert auth.detail =~ "UNKNOWN"
    refute auth.detail =~ "dead_sign_in"
    refute auth.fix =~ ~r/^Re-onboard/

    # The same blindness reaches default_model through an empty inventory; calling
    # that "not live" sent the operator to repoint a model that was fine.
    model = find(report, "default_model")
    assert model.unverifiable
    assert model.detail =~ "UNKNOWN"
    refute model.detail =~ "is not live"
  end

  # The precision half: only credential_server_unavailable is unverifiable.
  test "a genuinely dead credential still fails the run", ctx do
    dead = {:unavailable, {:needs_onboarding, :dead_credential}}
    catalog = {:ok, %{"claude" => [], "codex" => []}, %{"claude" => dead, "codex" => dead}}

    {status, report} = Doctor.evaluate(catalog, ctx.inputs)

    assert status == 1, "a dead credential is a real failure and must fail the run"
    refute report.ready

    auth = find(report, "harness_auth:claude")
    refute auth.unverifiable
    assert auth.detail =~ "dead_sign_in"
    assert auth.fix =~ "Re-onboard"
  end

  test "catalog fetch failures are loud and classified for auth and model checks", ctx do
    catalog = {:error, %{"claude" => {:unavailable, :missing_token}}}
    {1, report} = Doctor.evaluate(catalog, ctx.inputs)

    refute report.ready
    assert find(report, "default_model").detail =~ "catalog_unavailable"

    auth = find(report, "harness_auth:claude")
    refute auth.ok
    assert auth.detail =~ "harness=claude"
    assert auth.detail =~ "missing_token"
  end

  test "base dir and populated identity repo each have a fail branch", ctx do
    File.rm_rf!(ctx.base_dir)
    {1, missing} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    refute find(missing, "base_dir_identity").ok
    assert find(missing, "base_dir_identity").fix == "Run mix tightbeam.init."

    File.mkdir_p!(Path.join([ctx.base_dir, "identity", ".git"]))
    {1, empty} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    refute find(empty, "base_dir_identity").ok
  end

  test "injected advertised URL passes and absent URL without a fallback fails", ctx do
    {_status, passing} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert find(passing, "advertised_url").ok

    for value <- [nil, "  "] do
      {1, report} = Doctor.evaluate(ctx.catalog, put(ctx.inputs, :advertised_url, value))
      check = find(report, "advertised_url")
      refute check.ok
      assert check.fix == "Set TIGHTBEAM_ADVERTISED_URL."
    end
  end

  test "local host resolution has pass and fail branches", ctx do
    {_status, passing} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert find(passing, "hosts_registered").ok

    {1, report} = Doctor.evaluate(ctx.catalog, put(ctx.inputs, :hosts, %{}))
    check = find(report, "hosts_registered")
    refute check.ok
    assert check.detail =~ "local-test"
    assert check.fix == "Register a host."
  end

  test "github auth is not checked when the project has no github remote", ctx do
    {0, report} = Doctor.evaluate(ctx.catalog, ctx.inputs)

    refute find(report, "github_auth:github.com")
  end

  test "github auth passes only when the host probe reports live cli and git auth", ctx do
    inputs =
      ctx.inputs
      |> put(:github_remote_url, "https://github.com/example/project.git")
      |> put(:github_probe, fn "github.com", "https://github.com/example/project.git" ->
        {:ok, %{account: "octo", git_protocol: "https"}}
      end)

    {0, report} = Doctor.evaluate(ctx.catalog, inputs)
    check = find(report, "github_auth:github.com")

    assert check.ok
    assert check.detail =~ "GitHub github.com is live for octo via https"
    refute Doctor.format(report, :human) =~ "PAT"
  end

  test "github auth failure names onboarding repair and never asks for a PAT", ctx do
    inputs =
      ctx.inputs
      |> put(:github_remote_url, "git@github.com:example/project.git")
      |> put(:github_probe, fn "github.com", "git@github.com:example/project.git" ->
        {:error, :needs_onboarding,
         "not logged in github_pat_secret https://user:ghp_secret@github.com/example/project.git"}
      end)

    {1, report} = Doctor.evaluate(ctx.catalog, inputs)
    check = find(report, "github_auth:github.com")

    refute report.ready
    refute check.ok
    assert check.detail =~ "needs_onboarding: not logged in"
    refute check.detail =~ "github_pat_secret"
    refute check.detail =~ "ghp_secret"
    assert check.detail =~ "https://[redacted]@github.com/example/project.git"
    assert check.fix =~ "tightbeam onboard github --hostname github.com"
    assert check.fix =~ "Do not paste a PAT into an agent."
  end

  # RULED: doctor never creates org state. An org that has not booted has no DB,
  # so the registry is unreadable — a fact for the table, not a failed check and
  # never a reason to conjure the DB into existence.
  test "an absent org database is a fact row, not a failure", ctx do
    {status, report} = Doctor.evaluate(ctx.catalog, put(ctx.inputs, :hosts, :absent))
    check = find(report, "hosts_registered")

    assert status == 0
    assert check.unverifiable
    assert check.level == :info
    assert check.detail =~ "org database absent"
  end

  test "org_hosts leaves an absent org database absent", ctx do
    db_path = Path.join(ctx.base_dir, "state.db")
    refute File.exists?(db_path)

    assert Doctor.org_hosts(ctx.base_dir) == :absent

    # The never-creates-state half of the ruling: looking did not create it.
    refute File.exists?(db_path)
  end

  test "org_hosts reads a present hosts table through the read-only open", ctx do
    db = :"doctor_org_hosts_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.DB, path: Path.join(ctx.base_dir, "state.db"), name: db})
    :ok = Tightbeam.Placement.ensure_schema(db)

    {:ok, _entry} =
      Tightbeam.Placement.register_host(db, "worker", %{
        ssh: "tb@worker",
        base_dir: "/srv/tb",
        cli_bin: "/srv/tb/bin"
      })

    hosts = Doctor.org_hosts(ctx.base_dir)

    assert hosts["worker"] == %{ssh: "tb@worker", base_dir: "/srv/tb", cli_bin: "/srv/tb/bin"}
    assert hosts[Tightbeam.Placement.local_host_name()].ssh == nil
  end

  test "human and JSON formats expose status, detail, fixes, and readiness", ctx do
    {0, report} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    human = Doctor.format(report, :human)

    assert human =~ "check"
    assert human =~ "status"
    assert human =~ "fix-if-failed"
    assert human =~ "default_model"
    assert human =~ "PASS"

    assert {:ok, %{"ready" => true, "checks" => checks}} =
             report |> Doctor.format(:json) |> JSON.decode()

    assert Enum.any?(checks, &(&1["name"] == "advertised_url" and &1["ok"] == true))
    assert Enum.all?(checks, &is_binary(&1["level"]))
  end

  # AC5, doctor's half: an installed-but-unrunnable harness (on PATH but fails to
  # execute — the gibson codex-as-`.js`-without-node incident) must have its
  # EXECUTABILITY gap named as its own row, distinct from the credential axis —
  # doctor is O5's REFERENCE three-way taxonomy that readiness reflects, so it must
  # not collapse an unrunnable harness into "merely no credential." Regression
  # guard: this behavior already holds and must stay.
  test "an installed-but-unrunnable harness names the executability gap, distinct from credential",
       ctx do
    probe = fn
      :claude, _cli_bin -> {:ok, %{bin: "/fake/claude", version: "claude 1.0"}}
      :codex, _cli_bin -> {:error, {:exec_failed, "node: not found"}}
      :fixture, _cli_bin -> {:ok, %{bin: "/fake/fixture", version: "fixture 1.0"}}
    end

    inputs =
      ctx.inputs
      |> put(:harness_binary_probe, probe)
      |> put(:credential_state, fn _provider -> :missing end)

    {_status, report} = Doctor.evaluate(ctx.catalog, inputs)

    # The executability gap is named on its OWN row and points at the exec failure.
    binary = find(report, "harness_binary:codex")
    refute binary.ok, "an unrunnable codex CLI must not read as OK"
    assert binary.detail =~ "exec_failed", "the executability gap must name the exec failure"

    # …and it is DISTINCT from the credential axis: the credential row still exists
    # and speaks for itself, so codex's problem is never reported as merely
    # "no credential." A runnable harness's binary row stays a PASS.
    assert find(report, "harness_auth:codex"), "the credential axis is a separate row"
    assert find(report, "harness_binary:claude").ok
  end

  defp put(inputs, key, value), do: Keyword.put(inputs, key, value)

  defp entry(family, efforts) do
    %{
      family: family,
      context: nil,
      display_name: family,
      name: family,
      efforts: efforts,
      max_input_tokens: nil,
      capabilities: %{},
      provider: :anthropic
    }
  end

  defp find(report, name), do: Enum.find(report.checks, &(&1.name == name))

  defp fixture_body(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&String.starts_with?(&1, "//"))
    |> Enum.join("\n")
  end
end
