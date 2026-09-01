# GitHub host authentication

Choose the GitHub identity before you start GitHub work. Do not give a PAT or
token to an agent.

GitHub CLI owns each active secret home. Tightbeam creates no secret copy. A
profile name is a non-secret selector such as `default`, `work`, or `personal`.
The provider home is:

    <base_dir>/credential-homes/<machine>/github/<profile>

Run onboarding on the machine that will use the credential:

    tightbeam onboard github --profile work --hostname github.com --as-user <userId>

Use `--account <login>` when the observed account must match one login. Use
`--remote <URL>` to prove repository access in the same ceremony. Use
`--replace` to rotate the provider-owned authority in place. The command uses
GitHub CLI browser/device authentication and never accepts token input.

Elect one profile in each workshop archetype that needs GitHub access:

```toml
[provisioning]
class = "workshop"

[provisioning.credentials.github]
profile = "work"
```

Start a fresh session after the election changes. Provisioning sets the
registered machine, authenticated session principal, profile, and exact
host-local `GH_CONFIG_DIR`. It removes inherited GitHub token variables. A desk
archetype cannot elect a credential.

The compiled `github-network-auth-required` rule checks Bash operations before
execution. It recognizes `gh repo`, `gh pr`, `gh issue`, `gh api`, and network
Git verbs. It ignores prose and here-document bodies. It allows only a current
`live` provider check. Follow the named repair in any refusal.

Revoke one local login with:

    tightbeam revoke github --profile work --hostname github.com --account <login>

This leaves a non-secret local tombstone. Revoke the remote OAuth grant in
GitHub settings when required.

Treat `<base_dir>/auth/github/gh` as inert residue from the 0.1 implementation.
Version 0.2 does not project, probe, update, migrate, or delete it. Remove it
only as an explicit operator action. Product rollback can reactivate it.

Use `tightbeam doctor --json` for readiness details. A present file is not a
live credential. Only the current provider and optional Git probe can return
`live`. HTTP 401 means `expired`; HTTP 403 means `insufficient_scope`; timeout,
transport failure, or an unrecognized response means `unknown`.
