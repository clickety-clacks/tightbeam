# GitHub auth for projects

## Problem

New Tightbeam projects can be created in an environment where `git` and `gh`
are present but GitHub auth is not usable from the agent process. The human then
sees an agent drift toward "give me a PAT" even though the operator already has
a GitHub login on the machine, or can complete a browser/device login.

That is the wrong seam. A project should never discover GitHub auth by asking an
agent to handle a personal access token. Tightbeam should either prove the host
can use GitHub, onboard that host through a browser/device ceremony, or refuse
with a named repair.

## Authority

This spec authorizes a new GitHub host capability. It does not authorize changes
to model-provider credentials, harness home projection, or the existing
`anthropic`/`openai` onboarding semantics.

## Goals

- A fresh project can prove whether its selected host can perform authenticated
  GitHub operations before any agent tries to clone, fetch, push, or file
  issues.
- The default repair is `tightbeam onboard github`, backed by GitHub CLI's
  browser/device OAuth flow.
- PAT entry is never suggested to an agent and is never the default onboarding
  path. A PAT may be accepted only through an explicit operator-only
  non-interactive flag, if that flag is added later.
- Local and satellite hosts are judged independently. A login on the gateway
  proves nothing about a satellite unless the satellite runs and passes its own
  GitHub probe.
- The status is visible in project readiness and doctor output, with enough
  detail to explain the repair without printing tokens or credential locations
  that contain secrets.

## Non-goals

- Tightbeam does not become a GitHub token broker.
- Tightbeam does not copy GitHub credentials between machines.
- Tightbeam does not parse or persist `gh` token files.
- Tightbeam does not require GitHub for projects whose origin is not GitHub and
  whose configured workflow does not need GitHub.
- Tightbeam does not replace Git's credential helper or the GitHub CLI.

## Model

GitHub auth is a host-local capability, not a harness credential.

Each registered host may report one GitHub capability state for each GitHub
hostname it is asked to use:

- `live`: `gh` and `git` can authenticate to that hostname from the exact
  non-interactive environment Tightbeam will use for project work.
- `missing_cli`: `gh` is absent from that environment's `PATH`.
- `needs_onboarding`: `gh` is present but no active authenticated account is
  usable for the hostname.
- `insufficient_scope`: auth exists, but a required operation is refused because
  the grant is too narrow.
- `git_unready`: `gh` is live, but `git` cannot use the configured protocol or
  credential helper for repository operations.
- `unknown`: the host could not be asked or the probe timed out. This is never
  treated as live.

The capability is stamped as metadata under Tightbeam's base dir, but the
metadata is evidence only. The authority remains the live probe.

Suggested metadata path:

```text
auth/github/<hostname>/.tightbeam/capability.json
```

Suggested metadata fields:

```json
{
  "hostname": "github.com",
  "account": "gdiab",
  "git_protocol": "https",
  "checked_at": "2026-08-15T00:00:00Z",
  "status": "live",
  "source": "gh"
}
```

Do not store tokens, token hashes, keychain paths, or `gh auth status
--show-token` output.

## Onboarding

Add:

```sh
tightbeam onboard github [--hostname github.com] [--remote URL]
```

The command runs on the host whose GitHub capability is being banked.

Required behavior:

1. Verify `gh` is executable on the relevant `PATH`.
2. Run `gh auth status --active --hostname <host>`.
3. If status is already live, write capability metadata and finish.
4. If status is not live, drive `gh auth login --hostname <host> --web
   --git-protocol https` as the default ceremony.
5. When `--remote URL` is present, run `git ls-remote URL HEAD` from the same
   environment before writing capability metadata.
6. After login, re-run the probes before writing capability metadata.

The ceremony must not run `gh auth login --with-token` unless a future explicit
operator flag is added. If `gh` falls back to insecure plaintext storage, the
command must surface that fact in the result and doctor output; whether that is
allowed should be a policy setting, not an implicit success.

For satellites, the same command runs on the satellite after host registration.
Gateway-mediated onboarding may orchestrate the command, but the credential must
be created and stored on the satellite, by that satellite's `gh`.

## Readiness probes

Readiness has two parts because `gh` API auth and `git` repository auth can fail
independently.

GitHub CLI probe:

```sh
gh auth status --active --hostname <host>
gh api --hostname <host> user --jq .login
```

Git probe, for a project with a GitHub remote:

```sh
git ls-remote <remote-url> HEAD
```

Run these from the same environment class that will do project work:

