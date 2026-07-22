import Config

config :tightbeam, :escalation_decision_deadline_ms, 86_400_000
config :tightbeam, :adjudication_claim_window_ms, 300_000
config :tightbeam, :adjudication_response_window_ms, 86_400_000
config :tightbeam, :adjudication_park_fallback_ms, 14_400_000

if config_env() == :test do
  import_config "test.exs"
end
