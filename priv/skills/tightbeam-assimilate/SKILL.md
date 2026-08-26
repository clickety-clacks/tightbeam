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
   ssh access, node, npm and rsync on the target, and the CLI of every
   harness being enabled (`claude`, `codex`) — those are the operator's to
   install, never assimilation's, and the probe sees only what a
   non-interactive ssh session sees. Useful flags: --name <hostname>
   (defaults from the destination), --harness claude,codex, --dry-run
   (runs the probe for real and writes nothing, so it can and does fail).
1b. Cross-architecture satellites. The ceremony selects the immutable
   release archive for the satellite's observed OS and CPU. It verifies
   the archive against the release's `SHA256SUMS` before it ships the CLI.
   This fixes wi_984a7d2f-3c87-47b8-945c-222cfcad8dac. The release ships
   CLIs for macOS arm64 and Linux x86_64. For another target, let the
   ceremony register the host without a CLI, then use this source fallback:
   copy the repo's `cli/` and `priv/` directories to one repo root on the
   satellite, run `cargo build --release --manifest-path cli/Cargo.toml`
   there, and install `cli/target/release/tightbeam` at
   `<base-dir>/bin/tightbeam`. Do not re-run assimilate. The CLI embeds
   `priv/harness_registry.json` at build time, so a copied `cli/` directory
   without its sibling `priv/` directory cannot compile.
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
