alias Tightbeam.LiveBaseAdmission

[base, expected_stamp] = System.argv()
base = LiveBaseAdmission.canonical!(base)
Application.put_env(:tightbeam, :autostart, true)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :cwd, base)
Application.put_env(:tightbeam, :local_host_name, "fixture")
Application.put_env(:tightbeam, :drain_timeout_ms, 1_000)

# A SQL export has no build-owner marker. Supply the usual exact transition
# for this disposable base from the independently observed checkout identity.
unless File.exists?(Path.join(base, "build-owner.json")) do
  %{identity: target} =
    LiveBaseAdmission.prepare!(base <> "-unpopulated", payload_root: Application.app_dir(:tightbeam))

  transition =
    JSON.encode!(%{
      "base" => base,
      "source" => "unmarked",
      "target" => target,
      "expectedSchema" => expected_stamp
    })

  Application.put_env(:tightbeam, :live_base_guard, transition: transition)
end

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
