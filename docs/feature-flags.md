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
| `harness_switch_context_enabled` | Captures bounded source context at a harness switch and binds a fitting historical section to the first destination prompt. | `true` | Gateway | Remove after real release-soak acceptance confirms portable context and destination fit across supported harnesses. |
| `TIGHTBEAM_EXECUTION_MAP_TURN_BACKFILL=true` | Starts the execution-map turn backfill at gateway startup and enables indexed turn dependencies once it finishes. | `false` | Gateway release owner | Remove after a cold real-data check and a release soak confirm acceptable writer hold and ordinary turn-write cost. |
| `work_item_waits_enabled` (`TIGHTBEAM_WORK_ITEM_WAITS_ENABLED=true`) | Records explicit item waits and quiets only their routing/slate reminders. | `false` | Work-item coordination | Remove after explicit rollout approval and release-soak acceptance. |
| `wait_links_enabled` (`TIGHTBEAM_WAIT_LINKS_ENABLED=true`) | Optional wait reasons, missing-reason notices, bounded wait-chain reads and live waiting indicators. | `false` | Gateway reads | Remove after explicit rollout approval and release-soak acceptance. |
| `work_item_indicators_enabled` (`TIGHTBEAM_WORK_ITEM_INDICATORS_ENABLED=true`) | Serves `GET /api/work-item-indicators` ([work-item indicators](work-item-indicators.md)). | `false` | Gateway reads | Turn on by default once Chat's work-item pills use it in a release; then remove the flag. |


The item-wait table is additive upgrade schema and is created even while the flag is off. Disabled commands refuse without writing rows; reads omit the wait field and reminder logic does not consult item waits. Enabling the flag requires an operator configuration change.


Wait-link indexes are additive upgrade schema and remain installed while off. Existing required reasons for holder waits and separately enabled item waits remain supported. The flag controls only the new optional reason paths, read endpoints and live summary publication.

The work-item indicators route answers exactly like an unknown route while off. Its waiting, running, waits and questions fields also need `wait_links_enabled`; without it they are omitted.
