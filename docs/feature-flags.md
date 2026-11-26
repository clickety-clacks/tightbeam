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
| `TIGHTBEAM_PEOPLE_MESSAGE_RELAY_SESSION` | Grants one authenticated session permission to collect and report queued people-message operations and submit inbound events. Queued operations remain undelivered until a configured relay reports them. | Unset | Gateway | Keep the explicit relay permission while an independent relay can serve the organization. |
