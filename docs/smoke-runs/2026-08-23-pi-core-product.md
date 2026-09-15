# Pi harness core product acceptance — 2026-08-23

This capture ran the integrated Pi harness from `feature/pi-harness-core`
against an isolated Tightbeam base, database, homes tree, adapter tree, workdir,
gateway port, and user. The accepted base was
`/private/tmp/tb-pi-core-live2.v5wPd1`, its host was `pi-live-host`, and its
gateway listened on port 12185. The credential key traveled through stdin and
was banked only in the isolated base at mode 0600. No key bytes appear here.

The gateway installed the unscoped `pi-acp` package at version `0.0.33`. The
live provider catalog returned 21 OpenCode Go models. Its Luna row was:

```text
model=opencode-go/gpt-5.6-luna
provider=opencode_go
efforts=low,medium,high,xhigh
maxInputTokens=1050000
maxOutputTokens=128000
```

The first exact product spawn exposed the pre-Pi `sessions` CHECK constraints
and was refused before launch. The database was stamped
`operator-decision-requests-v1`. After the new exact migration ran, the same
database was stamped `pi-harness-v1`, retained its prior rows, passed the
foreign-key check, and accepted the same command:

```text
tightbeam spawn --display "Pi core live acceptance" --archetype default \
  --harness pi --model opencode-go/gpt-5.6-luna --effort medium \
  --host pi-live-host --key pi-core-live-spawn --as-user pi-core-admin
```

The created session row recorded harness `pi`, provider `opencode_go`, model
`opencode-go/gpt-5.6-luna`, effort `medium`, host `pi-live-host`, and active
state. A real prompt then produced this transcript pair:

```text
user:      Reply with exactly: PI LIVE TURN OK
assistant: PI LIVE TURN OK
```

Pi's native session record names the OpenCode Go Responses API, Luna model,
`stopReason=stop`, and nonzero live usage. Tightbeam recorded turn 1 as
delivered.

The second real turn asked Pi to call Bash with this exact command:

```text
touch /private/tmp/tb-pi-core-live2.v5wPd1/must-not-exist; echo tightbeam-gate-probe
```

Pi's native session JSONL records a `toolCall` named `bash` with those exact
arguments, followed by this error tool result:

```text
[gate: tightbeam-probe] Spawn wiring-check probe command; always refused by design.
```

The sentinel path did not exist after the delivered turn. This proves the
Tightbeam-owned global Pi extension received the real tool call and blocked the
whole command before Bash executed its first operation.

One setup command was initially run from inside the development worktree. CLI
discovery correctly preferred that worktree's `.tightbeam-session` over the
temporary base environment and created an unintended production user row plus
its add-user event. Both exact rows were removed immediately and zero-count
queries verified their absence. The accepted spawn, both turns, homes,
credential, adapter, and captured evidence all came from the isolated base.
The production database file was therefore briefly written during setup; it
was not byte-untouched, even though its logical rows were restored.
