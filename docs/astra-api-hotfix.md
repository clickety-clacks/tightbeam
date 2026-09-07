# Astra selection after OpenAI API-key onboarding

## Problem and scope

On Tightbeam 0.1.8 with patched codex-acp 1.1.4 and a separately installed,
natively pinned Codex 0.153.2, switching from subscription authentication to an
OpenAI API key removes Astra from the Tightbeam catalog. Two independent filters
cause this:

1. Codex 0.153.2's API-key `model/list` returns Astra only with
   `includeHidden: true`. The adapter's default query omits it, and selecting
   `gpt-6-astra` through `session/set_config_option` fails with `-32602`.
2. Tightbeam's API-key selectable-model pin admits only `gpt-5.6-sol`.

A direct Responses API request using the same installed key completed on
`gpt-6-astra`; the platform model inventory also included Astra. The observed
failure was not proof of missing account access.

This maintenance candidate requests hidden engine entries and retains only
previously visible entries plus Astra. It does not expose the rest of the hidden
inventory, invent an engine model, or replace the adapter. The API-key catalog
continues to intersect its selectable pin with the provider's returned inventory.
Astra's effort values are recorded from Codex 0.153.2's own model metadata so
existing medium/high selections remain routable after onboarding. Other API-key
entries retain their existing untiered behavior.

The adapter package remains 1.1.4 with one additional idempotent source patch.
Keep the native Codex 0.153.2 `CODEX_PATH` override for the tested combination.
This candidate does not establish compatibility with arbitrary engines or adapter
versions, and does not change production configuration.

## Recorded evidence (2026-09-06)

| Check | Result |
| --- | --- |
| Unmodified ACP 1.1.4 + Codex 0.153.2, real API-key authentication | Astra absent; selection rejected with `-32602 Invalid params` |
| Direct Responses API, same real key, `gpt-6-astra` | HTTP 200, completed, `ASTRA_DIRECT_API_OK` |
| Native `model/list` with the real key | Astra absent by default; present and hidden with `includeHidden: true` |
| PR-produced patched ACP copy, isolated API-key mode with a dummy key | Astra selection and high effort accepted; no generation attempted |
| PR-produced patched ACP copy, restored subscription authentication | Astra/high selection and actual response succeeded; usage metadata identifies `gpt-6-astra` |
| PR-produced patched ACP copy, subscription, adapter restart and `session/load` | Fresh response recalled the previous marker after replayed history was excluded from the observer |

The API-key credential was replaced by the operator's subscription before a full
patched API-key turn was obtained. The isolated dummy-key check exercises real
engine/adapter configuration behavior; it does **not** establish authentication,
entitlement, or generation success. The earlier direct API response and the
subscription ACP response do not substitute for that missing end-to-end test.

`test/fixtures/model_catalog/codex_0_153_2_api_models.json` is a three-model subset
of actual native `model/list(includeHidden: true)` output captured in isolated
API-key mode with a dummy key. It retains Astra, visible Sol, and hidden GPT-5.4.
The regression executes the patched discovery method with this captured payload,
including pagination, and verifies that it preserves metadata, excludes the
unrelated hidden model, and does not synthesize Astra when absent.

## Required before release

- Enforce the Codex 0.153.2 native engine prerequisite for any release rollout;
  older bundled engines were not validated and may lack Astra metadata.
- Complete an actual Astra/high turn through the patched ACP adapter using a real
  API key, then verify startup-hook gate PASS and remembered context after restart.
- Run the required fresh-org `feature_smoke` matrix for both Claude and Codex.
- Confirm baseline and after-change CI gates on supported Linux and macOS.
- Obtain maintenance-owner review and routing before integration; 0.1.8 is frozen.

The observed host's Claude authentication was expired, so the two-harness live
matrix has not been claimed. No production service restart or migration is part
of this PR. Once accepted and packaged, activate only at an idle maintenance
boundary, retain the previous build/override for rollback, and repeat the live
checks with the installed bytes.

## Reproduction sequence

Use a disposable directory and an isolated copy of codex-acp 1.1.4 with the
candidate patch applied. Keep the service adapter untouched. Set `CODEX_PATH`
to the native Codex 0.153.2 executable and `CODEX_HOME` to the intended test
credential home. Do not put the key in command arguments or captured output.

1. Send ACP `initialize` with `protocolVersion: 1`.
2. Send `session/new` with the disposable `cwd` and `mcpServers: []`.
3. Check that the model config option includes `gpt-6-astra`.
4. Send `session/set_config_option` with `configId: "model"`,
   `value: "gpt-6-astra"`; then set `reasoning_effort` to `high`.
5. Send a small `session/prompt` asking for a unique marker; inspect the actual
   response and model usage rather than treating successful selection as a turn.
6. Once idle, stop the isolated adapter, start it again, and send `session/load`
   for the same session and directory. Clear replayed updates from the observer
   before prompting for the remembered marker without repeating it.

Run Tightbeam's separate startup-hook gate and fresh-org feature smoke before
release. A standalone ACP prompt does not prove those gateway checks.

## Local suite record

Base `7311707d`: format check and authoritative Elixir gate passed with
9 doctests, 1,810 tests, 0 failures, 11 existing skips. After this change:
9 doctests, 1812 tests, 0 failures, 11 skipped. Focused adapter/catalog checks: 27 tests, 0 failures.
Shipped privacy and public rule-fact compatibility checks also passed.
These local Linux results do not replace the release gates listed above.
