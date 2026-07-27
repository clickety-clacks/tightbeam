# Test-host runbook — smoke on the real operator account

How the production-install smoke runs on shrdlu, tars, and any other real test host.
This is **test setup**, not part of any customer procedure, and it must never be
confused with one.

## The rule: run as the account that will really run it

**Run the smoke under the intended permanent service/operator account.** On shrdlu
that is **`clu`**; on tars it is **`mike`**. Not a purpose-made account.

This is not convenience — it is the only way the test measures the thing that
ships. Tight Beam installs as a **system service** (see
`service-mode-install-v1.md`), and the service runs as the account that installed
it. So that account's **permissions, paths, PATH, home layout, and credential
visibility are part of the artifact under test.** Run it somewhere else and you
prove the install works for an identity that will never exist in production.

An earlier version of this runbook required creating a uniquely-named disposable
OS account per run and deleting it at teardown. That is **removed**. It tested a
configuration nobody ships: different home, different PATH, different credential
reachability, and a service whose owning account was about to be deleted — which
forced a teardown-ordering rule that only existed to protect against a hazard the
test itself created.

**Never delete or reset the operator account.** Cleanup removes what this run
added, nothing else.

## 1. A clean start means Tight Beam is ABSENT — not that the identity is new

Before a run, for the operator account:

- no clone of the repo from a previous run
- no `base_dir` (`~/.tightbeam` unless `TIGHTBEAM_BASE_DIR` says otherwise) — no
  `state.db`, no `identity/`, no `auth/`, no `homes/`
- no installed unit or plist, no running gateway, nothing on the gateway port
- **no prerequisites that a previous run installed** — if an earlier smoke put
  rustup, Elixir, Hex/rebar or the harness CLIs there, they mask the prerequisite
  checks the procedure exists to exercise

Anything the account had **before** Tight Beam ever touched it stays. The
distinction is provenance, not tidiness: remove what a Tight Beam run added,
preserve what the machine already was.

## 2. Baseline BEFORE anything else

Capture what the account actually sees, so any later claim about a missing
prerequisite is evidence rather than assertion:

```sh
ssh <host> 'bash -lc '\''echo "PATH=$PATH"; for c in elixir mix erl cargo rustc \
  node npm claude codex git gcc make; do printf "  %-7s %s\n" "$c" \
  "$(command -v $c 2>/dev/null || echo MISSING)"; done; ls ~/.mix/archives 2>/dev/null'\'''
```

Record it verbatim in the run doc. A prerequisite finding is only credible against
a recorded baseline.

## 3. Run only the published procedure

No shortcuts, no dev checkouts, no substitutions, no repairs. **The procedure is
what is under test.** Stop at the first failure and report the exact step, command,
full output, and customer impact — do not work around it. Then patch the published
instructions, review and publish, restore a clean start per §1, and retry.

Capture per run: the installed commit, every step with its exit status (read exit
codes without a pipeline — `$?` after a pipe reports the last command, not yours),
and the resulting service health.

## 3a. Bootstrap the first client BEFORE onboarding

The published order is **boot → connect first client → onboard**, and it is not
optional: a fresh org has no users, `onboard` is admin-only, and the first client
to pair is auto-approved and becomes that admin (`Devices.pair/2` — zero users
means `allowlisted` plus a minted token, instantly). Running `onboard` first
returns `forbidden: admin required` and there is no other way to create the admin.
A run that skips this reports a sequencing mistake as a product defect — that has
already happened once.

On a headless host there is no GUI client, so pair with
`Tightbeam.ClientE2E.SimClient.pair/3`: it opens a pairing socket, sends
`pair_request`, reads `pair_result`, closes. That is the same wire ceremony a real
client performs, not a mock of the gateway side.

## 3b. Credentials are always onboarded fresh — never adopted

Tight Beam's onboarding stages into an isolated directory and installs only the
bytes that ceremony produces. It **cannot** adopt the operator account's existing
`claude` or `codex` login, and running as `clu` does not change that: the CLI is
invoked with `CODEX_HOME` / `CLAUDE_CONFIG_DIR` pointed at the staging dir.

So expect a **fresh interactive authorization per provider per run**, and treat it
as legitimate rather than an obstacle to route around. **Never copy, import,
symlink, or read the operator's own credential files** to satisfy a run — that is
the harvesting `SATELLITE.md` prohibits. If an authorization cannot be obtained,
**waive that leg by name** with the blocker stated; per `SMOKE.md` the verdict is
then INCOMPLETE, which is an honest outcome.

## 4. Verification — not "a process is running"

Per `service-mode-install-v1.md`, prove the service:

- starts with no interactive login
- survives logout of the operator account
- survives reboot
- runs a real turn against its own credentials

A foreground process is not evidence for any of these, and a green unit file is
not evidence for logout, reboot, or a turn.

## 5. End-of-run cleanup — uninstall, then remove only what this run added

Tight Beam does not stay behind on a test host. Run this even when the smoke
failed part-way.

1. **Uninstall via the documented production path** — the same one a customer
   runs. This is itself a test of that path; capture it as evidence.
2. **Remove the Tight Beam-owned test state** introduced by the run: the clone,
   `base_dir` (`state.db`, `identity/`, `auth/`, `homes/`, `bin/`), any staging
   dirs under `/tmp`, and the **test credentials this run onboarded** — they live
   in `base_dir/auth/`, so removing `base_dir` removes them. The operator's own
   `~/.claude` / `~/.codex` are NOT test state and stay.
3. **Remove prerequisites this run installed**, and only those. Establish
   provenance before deleting anything — mtimes against the run's start, or your
   own record of what you installed. If provenance is ambiguous, **leave it and
   report it**; a wrongly-removed toolchain breaks unrelated work on a shared box.
4. **Verify residue**: no unit or plist, no process, nothing on the gateway port,
   no `base_dir`, no clone.
5. **Confirm unrelated state survived** — the account itself, its own credentials,
   and every unrelated service. On shrdlu that means openclaw-gateway,
   subspace-daemon, postgresql and docker still `active`.

**Never delete or reset the operator account.** There is no account teardown.

## Host-specific notes

- **shrdlu** — linux gateway testing, operator account `clu`. Runs unrelated
  workloads (openclaw-gateway, subspace-daemon, postgresql@16, docker) that must
  be verified `active` before and after. Reboots are permitted when the operator
  has confirmed nothing in flight matters.
- **tars** — macOS gateway testing, operator account `mike`. Sanctioned for gateway
  testing by the topology assignment, but **no CLU development artifacts**: keep
  everything inside the run's `base_dir` and clean up after.
- **eurisko / eliza** — linux satellites, freely reinstallable.
- **gibson** — production. NOT a test host. Nothing installs there until shrdlu and
  tars have passed the full sequence. It runs a **llama-server** inference service
  on the GPU that must never be disturbed.
- Reachable over the tailnet; see the environment map for addresses.
