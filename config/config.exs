import Config

config :tightbeam, :escalation_decision_deadline_ms, 86_400_000

# Compaction uses the host's existing gateway ACP access. The selected model
# must be offered in the exact host/harness catalog and cheaper than the source.
config :tightbeam, :harness_switch_context_enabled, true
config :tightbeam, :harklight_pending_open_enabled, false
config :tightbeam, :harklight_grouped_outage_notices_enabled, false

source = %{
  source_model: "gpt-6-sol",
  source_model_contexts: [nil],
  source_context_tier: "standard-short",
  compactor_context_tier: "standard-short",
  source_processing_tier: "default",
  compactor_processing_tier: "default",
  source_input_usd_per_million: 2.0,
  source_output_usd_per_million: 10.0,
  source_price_url: "https://developers.openai.com/api/docs/models/gpt-6-sol",
  price_unit: "USD per 1M text tokens",
  checked_on: "2026-11-21"
}

config :tightbeam, :harness_switch_context, %{
  compactors: [
    %{
      route: :codex_acp,
      harness: Tightbeam.Harness.Codex,
      model: "gpt-6-luna",
      effort: "low",
      max_output_tokens: 16_000,
      protocol_overhead_bytes_upper: 512,
      source_applicability: [
        Map.merge(source, %{
          compactor_model: "gpt-6-luna",
          compactor_input_usd_per_million: 0.1,
          compactor_output_usd_per_million: 0.5,
          compactor_price_url: "https://developers.openai.com/api/docs/models/gpt-6-luna"
        })
      ]
    },
    %{
      route: :acp,
      harness: Tightbeam.Harness.Claude,
      model: "claude-haiku-5-5",
      effort: "low",
      max_output_tokens: 16_000,
      protocol_overhead_bytes_upper: 512,
      # Use the higher of Haiku's two published rates as the price bound.
      source_applicability: [
        Map.merge(source, %{
          compactor_model: "claude-haiku-5-5",
          compactor_input_usd_per_million: 0.5,
          compactor_output_usd_per_million: 2.5,
          compactor_price_url: "https://platform.claude.com/docs/en/models/haiku-5-5/overview"
        })
      ]
    }
  ]
}

if config_env() == :test do
  import_config "test.exs"
end
