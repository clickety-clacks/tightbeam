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
| `TIGHTBEAM_PEOPLE_MESSAGING` | Enables neutral people-message commands, storage and conversation routing. Set to `true` at gateway boot to opt in. Disabled boots leave existing people-message tables untouched and do not create them. | `false` | Gateway | Remove when people messaging is ready for default activation. |
| `TIGHTBEAM_PEOPLE_MESSAGE_RELAY_SESSION` | When people messaging is enabled, grants one authenticated session permission to collect and report queued people-message operations and submit inbound events. Queued operations remain undelivered until a configured relay reports them. | Unset | Gateway | Keep the explicit relay permission while an independent relay can serve the organization. |
| `harklight_pending_open_enabled` (`TIGHTBEAM_HARKLIGHT_PENDING_OPEN_ENABLED` at gateway startup) | Enables pending reads for first opens and expired checkpoints, plus their durable open state. | `false` | Gateway | Remove after soak acceptance on the real Agent/Server pair. |
| `harklight_grouped_outage_notices_enabled` (`TIGHTBEAM_HARKLIGHT_GROUPED_OUTAGE_NOTICES_ENABLED` at gateway startup) | Groups nearby listener outages by recipient and persists recoveries for grouped delivery. | `false` | Gateway | Remove after soak acceptance on the real Agent/Server pair. |
| `TIGHTBEAM_FIRST_RUN_ONBOARDING=true` | Enables the once-per-installation Chat welcome when setup invokes `tightbeam onboard --first-run`. | `false` | Installer owner | Keep setup opt-in until prompt approval and first-run acceptance on supported installers, then remove with the installer default change. |
| `TIGHTBEAM_HARKLIGHT_ITEM_ID_MATCHING=true` | Uses captured opaque Harklight item IDs for pre-0.2 routing and changes. Enable after capture reports zero remaining. | `false` | Gateway release owner | Remove after supported installations have recorded their retained item IDs and the release soak confirms item-ID-only routing and changes. |
| `TIGHTBEAM_HARKLIGHT_ITEM_ID_CAPTURE=true` | Captures opaque IDs for pre-0.2 sends using a read that does not mark delivery. Can run with routing disabled. The gateway logs `Harklight item ID capture remaining=0` when complete. | `false` | Gateway release owner | Remove with the transitional Server field after supported installations finish capture. |
| `provider_accounts_enabled` | Creates the provider-account schema and enables shared-login backfill at gateway startup. | `false` | Gateway | Remove after provider-account lifecycle and upgrade acceptance. |
