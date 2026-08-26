# Harness adapter seam coverage

Source of truth: `harness-adapter-seam-v1.md`, READY r10. Baseline:
`5ae730c8a32ca423b6107525a25fc438c605aa5d`.

This is the implementation checklist re-derived from this worktree before any
production edit. Line numbers describe the baseline and intentionally drift as
the sites move. A grouped row covers every named line in that group.

## Scan

The inventory was derived with:

```sh
rg -n -g '*.ex' -g '*.exs' \
  -e '(:claude|:codex|"claude"|"codex")' lib config
rg -n -g '*.ex' -g '*.exs' \
  -e 'CODEX_HOME|CLAUDE_CONFIG_DIR|codex-acp|claude-agent-acp|auth\.json|oauth-token|settings\.json|hooks\.json' \
  lib config
rg -n -g '*.ex' -g '*.exs' \
  -e 'case .*harness|if .*harness|unless .*harness|harness in|harness ==' lib config
rg -n -g '*.ex' -g '*.exs' \
  -e '\[:claude, :codex\]|\[:codex, :claude\]|\["claude", "codex"\]|\["codex", "claude"\]' \
  lib config
rg -n -e 'claude|codex|harness' cli/src/*.rs
```

The broad identity scan found 121 lines in 15 Elixir/config files. The
mechanics scan found 41 lines. The Rust scan found the three binding consumers
plus test oracles. SQL single-quoted enum values and the three gate-named
closed-world tests were inspected separately.

## Elixir production and config

