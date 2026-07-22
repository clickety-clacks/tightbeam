---
name: tightbeam-assimilate
description: Onboard a machine as a tightbeam host — the complete assimilation ceremony (probe, credentials, archetype WHERE, restart, verify). Use when the operator asks to assimilate a machine.
---

Assimilation onboards a machine as a host. It is a CEREMONY you can run
end-to-end when the operator asks — no source-diving, no guessing; this
section is the complete procedure.

1. `tightbeam assimilate <ssh-dest> --as-user <operatorId>` (admin act —
   run it AS the operator who asked). <ssh-dest> is anything ssh resolves
   (tailnet names work). Preconditions the probe checks for you: key-based
   ssh access and node on the target. Useful flags: --name <hostname>
   (defaults from the destination), --harness claude,codex, --dry-run.
1b. Cross-architecture satellites. The ceremony installs the CLI by
   shipping its own running binary, gated on identical target triples: a
   satellite whose OS/CPU differs from the control node SKIPS the CLI
   step with a warning (wi_c729ca10 tracks the product fix; the warning's
   "build for <target> and re-run" hint does not work from the control
   node — re-running still ships the control node's binary). Build on the
   satellite instead: copy the repo's cli/ source over (rsync), run
   `cargo build --release` there (needs a Rust toolchain), install the
   result at `<base-dir>/bin/tightbeam`, then re-run assimilate — every
   other step is idempotent.
2. Credentials. Doctrine: every {org, host, harness} gets its OWN grant —
   the ceremony's ONBOARD step runs the harness's login on the satellite,
   which needs an interactive terminal. YOU do not have one: assimilate
   will print the per-harness login commands instead — relay them to the
   operator VERBATIM and say plainly that this step is theirs. A
   "credentials missing" result is not failure: the host registers anyway
   and degrades visibly (turns there fail with an auth marker) until the
   operator onboards it. Never work around this with --push-credentials
   unless the operator explicitly chooses it — pushed copies share a
   grant, and shared grants revoke each other on refresh.
3. Allow placement. A registered host is usable only where an archetype's
   WHERE admits it. Archetypes are TOML manifests at
   `$TIGHTBEAM_HOME/identity/archetypes/<name>.toml`. The built-in
   "default" archetype has NO file; writing `default.toml` overrides it —
   minimal contents to admit a new host alongside the gateway's own:

       name = "default"
       where = ["<gateway-host>", "<new-host>"]

   Editing `where` alone never touches guidance, so it costs no session
   its memory.
4. Restart to apply. Archetype manifests load at substrate BOOT: a
   manifest edit takes effect at the next gateway restart, not before.
   Say so in your report — "registered and allowed; takes effect on the
   next substrate restart" — and never sit waiting for it silently.
5. Verify. After the restart: the host appears in `tightbeam list`, and
   `spawn --host <name>` places a session there.
