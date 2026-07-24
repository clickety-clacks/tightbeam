# Network map — machines on the network

Org-authored. This is the NETWORK map — every machine an agent should know exists,
assimilated or not. `tightbeam list` shows only what is registered as a host; this doc
is how you know what else is out there and what each machine is for.

- **eezo** — primary development host. The gateway runs here; coding agents work in
  worktrees under ~/src. Assimilated.
- **racter** — Linux x86-64 worker on the tailnet (`ssh racter`). Candidate satellite;
  the tightbeam CLI must be built on-machine (cross-arch gap).
- **tars** — production runtime for other systems (openclaw/clawline provider). On the
  network, deliberately NOT for development sessions or assimilation.
- **shrdlu** — satellite session host (`ssh shrdlu`); runs sessions that talk back to
  the gateway on eezo.