| Baseline site | Coupling | Destination / carve-out | Required proof |
|---|---|---|---|
| `config/runtime.exs:15-24` | closed-world env parser | `Harness.parse!/1`; configured value feeds `Harness.default/0` | fixture selectable through runtime/default path; unknown raises |
| `lib/tightbeam/application.ex:31` | hard-coded application default | `Harness.default/0` (product config remains authoritative) | configured default and registry-first fallback |
| `lib/mix/tasks/tightbeam.catalog_diff.ex:9,111-119` | hard-coded catalog sweep | registry (`Harness.all/0`) | catalog diff covers every registered harness |
| `lib/mix/tasks/tightbeam.doctor.ex:10,32-34,63-85` | hard-coded sweep/default | registry plus `Harness.default/0` | doctor inventory is registry-driven |
| `lib/tightbeam/acp/adapter.ex:27-37,61` | home env, permission and effort descriptors | `session_config/2` and launch plan | new/load, strict effort, rollback, contained/uncontained parity |
| `lib/tightbeam/acp/adapter.ex:251-273,555-559` | NEW/LOAD `_meta` shapes | `session_config/2` | new, load, and gate-attestation parity |
| `lib/tightbeam/acp/adapter.ex:410-419` | Codex-private auth envelope | `classify_auth_event/1` | terminal/transient/unknown parity |
| `lib/tightbeam/archetypes.ex:20,699-706` | type and closed-world validation/message | registry plus `Harness.parse!/1` | registry-driven error remains specific and rejecting |
| `lib/tightbeam/codex_acp_patch.ex:53-126` | adapter versions, bundles, package layout, harness dispatch | private implementation used by `ensure_adapter/1`; generic patch primitive may remain substrate-owned | local absence refusal and local/remote patch parity |
| `lib/tightbeam/credentials.ex` | provider completion and exact harness-home install | credential-provider registry lookup plus `credential_path/3` | one regular credential file in the named machine's harness home |
| `lib/tightbeam/credentials.ex:441-448,464-467,507-567` | ceremony executables/env/staging filenames | named provider ceremony/store exemption | onboarding ceremonies unchanged |
| `lib/tightbeam/gateway.ex` | credential service startup | no boot harvest or projection seam | gateway boot never reads or moves credential bytes between homes |
| `lib/tightbeam/gateway.ex:287-290` | Codex-specific catalog option | `fetch_catalog/1` state owned by harness module | catalog startup parity |
| `lib/tightbeam/gateway.ex:353-361` | hard-coded CLI readiness sweep | registry plus `probe_cli/1` | all registered harnesses probed; at least one required |
| `lib/tightbeam/gateway.ex:808-817` | hard-coded org options and provider inference | registry; provider stamped on catalog entry | returned catalog/provider parity |
| `lib/tightbeam/gateway.ex:958-967` | default harness provider mapping | `Harness.default/0`; deferred default-session provider comes from the selected catalog entry | default session parity |
| `lib/tightbeam/gateway.ex:986-1004` | Codex shim construction | `probe_cli/1` / harness-owned launch mechanics | pinned CLI/shim behavior parity |
| `lib/tightbeam/gateway.ex:1158-1162` | hard-coded health inventory | registry | list response contains every registered harness |
| `lib/tightbeam/gateway.ex:1568-1572` | two-field guidance snapshot | registry map | served guidance covers every harness |
| `lib/tightbeam/gateway.ex:2243-2271` | spawn parse and provider mapping with default-to-Claude bug | `Harness.parse!/1`, `credential_provider/0`; later selected catalog entry is provider authority | fixture spawn and unknown raises |
| `lib/tightbeam/gateway.ex:2361-2370` | tune whitelist, parse and provider mapping | registry parse/query | validate → readiness → deliver → persist → barrier |
| `lib/tightbeam/gateway.ex:2437` | persisted harness default-to-Claude decode | `Harness.parse!/1` | unknown persisted value raises |
| `lib/tightbeam/gateway.ex:2594-2634` | harness/provider maps | `credential_provider/0` and registry filtering | credential readiness and transition scoping |
| `lib/tightbeam/gateway.ex:2636-2693` | one-harness provider runtime stop/capture/start | enumerate all registry modules matching `credential_provider/0` | immutable capture and post-success publication; fixture match/nonmatch |
| `lib/tightbeam/gateway.ex:3515-3537` | two-harness model inference and provider map | registry iteration; provider from matched catalog entry | zero/one/multiple semantics |
| `lib/tightbeam/homes.ex` | rails filenames and projection writer | `reconcile_home/3`; home path helper stays neutral | reconciliation preserves every credential and emits no copy/link command |
| `lib/tightbeam/identity.ex:19,95-104,312-329` | guidance prose and skill discovery paths | guidance moves into harness session configuration; skill paths/effects into `materialize_skills/3` | local skill materialization parity |
| `lib/tightbeam/model_catalog.ex:13,29-51,70-161` | closed registry and harness→provider map | registry plus catalog-entry provider stamp | provider authority and registry-driven APIs |
| `lib/tightbeam/model_catalog.ex:170-215,369-372` | transport/path/parser dispatch | `fetch_catalog/1` per harness | both current catalog fixtures and third fixture |
| `lib/tightbeam/org.ex:74-75` | persisted harness/provider `CHECK` enums | persisted-enum carve-out; additive registry-derived DDL literal at schema construction | fixture suite recreates and stores third harness |
| `lib/tightbeam/placement.ex:526-704` | probe provisioning and complete local/remote launch recipes | `prepare_launch/3`, `probe_cli/1`, `session_config/2` | probe destruction/config/model/attestation; local/remote token injection |
| `lib/tightbeam/placement.ex:794-914` | adapter/CLI lookup, token env, provider mapping, skill paths | `ensure_adapter/1`, `probe_cli/1`, `credential_provider/0`, `materialize_skills/3` | requested adapter re-check, CLI pinning, auth/subagent handlers |
| `lib/tightbeam/placement.ex:923-1060` | local/remote home projection, remote preservation, rails/auth filenames | `reconcile_home/3` owns local and remote effects | railed/lawless and local/remote preservation parity |
| `lib/tightbeam/rails.ex:26-37,116` | descriptive harness mechanics literals | documentation carve-out; the scan strips docs and checks the executable remainder | literal scan |
| `lib/tightbeam/spinup.ex:16-214` | per-harness readiness, combined install literal, credential paths | harness `ensure_adapter/1` and `credential_ready?/2`; registry-wide `install_package/0` combiner | combined one-command install and requested executable re-check |
| `lib/tightbeam/subagent_markers.ex:111,116-260` | closed type and private envelope decode | dispatch to `classify_subagent_event/1`; module consumes neutral result | both harness classification fixtures |
| `lib/tightbeam/subagent_markers.ex:26` | persisted harness `CHECK` enum | persisted-enum carve-out; registry-derived DDL literal at schema construction | fixture marker persists |
| `lib/tightbeam/containment.ex:23-28` | Claude-derived static write grants/comment | concatenate registry `containment_additions/0` | existing profile parity |

