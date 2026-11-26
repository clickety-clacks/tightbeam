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
| `subtree_rules` (`config :tightbeam, :subtree_rules`; `TIGHTBEAM_SUBTREE_RULES`; read with `Tightbeam.FeatureFlags.subtree_rules?/0`) | Subtree rules: `scope = { subtree_of = "role:<name>" }` and the `roles` filter on statutes, policies and reactions, the `anchor` notice target, every-session default for org rules, and the facts, `contains` operator and `[[reminder]]` form built on them. | `false` | Rules engine | Remove once subtree rules have passed a release soak and the org has adopted them as normal behavior. |
