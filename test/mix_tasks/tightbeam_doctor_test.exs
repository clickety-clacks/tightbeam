defmodule Mix.Tasks.Tightbeam.DoctorTest do
  use ExUnit.Case, async: true

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
      default_model: "claude-live[medium]",
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
         "claude" => [%{ref: "claude-live[medium]"}],
         "codex" => [%{ref: "codex-live[high]"}],
         "fixture" => [%{ref: "fixture-model"}]
       }}

    %{base_dir: base_dir, catalog: catalog, inputs: inputs}
  end

  test "all bootstrap checks pass with hermetic inputs", ctx do
    assert {0, %{ready: true, checks: checks}} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert Enum.all?(checks, & &1.ok)
  end

  test "injected default model passes when live and fails when invalid", ctx do
    {_status, passing} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert find(passing, "default_model").ok

    for model <- [nil, "claude-live", "claude-dead[medium]"] do
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

    fixture = Path.expand("../fixtures/model_catalog/codex_models_cache.jsonc", __DIR__)
    codex_json = fixture_body(fixture)

    catalog =
      Mix.Tasks.Tightbeam.Catalog.Diff.fetch_live(ctx.base_dir, 1_000,
        name: :"doctor_catalog_#{System.unique_integer([:positive])}",
        credential_status: fn
          :anthropic -> {:needs_onboarding, :dead_credential}
          _provider -> :onboarded
        end,
        codex_read: fn _path -> {:ok, codex_json} end
      )

    assert {:ok, %{"claude" => [], "codex" => [_ | _]}, %{"claude" => reason}} = catalog
    assert reason == {:unavailable, {:needs_onboarding, :dead_credential}}

    inputs =
      ctx.inputs
      |> put(:default_harness, :codex)
      |> put(:default_model, "gpt-5.6-sol[medium]")

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

  defp put(inputs, key, value), do: Keyword.put(inputs, key, value)
  defp find(report, name), do: Enum.find(report.checks, &(&1.name == name))

  defp fixture_body(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&String.starts_with?(&1, "//"))
    |> Enum.join("\n")
  end
end
