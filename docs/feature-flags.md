# Feature-flag register

This register records the default-off flags used to land large features on
`main`. The branch and release policy lives in [AGENTS.md](../AGENTS.md).

For each feature flag, name the actual configuration control, describe the
behavior it enables, and record its default, accountable owner and removal
condition. Use a public team or responsibility name for ownership rather than a
private user identifier. The removal condition should say when the feature can
become normal behavior or be removed.

This register is not an inventory of every existing configuration option.

| Flag / configuration control | Enabled behavior | Default | Owner | Removal condition |
| --- | --- | --- | --- | --- |
| `TIGHTBEAM_PI_TYPED_TURN_FAILURES=1` | Reports exhausted Pi retries and final Pi turn errors through the gateway's failed-turn route and suppresses automatic replay of those typed failures. | Off | Gateway | Remove after a release soak verifies failure reporting and recovered retries, or after upstream supplies equivalent failure reporting. |
| `harness_switch_context_enabled` | Captures bounded source context at a harness switch and binds a fitting historical section to the first destination prompt. | `true` | Gateway | Remove after real release-soak acceptance confirms portable context and destination fit across supported harnesses. |
| `harklight_pending_open_enabled` (`TIGHTBEAM_HARKLIGHT_PENDING_OPEN_ENABLED` at gateway startup) | Enables pending reads for first opens and expired checkpoints, plus their durable open state. | `false` | Gateway | Remove after soak acceptance on the real Agent/Server pair. |
| `harklight_grouped_outage_notices_enabled` (`TIGHTBEAM_HARKLIGHT_GROUPED_OUTAGE_NOTICES_ENABLED` at gateway startup) | Groups nearby listener outages by recipient and persists recoveries for grouped delivery. | `false` | Gateway | Remove after soak acceptance on the real Agent/Server pair. |
| `TIGHTBEAM_EXECUTION_MAP_TURN_BACKFILL=true` | Starts the execution-map turn backfill at gateway startup and enables indexed turn dependencies once it finishes. | `false` | Gateway release owner | Remove after a cold real-data check and a release soak confirm acceptable writer hold and ordinary turn-write cost. |
| `TIGHTBEAM_FIRST_RUN_ONBOARDING=true` | Enables the once-per-installation Chat welcome when setup invokes `tightbeam onboard --first-run`. | `false` | Installer owner | Keep setup opt-in until prompt approval and first-run acceptance on supported installers, then remove with the installer default change. |
