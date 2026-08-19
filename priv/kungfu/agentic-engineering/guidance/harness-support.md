# Harness support

| Feature | claude | codex | Mechanism / notes |
|---|---|---|---|
| Parent-attributed subagent markers + wake-on-stop | ✅ | ✅ | Producer-side observability only: claude-agent-acp 0.59.0 emits the correlated stop update at `liveBackgroundTasks` settlement; codex-acp 1.1.4 correlates child-thread terminal status with the originating `subAgentActivity`. Tightbeam may see subagents but never predicate obligations on them. |
| CAP-018 credential liveness | ✅ | ✅ | Bounded authenticated probes with injected transport: Claude calls `GET https://api.anthropic.com/v1/models?limit=1`; Codex calls `GET https://chatgpt.com/backend-api/wham/accounts/check`. HTTP 2xx is `:live`, explicit 401/403 rejection is `{:dead, reason}`, and timeout/transient transport failure is `{:unknown, reason}`. The fixture harness names `DIV-CREDENTIAL-LIVE-FIXTURE-NO-PROBE`. |
