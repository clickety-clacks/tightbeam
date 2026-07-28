# Assimilation runbook — bringing a satellite into an org

The golden path for turning a reachable machine into a Tight Beam satellite, and
proving it worked. This **replaces** the manual host-declaration procedure as the
tested path: `docs/SATELLITE.md` remains the conceptual reference for what a
satellite *is* and what its operator must do by hand, and this runbook is what you
actually run and score.

A satellite runs agent *harnesses*. The substrate, ledger and stores stay on the
gateway. There is no satellite daemon — sshd is the transport, rsync materializes
non-secret session identity, and the gateway owns all lifecycle. Nothing on the
satellite supervises anything.

## Host selection — criteria, not names

This is a product runbook; it names no machines. Pick a target that satisfies all
of:

1. **Reachable non-interactively over ssh from the gateway host.** `ssh <dest> true`
   exits 0 with no prompt. You bring the keys; Tight Beam never creates them.
2. **Has `node`, `npm`, and `rsync`** on a PATH the ssh session sees. A
   non-login shell is what assimilation gets — a tool installed only by `.bashrc`
   is not installed.
3. **Reaches the gateway's advertised URL.** `TIGHTBEAM_ADVERTISED_URL` must be
   resolvable *from the satellite*, never `127.0.0.1`.
4. **Is approved for this use**, and is either unassimilated or has been returned
   to a clean state by §7.
5. **Runs nothing whose disruption matters**, or whose owner has agreed. Assimilation
   writes into a base dir and installs npm packages; it touches nothing else, but
   "touches nothing else" is a claim you should be able to make about the host.

Actual host assignments belong in `docs/TEST-HOSTS.md`, not here.

## Prerequisites on the GATEWAY, checked first

Assimilation will appear to succeed and then fail at first spawn if these are
missing, so check them before you start.

- **The gateway holds a credential for every harness the satellite will run**, even
  though those sessions execute remotely. Catalogs are derived gateway-side and a
  spawn is refused when the catalog is missing. A satellite grant does not cover
  the gateway. See `SATELLITE.md` §What failure looks like.
- **Each such catalog is actually live**, not merely credentialled — `mix
  tightbeam.catalog.diff` returns without `catalog_unavailable`. On a fresh org the
  codex catalog additionally requires `models_cache.json` in the gateway's codex
  home; see finding **#67**, which blocks this prerequisite until resolved.
- **`TIGHTBEAM_ADVERTISED_URL` is set** to an address the satellite can reach.
- The gateway is `active` and its boot summary reads READY for those harnesses.

Record all four. A run that skips them will misattribute a gateway fault to the
satellite, which is the single most common way this procedure is misread.

## 1. Baseline the satellite BEFORE anything

Capture, on the target, and keep it — §7 compares against this:

```sh
ssh <dest> 'hostname; uname -srm;
  for b in node npm rsync git; do printf "%-6s %s\n" "$b" "$(command -v $b || echo MISSING)"; done;
  ls -la ~/.tightbeam 2>/dev/null || echo "no base_dir"'
```

Use **birth times** (`stat -c %w` on linux, `stat -f %SB` on macOS) rather than
mtimes for anything you may later claim this run created. mtimes move for reasons
that have nothing to do with creation.

## 2. Dry run — the probe, with nothing written

```
tightbeam assimilate <ssh-dest> --name <host-name> --dry-run --as-user <admin>
```

PASS: reports the probe results — ssh reachable, node/npm/rsync present, the
resolved base dir and bin paths — and **writes nothing**. Re-run §1 and confirm the
satellite is byte-for-byte as it was.

FAIL: any missing prerequisite is named. Fix it on the host and re-probe. A
`--dry-run` that reports success and then a real run that fails on the same
prerequisite is a FINDING, not a retry.

## 3. Assimilate

```
tightbeam assimilate <ssh-dest> --name <host-name> [--base-dir <path>] \
  [--harness claude|codex] --as-user <admin>
```

