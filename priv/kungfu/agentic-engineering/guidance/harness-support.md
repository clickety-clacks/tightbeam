# Harness support

| Feature | claude | codex | Mechanism / notes |
|---|---|---|---|
| Parent-attributed subagent markers + wake-on-stop | ✅ | ✅ | Producer-side observability only: claude-agent-acp 0.59.0 emits the correlated stop update at `liveBackgroundTasks` settlement; codex-acp 1.1.4 correlates child-thread terminal status with the originating `subAgentActivity`. Tight Beam may see subagents but never predicate obligations on them. |
