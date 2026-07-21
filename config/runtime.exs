import Config

if value = System.get_env("TIGHTBEAM_BASE_DIR") do
  config :tightbeam, :base_dir, value
end

if value = System.get_env("TIGHTBEAM_PORT") do
  config :tightbeam, :port, String.to_integer(value)
end

if value = System.get_env("TIGHTBEAM_CWD") do
  config :tightbeam, :cwd, value
end

if value = System.get_env("TIGHTBEAM_DEFAULT_HARNESS") do
  _ = [:claude, :codex]

  harness =
    case value do
      "claude" -> String.to_existing_atom("claude")
      "codex" -> String.to_existing_atom("codex")
    end

  config :tightbeam, :default_harness, harness
end

if value = System.get_env("TIGHTBEAM_DEFAULT_MODEL") do
  config :tightbeam, :default_model, value
end

if value = System.get_env("TIGHTBEAM_WAKE_TICK_MS") do
  config :tightbeam, :wake_tick_ms, String.to_integer(value)
end

if value = System.get_env("TIGHTBEAM_PROD_LIMIT") do
  config :tightbeam, :prod_limit, String.to_integer(value)
end

if value = System.get_env("TIGHTBEAM_ADVERTISED_URL") do
  config :tightbeam, :advertised_url, value
end

# Hosts are instance config (spec §Placement): JSON map of
# name => {"ssh": destination-or-null, "base_dir": path, "cli_bin": path?}.
# The gateway's own machine is merged in by Placement.hosts/1 under its
# real hostname (override: TIGHTBEAM_LOCAL_HOST_NAME).
if value = System.get_env("TIGHTBEAM_HOSTS") do
  hosts =
    for {name, h} <- JSON.decode!(value), into: %{} do
      {name,
       %{
         ssh: h["ssh"],
         base_dir: Map.fetch!(h, "base_dir"),
         cli_bin: h["cli_bin"],
         adapter_bin_dir: h["adapter_bin_dir"]
       }}
    end

  config :tightbeam, :hosts, hosts
end

if value = System.get_env("TIGHTBEAM_DRAIN_TIMEOUT_MS") do
  config :tightbeam, :drain_timeout_ms, String.to_integer(value)
end

if value = System.get_env("TIGHTBEAM_LOCAL_HOST_NAME") do
  config :tightbeam, :local_host_name, value
end