- local gateway project: gateway service environment plus the project workdir;
- satellite project: non-interactive ssh environment plus the project workdir;
- adapter session: the adapter launch environment after Tightbeam adds its
  common env.

The probe may be bounded and cached, but stale cache must not authorize work
after a failed live check. A timeout is `unknown`.

## Project creation

When creating or opening a project whose remote URL is on a GitHub hostname:

1. Resolve the project host.
2. Resolve the GitHub hostname from the remote URL, defaulting to `github.com`.
3. Run the host's GitHub readiness probe unless a fresh live result already
   exists.
4. If the result is not `live`, refuse project GitHub operations with a message
   naming the host, hostname, failed phase, and repair.

Example refusal:

```text
Tightbeam cannot use GitHub from host eezo for github.com: gh is not
authenticated in the non-interactive project environment. Run:
  tightbeam onboard github --hostname github.com
  tightbeam onboard github --hostname github.com --remote <remote-url>
on eezo, then retry. Do not paste a PAT into an agent.
```

Projects without a GitHub remote do not fail this gate unless their requested
workflow explicitly needs GitHub operations such as issue filing, PR creation,
or repository search.

## Agent environment

Do not inject tokens into agent environment variables.

Every projected harness home includes Tightbeam's reserved GitHub auth hook.
Before an agent shell call that names `github.com` or a GitHub CLI repo/PR/issue
operation runs, the hook calls `tightbeam github-auth-check` with the raw tool
call. Non-GitHub calls pass through. GitHub-dependent calls must prove host
`gh` auth and, when a remote URL is present, `git ls-remote <remote> HEAD`.
Failure exits as a tool refusal with the repair command and the instruction not
to paste a PAT into an agent.

For local sessions, preserve the host environment needed for `gh` and Git's
credential helper unless a containment mode explicitly forbids it. If
containment forbids the OS credential store, the project must report GitHub as
unavailable instead of falling back to PAT prompts.

For remote sessions, do not assume the gateway's `HOME`, keychain, or
`~/.config/gh` applies. The remote host must pass its own readiness probe.

The following names are reserved for future policy, not required by this spec:

- `TIGHTBEAM_GITHUB_HOST`
- `TIGHTBEAM_GITHUB_REQUIRED`
- `TIGHTBEAM_GITHUB_STATUS`

## Doctor and status

`tightbeam doctor` should include a GitHub section when a project has a GitHub
remote or the operator requests a GitHub check.

Minimum output:

- host;
- GitHub hostname;
- `gh` executable path or missing-path refusal;
- active account, if known;
- git protocol;
- state: live, needs onboarding, insufficient scope, git unready, or unknown;
- exact repair command.

Session/project status should expose only non-secret fields. Suggested display:

```json
{
  "github": {
    "hostname": "github.com",
    "state": "live",
    "account": "gdiab",
    "gitProtocol": "https"
  }
}
```

## Acceptance tests

- A fresh project with a GitHub remote and no `gh` binary refuses before agent
  work, names `missing_cli`, and prints the searched `PATH`.
- A fresh project with `gh` installed but no active login refuses with
  `needs_onboarding` and names `tightbeam onboard github --hostname github.com`.
- A project on a satellite does not pass because the gateway has GitHub auth;
  it passes only after the satellite probe passes.
- A local project where `gh auth status --active` and `git ls-remote` both pass
  reports GitHub `live`.
- A `gh` login that exists but cannot `git ls-remote` reports `git_unready`,
  not `live`.
- A proposed agent shell call such as `git clone https://github.com/org/repo.git`
  is refused before execution when host GitHub auth is missing, and the refusal
  names `tightbeam onboard github --hostname github.com --remote ...`.
- No prompt, status payload, log event, or agent message asks the operator to
  paste a PAT.
- No token bytes appear in events, doctor output, status JSON, stderr logs, or
  project metadata.
- A timeout or unreachable host reports `unknown` and does not authorize GitHub
  work.

## Implementation notes

The existing adapter launch path already adds common environment variables in
`Tightbeam.Placement`. GitHub readiness should be checked alongside project
placement/readiness, not inside a shared serializer. Any probe that can touch the
network or ssh must run in the process that owns that failure.

The capability is intentionally separate from `Tightbeam.Credentials`: provider
credentials authorize harnesses to run model turns; GitHub auth authorizes a
host to operate on repositories and tracker objects. They share the
host-local/no-copy rule, but not storage or liveness probes.
