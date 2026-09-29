# 0.1.9 provider, session and host-runtime checks

Run on a permitted test host and a disposable feature base copied from the
preserved migrated database. Follow the shared limits in the
[aggregate](README.md#execution-contract). Do not copy provider credentials from
the source database or live base.

## Scripted area

Prepare a fresh area clone and start its gateway as described in the
[aggregate](README.md#aggregate-run). From the repository root on Racter or
Eezo, have the unchanged canonical wrapper execute:

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
| `identity current` | From a session with a `.tightbeam-session` marker, run `tightbeam identity current`. | It prints only that marker's session key; it does not print a bearer or token. |
| Identity status and refresh | Use only a discardable identity revision and throwaway session already prepared in the isolated test base. Read `identity status`, run `identity apply <session>`, then read status and the session transcript. | The selected session's owned skill files advance to the expected revision and an ordinary prompt asking it to reread them is submitted. This does not prove that a running model context reloaded. Do not edit shared identity to create this fixture; without the isolated revision, mark `INCOMPLETE`. |
| `session-connect` | Connect to a throwaway session with `tightbeam session-connect --session <key>`. Send one line such as `{"type":"send","protocolVersion":1,"requestId":"smoke-1","content":"reply with SMOKE OK","idempotencyKey":"smoke-session-connect-1"}`, then close stdin. | The client emits `ready` after its subscription snapshot, returns `send.accepted` with `requestId=smoke-1` and a wake ID, only the selected session receives the harmless prompt, replies are valid NDJSON, and EOF ends the client cleanly. |
| Provider onboarding variants | In a separately authorized test org, exercise the provider form under test (`onboard cursor --api-key`, `onboard opencode-go --api-key` or `--daemon-credential`, or `onboard local-openai --name ... --endpoint ...`). | The documented input channel is used, the provider-specific validation/readback succeeds, and no key appears in command arguments, output, logs or scorecard. Do not perform this row without explicit test credentials already authorized by the operator. |
| Kungfu setup and sentinel readback | Run `kungfu list`, `kungfu setup <learned-bundle>`, and `sentinel list`; inspect sentinel state through `doctor --json`. | Setup lists declared sentinels and missing setting names; status identifies enabled/disabled/blocked state and never reveals setting values. |
| Sentinel environment and lifecycle | On an isolated gateway, use `host-env-set --sentinel <name> NAME=VALUE`, `host-env-list --sentinel <name>`, then `host-env-unset`. If the selected shipped sentinel has a safe, authorized test configuration, enable it and verify `sentinel list`, then disable it. | The setting name and state are visible, its value remains hidden, unset removes only that sentinel overlay, and enable/disable changes only the selected test sentinel. If enable could contact or mutate a real service, do not run it. |
| Harness process ledger | Start one harmless turn on a disposable test session, then run `harness-process list`. | The ledger reports the launch identity and terminal status for that test turn; it does not claim an unrelated process as a harness launch. |
| Harness-health incident lifecycle | Use only an already observed, real host/harness failure with redacted exact evidence. Exercise `harness-health-observe-other`, resolve after a real recovery observation, read `harness-health-evidence-other`, and file the required `harness-health-review-other`. Exercise promotion close only with its real spec artifact, independent review artifact/attest/assignment and exact candidate commit. | State transitions match the evidence, redaction and time bounds; review is required; promotion provenance is verified. Never create a synthetic incident to make this row pass. |

Mark credential-dependent, sentinel-execution and harness-health rows
`INCOMPLETE` when their real prerequisites are not available. Do not fill those
gaps with dummy credentials, fake process records, or invented incident data.
