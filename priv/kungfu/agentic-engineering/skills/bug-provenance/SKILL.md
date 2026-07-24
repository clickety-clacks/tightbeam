# Bug provenance

A causal investigation behind one bug, ending in a classified verdict and a routed fix
plan. This is not recon's mapping ("what is here") — it is the autopsy ("why is this so").
You diagnose; you never operate: **this skill forbids editing implementation files.** A
diagnosis loses its independence the moment the diagnostician starts fixing.

1. Classify the bug into exactly one cause class, and route it:

   | Class | Meaning | Route |
   |---|---|---|
   | `code-violates-spec` | spec right, code wrong | fix plan for the code; dispatch implementation |
   | `spec-hole` | the behavior is undefined | file the hole for a spec ruling FIRST; the fix is blocked until the owning spec gains the ratified sentence |
   | `stale-spec` | spec contradicts ratified intent | spec amendment first, then code — never obey a stale spec into destroying working behavior |
   | `spec-conflict` | two specs disagree at a seam | adjudication first; no code until authority is ruled |
   | `wrong-proof` | code right, spec right, the test asserts an old implementation's accident as intent | fix the oracle AND audit what it masked while wrong |
   | `composition` | every part conforms, the seam between them doesn't | name the seam's owner (often nobody — that is the finding), spec the seam, then fix |
   | `environment-drift` | the repo didn't change; the world under it did | re-probe against the current world, pin the dependency, record the drift |

2. Consult the attempt ledger — mandatory. Engram for the code's originating
   conversations, git history of the implicated files, and the work-item's assignment
   history. Enumerate prior fix attempts by name: what level each operated at, how each
   failed.
3. Re-classify before re-fix. A series of failed fixes is itself evidence — usually of
   mis-classification. Each failed attempt at level N raises the odds the cause lives at a
   different level. Your plan must state why its classification differs from (or survives)
   every failed attempt; a novel patch at the same level does not satisfy this.
4. Deliver a verdict, never a patch: classification + causal narrative with citations
   (file:line, engram session, spec clause) + the routed plan + the attempt ledger.
   Attest it on the bug's work-item assignment:
   `tightbeam attest <assignmentId> --kind verdict --verdict diagnosed --note "<class>: <cause + citations + routed plan>"`.
5. Wake the requester with the verdict and end the session, per `recon-lifecycle`.
