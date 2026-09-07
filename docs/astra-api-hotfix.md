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
| Fresh hotfix gateway, real API key, Astra/high | Actual response, startup-hook PASS, and remembered phrase after full gateway restart all passed |

A subsequent fresh-org gateway run with a real API key closed the earlier
API-key turn gap. The test used the hotfix source at `1941e7d4`, an isolated
adapter installation, and the same native Codex 0.153.2 engine. The live catalog
advertised Astra and all recorded efforts. Astra/high returned
`ASTRA_API_READY amber harbor 8624`, then, after an idle full gateway restart,
returned `ASTRA_API_RESUMED amber harbor 8624` without the phrase in the second
prompt or a transcript lookup. Both turns were delivered with no error and
recorded `gpt-6-astra` as their model. The startup wiring gate logged PASS before
and after the restart. The disposable canary was retired.

The full fresh-org `feature_smoke` matrix now passes: 13 checks on Claude
and 13 on API-key Codex/Astra, including real artifact-carrying turns and
cross-harness review gates. No failed assertion or rule was disabled. Completing
that gate required repairing the pinned Claude 0.73.0 patch anchors while
preserving upstream completion bookkeeping, and activating its disk-only forks
with `resumeSession` before returning configuration metadata. The fork regression
executes the patched method extracted from recorded upstream source and checks
ordering, metadata preservation, and propagation of a resume failure.

The smoke census now delegates native runtime filenames to the harness registry,
with conformance vectors and negative controls for arbitrary files. Its filesystem
walk tolerates entries that disappear between listing and stat, but still refuses
permission and other IO errors. Existing required-entry and durable-state checks
remain. The review fixtures now file actual committed fixture-check receipts and
the required posture ruling; telemetry assertions use the renamed execution-map
verbs. The smoke gateway uses its required 2500ms effort-check-in horizon.

`test/fixtures/model_catalog/codex_0_153_2_api_models.json` is a three-model subset
of actual native `model/list(includeHidden: true)` output captured in isolated
API-key mode with a dummy key. It retains Astra, visible Sol, and hidden GPT-5.4.
The regression executes the patched discovery method with this captured payload,
including pagination, and verifies that it preserves metadata, excludes the
unrelated hidden model, and does not synthesize Astra when absent.

## Required before release

- Enforce the Codex 0.153.2 native engine prerequisite for any release rollout;
  older bundled engines were not validated and may lack Astra metadata.
- Repeat the required fresh-org matrix for any changed engine, adapter, or source revision.
- Confirm baseline and after-change CI gates on supported Linux and macOS.
- Obtain maintenance-owner review and routing before integration; 0.1.8 is frozen.

The two-harness live matrix passed on the final candidate. No production service restart or migration is part
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
9 doctests, 1818 tests, 0 failures, 11 skipped. Overlay installer safety: 6 tests, 0 failures. The original focused adapter/catalog gate passed 27 tests; the later conformance, census and adapter gate passed 20 tests.
Shipped privacy and public rule-fact compatibility checks also passed.
These local Linux results do not replace the release gates listed above.

## Exact-build production overlay

A full maintenance package upgrade is separate from applying this workaround.
The tested production build is 0.1.8 at source `84dd13e3` with the
`cursor-harness-v1` database stamp. The 0.1.9 branch has a different schema
contract; do not replace that production package with this branch's full
release as an incidental part of enabling Astra.

For that exact installed build, the prepared overlay changes only
`Elixir.Tightbeam.Harness.Codex.beam` and the existing ACP 1.1.4 `dist/index.js`.
It retains the production provisioning callback, Cursor support, database,
identity and other adapters. The original source was first rebuilt using the
installed release libraries, relative source paths and Logger's compile-time
application metadata. Its executable BEAM MD5 matched the installed module
before the three Codex changes from this PR were applied. The final payloads
are tied to their original and patched SHA-256 hashes in a manifest.

`packaging/astra-overlay.py` consumes such a reviewed bundle. It refuses unknown
or mixed installed bytes, corrupted payloads, a listening local gateway, and
mismatched rollback backups. It preserves file modes, backs up both originals,
and restores them if a write raises. An interrupted process can still leave
mixed state; that state is refused loudly rather than guessed at. The installer
does not onboard credentials, restart services, or migrate the database.

The bundle is specific to the captured build, not a portable release. Rebuild
and revalidate for different installed bytes. Example operator sequence:

```sh
python3 /path/to/bundle/astra-overlay.py check --bundle /path/to/bundle \
  --package-root /absolute/npm/tightbeam --base-dir /absolute/tightbeam-state \
  --backup-dir /absolute/private/overlay-backup
```

At an idle maintenance boundary, stop the gateway and wait until its process
has exited and its listener is down. Run the same command with `apply` in place
of `check`, then start the gateway. Verify the pinned native Codex 0.153.2 path,
Astra catalog, real Astra/high turn, startup-hook PASS, and restart/resume before
changing authentication or agents in bulk. The original CODEX_PATH persists.

For rollback, stop and fully drain the gateway again, run `rollback` with the
same paths and private backup directory, then start it. Restore the prior
authentication separately if it was changed. This restores original module and
adapter bytes; it does not undo later conversation turns or credential changes.
The overlay changes no schema, so it requires no reverse migration.

Keep the bundle manifest, original bytes, source patch, and validation evidence
with the deployment record. Review and remove the overlay when an official
release replaces it. Maintenance-owner approval remains the merge/release step;
production activation is a separate operator decision.
