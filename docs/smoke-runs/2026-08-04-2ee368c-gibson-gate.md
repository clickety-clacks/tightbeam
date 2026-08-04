# e2e run — 2026-08-04 @ 2ee368c (the Gibson gate)

Operator: Claude (overnight, unattended) · Trigger: Flynn — "do whatever else is needed
to get to gibson. i'm going to bed so you have all night to fix whatever."

## Verdicts

| tier | verdict | note |
|---|---|---|
| T1 suites, eezo | PASS | mix 1319 + 9 doctests, cargo 214, zero failures |
| T1 suites, shrdlu (GATING) | PASS | mix 1317 + 9 doctests, cargo 214, zero failures, at 8556caa |
| T4 soak, 60 min | **PASS** | A1–A5 all green. 29 kills, 29 recovered, 250 loads, 0 load errors, 0 unexpected exits |
| Release runtime (npm) | PASS | installed from the tarball, booted READY, and **ran a real turn** |
| Code review | 4 rounds, cleared | 9 blocking findings across the npm/boot work, all confirmed and fixed |
| G7 adapter deaths | MERGED | soak oracle A3 was failing before it and passes after |

**Run verdict: PASS.** Nothing on Flynn's gate — "anything that affects the core
loop/operations of tightbeam in such a way that it makes it fail" — is outstanding.

## The soak's FAIL last night was the instrument, not the substrate

Last night's run verdicted FAIL and blamed the product. It was the arena, and the
evidence was already in its own two logs:

    23:19:27.330  gateway logs "SIGTERM received - shutting down"
    23:20:27      await_gateway_exit gives up after 60s; the `with` in
                  kill_and_restart_gateway falls to `else`, so start_gateway is
                  NEVER CALLED — the signal landed, the restart did not
    23:20:27      the recovery probe asks /version and the still-shutting-down
                  gateway answers in 12ms, so the row scores recovered=true
    23:20:58.6    the process finishes exiting, 91s after the signal
    → 00:15       the remaining 27 of 29 kills, and 53 of the 60 minutes, run
                  against a closed socket, every one scored against the product

Two defects, both the house class, both in the instrument. The recovery oracle could not
tell "my replacement is up" from "the process I just signalled has not finished dying",
because a dying gateway serves correctly right until it stops. And the arena RECORDED
`unexpected_exit` and carried on.

This also retro-explains the queued-turn mystery I produced three wrong theories about
before compaction: at the eleven-minute mark I was reading a gateway that had been dead
for four minutes. **A harness needs a liveness precondition on the thing it measures,
checked every cycle.** An instrument that cannot detect its subject is missing does not
report nothing; it reports zero.

Fixed in `66f6e9a` (port-identity recovery gate, `ensure_gateway/1` per tick) and
`3f5dedc` (a spontaneous death is now SCORED, not silently repaired — restoring the
arena and judging the product are separate jobs). Verified by injecting the exact
condition: before, `recovered=true recovery="version_ok poll=11ms"`; after,
`recovered=false … "version answered by the gateway that was signalled"`, followed by
`arena gateway restarted` and a run that continued.

## The 91-second shutdown did not reproduce

Recorded because the number is alarming and the follow-up is what matters.

| condition | SIGTERM → exit |
|---|---|
| last night, 3 sessions under load | ~91s |
| tonight, same tree, same load, 7 gateway SIGTERMs | 5.1s – 7.2s |
| idle gateway, measured directly | 1.09s |
| pre-merge soak, comparable load | 3.9s |

So it is an outlier, not a systematic regression, and it was only ever fatal because the
arena abandoned its restart. Left as a watch item: if a future run exceeds ~15s, capture
which supervision child blocks BEFORE theorising. The arithmetic that 91s ≈ 18 children ×
5s default shutdown is a hypothesis, and this codebase was wrong three times in one night
by preferring an inferred mechanism to a measurement.

## Review found nine blocking defects, and the best ones were about tests

Four rounds, distinct codex gpt-5.6-sol at high reasoning, on the npm packaging and boot
refusal work. Every finding was confirmed against the code before acting.

**The boot guard was theatre.** `start/2` wrapped `start_tree/1` in a try/rescue naming
two refusals it promised to catch quietly, and NEITHER ARM COULD EVER RUN — the identity
refusal raises inside `preflight/1`, called before the try; `Schema.ShapeError` is raised
inside `Boot.start_link/1`, a supervised child, so `Supervisor.start_link/2` RETURNS an
error tuple rather than raising. Both states still produced the crash dump the code
asserted in a comment that it prevented. Three independent confirmations: this repo's own
boot log, the module structure, and a test in `application_test.exs` that has always
asserted the identity path RAISES — which it could not have done had the rescue worked.

