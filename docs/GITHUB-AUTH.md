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

The credential itself is banked **file-backed** in a Tightbeam-owned GitHub CLI
config dir under the base dir:

```text
auth/github/gh/
```

One shared dir, not per-hostname: `GH_CONFIG_DIR` is single-valued while gh's
`hosts.yml` natively holds every hostname. The dir is 0700, the files inside
0600, and gh owns their format — Tightbeam never parses them.

GHE and other non-github.com hostnames onboard and operate through gh's
native multi-host support in that same store, but the shell guard's remote
extraction and doctor's hostname recognition currently know only github.com —
GHE operations run unguarded (failing at runtime with gh's own errors when
unauthenticated, the guard's documented under-match direction) and undoctored
until a canonical host parser is added.

The OS login keychain is deliberately not the store. Agent processes descend
from the gateway daemon, and a daemon-descended context cannot read the login
keychain (`security` fails with `errSecInteractionNotAllowed`, exit 36 —
observed on gd-mbp, 2026-08-16). A keyring credential therefore probes live
from an operator terminal while being unreadable from every environment that
does project work. File-backed storage under the base dir is the same shape as
the banked model-provider credentials and is readable by exactly the processes
that need it.

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
  "source": "gh",
  "storage": "file"
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
2. Create the banked config dir (`auth/github/gh`, 0700) and run every gh and
   git invocation below with `GH_CONFIG_DIR` pointing at it.
3. Run `gh auth status --active --hostname <host>`.
4. If status is already live in the banked dir, write capability metadata and
   finish.
5. If status is not live, drive `gh auth login --hostname <host> --web
   --git-protocol https --insecure-storage` as the default ceremony.
   `--insecure-storage` is a deliberate choice, not a fallback: it lands the
   credential in the banked dir as a 0600 file instead of the login keychain,
   which agent environments cannot read (see Model). The `storage: "file"`
   fact is surfaced in the command result, capability metadata, and doctor
   output rather than passing as implicit success.
6. When `--remote URL` is present, run `git ls-remote URL HEAD` from the same
   environment before writing capability metadata.
7. After login, re-run the probes before writing capability metadata.

The ceremony must not run `gh auth login --with-token` unless a future explicit
operator flag is added.

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

The guard judges operations, not mentions, from an executable-command
representation. It reads only `tool_input.command`; prompts, briefs, and
descriptions ride alongside and cannot run. Its shell tokenizer keeps quoted
arguments as arguments, splits executable commands at shell connectors,
recurses into `sh -c`/`bash -c` scripts, and removes here-document bodies
before classifying commands. A multi-line brief or here-document can therefore
contain `gh pr view` or `git clone` as data without becoming an operation,
while the same words in a nested shell script are gated. Environment
assignments and plain wrappers such as `env`, `exec`, and `xargs` are unwrapped
before the program is classified. Only owner/repo-shaped URLs are candidate
remotes, so a command whose argument links an issue or PR page is not
`ls-remote`d into a refusal.

For `git fetch`, `pull`, `push`, or `ls-remote` with a named remote rather than
a URL, the guard runs `git config --get remote.<name>.url` locally. It gates the
operation only when that configured URL is a recognized GitHub remote. An
omitted fetch/pull/push remote defaults to `origin` for this resolution. This
is local configuration inspection; no network or credential probe runs for a
configured non-GitHub remote.

Git's side of the rail depends on `gh auth git-credential` being configured
as a credential helper in a git config the agent's git reads; `gh auth login`
writes that into the operator's `~/.gitconfig` as a side effect, which agents
share on a local host. The hook's `git ls-remote` probe runs in the agent
environment, so a missing helper is caught at tool-call time as
`git_unready` — but note the repair for that state is fixing the helper
config, not re-running onboarding.

`tightbeam github-auth-check` resolves the banked config dir itself, so the
hook's probe never depends on the session's projected environment. Agent
`gh`/`git` invocations use the same path because `GH_CONFIG_DIR` is projected
unconditionally at every adapter launch, whether or not the bank exists yet.
When onboarding later creates files at that path, an already-running session
sees them on its next invocation; no respawn or per-turn environment
re-projection is required.

Every agent environment (local adapter launch and satellite ssh launch) gets
`GH_CONFIG_DIR` pointing at the host's banked dir — a path, never token bytes,
set unconditionally whether or not the dir exists yet. Pointing gh at an
absent dir yields the honest answer (`needs_onboarding` against the host's
own store), while any ambient fallback would repeat the trap this capability
exists to eliminate: a keyring credential that is live from a terminal and
unreadable from project work. The probes in `tightbeam onboard github`,
`tightbeam github-auth-check`, and doctor pin the same dir for the same
reason. Git rides the same rail through gh's credential helper
(`gh auth git-credential`), which consults `GH_CONFIG_DIR`.

If a containment mode forbids even the banked file store, the project must
report GitHub as unavailable instead of falling back to PAT prompts.

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
    "host": "eezo",
    "hostname": "github.com",
    "gh_path": "/opt/homebrew/bin/gh",
    "state": "live",
    "account": "gdiab",
    "git_protocol": "https",
    "storage": "file",
    "repair": null
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
- `git fetch origin` resolves `remote.origin.url` and is refused before
  execution when that URL is on GitHub. A configured non-GitHub origin passes.
- A GitHub operation inside `sh -c` is gated; the same text inside a
  here-document body is data and passes without a probe.
- A command that merely mentions a GitHub URL or a gh subcommand in argument
  prose — `tightbeam assign --brief "read the gh issue thread at
  https://github.com/org/repo"` — is not probed and not refused.
- With a banked file credential present, `gh auth status` run by the probe
  reports the account sourced from the banked `hosts.yml`, not from an OS
  keyring, and the probe passes from a daemon-descended process.
- No prompt, status payload, log event, or agent message asks the operator to
  paste a PAT.
- No token bytes appear in events, doctor output, status JSON, stderr logs, or
  project metadata, including a token-shaped substring embedded after text
  such as `provider_error=ghp_...`.
- Before onboarding reports success, every banked directory is 0700 and every
  banked file is 0600, including a provider-created `hosts.yml` that began
  with a permissive mode.
- A timeout or unreachable host reports `unknown` and does not authorize GitHub
  work.

## Fixture-backed 0.1.8 runbook

Run this gate from the repository root. First remove every inherited
`TIGHTBEAM_*` and `RELEASE_*` variable, as required by `AGENTS.md`. Do not use a
real GitHub login, token, remote, or network endpoint.

Build the real candidate CLI that the test will execute:

```sh
CARGO_TARGET_DIR=cli/target/github-auth-e2e \
  cargo build --release --manifest-path cli/Cargo.toml
```

Expected result: exit 0 and an executable at
`cli/target/github-auth-e2e/release/tightbeam`. The E2E repeats this cached build
in `setup_all` so no other suite can replace the tested binary through the shared
Cargo target. Existing compiler warnings do not change the result.

Run the fixture E2E:

```sh
MIX_ENV=test mix test test/github_auth_e2e_test.exs
```

Expected result: exit 0, `5 tests, 0 failures`. The test puts fixture `gh` and
`git` programs first on `PATH`. Those programs write only under the test's
temporary directory. They do not contact GitHub. The timeout row takes about 32
seconds because both the Rust and Elixir probes exercise the real 15-second
deadline.

The 0.1.8 GitHub E2E inventory is:

| Row | Required evidence |
| --- | --- |
| Bank and private storage | The real CLI uses browser/device login with `--web --git-protocol https --insecure-storage`; it never uses `--with-token`; directories are 0700 and files are 0600. |
| Host isolation | A satellite cannot borrow the local bank or ambient `GH_CONFIG_DIR`. Every fixture call sees only that host's bank. |
| Environment projection | Local adapter options and satellite SSH commands receive the correct host-local `GH_CONFIG_DIR` and `TIGHTBEAM_MACHINE`. No token bytes are projected. |
| Refusal and repair | A GitHub operation is refused before `git` runs. The refusal names host, hostname, failed phase, state, exact onboarding command, and the no-PAT rule. Quoted brief text and description prose do not trigger the guard. |
| Probe states | Fixture probes prove `live`, `needs_onboarding`, `insufficient_scope`, `git_unready`, and timeout or provider failure as `unknown`. Unknown never authorizes work. |
| Redaction and agreement | Rust and Elixir classify the same API failures. Refusals, doctor output, JSON, and capability metadata omit fixture secrets and bank paths. |

The later installed-build live E2E should use **tars**, the sanctioned
non-production macOS gateway test host. It must run only after separate authority
permits packaging, installation, and a human device login. This fixture gate does
not perform that row, and this producer does not install a build or touch a live
credential.

## Implementation notes

The existing adapter launch path already adds common environment variables in
`Tightbeam.Placement`. GitHub readiness should be checked alongside project
placement/readiness, not inside a shared serializer. Any probe that can touch the
network or ssh must run in the process that owns that failure.

The capability is intentionally separate from `Tightbeam.Credentials`: provider
credentials authorize harnesses to run model turns; GitHub auth authorizes a
host to operate on repositories and tracker objects. They share the
host-local/no-copy rule, but not storage or liveness probes.
