import Config

config :tightbeam, :escalation_decision_deadline_ms, 86_400_000

# Initial lower-priced compactor route through the gateway's existing Codex
# ACP access for the source model and tier listed below. Its input capacity is
# resolved from the exact host/harness/model catalog entry at switch time.
config :tightbeam, :harness_switch_context_enabled, false

config :tightbeam, :harness_switch_context, %{
  compactor: %{
    route: :codex_acp,
    harness: Tightbeam.Harness.Codex,
    model: "gpt-6-luna",
    effort: "low",
    max_output_tokens: 16_000,
    protocol_overhead_bytes_upper: 512,
    source_applicability: [
      %{
        source_model: "gpt-6-sol",
        source_model_contexts: [nil],
        compactor_model: "gpt-6-luna",
        source_context_tier: "standard-short",
        compactor_context_tier: "standard-short",
        source_processing_tier: "default",
        compactor_processing_tier: "default",
        source_input_usd_per_million: 2.0,
        source_output_usd_per_million: 10.0,
        compactor_input_usd_per_million: 0.1,
        compactor_output_usd_per_million: 0.5,
        source_price_url: "https://developers.openai.com/api/docs/models/gpt-6-sol",
        compactor_price_url: "https://developers.openai.com/api/docs/models/gpt-6-luna",
        price_unit: "USD per 1M text tokens",
        checked_on: "2026-11-11"
      }
    ]
  }
}

if config_env() == :test do
  import_config "test.exs"
end
