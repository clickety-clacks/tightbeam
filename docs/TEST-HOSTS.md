# Test-host runbook — disposable account protocol

How tests run on Gibson, shrdlu, and any other real test host. This is **test
setup**, not part of any customer procedure, and it must never be confused with
one: the disposable account represents *the customer invoking the installer*, and
Tight Beam itself installs as an independent system service outside it (see
`service-mode-install-v1.md`).

Written because both failure modes have already happened: a test that ran as the
developer's own account and was silently contaminated by prerequisites installed
hours earlier, and an account created without authorization.

## 1. Create one uniquely named disposable account

One per run, named so two concurrent runs cannot collide and so the account's
purpose is legible to anyone reading `/etc/passwd`:

```sh
sudo useradd -m -s /bin/bash \
  -c "disposable tightbeam test account — run <RUNID>" tbtest-<RUNID>
```

`<RUNID>` is unique per run (date + short token). **Never reuse a name, never reuse
an account across runs, and never run a test from a human's account** — a prior
run's caches, PATH, tools, or credentials will mask exactly the failures the test
exists to find.

Record at creation: account name, uid, creation timestamp.

## 2. Baseline the clean environment BEFORE anything else

Capture what the account can see, so any later claim about a missing prerequisite is
evidence rather than assertion:

```sh
sudo -u tbtest-<RUNID> -i bash -lc 'echo "PATH=$PATH"; for c in elixir mix erl cargo \
  rustc node npm claude codex git gcc make; do printf "  %-7s %s\n" "$c" \
  "$(command -v $c 2>/dev/null || echo MISSING)"; done; ls ~/.mix/archives 2>/dev/null'
```

A fresh account sees only system-wide tools. Anything found under the *developer's*
home is invisible to it, which is the point.

## 3. Run only the published procedure, from that account

No shortcuts, no dev checkouts, no substitutions, no repairs. **The procedure is what
is under test.** Stop at the first failure and report the exact step, command, output,
and customer impact — do not work around it. Patch the published instructions, review
and publish, reset the account, and retry from step one.

Capture per run: installed commit/version, every step with its exit status, and the
resulting service health.

## 3a. Bootstrap the first client BEFORE onboarding

The published procedure's order is **boot → connect first client → onboard**, and
it is not optional: a fresh org has no users, `onboard` is admin-only, and the
first client to pair is auto-approved and becomes that admin
(`Devices.pair/2` — zero users means `allowlisted` + a minted token, instantly).
Running `onboard` first returns `forbidden: admin required` and there is no other
way to create the admin. A run that skips this reports a sequencing mistake as a
product defect — that already happened once.

On a headless test host there is no GUI client, so pair with
`Tightbeam.ClientE2E.SimClient.pair/3`, which opens a pairing socket, sends
`pair_request`, reads `pair_result`, and closes. That is the same wire ceremony a
real client performs; it is not a mock of the gateway side.

## 4. Verification — not "a process is running"

Per `service-mode-install-v1.md`, the service must be proven to:

- start with no interactive login
- survive logout of the disposable account
- survive reboot
- run a real turn against its own credentials

An earlier version of this list also demanded the service "read nothing from the
disposable account's home". That was wrong and is struck: there is no dedicated
service account — the service runs as the account that installed it, which in a
test run *is* the disposable one, so its working directory, `ExecStart`, and
`base_dir` all live there by construction. Following the README made that bullet
unsatisfiable. What it was really guarding against — a system service outliving
the account that owns its files — is already handled by the teardown ordering in
§5: uninstall first, verify no residue, and only then delete the account.

A foreground process is not evidence for any of these.

## 5. Teardown — uninstall FIRST, then the account

**Order is load-bearing.** Tight Beam is a system service whose identity and files
outlive the account that installed it; deleting the account first orphans it.

1. Run the **documented production uninstall path** — the same one a customer runs.
2. **Verify no residue**: no unit or plist, no process, no listener on the gateway
   port, no service account, nothing left under the service `base_dir`.
3. Only then, validate the disposable account before deleting it:
   - it is the exact `tbtest-<RUNID>` created by this run, matching the recorded uid
     and creation timestamp
   - no processes are running as it: `pgrep -u <account>`
   - it owns nothing outside its own home: `find / -xdev -user <account> -not -path "<home>/*"`
4. Delete only it: `sudo userdel -r tbtest-<RUNID>`
5. Confirm afterwards that every other account still exists, and that unrelated
   workloads on the host are untouched.

**Never delete any other account**, and never delete shared machine tooling merely
because a customer might not have it — isolation is achieved by the fresh account,
not by stripping the host.

## Host-specific notes

- **gibson** — production canary. Runs a **llama-server** inference service on the GPU
  that must never be disturbed: verify `systemctl is-active llama-server` and that
  `:8080` still answers before and after any test.
- **shrdlu** — the linux test host; broadly disposable.
- Both are reachable over the tailnet; see the environment map for addresses.
