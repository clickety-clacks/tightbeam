# conformance-smoke handoffs

Only the independent verifier's ten legitimate external/spec blockers remain. Every
lane-closeable residual was removed from this handoff and is covered by the executable
corpus runner.

| Clause(s) | Exact blocker | Required cross-lane/spec change |
|---|---|---|
| #4 | Copying the corpus and invoking the same ExUnit loader is not a second self-tuning consumer. | The self-tuning/generated-rail owner must load `identity/conformance/` through its real validator and run the unchanged corpus. |
| #7, #147, #155 | The governing spec makes forbidden-substitution intent advisory and names containment only as partial coverage. | Define an enforceable observable if this advisory intent is to become a mechanical acceptance check. |
| #21 | §1.2 says every fixture in a green class is green, while A1 requires green C2/C3 classes containing three `pending-unhomed` fixtures. | Reconcile the governing spec's class-green rule with A1/taxonomy. |
| #39 | The locked `world.adjudicate = {session, hold}` shape conflicts with the actual owner API, which requires an episode/action request. | Reconcile the world shape with the authorized owner verb; direct SQL remains forbidden. |
| #43, #116 | The exact public `rail_step/4`/`window_start` seam named by the spec is not exposed; the available public consumer is `Supervision.evaluate/5`. | Expose the pinned rail-step/window input contract. The public consumer's nil/no-write and duplicate end states are covered here. |
| #60 | Canonical fresh-identity bootstrap is owned by identity/archetype code and canonical material outside this lane. | The identity owner must supply the fresh-bootstrap artifact proof. |
| #133 | A sandbox profile-application refusal cannot be deterministically caused by fixture script content. | Expose Q3's deterministic profile-apply-failure hook; `contained-refused` remains case-level `pending-runtime`. |
