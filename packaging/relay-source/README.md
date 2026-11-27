# Harklight people relay

The relay runs under an organization-owned service account. Tightbeam queues
people-message records and accepts delivery reports and events. The relay
uses Harklight Agent for service calls.

## Install

Use versions of Tightbeam and Harklight Agent that expose the people-message
and shared-message commands, respectively. Configure the service account's
Tightbeam CLI with the organization's active people-message relay permission.
Make both CLIs available on the service's PATH.

Extract the release so this directory is at
`$HOME/.local/share/harklight-tightbeam-pack/pack/relay`. Copy
`config.example.json` to `$HOME/.config/harklight-people-relay/config.json`.
Set `connection` to the Agent identity directory for the existing Harklight
connection and `sender` to its authorized sender ID. Map each Tightbeam user
ID to an opaque Harklight person ID in `users`. Each person may appear once.
Display names and handles can change and do not act as addresses.

For systemd user services, copy the two unit files to
`$HOME/.config/systemd/user/`, then run `systemctl --user daemon-reload` and
`systemctl --user enable --now harklight-people-relay.timer`. The pack
installer leaves this service disabled. The timer runs one relay instance
at a time. Keep its state directory across service restarts and pack upgrades.
It holds pending operation IDs and requests, the conversation bindings, the
Agent journal, and the last accepted feed position. Preserve that state
with its connection and sender.

The shared-messaging interface supports named recipients in this release
of the relay. Group addresses receive an unsupported delivery report until
the Harklight groups interface is available. If the service is stopped,
Tightbeam keeps waiting records for its next run. Harklight's pending
baseline recovers chat and answers after a cursor expires. Historical Seen
transitions may be unavailable after Server feed compaction.

Back up and restore the relay database and Agent journal together. The
database preserves the Agent session ID, which scopes the sender feed.
Tightbeam can recover the binding and delivered revision for a known
conversation within that scope. An unknown write still needs its original
prepared request and journal to recover safely.
