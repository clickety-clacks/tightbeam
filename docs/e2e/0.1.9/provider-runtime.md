# 0.1.9 provider, session and host-runtime checks

Run on a permitted test host and a disposable feature base copied from the
preserved migrated database. Follow the shared limits in the
[aggregate](README.md#execution-contract). Do not copy provider credentials from
the source database or live base.

## Scripted area

The shared [safe-stop](README.md#safe-stop-before-copied-org-gateway-boot)
blocks boot on this copied database. Do not start it until the PO records the
source-backed isolation path and this runbook names its supported use. Once
cleared, prepare a fresh area clone and use that route before the unchanged
canonical wrapper on Racter or Eezo executes:

```sh
TIGHTBEAM_BASE_DIR="$AREA_BASE" \
TIGHTBEAM_SMOKE_AREAS=provider \
mix run --no-start scripts/feature_smoke.exs
```

This area checks the local deployment projection, identity surface, and
existing onboarding lifecycle. It does not prove real provider parity;
complete every registered harness leg or record a named incomplete blocker.

## Manual 0.1.9 checks

| Feature | Exercise | Pass condition |
|---|---|---|
| <a id="identity-current"></a>`identity current` | From the throwaway test session's work directory, first confirm its `.tightbeam-session` URL is the area's loopback endpoint, its session key is the selected fixture, and its token matches that area's `gateway.json` without printing the token. Keep `TIGHTBEAM_URL` and `TIGHTBEAM_TOKEN` unset, then run `tightbeam identity current`. | It prints only that test marker's session key; it does not print a bearer or token. |
| Identity status and refresh | Use only a discardable identity revision and throwaway session already prepared in the isolated test base. Read `identity status`, run `identity apply <session>`, then read status and the session transcript. | The selected session's owned skill files advance to the expected revision and an ordinary prompt asking it to reread them is submitted. This does not prove that a running model context reloaded. Do not edit shared identity to create this fixture; without the isolated revision, mark `INCOMPLETE`. |
| <a id="session-connect"></a>`session-connect` | Connect to a throwaway session with `tightbeam session-connect --session <key>`. Send one line such as `{"type":"send","protocolVersion":1,"requestId":"smoke-1","content":"reply with SMOKE OK","idempotencyKey":"smoke-session-connect-1"}`, then close stdin. | The client emits `ready` after its subscription snapshot, returns `send.accepted` with `requestId=smoke-1` and a wake ID, only the selected session receives the harmless prompt, replies are valid NDJSON, and EOF ends the client cleanly. |
| <a id="firehose-harness-switch"></a>Firehose `setHarness` and queued-seat switch | In the disposable test org, subscribe to the `sessions` Firehose resource for an active throwaway session and read its advertised `capabilities.setHarness`. With one harmless queued message and no running turn, request an enabled alternate through the packaged client's `/api/session-control` action `set_harness`; then repeat the resulting no-op once. | The capability lists only valid options and disables the resident harness. One committed `session.harness_changed` update has a higher row version and the same session identity; the queued message remains in order, and the no-op creates no second update. A rejected target leaves harness, history and queue unchanged. |
| Provider onboarding variants | In a separately authorized test org, exercise the provider form under test (`onboard cursor --api-key`, `onboard opencode-go --api-key` or `--daemon-credential`, or `onboard local-openai --name ... --endpoint ...`). | The documented input channel is used, the provider-specific validation/readback succeeds, and no key appears in command arguments, output, logs or scorecard. Do not perform this row without explicit test credentials already authorized by the operator. |
| <a id="credential-backoff"></a>Credential backoff | Use only a provider's documented sandbox or test account that supports a genuine, reversible transient rejection. Observe one real rejection, follow the reported retry/backoff interval, and retry after the provider permits it. | Tightbeam preserves the provider failure classification and does not issue a rapid retry or claim sign-in success during backoff. If the provider cannot produce this fixture safely, mark `INCOMPLETE`; do not use fabricated credentials or repeated live failures. |
| <a id="sign-in-recovery-wake"></a>Sign-in recovery wake | With an explicitly authorized disposable user on the test host, complete that user's ordinary provider subscription sign-in from Main, then read its newly delivered wake. | Exactly that user's canonical Main receives the recovery wake after a genuine sign-in completes. API-key onboarding and failed provider starts do not create a recovery wake. Keep authentication bytes out of logs and scorecards. |
| <a id="retirement-cleanup-on-the-original-host"></a>Retirement cleanup on the original host | Create a disposable custom session with an owned work directory on a named test host, then retire that session through the packaged CLI. Read its terminal session row and inspect only that test host's session-owned directory. | The retired session no longer has an active work directory on its original host; another disposable session and host remain unchanged. Do not run this against Gibson or an operator's real session. |
| <a id="codex-guardian-default"></a>Codex Guardian default | Reconcile a fresh disposable Codex home through the ordinary test-host projection route, then inspect its TOML. Repeat with an isolated home whose operator-supplied config explicitly enables Guardian. | An absent `features.guardian_approval` is defaulted to `false`; an explicit operator value is preserved. Do not inspect or edit an operator's real Codex home. |
| Kungfu setup and sentinel readback | Run `kungfu list`, `kungfu setup <learned-bundle>`, and `sentinel list`; inspect sentinel state through `doctor --json`. | Setup lists declared sentinels and missing setting names; status identifies enabled/disabled/blocked state and never reveals setting values. |
| <a id="sentinel-lifecycle"></a>Sentinel environment and lifecycle | On an isolated gateway, use `host-env-set --sentinel <name> NAME=VALUE`, `host-env-list --sentinel <name>`, then `host-env-unset --sentinel <same-name> NAME`. If the selected shipped sentinel has a safe, authorized test configuration, enable it and verify `sentinel list`, then disable it. | The setting name and state are visible, its value remains hidden, unset removes only that sentinel overlay, and enable/disable changes only the selected test sentinel. If enable could contact or mutate a real service, do not run it. |
| Harness process ledger | Start one harmless turn on a disposable test session, then run `harness-process list`. | The ledger reports the launch identity and terminal status for that test turn; it does not claim an unrelated process as a harness launch. |
| Harness-health incident lifecycle | Use only an already observed, real host/harness failure with redacted exact evidence. Exercise `harness-health-observe-other`, resolve after a real recovery observation, read `harness-health-evidence-other`, and file the required `harness-health-review-other`. Exercise promotion close only with its real spec artifact, independent review artifact/attest/assignment and exact candidate commit. | State transitions match the evidence, redaction and time bounds; review is required; promotion provenance is verified. Never create a synthetic incident to make this row pass. |

Mark credential-dependent, sentinel-execution and harness-health rows
`INCOMPLETE` when their real prerequisites are not available. Do not fill those
gaps with dummy credentials, fake process records, or invented incident data.
