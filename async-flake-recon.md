# Async flake recon: AdapterCoordinator and ModelCatalog

Date: 2026-08-09 UTC  
Assignment: `asg_403090a6-7466-49f8-ba9a-f033dd9b5117`  
Work item: `wi_8afb502f-e02d-4109-a19b-797c3406df66`  
Repository state: `4b34b4d0eb06a697f7d32a3b87d0b8110b956aba`; no source edits

## Decision and verdict

Decision question: should the owner dispatch one shared de-flake change for both families, or separate changes?

**Verdict: not-proven.** The available evidence cannot decide whether every contributing
cause is separate because Family A's failed assertion and macOS event trace are missing.
Do not dispatch one shared change: a single shared product regression is falsified, but a
shared environmental scheduling contributor remains possible and unmeasured.

Confidence is **high** that Family B is a test synchronization defect and is not global-state leakage. Family A's cause is **not proven**. The surviving hypotheses are test synchronization under process-spawn pressure, a product transition defect that the isolated run did not reach, and an unobserved assertion-specific failure. The missing evidence is the exact failed assertion and event timing from macOS job `93124140983`, followed by an independent reproduction under the failed job's conditions.

Observed code shows a broad similarity: each test observes asynchronous work without an owned event barrier. That similarity does not prove a common cause. Family A waits for five real process failures under host load. Family B misattributes work that its own setup launched before the action under test. A shared implementation change would join unrelated modules without evidence.

## Observed facts

### Family A: AdapterCoordinator

- The test launches a real `false` executable through the ACP adapter five times, then polls coordinator health until the circuit opens. See `test/adapter_coordinator_test.exs:29-65` at repository commit `4b34b4d0eb06a697f7d32a3b87d0b8110b956aba`.
- Its helper sleeps 10 ms per attempt. The passed value `1_500` therefore permits about 15 seconds, despite surrounding prose that discusses millisecond measurements. See `test/adapter_coordinator_test.exs:233-244` at that commit.
- The test itself records a bimodal macOS history and attributes the slow mode to fork/exec contention with sibling suites. See `test/adapter_coordinator_test.exs:49-55` at that commit.
- The coordinator is the single owner of the failure count. Each accepted `:DOWN` increments the count, computes the circuit state, and stores both in one GenServer callback. See `lib/tightbeam/adapter_coordinator.ex:516-595` at that commit.
- Durable CI evidence `att_6078f458-6827-45f6-9e44-e617bdc25738` records one macOS failure at release commit `d238aed`, a clean same-run rerun, and a green predecessor. Commit `d238aed` changed only `cli/Cargo.toml` and `cli/Cargo.lock`, so it did not introduce this behavior.
- The test file is byte-unchanged from `d238aed` through current main. The only relevant coordinator change replaces harness-process reconciliation with `settle_proven_dead`; the failure increment and circuit calculation remain unchanged.
- Current-main isolated stress passed 100 consecutive repetitions: `mise exec -- mix test test/adapter_coordinator_test.exs:29 --seed 0 --repeat-until-failure 100 --max-failures 1`. This does not falsify a macOS full-suite timing failure. It does weigh against an always-present state-machine defect. The run is filed in `att_bf7dc71d-9356-4dea-988f-3df02da19ed1`.

Classification: **not proven**. Test synchronization influenced by macOS/process-spawn timing is the leading hypothesis, not a finding. A product race is also not proven. Exact regression provenance is **not proven** because `gh run view ... --log` requires a missing credential in this session; that limitation is filed in `att_43f15f31-7709-437e-88c2-e306096a99e9`.

### Family B: ModelCatalog

Both historical failures reproduced from unchanged current source under the repository-pinned Elixir 1.19.5 / OTP 28 toolchain and the gate's environment hygiene:

- Line 1457 reproduced the historical unexpected `{:codex_probed, ...}` at repetition 11.
- Line 1666 reproduced the historical unexpected `{:claude_probed, ...}` at repetition 7.
- Forty fresh-VM runs of each target passed. The failures do not require another test's process or filesystem state; same-VM repetition merely made the scheduler window easier to hit.
- Raw historical failures are preserved by artifacts `art_f4dc2517` and `art_646ec135`; producer reproduction details are filed in `att_bf7dc71d-9356-4dea-988f-3df02da19ed1`. Their unexpected-message signatures match.

The producer runs used the repository-pinned `mise` toolchain. The independent reviewer could not execute a pinned rerun because `mise` was unavailable on that host (`att_9be91c20-4458-472f-b324-81b1af989451`). No unpinned `mix` command was substituted. Independent runtime confirmation is therefore unavailable; the reproduced signatures are producer evidence, while the source-ordering proof is independently readable.

The event order is deterministic at the code level:

1. Each test waits by calling `ModelCatalog.get/3`. See `test/model_catalog_test.exs:1492-1497,1694-1699` at repository commit `4b34b4d0eb06a697f7d32a3b87d0b8110b956aba`.
2. `get/3` calls `refresh_due/1` before it replies. See `lib/tightbeam/model_catalog.ex:327-329` at that commit.
3. `refresh_due/1` considers every harness, not only the harness read by the test. See `lib/tightbeam/model_catalog.ex:400-408` at that commit.
4. A `needs_onboarding` result is always eligible for another refresh. See `lib/tightbeam/model_catalog.ex:584-590` at that commit.
5. The final setup read therefore launches new background tasks before returning the expected unavailable answer. See `lib/tightbeam/model_catalog.ex:420-437` at that commit.
6. The test flips `present?` to true. Those already-launched tasks can now pass the credential gate and emit probe messages.
7. The line-1457 test wrongly attributes those messages to the later anthropic cast. Its positive Claude assertion can also observe pre-cast work, while its Codex negative assertion catches the same pre-cast work. See `test/model_catalog_test.exs:1501-1509` at that commit.
8. The line-1666 test wrongly attributes the pending Claude work to recognition of a nonexistent fact. The production actually returns `:ok` without a cast for `:no_match`. See `lib/tightbeam/productions/catalog_rederive.ex:46-50` and `test/model_catalog_test.exs:1703-1713` at that commit.

