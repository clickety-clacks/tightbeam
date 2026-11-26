# Operating Tightbeam

## Check readiness

Read the gateway log's boot summary. `READY: … can run turns.` names the
harnesses that can run turns. `NOT READY` lists the gaps and how to resolve
them. The service can be running and accepting connections while no harness
can run a turn. After the boot summary reports readiness, send a message
to an agent and check that it replies.

## Remove an installation

Stop and disable the gateway and Chat before removing their files. Use the
scope for each service in the table, then remove the corresponding service
definitions. On Linux, reload systemd in the scopes you changed.

| Platform | Gateway | Chat |
| --- | --- | --- |
| Linux | `tightbeam.service` under `~/.config/systemd/user` in quick mode or `/etc/systemd/system` in full mode | `tightbeam-chat.service` under `~/.config/systemd/user` |
| macOS | `com.tightbeam.gateway.plist` under `~/Library/LaunchAgents` in quick mode or `/Library/LaunchDaemons` in full mode | `com.tightbeam.chat.plist` under `~/Library/LaunchAgents` |

Remove the setup-created `~/.local/bin/tightbeam` symlink. The gateway
release files are under `~/.local/share/tightbeam` in quick mode and
`/opt/tightbeam` in full mode. Chat's program files are under
`~/.local/share/tightbeam-chat`. Remove the release files belonging to the
installation you're removing.

If you installed with Homebrew, uninstall the formula to remove its copy.
For an npx install, remove its downloaded release files under
`~/.local/share/tightbeam-install`. Check that neither service is still
running or listening on its configured port.

Keep your base directory if you want to retain your installation's identity,
credentials, sessions, and work records. It defaults to `~/.tightbeam`.
Check your configured base directory before removing any program files so
you can preserve your data.

## Shared Harklight origin listener

With an origin-capable Harklight Agent and Server, a sending Tightbeam session
can move one of its existing conversations to the shared listener:

```sh
tightbeam harklight-cover --session <Harklight-handle>
```

Opt in each handle separately. The shared listener uses the gateway's
configured Agent enrollment and sender scope. Other conversations keep their
per-handle listeners.

A `covered` result confirms that the move finished. For a `pending` result,
repeat the command for the same handle to continue the move. Tightbeam
retains captured offers during the handover and resumes a recorded move
after restart. Repeating the command continues the move without sending a
new conversation.

An external support declaration for the handle that omits `origin_listener`
withdraws coverage. Acknowledgments, replies, and results use separate
Agent requests.

## Further reference

- [Smoke runbook](SMOKE.md) for checking core user journeys.
- [Firehose](firehose.md) for live change delivery, recovery limits, and snapshot costs.
