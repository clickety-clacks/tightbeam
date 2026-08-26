# Soak and kill-matrix driver

`scripts/soak.exs` runs a dedicated Tightbeam gateway under sustained Claude
Haiku load, kills gateway and adapter processes in a repeating matrix, and
audits the arena database. It proves recovery keeps working over time rather
than proving only that one hand-run recovery once worked.

The final scorecard checks every required invariant:

- **A1 — terminal turns:** no `queued` or `running` turn is older than the
  180-second stall threshold.
- **A2 — message integrity:** every turn has exactly one user echo, every
  delivered turn has exactly one assistant reply, reply counts agree, and no
  `wakeId` produced duplicate turns.
- **A3 — visible failures:** failed turns contain an error reason and adapter
  deaths have lifecycle rows.
- **A4 — wake conservation:** every wake accepted from the driver is either
  fired with a turn, still pending, or represented by `wake_unresolved`.
- **A5 — gateway recovery:** every kill action succeeds and `/version` answers
  again within 60 seconds.

Run the two-minute acceptance smoke from the repository root:

```sh
mix run scripts/soak.exs -- --minutes 2 --self-check
```

Self-check forces one session, five-second load intervals, and one execution
of each kill type. The ordinary one-hour run uses the driver defaults:

```sh
mix run scripts/soak.exs -- --minutes 60
```

For a 24-hour soak:

```sh
mix run scripts/soak.exs -- --minutes 1440
```

The default arena is `~/.tightbeam-soak`; use `--base-dir` and `--port` for a
different dedicated arena. The driver refuses an existing directory unless
it contains its `.soak-arena` marker, then recreates that marked arena for a
fresh run. It seeds the arena from the exact Claude harness home under
`~/.tightbeam-beam/homes/`; it never reads a legacy shared-auth directory.

Results remain in the arena: `state.db` is the audited ledger,
`soak-events.log` records load, kill, recovery, and audit events,
`gateway.log` contains gateway output, and adapter stderr logs sit beside
them. Any A1–A5 `FAIL` blocks deployment of whatever change the soak was
testing. The arena is disposable after results have been collected:

```sh
rm -rf ~/.tightbeam-soak
```