Global leakage is falsified as the root cause. The test module already uses `async: false`; each callback sends to the current test PID; and each setup creates a unique database name and base directory. See `test/model_catalog_test.exs:1-25` at that commit. An old task cannot send a probe message to a later test PID.

Classification: **proven test synchronization and event-attribution defect**. It is not a product provider-scope defect, a global-state leak, or a macOS-only condition.

## Competing hypotheses and disconfirmation

| Hypothesis | Result | Discriminating evidence |
|---|---|---|
| One product regression caused both families | Falsified | Family B's exact messages come from work launched by its own setup read; `d238aed` changed only CLI dependency files. |
| One environmental scheduling contributor affects both | Not proven | Same-VM repetition exposes Family B; the only durable Family A failure was macOS. No matched cross-family trace exists. |
| Family A product circuit race | Not proven; evidence weighs against | One GenServer owns the transition; 100 targeted repetitions passed; same CI run reran clean. Raw failed assertion is missing. |
| Family A host/process timing | Survives | The test performs real process launches; its own comment records macOS fork/exec contention; failure occurred only on macOS and reran clean. |
| Family B provider-scope product bug | Falsified | The cast filters harnesses by provider at `lib/tightbeam/model_catalog.ex:345-352`; the unexpected tasks were launched earlier by `get/3`. |
| Family B global leakage | Falsified | Unique resources, current test PID ownership, `async: false`, and exact source ordering. |
| Family B test synchronization defect | Proven | Both signatures reproduced; source guarantees the pre-action task can exist. |

## Smallest deterministic de-flake designs

### Family A

Keep the circuit-threshold assertion, but remove external process scheduling from the threshold proof.

1. Use a controlled in-VM adapter attempt that announces each boot attempt and waits for the test to release it into a failure.
2. Give the coordinator a narrow failure-observer seam, or factor the failure transition into a pure function plus one observer-backed integration test.
3. Drive exactly five failure events. Assert the emitted fifth transition is `%{consecutive_failures: 5, circuit: :open}`.
4. Keep one separate integration test that proves a real ACP boot failure reaches the transition. Do not make five real executable launches the threshold proof.

This design owns the event that advances each step. It does not add sleeps, widen a timeout, retry a failed assertion, or weaken the circuit invariant.

### Family B

Use a settled, already-onboarded initial catalog for the scope and fact-gating assertions. Other tests already cover absent-to-present recovery.

1. Start with `credential_status` returning `:onboarded` and wait until Claude and Codex are fresh. This leaves no eligible setup refresh.
2. Record per-harness attempt generations or counters.
3. For provider scope, gate the forced Claude fetch. Send the anthropic cast, use a GenServer mailbox barrier, assert Claude's generation increments, and assert Codex's generation does not.
4. For fact gating, record the Claude generation, recognize a nonexistent fact, and assert the generation is unchanged. Then file the fact, recognize it, and assert one new gated Claude attempt.
5. Replace both `refute_receive ... 300` checks with generation/state assertions after the owning process barrier.

This test-only rewrite preserves the product behavior and assertions. It separates pull-backstop coverage, provider-scope coverage, and fact-recognition coverage so one test cannot attribute another mechanism's work to its subject.

## Test plan and deletion assessment

After implementation, each replacement must be proved independently before it can replace
the existing test:

1. Run each rewritten target 100 times in one VM and 40 times in fresh VMs with the gate's stripped `TIGHTBEAM_*`, `RELEASE_*`, `ROOTDIR`, and `BINDIR` environment.
2. Run the complete AdapterCoordinator and ModelCatalog test files together with randomized seeds.
3. Run the full Linux and macOS suites without rerun-as-success policy.
4. Perform fail-before mutations: make the circuit open at four or six; include Codex in the anthropic scope; and make `:no_match` cast. Each corresponding test must fail.
5. For Family A, retain the old test until the controlled candidate passes the same macOS full-suite lane and its threshold mutations fail. Capture the coordinator's attempt/failure/open ordering in that lane. This is the required independent reproduction of the replacement design; it has not yet occurred.

Delete no tests, assertions, or product features. Family A covers the required repeated-failure circuit behavior documented at `docs/ASSIMILATION-E2E.md:196`. Family B covers two separate invariants: provider-scoped refresh and fact-driven recognition. Rewrite their orchestration and keep their teeth.

## Current-main applicability

- Prerequisite `a05b944` is an ancestor of current main.
- Family B's test and implementation files are unchanged from `0e9ee37` through current main. Both failures reproduced on current main.
- Family A's test file is unchanged from `d238aed` through current main. Its failure-count and circuit-open transition remains intact. The flake did not reproduce locally, but the nondeterministic external-process design remains.

The owner can dispatch the Family B test-only change now. Keep Family A in recon or dispatch
only a test-harness candidate whose acceptance requires the independent macOS and mutation
proof above. No evidence supports a product behavior change.
