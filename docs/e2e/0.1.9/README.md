# Tightbeam 0.1.9 end-to-end acceptance

These are runbooks. They record no result, and nobody runs them until Mike calls
the run. The branch's source CI does not execute them. Writing or reviewing a
runbook authorizes no host, container runtime, `sudo` route, database copy,
credential or execution.

The procedure migrates one real 0.1.8 database once and preserves the migrated
result. Historical preservation and a migrated-state read sample use copies of
that result. New-record feature journeys use disposable fresh bases and
test-owned actors; they do not require another real-org copy. No feature check
repeats the migration or changes the preserved copy.

| Runbook | What it covers | Starts from |
|---|---|---|
| [PREFLIGHT.md](PREFLIGHT.md) | Readiness: every prerequisite classified, what is missing and who supplies it | Nothing; read it first |
| [migration.md](migration.md) | 0.1.8 to 0.1.9 migration, package acquisition and kind, build admission (`TIGHTBEAM_LIVE_BASE_TRANSITION` or release provenance), preservation reads, reusable output | A verified copy of a real 0.1.8 `state.db` |
| [gateway-surface.md](gateway-surface.md) | Gateway shim verbs, stop isolation, REST authentication and D1 reads, CLI transport diagnostics | Fresh empty bases, plus one migrated copy |
| [provider-runtime.md](provider-runtime.md) | Identity, harness transition, satellite connection, shipped guidance, conditional recovery | Fresh base |
| [work-routing.md](work-routing.md) | Work-item fields and body, current-owner routing, topology, replace/stop/resume, conditions, sentinel lifecycle | Fresh base |
| [decisions-assignments.md](decisions-assignments.md) | Cannot-proceed; ask, answer and return; liveness, completion handoff and gates; revoke, reopen and conditional recovery | Fresh base |
| [telemetry.md](telemetry.md) | Breathing, queue summary, execution map, durable Toplines, fourth-review notice | Fresh base; historical sample may reuse a migrated copy |
| [artifacts.md](artifacts.md) | Producer and verdict binding, gate enforcement, uncaptured content, original-host retirement cleanup | Fresh base; contained migrated copy only for the unreachable historical-host control |

