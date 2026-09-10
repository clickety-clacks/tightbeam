import ExUnit.Assertions
alias Tightbeam.{Gateway, Model}
[payload, base, locks] = System.argv()
assert Path.expand(Application.app_dir(:tightbeam)) == Path.expand(payload)
{:ok, _} = Application.ensure_all_started(:logger)
bin = Path.join(Path.dirname(base), "broken-gateway-cli")
File.mkdir_p!(bin)
codex = Path.join(bin, "codex")
File.write!(codex, "#!/bin/sh\necho broken >&2\nexit 1\n")
File.chmod!(codex, 0o755)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :fixture_harness, false)
System.put_env("PATH", bin)
refute File.exists?(base)
# Preflight must refuse before DB admission or any org artifact creation.
exception =
  assert_raise RuntimeError, fn ->
    Gateway.children(%{
      base_dir: base,
      cwd: base,
      port: 0,
      db: Tightbeam.DB,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      guard_inputs: [lock_dir: locks]
    })
  end

message = Exception.message(exception)
assert message =~ "no usable harness CLI"
assert message =~ "codex: exec failed"
assert message =~ "Install a registered harness CLI"
refute File.exists?(base)
IO.puts("guarded-gateway-refusal: ok")
