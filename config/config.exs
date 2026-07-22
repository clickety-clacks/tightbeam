import Config

config :tightbeam, :escalation_decision_deadline_ms, 86_400_000

if config_env() == :test do
  import_config "test.exs"
end