Each runbook runs on its own. A later change reruns only the runbooks it
touches, with the fixture class its row names. The
[aggregate run](#aggregate-run) runs them all.

## Execution contract

- Use one hash-verified 0.1.9 package for the whole run. Call its gateway, its
  gateway shim and its CLI by absolute path (`$PKG/bin/tightbeam-gateway`,
  `$PKG/bin/tightbeam`). Never let `PATH` pick an installed CLI or shim, and
  never mix a checkout gateway with a package gateway: a mixed run describes no
  real build.
- Before each runbook, record the package version, its source commit and SHA-256,
  its payload `buildIdentity`, the host, and each harness CLI version. Record
  the migration manifest digest for every area that starts from the migrated
  result.
- Nothing runs against a live base, and nothing is installed on Gibson. Every
  base is a new directory under the environment's scratch space, with an
  unused loopback port.
- A check whose real prerequisite is absent (an incident, a failed turn, a
  provider grant, an interactive login) records `skipped` with the missing
  prerequisite. Never fabricate the prerequisite with synthetic rows.

### CLI shell

The CLI finds its endpoint in this order: a `.tightbeam-session` file in any
ancestor of the working directory, then `TIGHTBEAM_URL` with `TIGHTBEAM_TOKEN`,
then `gateway.json` under `TIGHTBEAM_BASE_DIR`, `TIGHTBEAM_HOME` or
`~/.tightbeam`. Every CLI call in these runbooks runs from a shell set up like
this, so only the named test base can answer:

```sh
cli_cwd="$(mktemp -d "${SCRATCH:?}/cli.XXXXXX")"
cd "$cli_cwd"
directory="$(pwd -P)"
while :; do
  test ! -e "$directory/.tightbeam-session" || {
    echo "session marker in CLI working-directory ancestry; stop" >&2
    exit 1
  }
  test "$directory" = "/" && break
  directory="$(dirname "$directory")"
done
unset TIGHTBEAM_URL TIGHTBEAM_TOKEN TIGHTBEAM_HOME
tb() { TIGHTBEAM_BASE_DIR="${AREA_BASE:?}" "${PKG:?}/bin/tightbeam" "$@"; }
```

`tb` acts as the area gateway's operator. Rows that need an admin add
`--as-user <adminUserId>` with an admin user of that test base.

### Fresh-base actors

Use a separately authorized empty base with the same verified package and the
CLI shell above. Record its test admin, admitted local host, test owner(s),
session keys and workdirs. Create users with `add-user`, and sessions with
`spawn --display <test-display-name> --name <unique-role>
--archetype <admitted-role> --harness <harness> --model <catalog-model>`, using
the actual catalog and admission constraints. `--display` is required;
`--name` supplies the optional role handle.
Never insert fixture rows in the database or copy a live session/token into
this base. A missing admitted actor is `INCOMPLETE` with the refused operation;
it does not authorize relaxing admission.

For a local test session, run the packaged CLI from its returned workdir so
the CLI carries that session's own identity. In the area tables, `as_actor
<workdir> <verb> ...` means:

```sh
as_actor() {
  actor_dir="$(realpath "${1:?test session workdir}")" || return 1
  shift
  actor_root="$(realpath "${AREA_BASE:?}/work")" || return 1
  case "$actor_dir" in "$actor_root"/*) ;; *) echo "actor outside test base" >&2; return 1 ;; esac
  test -f "$actor_dir/.tightbeam-session" || return 1
  (cd "$actor_dir" && "${PKG:?}/bin/tightbeam" "$@")
}
```

Use only workdirs created in this base and verified to belong to the recorded
test sessions. For an authorized satellite actor, use its own workdir on that
satellite, its matching packaged CLI, and its configured test gateway route;
record those paths separately. Do not copy a bearer into command arguments or
evidence. Reads of named non-secret database columns are allowed in private
test scratch. Never `SELECT * FROM sessions`.

`Fresh / records` rows need admitted actors and normal public record operations;
they do not require a model to demonstrate the record's semantics. Spawn,
dispatch, automatic remedies or identity apply can still require working host
or provider setup. Record those real prerequisites and any incidental turns.
`Fresh / online` rows require actual provider, satellite, GitHub or human
interaction. A command returning a queued wake is not proof of a model reply.

These fixture instructions do not extend execution authority. All records,
roles, files and repositories belong to the authorized test environment.

### Copied session tokens

Rows that act as a copied session are conditional. They run only inside an
area copy whose containment conditions all passed, and only when the run's
recorded execution approval names copied-token use. The PO's authoring ruling
(`att_eb2fcdf2`) permits these checks to be written; it grants no credential,
host or execution authority. The helper below stops before it reads any token
unless `COPIED_TOKEN_APPROVAL` names that execution approval; without it, each
such row is recorded `INCOMPLETE: copied-token use not approved`. Rows that
only use `tb` as the operator or an admin still run.

With that approval, a row uses the session's `cliToken` from the area copy.
That value is the live org's real bearer, and isolating the copy does not
revoke it: it would still work against the live gateway. So it is used only
inside the verified boundary, only against the area's loopback gateway, and
never printed, logged, exported or saved. A copied session acts with its own
ordinary permissions; no row grants it more. These runbooks do not claim a copied token is
accepted by the area gateway: if a call is refused for authentication, record
that row `INCOMPLETE` with the refusal code, not `observed-fail`. Do not run
this helper under `set -x`:

```sh
as_session() {
  if test -z "${COPIED_TOKEN_APPROVAL:-}"; then
    echo "STOP: copied-token use not approved; record this row INCOMPLETE" >&2
    return 1
  fi
  key="$1"; shift
  token="$(sqlite3 -readonly "${AREA_BASE:?}/state.db" \
    "SELECT cliToken FROM sessions WHERE sessionKey = '$(printf %s "$key" | sed "s/'/''/g")'")"
  test -n "$token" || return 1
  TIGHTBEAM_URL="http://127.0.0.1:${AREA_PORT:?}" TIGHTBEAM_TOKEN="$token" \
    "${PKG:?}/bin/tightbeam" "$@"
}
```

Never `SELECT *` from `sessions`. Query named columns only.

### Gateway start and stop

Every runbook starts a gateway through these helpers, in the same script as its
checks, so an interrupted script still stops the gateway it started.
`gateway_start` waits up to 120 seconds for `/version` and fails sooner if the
process exits. Refusal probes and every ordinary start use it.

`gateway_start_migration` is only for the positive start in
[migration.md](migration.md#run-the-migration-once), the one start that
migrates a real-size base. A gateway serves `/version` only after its
migration completes, and that can take longer than 120 seconds, so this
helper has no time limit. It keeps waiting only while the launched process is
alive. If the process exits first, it reports the exit status and returns
failure; that exit is never treated as a ready gateway. Every 60 checks it
prints the elapsed seconds and the private log's size in bytes. It prints
nothing from the log. An operator stops a start that has gone on too long by
interrupting the script, which runs the same cleanup trap.

The package `stop` verb signals the process recorded in the named base's
`gateway.json` and does not wait, so the trap waits for it. Startup writes
`gateway.json` only after preflight, and `stop` refuses before then; in that
window the helper sends `TERM` to the child this shell launched, and nothing
else. The wait is bounded: a child still running after 60 seconds gets `KILL`.

```sh
gateway_pid=""
gateway_launch() { # gateway_launch BASE PORT LOG [NAME=VALUE ...]
  base="$1"; port="$2"; log="$3"; shift 3
  env -u TIGHTBEAM_LIVE_BASE_TRANSITION -u TIGHTBEAM_ADVERTISED_URL \
    -u RELEASE_NODE -u RELEASE_COOKIE -u TIGHTBEAM_NODE \
    TIGHTBEAM_BASE_DIR="$base" TIGHTBEAM_PORT="$port" "$@" \
    "${PKG:?}/bin/tightbeam-gateway" >"$log" 2>&1 &
  gateway_pid=$!
  gateway_base="$base"
  gateway_port="$port"
  gateway_log="$log"
}
gateway_ready() { # one /version read from the last launched gateway
  curl -fsS --noproxy '*' "http://127.0.0.1:$gateway_port/version" >"$gateway_log.version"
}
gateway_start() { # gateway_start BASE PORT LOG [NAME=VALUE ...]
  gateway_launch "$@"
  attempt=0
  until gateway_ready; do
    kill -0 "$gateway_pid" 2>/dev/null || return 1
    attempt=$((attempt + 1))
    test "$attempt" -lt 120 || return 1
    sleep 1
  done
}
gateway_start_migration() { # same arguments; no time limit while the process lives
  gateway_launch "$@"
  started="$(date +%s)"
  attempt=0
  until gateway_ready; do
    elapsed=$(($(date +%s) - started))
    if test -z "$gateway_pid"; then
      echo "migration start: stopped by the operator after ${elapsed}s" >&2
      return 1
    fi
    if ! kill -0 "$gateway_pid" 2>/dev/null; then
      status=0; wait "$gateway_pid" || status=$?; gateway_pid=""
      echo "migration start: gateway exited with status $status after ${elapsed}s without serving /version" >&2
      return 1
    fi
    attempt=$((attempt + 1))
    test $((attempt % 60)) -ne 0 ||
      echo "migration start: gateway alive, no /version yet, ${elapsed}s, log $(wc -c <"$gateway_log") bytes" >&2
    sleep 1
  done
  echo "migration start: /version served after $(($(date +%s) - started))s" >&2
}
gateway_stop() {
  test -n "$gateway_pid" || return 0
  TIGHTBEAM_BASE_DIR="$gateway_base" "${PKG:?}/bin/tightbeam-gateway" stop ||
    kill -TERM "$gateway_pid" 2>/dev/null || true
  stop_wait=0
  while kill -0 "$gateway_pid" 2>/dev/null && test "$stop_wait" -lt 60; do
    stop_wait=$((stop_wait + 1))
    sleep 1
  done
  if kill -0 "$gateway_pid" 2>/dev/null; then kill -KILL "$gateway_pid" || true; fi
  wait "$gateway_pid" || true
  gateway_pid=""
}
trap gateway_stop EXIT INT TERM
```

Gateway logs stay in private scratch. A scorecard carries only non-secret
checks and redacted excerpts.

## Containment

The PO approved this procedure as content only (`att_0b54ceab`). Any boot of
real copied data (the migration, its refusal probes and every offline area)
happens inside a disposable environment that satisfies all six conditions
below, checked from inside that environment before the first gateway start.
The checks assume a Linux environment. Elsewhere, record equivalent commands
before running, or record the condition as unmet.

If any check fails or its result is uncertain, record
`INCOMPLETE: isolation condition <n> unmet` and start no gateway. Never meet a
condition by editing, deleting or rewriting copied rows.

Set these first. `SOURCE_DIR` is the read-only mount holding the verified
source `state.db`, its manifest and the 0.1.8 package; `SCRATCH` is the only
writable area.

```sh
SOURCE_DIR=/operator-supplied/read-only/source
SCRATCH=/operator-supplied/scratch
PKG=/operator-supplied/verified-0.1.9/package
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }
```

1. **Authority and capacity.** The recorded approval for this run names this
   environment. The tools are present, and scratch holds at least three times
   the source database (the migration base copy, the `VACUUM INTO` output and
   one area copy).

   ```sh
   echo "approval: <record id naming this environment>"
   for tool in sh sqlite3 python3 curl git ps find; do
     command -v "$tool" >/dev/null || echo "missing: $tool"
   done
   source_bytes="$(wc -c <"$SOURCE_DIR/state.db")"
   scratch_bytes="$(df -Pk "$SCRATCH" | awk 'NR==2 {print $4 * 1024}')"
   test "$scratch_bytes" -ge $((3 * source_bytes))
   ```

2. **Filesystem.** Only the environment's root and the explicit scratch and
   source mounts exist. No base directory named by a copied `hosts` row exists
   or resolves here, and no live Tightbeam base does. The source is read-only.

   ```sh
   cat /proc/self/mountinfo   # every entry is the root, scratch, SOURCE_DIR or a kernel pseudo-filesystem
   sqlite3 -readonly "$SOURCE_DIR/state.db" "SELECT baseDir FROM hosts WHERE baseDir IS NOT NULL" |
     while IFS= read -r dir; do
       dir="$(eval echo "$dir")"
       if test -e "$dir" || test -L "$dir"; then echo "copied host base present: $dir"; fi
     done
   for dir in /root/.tightbeam /home/*/.tightbeam; do
     if test -e "$dir" || test -L "$dir"; then echo "live base present: $dir"; fi
   done
   if touch "$SOURCE_DIR/.write-probe" 2>/dev/null; then
     rm -f "$SOURCE_DIR/.write-probe"; echo "source is writable"
   fi
   ```

   Any printed line fails the condition. A container runtime's own bind mounts
   of `/etc/hosts`, `/etc/hostname` and `/etc/resolv.conf` are expected and do
   not fail it; anything else from the host does.

3. **No host control.** No container runtime, systemd, D-Bus, tmux or SSH-agent
   socket is reachable, and every Unix socket lives in scratch. The process list
   shows only this environment. No Erlang node is registered, and nothing
   inherits a node name or cookie.

   ```sh
   find / -xdev -type s ! -path "$SCRATCH/*" 2>/dev/null
   ls -l /var/run/docker.sock /run/containerd /run/podman /run/systemd/private \
     /run/dbus/system_bus_socket /tmp/tmux-* 2>/dev/null
   ps -eo pid,user,args
   "$PKG"/release/erts-*/bin/epmd -names 2>&1
   env | cut -d= -f1 | grep -E '^(RELEASE_NODE|RELEASE_COOKIE|TIGHTBEAM_NODE|SSH_AUTH_SOCK)$'
   test ! -e "$HOME/.erlang.cookie"
   ```

   The `find`, `ls` and `env` lines print nothing. `ps` lists only processes
   started inside the environment (its own PID namespace). `epmd -names`
   reports no running daemon or no names.

4. **Loopback only.** The only interface is `lo`. Name resolution fails, and TCP
   connections fail to every copied SSH target, the provider APIs, GitHub and a
   literal public address.

   ```sh
   ls /sys/class/net
   sqlite3 -readonly "$SOURCE_DIR/state.db" "SELECT ssh FROM hosts WHERE ssh IS NOT NULL" >"$SCRATCH/ssh-targets"
   python3 - "$SCRATCH/ssh-targets" <<'PY'
   import socket, sys
   failures = []
   try:
       socket.getaddrinfo("github.com", 443)
       failures.append("DNS resolved github.com")
   except OSError:
       pass
   targets = [("api.anthropic.com", 443), ("api.openai.com", 443), ("github.com", 443), ("1.1.1.1", 443)]
   for line in open(sys.argv[1], encoding="utf-8"):
       host = line.strip().split("@")[-1].split(":")[0]
       if host:
           targets.append((host, 22))
   for host, port in targets:
       try:
           socket.create_connection((host, port), timeout=5).close()
           failures.append(f"connected to {host}:{port}")
       except OSError:
           pass
   print("\n".join(failures) or "no route")
   PY
   ```

   `ls` prints only `lo`, and the probe prints `no route`.

5. **No ambient credentials.** `HOME` is in scratch, with no `.ssh` and no
   harness login state. No credential or endpoint variable is set, and no
   ancestor of the working directory holds a session marker. Print variable
   names only, never values.

   ```sh
   case "$HOME" in "$SCRATCH"/*) ;; *) echo "HOME outside scratch";; esac
   ls -a "$HOME"   # no .ssh, .claude, .codex, .cursor, .pi, .config/gh or similar login state
   env | cut -d= -f1 | grep -E '^(SSH_AUTH_SOCK|TIGHTBEAM_URL|TIGHTBEAM_TOKEN|TIGHTBEAM_ADVERTISED_URL|CREDENTIALS_DIRECTORY|TIGHTBEAM_CREDENTIALS_DIRECTORY|TIGHTBEAM_LOCAL_HOST_NAME|TIGHTBEAM_HOME)$'
   env | cut -d= -f1 | grep -Ei '(anthropic|openai|cursor|claude|codex|gh_|github|token|api_key|secret)'
   ```

   Both `grep` lines print nothing. Run the [CLI shell](#cli-shell) marker check
   from the working directory you will use.

6. **Contained prerequisites.** The package hash matches its published value and
   the source snapshot's digest matches its manifest. Boot preflight refuses to
   start (`no_harness_cli`) unless a registered harness CLI can run, so the
   harness CLIs are installed inside the environment, logged out.

   ```sh
   test "$(sha256 "$SOURCE_DIR/package-0.1.9.tar")" = "<published SHA-256>"
   test "$(sha256 "$SOURCE_DIR/state.db")" = "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stateDbSha256"])' "$SOURCE_DIR/manifest.json")"
   claude --version; codex --version
   ```

Copied rows are not sanitized. They hold real bearer tokens and host routes;
isolation does not revoke those tokens, and condition 4 only keeps them from
reaching anything outside the copy. Never show, export or log them. Remove each area copy after its runbook finishes, keep the migrated
output, and discard the environment at the end.

### Reference environment

<a id="reference-environment"></a>

The six conditions describe the environment; this is one way to build it that
satisfies them, on a Linux host with Docker. The approval for the run names
the image ID, and the container is started by that ID, not by a tag that can
move. Nothing here touches the host's own Tightbeam base.

```Dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git sqlite3 python3 procps findutils libssl3 libncurses6 nodejs npm \
    && npm install -g @anthropic-ai/claude-code @openai/codex \
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 10001 e2e
USER e2e
```

```sh
docker build -t tightbeam-e2e:0.1.9 -f Dockerfile .
image_id="$(docker image inspect --format '{{.Id}}' tightbeam-e2e:0.1.9)"   # sha256:…, record this
docker run --rm -it --network none --hostname e2e \
  -v "/host/source-dir:/source:ro" -v "/host/scratch:/scratch" \
  -e SOURCE_DIR=/source -e SCRATCH=/scratch -e HOME=/scratch/home \
  "$image_id" bash
```

Inside: `mkdir -p "$HOME"`, extract the package into `$SCRATCH/pkg` and set
`PKG="$SCRATCH/pkg/tightbeam"`, then run the six checks above before anything
else. The harness CLIs are installed and have never been logged in, which is
what condition 5 and the boot preflight need. `/host/source-dir` holds the
[source snapshot](migration.md#source-snapshot) files, the 0.1.9 package, its
`SHA256SUMS` and the candidate checkout; `/host/scratch` must have room for
three copies of the database. Files under `/source` keep the host user's
ownership, so any `git` command against the candidate checkout there needs
`safe.directory` for that command, as the migration runbook shows; do not
`chown` the mount or change its permissions.

## Tiers

- **Offline, real-data copy.** Inside the verified boundary: the migration and
  its refusal probes, preservation reads, transition checks and the migrated
  acceptance sample. Rows that need a copied session to
  act are conditional on the [copied-token ruling](#copied-session-tokens).
- **Online, fresh empty base.** A separately authorized environment with
  conditions 1 to 3 met; its online authorization replaces conditions 4 and 5.
  It uses test-owned accounts and a new empty 0.1.9 base, never copied data.
  Rows that need a provider turn, GitHub or an interactive login run here. Label
  every result "fresh-base feature evidence, not proof on migrated state".

Fresh-base record work uses the same authorized fresh-base environment; record
checks run once rather than once per provider. The feature smoke still has
real runtime prerequisites and runs only in the authorized online tier. A
shared smoke result is not evidence for an omitted harness.

## Scorecard

Each row records exactly one status:

- `observed-pass`: the check ran and its assertion held.
- `observed-fail`: the check ran and its assertion did not hold. Keep the
  check as written; a product failure is a finding, not a reason to change the
  runbook.
- `skipped`: a named prerequisite was absent.
- `INCOMPLETE`: containment or a setup step failed before the check could run.
- `unexecuted`: nobody ran it.

An expected outcome in a runbook is an assertion, never a predicted pass. Keep
E2E results separate from source CI and static review.

For a conditional recovery row, name the exact missing behavior and its source
test reference. `skipped: no incident` alone is insufficient: a missing rate
limit is different from a missing typed ACP failure. A source test reference is
an explicit limit on E2E evidence, not an `observed-pass`. When a row reuses
another row's result, record its evidence ID and do not rerun that journey.

### One aggregate owner per behavior

The manual area is the owner unless this table assigns the journey to smoke.
Standalone areas use the same owner, including their selected smoke area when
needed. An extension below adds distinct evidence to the owner's result.

| Behavior | Owner | Other references do only this |
|---|---|---|
| Body replace/repeat/clear, other-field preservation | Work-routing CLI row | Smoke omits its duplicate body/owner lifecycle |
| Owner-link CRUD and current-owner notification | Work-routing owner/topology journey | Smoke omits its duplicate owner lifecycle |
| Identity status/apply and reversible identity edits | Provider CLI journey | Per-harness smoke keeps actual deployment/projection evidence |
| Cannot-proceed routing/replay and standing refusals | Decisions CLI journey | Smoke omits its duplicate cannot-proceed lifecycle |
| Topline mutations/history/replay | Telemetry CLI journey | Smoke keeps execution-map roster/filter assertions |
| Execution-map and physical breathing reads | Shared smoke telemetry pass | CLI adds one packaged read/shape check and the queue authorization outcome |
| Review/verification/artifact gate chain | Shared smoke, once if decisions or artifacts is selected | Both areas cite that one chain; no flagship duplicate |
| Tool-observed artifact provenance | Real carrier smoke per selected harness | Ordinary uncaptured content needs only a registered file |
| Replace queued dispatch, stop audit, correction runs | Work-routing combined journey | Decisions cites its stop evidence |
| Sentinel settings, checks, landing fact, disable | Work-routing one disposable-PR journey | Provider cites its lifecycle evidence |
| Fourth-round notice | Telemetry CLI journey | Guidance inspection alone is not notice evidence |
| Pi tool boundary (#47 and #106) | One provider Pi journey | One onboarding per selected provider; no second #47 run |

## Feature smoke

`scripts/feature_smoke.exs` drives most area checks over HTTP. It runs from a
source checkout of the same commit as the package, against a gateway already
started on a fresh online base, never on Gibson:

```sh
env -u TIGHTBEAM_URL -u TIGHTBEAM_TOKEN -u TIGHTBEAM_HOME -u RELEASE_NODE -u RELEASE_COOKIE \
  TIGHTBEAM_BASE_DIR="${AREA_BASE:?}" \
  TIGHTBEAM_SMOKE_OWNED_BASE="${AREA_BASE:?}" \
  TIGHTBEAM_SMOKE_AREAS=work \
  mix run --no-start scripts/feature_smoke.exs
```

The script refuses unless `TIGHTBEAM_SMOKE_OWNED_BASE` names the same base.
Per-leg model and effort variables, the verification statutes and a coder
archetype are listed in [SMOKE.md](../../SMOKE.md). `TIGHTBEAM_SMOKE_AREAS`
takes `provider`, `work`, `decisions`, `telemetry`, `artifacts` or `all`.

The feature smoke prefixes fixture labels with the Unix-second value captured
at process start and adds unique integers within that run. It does not sweep
work items from a previous process or clean one provider leg for another. Each
check revokes only the specific assignments it creates. If an invocation
stops part-way through, discard that base and start a new empty one; a later
process cannot safely identify the interrupted run's leftover rows.

## Aggregate run

1. Verify [containment](#containment) and record each condition's result.
2. Run [migration.md](migration.md) once. It ends with a preserved `state.db`,
   the gateway-written `build-owner.json` and a manifest. If migration fails,
   stop: no area runs on an unapproved result.
3. Make one area copy as [migration.md](migration.md#reuse-the-result)
   describes. Run the gateway D1 historical reads and telemetry historical
   breathing sample; the artifact unreachable-original-host control remains
   conditional on copied-token/actor authority. Stop its gateway and discard
   only this disposable copy. Keep the preserved migration output.
4. Run the fresh-base gateway checks, then each manual area's fresh-base
   journeys once. Retain their result IDs; use the ownership table above.
5. In the separately authorized online environment, run the feature smoke
   with `TIGHTBEAM_SMOKE_AREAS=all` once, recording its shared results and real
   harness results separately. Run the distinct manual online extensions
   once. Reuse accounts and evidence, not a second full lifecycle for a row
   already owned by smoke. Never reconnect a copied-data base to the network.
6. Complete the scorecard: package and source identity, host, harness, model
   and effort per leg, commands, the status of every row and every missing
   prerequisite.

A standalone rerun checks the applicable containment and package inputs, then
runs only the selected area's owner journeys on their stated fixture class.
Historical checks use a new copy of the preserved output; new-record checks use
a fresh base. Neither requires a second migration.

## Coverage of merged 0.1.9 work

This matrix follows the merged-work ledger
(`shared/evidence/e2e-019/landed-on-019.md`): 48 work items and 60 unique merged
pull requests, including the 10 pull requests with no work item, plus PR #183, which
merged after the ledger. Each entry names the row that checks it or the reason
there is none. TEST means the focused source suite is the proportionate owner
of that case; CI means the change is to CI or test infrastructure; GUIDANCE means it
changed shipped guidance, checked by the
[guidance presence](provider-runtime.md#guidance-presence) row.

The ledger lists merged pull requests with work-item trailers, but the 0.1.8
to 0.1.9 range holds many more commits. The area runbooks therefore also carry
one row for each user-callable 0.1.9 verb or flag found outside the ledger, such
as the typed [`cannot-proceed`](decisions-assignments.md#cannot-proceed) attest,
`identity current`, durable Toplines, dependency waits and artifact binding.
A 0.1.9 change with no user-callable surface outside the ledger has no row.

| Work item | PRs | Row or reason |
|---|---|---|
| `wi_0488b06a` | #149 | [Editable work-item body](work-routing.md#editable-work-item-body) |
| `wi_08c74b58` | #123 | [Sign-in recovery wake](provider-runtime.md#sign-in-recovery-wake), online, operator at keyboard |
| `wi_0f4ec953` | #168 | CI: workflow change only |
| `wi_14dd922d` | #108 | TEST: two test modules made synchronous; the fix landed in `8121b52d` |
| `wi_164c025c` | #64 | NOT SHIPPED on 0.1.9; no row checks it. The ledger maps it from #64, whose body says "Landing is serialized behind lane 1 (wi_164c025c)" and names wi_5501fe61 / asg_265faa86 as its work. #64 merged as `91da0304` onto 0.1.9: six cherry-picked Class A failed-turn commits (`8d899368..91da0304` on `35a6c0ca`), covered under `wi_5501fe61`. The completion-deliverable contract is main-only (#61, merge `910cbde0`, cut for 0.1.9 by `dr_7683fd67`). |
| `wi_1926c45c` | #142, #161 | [Harness change refused during a turn](provider-runtime.md#tune-turn-in-progress), online |
| `wi_1b74fd76` | #132, #136, #139 | TEST: test files only |
| `wi_2457fbf2` | #159 | [Sentinel lifecycle](provider-runtime.md#sentinel-lifecycle) lists landing-watch; [landing watcher](work-routing.md#landing-watcher), online |
| `wi_25e38cf9` | #133 | [Canonical session topology](work-routing.md#canonical-topology) |
| `wi_2aa19876` | #60 | GUIDANCE |
| `wi_2c216950` | #127 | TEST: one test timeout |
| `wi_379c3e06` | #115 | [Composed guidance/deployment inspection](provider-runtime.md#identity-and-composed-guidance) reads the generated Codex configuration; explicit-value permutations stay in `test/codex_guardian_default_test.exs`. |
| `wi_3b4a20ce` | #142 | [CLI transport diagnostics](gateway-surface.md#cli-transport-diagnostics); bounded upstream refusal/unreadable/decode fidelity remains in `cli/src/dispatch.rs`. |
| `wi_40820f7a` | #141 | [Worker queue summary](telemetry.md#worker-queue-summary) |
| `wi_46596ef4` | #35 | GUIDANCE |
| `wi_4e7e6130` | #108 | TEST: runtime fix to forced shutdown with a parked adapter; no safe trigger |
| `wi_502874f7` | #156, #176 | [Replace unread messages](work-routing.md#replace-unread-messages), online; [wake cancellation history](work-routing.md#wake-cancellation-history) |
| `wi_5501fe61` | #64 | [Incident evidence](decisions-assignments.md#incident-evidence): conditional rate-limit successor with preserved lineage; ordinary escalation is a different outcome. |
| `wi_57b42e04` | #136 | TEST: the ledger associates the settlement product question with #136; #135 implements its resolution under `wi_6eb31048`. No second feature or race E2E. |
| `wi_5b430658` | #177 | TEST: test and fixtures only |
| `wi_5ed0c7e1` | #167 | [Liveness superseded by progress](decisions-assignments.md#liveness-superseded-by-progress) |
| `wi_6454bc1d` | #131 | GUIDANCE |
| `wi_66725983` | #147 | [Replace, stop and resume](work-routing.md#queue-correction): authorization, actor/reason and real correction in the same session. |
| `wi_684f7f8f` | #120 | [Session connection](provider-runtime.md#session-connect) |
| `wi_6c9bf9fd` | #145 | [Fourth-review supervision notice](telemetry.md#fourth-review-notice); the other predicates and exact reevaluation/races remain source-tested. |
| `wi_6eb31048` | #135 | TEST: race; no safe trigger |
| `wi_725a1bc6` | #58 | [REST authentication and D1 reads](gateway-surface.md#rest-d1), extended by the [non-admin/redaction pair](gateway-surface.md#non-admin-authorization-and-redaction-u10). |
| `wi_73e7bc28` | #144 | [Completion handoff](decisions-assignments.md#completion-handoff) |
| `wi_74a9ad87` | #119, #126 | TEST: the configured model reaches adapter options only, and #119 needs a malformed catalog |
| `wi_762dede5` | #163 | GUIDANCE |
| `wi_78db9a18` | #129 | [Transcript index and query](migration.md#transcript-index) |
| `wi_7e25614b` | #121 | [Provider recovery evidence](provider-runtime.md#provider-recovery-evidence): conditional suppression, public refusal/standing remedy and recovery; absent incident halves stay named gaps. |
| `wi_7ff1a4ed` | #114 | [Sentinel lifecycle](provider-runtime.md#sentinel-lifecycle) |
| `wi_8e99311d` | #134 | GUIDANCE |
| `wi_97ff875e` | #93 | [Gateway shim verbs](gateway-surface.md#shim-verbs) and [stop isolation](gateway-surface.md#stop-isolation) |
| `wi_9a725587` | #170 | TEST: test fixture |
| `wi_a00bca2e` | #162 | [Harness control capability](provider-runtime.md#harness-capability) |
| `wi_a1ee0c7a` | #122 | [Canonical session topology](work-routing.md#canonical-topology) (reparent) and [guidance presence](provider-runtime.md#guidance-presence) (operating-manual skill) |
| `wi_a597deb3` | #138 | [Provider recovery evidence](provider-runtime.md#provider-recovery-evidence): an already-unreachable registered test host reports unavailable, not missing credentials; timing/fencing stays source-tested. |
| `wi_ac41993f` | #173 | TEST: test fixture |
| `wi_b9d31443` | #130 | TEST: runtime fix to lane recovery; no safe trigger |
| `wi_c00e925d` | #100 | GUIDANCE |
| `wi_c13b63c8` | #146 | [Direct delivery owner](work-routing.md#delivery-owner) |
| `wi_e92b90d7` | #164 | [Completion while blocked](decisions-assignments.md#completion-while-blocked) |
| `wi_eb1e49bd` | #165 | GUIDANCE |
| `wi_f2dba202` | #94 | CI: source gate |
| `wi_f9360112` | #153 | [Incident evidence](decisions-assignments.md#incident-evidence): conditional typed ACP recovery and one original-message redelivery. |
| `wi_fb0a697a` | #151, #157 | [Retirement cleanup](artifacts.md#retirement-cleanup) |

### Pull requests without a work item

| PR | Row or reason |
|---|---|
| #154 | TEST: no-attempt transport/unreadable/decode fidelity in `cli/src/dispatch.rs` (`no_attempt_unreadable_callers_preserve_ordinary_and_tune_shapes`, `no_attempt_version_decode_keeps_status_location_and_redacted_body`) and `cli/src/harnesses.rs` (`a_no_attempt_catalog_decode_failure_keeps_status_and_redacts_body`). The ordinary recorded-attempt CLI refusal is adjacent, not proof of this delta. |
| #112 | [Sentinel/PR lifecycle](work-routing.md#sentinel-and-pr): two eligible owners observe the same process-filed fact; owned-fact isolation remains in `test/condition_facts_test.exs`. |
| #106 | [Pi harness and local providers](provider-runtime.md#local-openai), online, optional |
| #48 | [Incident evidence](decisions-assignments.md#incident-evidence): one sanctioned repair, identical-key replay and preserved terminal history, conditional on a genuine failed runner. |
| #47 | [Pi harness and local providers](provider-runtime.md#local-openai), online, optional |
| #39 | [Composed guidance](provider-runtime.md#identity-and-composed-guidance) checks surviving agreed-phase/MVP and blocker scope; the deleted engineering-posture rail is not required. |
| #37 | CI: OTP patch-release gate |
| #33 | [Composed guidance](provider-runtime.md#identity-and-composed-guidance) checks surviving owned-clone/custody intent; the old clone-owned skill removed by `f608318e` is not required. |
| #31 | [Cursor leg](provider-runtime.md#cursor-leg), online, optional |
| #19 | TEST: a real 401 credential refresh has no safe trigger |
| #183 | [Build admission](migration.md#build-admission) and the [left-set refusal](migration.md#left-set-refusal) |

The artifacts area checks the truthful `content_not_captured` result. No
shipped capture fixture exists for positive content retrieval, so the runbooks
make no positive retrieval claim.

Do not wire these runbooks or the matrix into CI.