Deleted rather than resurrected: since neither arm ever fired, making them work would be
a behaviour change with nothing requiring it, and neither state arises on a fresh install.

**The test that could not fail.** The old refusal test asserted

    Application.get_env(:tightbeam, :refusal_exit, :halt) == :halt

which is the fallback the assertion itself supplies — it exercised Elixir's standard
library and stayed green against a `refuse/1` returning `:ok`. Replaced by a subprocess
boot with a harness-free PATH. Getting THAT honest took three corrections, each caught by
running it:

- a PATH of "the toolchain's own bindir" handed the harness straight back — `codex` is
  installed into /opt/homebrew/bin next to `elixir`, so the boot SUCCEEDED. The test now
  links only what `mix run` needs into a directory of its own and asserts both harnesses
  are absent from the PATH it built.
- `output =~ "no registered harness CLI"` passed against the broken form, because Logger
  prints the same words behind a timestamp. It now requires a line BEGINNING with the
  sentence, which only `IO.puts(:stderr, ...)` can produce.
- "no erl_crash.dump exists" failed on a stale dump this repo has carried since
  2026-07-28, and would equally have passed for the wrong reason where none existed.

Verified red against both broken forms, then green. The Logger-only form produced exactly
the zero-byte output that regression is named for.

**Removing the seam broke a test I had not read.** Round 2's single finding: deleting
`:refusal_exit` left `application_test.exs` calling `Application.start/2` in-process on a
path that now genuinely halts — it would have taken the whole ExUnit VM down. My targeted
run after the change covered two files and missed that one. The full suite would have
caught it; the review got there first.

## G7 merged with one reviewed gap left open on purpose

`await_adapter_exit/3` returned a bare boolean, collapsing "closed as asked" and "killed
while we asked". Fixed, and the soak's A3 oracle — "a fast-recovered adapter death IS
recorded" — went from failing to passing.

Review then found the same collapse surviving on the timeout path, and I got the fix
wrong in an instructive way. `HarnessProcess.park/2` is documented "Deliver SIGKILL to a
parked process group": after grace expiry the coordinator kills the harness ITSELF, so my
"record any late non-normal exit" would have filed the coordinator's own planned kill as
a fault — inventing exactly the kind of false record the lane exists to make trustworthy.
It also did not close the window, the receive and the flush not being atomic. Reverted.

I had also claimed no deterministic test was possible. That was wrong, and the reviewer
named the mechanism: `park/2` invokes the configurable process helper and performs
several writes, which is a real barrier a test can block on. Both the gap and that recipe
are in ROADMAP.

## The npm release, proven by using it

Flynn's ruling stands: no special docs or tools for Gibson — install per the README like
any other user. So the README now documents the release-package path beside the source
build, with prerequisites split between them (the package drops Elixir, Rust, Hex/rebar
and the C toolchain; it still needs node, git and a harness CLI).

Proven end to end on this box, from the built tarball only:

    npm install -g ./tightbeam-0.1.0-darwin-aarch64.tgz
    tightbeam --version                → 0.1.0
    tightbeam-gateway                  → seeds identity, creates state.db,
                                         "READY: claude on eezo can run turns"
    tightbeam spawn / wake             → assistant reply: "RELEASE RUNTIME OK"

That last line is the one that mattered: a real turn, through the bundled ERTS, with no
Elixir toolchain anywhere in it. Everything before tonight showed the package *booted*.

Two packaging defects fixed on the way: `assemble.sh` mapped every non-aarch64 machine to
npm's `x64` and built anyway, so a linux-arm64 box produced a package labelled x64 that
npm would install and could not run — it now refuses unsupported platforms by name. And
mix.exs advertised `npm install <git-url>`, which cannot work: there is deliberately no
root manifest, and no checkout can supply a compiled runtime.

## Found while proving it: two gateways cannot share a host

The release takes a fixed Erlang node name, so a second instance dies with

    Protocol 'inet_tcp': the name tightbeam_gateway@eezo seems to be in use by
    another Erlang node

which names neither Tightbeam, nor the port, nor the base dir, nor the other instance. I
hit it because my own earlier probe was still running. Not a Gibson blocker — Gibson runs
one — but it is a T-CONSPICUOUS defect on precisely the path a second tenant hits, which
is the TARS shape. In ROADMAP.

## Rails

Every signal sent to an exact PID whose command line was verified to contain this
session's own scratchpad path first, and death confirmed after. No `pkill`, no pattern
kills, no `sudo`, no service-manager operations. Credential copies were confined to
disposable arenas and taken while the grant had five hours of validity left, so no
refresh — and therefore no rotation — could occur ([[two writers of one credential]]).
The stale `erl_crash.dump` from 2026-07-28 in the repo root was left alone: not mine, and
not this run's.
