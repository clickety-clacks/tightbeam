# Claude 0.73.0 native subagent regression evidence

The pinned `@agentclientprotocol/claude-agent-acp@0.73.0` already emits
`subagent_spawned` and `subagent_state_update` after negotiation with
`clientCapabilities.subagents: {}`. Its old source patch no longer matches.
This change consumes that version's native lifecycle, keeps nested markers
attributed to their root, and preserves independent child transcripts.

These are the pinned adapter's extension events, not finalized ACP schema.
[ACP proposal #1992](https://github.com/agentclientprotocol/agent-client-protocol/pull/1992)
is still evolving; a version upgrade needs new captures.
The adapter implementation landed in
[vendor #1017](https://github.com/agentclientprotocol/claude-agent-acp/pull/1017).

## Reproduce the package check

With the exact package installed in an isolated directory:

```sh
node scripts/capture_claude_native.mjs /path/to/node_modules/@agentclientprotocol/claude-agent-acp > /tmp/claude-native.json
cmp /tmp/claude-native.json test/fixtures/subagent_markers/claude-native-0.73.0-capture.json
```

The script imports the actual `NativeSubagentRuntime` and capability predicate.
It asserts negotiation, nested parent routing, child output identity, all terminal
normalizations, and duplicate-completion suppression. Inputs representing SDK
task events are synthetic. This is package-boundary evidence, **not authenticated
model smoke**. The `.jsonc` fixture excerpts these native frames; its legacy
completed-tool input is an explicit negative regression case.

Capture recorded 2026-09-15 from the installed 0.73.0 package:

- npm integrity: `sha512-xKnGIntdBbr2dDS2NEsVGdjoLH62EaWjfYlp/U7TYdxUJzERlApe2gliYW3rVFTeWGjG0dUyPszhG9TWhsqGlA==`
- `dist/acp-agent.js` SHA256: `e41014b49c5ac096b5e18a89f990ee0ec64452e440666b59dcf4e087f632e370`

The authenticated `feature_smoke` matrix (both harnesses, fresh org) remains a
pre-merge requirement under `AGENTS.md`. Unit and package checks cannot replace it.

The implementation selectively adapts the Claude lifecycle and root attribution
from [draft #81](https://github.com/clickety-clacks/tightbeam/pull/81), retaining
Claude 0.73.0 and exact package verification. This follows
[merged #106](https://github.com/clickety-clacks/tightbeam/pull/106).

## Upgrade and reconnect constraints

Claude wake handles now use the native child session/task ID. The obsolete
Agent tool-call ID is rejected as `subagent_not_found`; no alias can be derived
from the native spawn frame. New native start/stop markers resolve the same
canonical child and trigger condition wakes. Drain outstanding Claude waits
created under the previous tool-call scheme before deploying this transition.
Codex retains its existing handle behavior.

The pinned adapter's `session/load` replay constructs child IDs as
`<root>:replay-subagent:<toolUseId>` and emits terminal history as well as starts.
These IDs differ from live task IDs. This change does not claim continuity for
live child waits across reconnect/replay; their timeout fallback still applies.
Exercise this explicitly in the authenticated smoke gate and resolve any required
stronger continuity guarantee before marking the PR ready for merge.
