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