`--name` is yours; `local` is reserved. `--harness` narrows which ACP adapters get
installed (see #13, fixed). Omitting it installs every registered harness's adapter.

PASS, all of:

- exit 0
- the host is registered — `tightbeam config` / `role-list`-adjacent listing shows
  it with the ssh destination, base dir, cli bin dir and adapter bin dir it reports
- on the satellite, `<base_dir>/` exists with the adapter packages and a `tightbeam`
  executable at the recorded `cli_bin`
- **no `auth/` contents were created and nothing was copied there.** Assimilation
  does not carry credentials. Verify the gateway's own `auth/` files are unchanged
  by hash, and that the satellite has no credential it did not already have.

> **OPEN QUESTION (Q4), flagged rather than invented.** Host configuration has two
> sources: `TIGHTBEAM_HOSTS` (read at `config/runtime.exs:67`) and
> `Placement.register_host/3` as written by `assimilate`/`register-host`. This
> runbook assumes `assimilate` is the golden path and the env var is the older
> manual route. Whether they merge, which wins on conflict, and whether a host
> registered one way is visible to the other is **not yet ruled**. Until it is, do
> not declare the same host both ways in one run, and record which route you used.

## 4. Credentials — onboarded ON the satellite, never transported

Run Tight Beam onboarding independently on the satellite, once per harness that
will run there:

```
tightbeam onboard anthropic --as-user <admin>     # claude
tightbeam onboard openai    --as-user <admin>     # codex
```

**Never copy, harvest, scp or rsync credentials between machines.** This is not a
tidiness rule — a credential that travels makes every host's blast radius the union
of all hosts'.

PASS: each provider reaches `onboarded`, and the credential file exists under the
**satellite's** `<base_dir>/auth/<harness>/`. The gateway's auth store is unchanged.

WAIVER: if an authorization cannot be obtained, waive that harness **by name** with
the blocker stated. The run verdict is then INCOMPLETE, which is honest. Do not
substitute a credential from elsewhere to avoid a waiver.

## 5. Placement — a host is usable only where an archetype admits it

Placement is law. In the gateway's `<base_dir>/identity/archetypes/`:

```toml
# <archetype>.toml
where = ["<host-name>"]
[defaults]
harness = "codex"
```

Then:

```
tightbeam spawn --display "<name>" --archetype <archetype> --as-user <admin>
```

PASS, all of:

- the session's turns record the satellite as their host
- **projected identity arrived**: `<base_dir>/homes/<machine>/<harness>` exists on
  the satellite; guidance is present in the harness instruction channel
- **rails arrived**: the projected home carries `settings.json` (claude) or
  `hooks.json` with `tightbeam-probe` LAST (codex) — and the *inverse* file is
  absent on each, the same divergence SMOKE.md §9 asserts locally
- **elected skills** are materialized at the exact remote session cwd under
  `.claude/skills/tightbeam__*` or `.codex/skills/tightbeam__*` — not in the shared
  home
- **zero statute bytes** in composed guidance, exactly as locally
- a real turn is `delivered` from the satellite session
- **no credential bytes appear in any captured ssh or rsync command**

Then spawn OUTSIDE `where` and confirm it is **denied, citing the check**. A
placement that silently succeeds where the archetype forbids it is a FAIL.

## 6. The properties that distinguish assimilation from "it worked once"

**6a. Idempotent re-assimilation.** Run §3 again, unchanged. PASS: exit 0, no
duplicate host registration, credentials untouched, existing sessions unaffected.
Re-assimilating is how an operator repairs a partial install; it must not be
destructive.

**6b. Adapter and gateway restart.** Restart the gateway. PASS: the satellite
session reconnects without intervention; the harness pointer reads `loaded`, never
`fallback`; a queued turn for that session survives and delivers without re-sending.

**6c. Satellite loss and recovery — bounded, not silent.** Make the satellite
unreachable (drop the network, or stop sshd — record which). PASS: turns fail
**fast with a reason**, backoff is visible, the circuit opens after repeated
failures, and `/version` shows it. Nothing hangs indefinitely and nothing retries
forever. Restore reachability. PASS: the circuit closes on the next successful
start with no operator action.

**6d. Failure diagnostics name the right machine.** A spawn refused
`catalog_unavailable` naming the **gateway** is the §Prerequisites failure, not a
satellite fault, and onboarding the satellite again will not fix it. Confirm the
message names the provider, the host, and the repair. A diagnostic that sends the
operator to the wrong machine is a FINDING.

## 7. End of run — retain or return, deliberately

**Default: retain.** Per `docs/TEST-HOSTS.md` §5 an installation stays so later
runbooks have something to run against, and this satellite is the prerequisite for
`INTER-NODE-COMMS.md`. Clean only temporary artifacts: scratch clones, `/tmp`
staging, probe output outside the base dir.

**Returning a host to unassimilated is a separately authorized action**, not a
phase of this run. When authorized: remove the base dir and the adapter/CLI
installs this run created, verify against the §1 baseline by birth time, and
confirm nothing that predates the run was removed. Never remove the operator
account, its own credentials, or any unrelated toolchain — if provenance is
ambiguous, **leave it and report it**.

Re-verify unrelated workloads are still running, on both hosts.

## Scorecard

`docs/smoke-runs/<date>-<short-sha>-assimilation-<host-name>.md`, one row per
section §1–§7 with PASS / FAIL(note) / WAIVED(blocker) / NOT VERIFIED(reason) /
BLOCKED(blocker). Header carries gateway commit, gateway host, satellite host,
harnesses assimilated, and the retain-or-return decision.

A FAIL blocks; a waived harness leg makes the run INCOMPLETE, not passed.
