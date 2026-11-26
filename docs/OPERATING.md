# Operating Tightbeam

## Check readiness

Read the gateway log's boot summary. `READY: … can run turns.` names the
harnesses that can run turns. `NOT READY` lists the gaps and how to resolve
them. The service can be running and accepting connections while no harness
can run a turn. After the boot summary reports readiness, send a message
to an agent and check that it replies.

## Remove an installation

Stop and disable the Tightbeam gateway and Chat services before removing
their files. On Linux, use systemd in the user scope for quick mode or the
system scope for full mode. On macOS, unload the LaunchAgents for quick mode
or the LaunchDaemons for full mode. Remove the service definitions you
unloaded and ask systemd to reload its configuration on Linux.

After the services have stopped, remove the Tightbeam package with the
package manager you used. For an npx installation, remove its Tightbeam
release files from your home directory. Check that neither service is still
running or listening on its configured port.

Keep your base directory if you want to retain your installation's identity,
credentials, sessions, and work records. Removing the program files and
service definitions preserves that data.

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
