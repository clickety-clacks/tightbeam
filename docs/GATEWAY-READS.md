# Gateway read identity

An organization bearer authenticates requests to the gateway. Where a read needs
a user visibility context, the request supplies that user with `asUser`. The
gateway applies its existing owner-or-admin visibility for that user.

## REST session history

Use the organization bearer with `asUser` on a selected session's `messages`,
`wakes`, or `turns` collection. The selected session must be visible to that
user under the existing owner-or-admin rule. Other user-visible REST state
continues to use the same `asUser` query form.

Device and session bearers keep their existing identity and visibility. This
read behavior does not change write or dispatch permissions.

## Change socket

Authenticate an organization bearer with an `asUser` value. When the auth
message omits `sessionKey`, subscriptions may cover organization-wide changes
or narrow themselves with a per-session filter. The gateway sends only changes
visible to that user. When auth includes `sessionKey`, subscriptions remain
limited to that selected session, as before.

Session bearers remain tied to their authenticated session. Device bearers
continue to use their existing user visibility.

## Session connection command

The session connection command continues to use its discovered bearer for the
initial REST snapshot and change stream. Its optional identity flags affect
wake attribution; read visibility follows the bearer and gateway API behavior
described above.
