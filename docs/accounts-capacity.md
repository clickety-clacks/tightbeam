# Provider accounts and capacity

Tightbeam can keep several Claude or Codex subscription accounts signed in on
each host. An account ID identifies one login on one host. The **serving**
account is the login Tightbeam uses for new turns on that host and harness.

The gateway's `provider_accounts_enabled` feature flag defaults to off.
Automatic switching is a separate setting and also defaults to off.
`tightbeam config get account-switching` shows the current setting.
An operator can use `tightbeam config set account-switching on --harness claude`
to enable it for Claude, or use `off` to disable it.

```sh
tightbeam accounts list
tightbeam accounts show acct_example
tightbeam accounts use acct_example
```

Use the account ID from the list. `accounts rename` changes its display label.
`accounts disable` takes it out of rotation, and `accounts enable` puts it back
in rotation. `accounts verify` checks the login. `accounts remove` removes the
account from Tightbeam's list and keeps the login on its host. Sign in to a
second account using the existing onboarding command with `--account new`.
Use `--account acct_example` when signing in again to the same account.

Capacity reads require an administrator's device credential or an organization
credential with an administrator as the read principal. With an organization
credential, use `--as-user <userId>` to select the read principal, or
`--as-process <name>` to use the default read principal. Run capacity commands
outside a session worktree so discovery selects your administrator credential.

## Read capacity

```sh
tightbeam capacity
tightbeam capacity show --account acct_example --refresh
tightbeam capacity history --account acct_example
tightbeam capacity forecast
tightbeam capacity forecast --account acct_example
tightbeam capacity health
tightbeam capacity watch --account acct_example
```

- `show` reports quota windows and resets, headroom, freshness, plan and
  subscription status. `--refresh` waits for an updated reading, subject to
  provider availability and rate limits. Usage reads spend no inference.
- `history` shows recent samples for one account. The API keeps up to seven
  days in five-minute buckets.
- `forecast` estimates exhaustion from recent usage and shows pools for
  comparable windows. A pool counts a known shared provider identity once.
  Estimates depend on available history and current workload.
- `health` summarizes provider CLI availability and login state.
- `watch` prints the initial visible snapshot and updates as capacity changes.
  It re-subscribes and rebuilds from REST after a disconnect.

Use `--json` for the REST response, including nulls and unknown reasons.
`watch --json` writes one complete snapshot per line. Timestamps in the API
are Unix epoch milliseconds. An unavailable reading may retain a stale sample
with a reason. A missing usage percent or reset remains unknown. A forecast
failure leaves usage readable.

## Connect an API client

Use the gateway's bearer authentication and normal resource visibility rules.

| Request | Projection |
| --- | --- |
| `GET /api/accounts` | Visible provider accounts |
| `GET /api/accounts/:id` | One account, with optional admin-only provider identity detail |
| `GET /api/capacity` | Visible usage results |
| `GET /api/capacity/:accountId` | Usage for one account |
| `GET /api/capacity/:accountId/history` | Usage history |
| `GET /api/capacity/forecast` | Account forecasts and comparable pools |
| `GET /api/capacity/:accountId/forecast` | Forecast for one account |
| `GET /api/capacity/health` | Provider CLI availability and account counts |

Usage routes accept `refresh=wait` for a bounded wait and
`refresh=background` for a read that can return a retained sample. Requests
respect provider rate-limit holds. Use `refresh=cache` to read the stored
projection without starting or waiting for a provider read. Cache-only reads
return an empty results list when no accounts are visible and a result with
`sample: null` when a visible account has no reading. A missing or invisible
account returns HTTP 404.

For live capacity, authenticate to [Firehose](firehose.md), subscribe, and
wait for `subscription_ready` before reading a `refresh=cache` REST snapshot.
Queue invalidations received during the snapshot and reconcile them with more
cache-only reads. The relevant Firehose classes are `capacity.changed`,
`provider_account.changed`, `provider_account.removed`,
`account_serving.changed`, and `account_limit.changed`. A successful capacity
read can advance the observation timestamp while usage percentages stay the
same.

After a disconnect or `reload_required`, establish a new subscription and
rebuild the snapshot. Firehose delivers live events for the current
subscription.

## Using Lachesis alongside Tightbeam

Use a fresh sign-in through Tightbeam for each login you add. Tightbeam and
Lachesis keep separate login homes and usage history. Forecasts start building
from Tightbeam's own samples. The Tightbeam serving account reflects gateway
routing for its host and harness. A desktop app can have a different selected
login.
