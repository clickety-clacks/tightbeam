alias Tightbeam.LiveBaseAdmission

[payload, base, expected_stamp] = System.argv()
^payload = Path.expand(Application.app_dir(:tightbeam))
base = LiveBaseAdmission.canonical!(base)
Application.put_env(:tightbeam, :autostart, true)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :cwd, base)
Application.put_env(:tightbeam, :local_host_name, "fixture")
Application.put_env(:tightbeam, :port, 0)
Application.put_env(:tightbeam, :fixture_harness, true)
Application.put_env(:tightbeam, :default_harness, :fixture)
Application.put_env(:tightbeam, :default_model, Tightbeam.Model.new("fixture-model"))
Application.put_env(:tightbeam, :drain_timeout_ms, 1_000)

# A SQL export has no build-owner marker. Supply the usual exact transition
# for this disposable base from the independently observed checkout identity.
if expected_stamp != "" and not File.exists?(Path.join(base, "build-owner.json")) do
  %{identity: target} =
    LiveBaseAdmission.prepare!(base <> "-unpopulated", payload_root: payload)

  transition =
    JSON.encode!(%{
      "base" => base,
      "source" => "unmarked",
      "target" => target,
      "expectedSchema" => expected_stamp
    })

  Application.put_env(:tightbeam, :live_base_guard, transition: transition)
end

Application.put_env(:tightbeam, :provider_accounts_enabled, System.get_env("TB_UPGRADE_ACCOUNTS") == "1")

if System.get_env("TB_UPGRADE_INTERRUPT") == "1" do
  Application.put_env(:tightbeam, :provider_schema_checkpoint, fn ->
    IO.puts("UPGRADE_TRANSACTION_OPEN #{System.pid()}")

    receive do
      :finish -> :ok
    end
  end)
end

{:ok, _} = Application.ensure_all_started(:tightbeam)
IO.puts("UPGRADE_READY")
:ok = Application.stop(:tightbeam)
