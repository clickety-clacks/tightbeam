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
      local_host_name: "local-test"
    ]

    catalog =
      {:ok,
       %{
         "claude" => [%{ref: "claude-live[medium]"}],
         "codex" => [%{ref: "codex-live[high]"}]
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

  test "each configured harness auth passes only with a fetched non-empty inventory", ctx do
    {_status, passing} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert find(passing, "harness_auth:claude").ok
    assert find(passing, "harness_auth:codex").ok

    catalog = put_in(ctx.catalog, [Access.elem(1), "codex"], [])
    {1, report} = Doctor.evaluate(catalog, ctx.inputs)
    failed = find(report, "harness_auth:codex")

    refute failed.ok
    assert failed.detail =~ "dead_sign_in: harness=codex reason=:empty_inventory"
    assert failed.fix =~ "Re-onboard the codex"
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
  end

  defp put(inputs, key, value), do: Keyword.put(inputs, key, value)
  defp find(report, name), do: Enum.find(report.checks, &(&1.name == name))
end
