defmodule Tightbeam.ApplicationDefaultsTest do
  # apply_installed_defaults/2 must derive the no-preference boot default from
  # what the box can ACTUALLY RUN (installed AND onboarded), not merely what is
  # on PATH. The tester-blocking bug (mike repro 2026-08-06, wi_24028d10): BOTH
  # CLIs installed, ONLY codex onboarded -> registry-order claude + claude-sonnet-5,
  # a dead default whose first turn cannot run.
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.{Credentials, Harness, Model}

  setup do
    base = Path.join(System.tmp_dir!(), "tb_defaults_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    # No-preference boot: neither env override may be set for these assertions.
    prev_default_harness = Application.get_env(:tightbeam, :default_harness)
    prev_default_model = Application.get_env(:tightbeam, :default_model)
    Application.delete_env(:tightbeam, :default_harness)
    Application.delete_env(:tightbeam, :default_model)

    on_exit(fn ->
      restore(:default_harness, prev_default_harness)
      restore(:default_model, prev_default_model)
    end)

    %{base: base}
  end

  defp restore(key, nil), do: Application.delete_env(:tightbeam, key)
  defp restore(key, value), do: Application.put_env(:tightbeam, key, value)

  # Write the same onboarded-credential metadata that a real onboard leaves, so
  # Credentials.kind_at reads a non-:none kind for the provider.
  defp onboard!(base, provider) do
    meta = Path.join([Credentials.store_dir(base, provider), ".tightbeam", "credential.json"])
    File.mkdir_p!(Path.dirname(meta))

    File.write!(
      meta,
      JSON.encode!(%{
        "provider" => to_string(provider),
        "onboarded" => true,
        "kind" => "subscription"
      })
    )
  end

  defp config(base), do: %{base_dir: base, default_harness: nil, default_model: nil}

  test "both CLIs installed but ONLY codex onboarded -> defaults to codex, not sonnet", %{
    base: base
  } do
    onboard!(base, :openai)

    updated = Tightbeam.Application.apply_installed_defaults(config(base), [:claude, :codex])

    assert updated.default_harness == :codex
    assert updated.default_model == Harness.module!(:codex).default_model()
    refute updated.default_model == Harness.module!(:claude).default_model()
  end

  test "the sole-onboarded derivation is logged conspicuously and names the available harness", %{
    base: base
  } do
    onboard!(base, :openai)

    log =
      capture_log(fn ->
        Tightbeam.Application.apply_installed_defaults(config(base), [:claude, :codex])
      end)

    assert log =~ "codex is the only onboarded"
  end

  test "claude-only onboarded keeps claude (no regression)", %{base: base} do
    onboard!(base, :anthropic)

    updated = Tightbeam.Application.apply_installed_defaults(config(base), [:claude, :codex])

    assert updated.default_harness == :claude
    assert updated.default_model == Harness.module!(:claude).default_model()
  end

  test "both onboarded keeps registry-order default (no regression)", %{base: base} do
    onboard!(base, :anthropic)
    onboard!(base, :openai)

    updated = Tightbeam.Application.apply_installed_defaults(config(base), [:claude, :codex])

    assert updated.default_harness == Harness.default().id()
  end

  test "none onboarded falls back to the installed-based default without crashing", %{base: base} do
    # No credentials written: readiness will report NOT READY; boot must still
    # pick a default rather than crash.
    updated = Tightbeam.Application.apply_installed_defaults(config(base), [:claude, :codex])

    assert updated.default_harness == Harness.default().id()
    assert %Model{} = updated.default_model
  end

  test "a single installed harness that is NOT onboarded is still chosen (fallback preserved)", %{
    base: base
  } do
    updated = Tightbeam.Application.apply_installed_defaults(config(base), [:codex])

    assert updated.default_harness == :codex
  end
end