## Cross-language boundary

| Baseline site | Coupling | Destination / carve-out | Required proof |
|---|---|---|---|
| new route and boot file | no current projection boundary | opaque `wire_projection/0`; route and boot-time `harnesses.json` are its sole Elixir consumers | exact-call-site and decoded-key enforcement |
| `lib/tightbeam/wire/router.ex` | route surface absent | authenticated `GET /harnesses` serving the same opaque bytes | file/route byte identity |
| `lib/tightbeam/boot.ex` and gateway composition | boot persistence absent | write `harnesses.json` beside `gateway.json` on every boot | offline CLI fixture |
| `cli/src/args.rs:215,223,281,779-783` | two help lists, named example, default list | fetched projection; neutral `tightbeam doctor` pointer without projection | fixture appears; absent names do not |
| `cli/src/ceremonies.rs:153-157,226-248` | assimilation closed-world validation | projection wire names | fixture validates and defaults |
| `cli/src/ceremonies.rs:271-275` | embedded adapter package set | projection install-package fields | fixture package provisioned |
| `cli/src/ceremonies.rs:87-132` | provider-owned onboarding ceremony | provider-ceremony carve-out; unchanged | onboarding tests |
| `cli/src/probe.rs:155,215,338-352,413-522,884-902` | static marker scan and static string lifetimes | projection process markers/wire names | positive and negative marker fixtures |
| `cli/src/args.rs`, `cli/src/ceremonies.rs`, `cli/src/probe.rs` test modules | current-name literals | test-oracle carve-out, reconciled/additive where closed-world | conformance round trip and negative help assertions |
| `cli/src/dispatch.rs:671-682` | request serialization fixture | test-oracle carve-out | serialization parity |

## Tests and documentation carve-outs requiring reconciliation

Harness-name literals in ordinary test setup and conformance worlds are parity
oracles, not production coupling. They remain valid unless their subject is a
closed world. The specifically closed-world subjects are:

| Site | Classification | Required reconciliation |
|---|---|---|
| `test/archetypes_test.exs:180-184` (spec's former `:562` anchor) | test oracle with exact two-name message | expected valid-name text derives from registry while still rejecting the bad value |
| `test/gateway_test.exs` model-inference probe (spec's former `:638` anchor) | test oracle with two-clause probe | registry-driven zero/one/multiple probe including fixture |
| doctor test in `test/mix_tasks_test.exs` (spec's former `tightbeam_doctor_test.exs:29` anchor) | test oracle with two-inventory catalog | registry-driven inventory including fixture |
| `test/model_catalog_test.exs`, `test/spinup_test.exs`, `test/placement_test.exs`, `test/homes_test.exs`, `test/acp_adapter_test.exs`, `test/subagent_markers_test.exs` | parity oracles | retain subjects and add the spec's seam/parity cases |
| `docs/**`, `priv/**`, `scripts/**`, test fixtures | docs/fixture carve-out | no production dispatch; names may remain as examples/oracles |

## Credential kinds and the seam surface

A host holds one credential per provider, of either KIND (API key or
subscription), recorded in `credential.json`. Three seams dispatch on it; the
rest do not, and the split is worth stating because it decides where a kind
argument belongs.

| Seam | Kind-dispatched? | Why |
|---|---|---|
| `prepare_launch/3` | YES for claude, NO for codex | claude carries its credential in an environment variable whose NAME is the kind; codex reads its own `auth.json`, so its plan is kind-invariant — pinned by running both kinds through the conformance vectors rather than assumed |
| `fetch_catalog/1` | YES, both | claude: one route, two headers. codex: two ROUTES answering in two SHAPES, so two derivations |
| `credential_live?/3` | YES, both | no single call authenticates both kinds on either provider |
| `credential_ready?/2`, `reconcile_home/3`, `owned_home_entries/0` | NO | they name the exact home and credential file; reconciliation does not own that file |

The kind is never read by a harness module. It is resolved by the caller that
already knows `{host, provider}` — `ModelCatalog`, `Placement`, the e2e
preflight — and injected, so `Tightbeam.Credentials` stays the one authority and
the harness modules stay stateless.

## Findings

Every discovered production coupling maps to a required seam operation,
registry use, persisted-enum carve-out, provider ceremony/store carve-out, or
cross-language consumer. There are no unmapped sites in the baseline scan.
