# Model-resolution architecture audit

Status: current-architecture finding for
`wi_4e1d39f7-0425-4607-bebb-7f81b2f30eb9`.

## Ruling

The unification architecture already exists. Do not open a model-resolution rewrite.

The current design has two ordered authorities with different jobs:

1. The per-host, per-harness `ModelCatalog` decides whether Tightbeam has enough
   inventory evidence to attempt a selection. It carries freshness and permits a
   populated stale inventory to degrade without lying.
2. The resident harness adapter applies the requested fields and reads them back. Only
   that readback permits Tightbeam to record or report an applied runtime.

These are not competing sources of truth. The catalog is preflight evidence. The live
harness is applied-runtime truth. The prior diagnosis correctly identified historical
drift risks, but it does not prove that the current tree still lacks a unified design.

## Existing seams

| Consumer | Existing path | Final authority |
| --- | --- | --- |
| Spawn and host placement | `spawn_model_selection` uses `resolve_selection`, `compose_model_selection`, then `ModelCatalog.route` for the selected host | `session/new` applies the stored `%Model{}`; adapter readback must match |
| Default and archetype model | Defaults enter the same spawn selection and route path; they do not bypass host validation | Adapter application on the first real engine session |
| Turn fallback after lost engine context | Reuses the session's stored `%Model{}` and calls the same verified `session/load` or `session/new` adapter path | Adapter apply/readback before the replacement pointer is accepted |
| Live model change | `set_model` uses `resolve_selection`, `compose_model_selection`, catalog validation, and the turn-boundary mutation path | Verified resident switch or fork readback |
| Live effort change | `set_reasoning` changes the effort field, then uses the same apply path as model change | Effort config readback |
| Live harness change | Resolves and composes against the destination catalog before the destination runtime starts | Destination adapter application; the live-tune slice is tightening commit and cleanup truth |
| Session status and picker catalog | `session_status` projects `ModelCatalog` through the same `wire_model` identity used for inbound resolution | Catalog for choices; stored verified runtime for the current selection |
| Clawline web picker | Uses `sessionStatus.modelCatalog.models[].ref` when the catalog is available | Tightbeam session-status payload |
| Clawline iOS picker | Uses the same `modelCatalog.models[].ref`; provider-supplied capability options win for effort | Tightbeam session-status payload |
| Future `tightbeam tune` CLI | Calls the existing gateway `tune` verb | Same gateway and adapter readback path |
| `/model` and similar slash text | Tightbeam sends it as ordinary user text; it is not a substrate model selector | The harness, if it interprets the text |

## Evidence

- `Tightbeam.Model` is the single internal field shape: family, context, and effort stay
  separate. See `lib/tightbeam/model.ex:1-36` and `:107-168`.
- `ModelCatalog` is keyed by `{host, harness}`, carries `fresh | stale | unavailable`,
  and names `route` as the one routability answer. See
  `lib/tightbeam/model_catalog.ex:1-29` and `:103-190`.
- Picker output comes directly from `ModelCatalog` through `wire_model`. See
  `lib/tightbeam/gateway.ex:1238-1269` and `:1271-1416`.
- Inbound selection resolves an issued row, completes omitted fields, and does not
  silently accept a miss. See `lib/tightbeam/gateway.ex:1433-1534`.
- Spawn and live tune both call that selection pipeline. See
  `lib/tightbeam/gateway.ex:3559-3685` and `:3730-3902`.
- Fallback carries the stored model into verified adapter load or creation before it
  appends the fallback pointer. See `lib/tightbeam/gateway.ex:2081-2203`.
- The adapter verifies model and effort config readback for new, loaded, in-place, and
  forked engine sessions. See `lib/tightbeam/acp/adapter.ex:573-602`, `:605-710`, and
  `:724-798`.
- Tests pin populated-stale routing, target-host validation, field completion, picker
  round-trip, effort options, and harness-change round-trip. See
  `test/gateway_test.exs:1714-1750`, `:2905-2940`, `:3505-3650`, `:3748-4065`, and
  `:4759-4805`.
- The real client journey selects a catalog ref, applies it, checks stored and reported
  state, then runs the next turn. It also states that `/model` is ordinary text. See
  `lib/tightbeam/client_e2e/journeys.ex:168-182` and `:1236-1379`.
- Clawline web consumes the catalog at
  `src/features/chat/SessionStatusFooter.tsx:148-186` in Clawline commit
  `159097742b7c4faa81da9d75d2b6a39304ae8f51`.
- Clawline iOS consumes the same rows at
  `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:8555-8611` and
  prefers provider capability options at `:8613-8640` in the same commit.
- A read-only live check on 2026-08-08 showed this session as Codex,
  `gpt-5.6-sol`, effort `high`, on `gibson`; the live Gibson Codex catalog exposed
  nine field-separated model rows with their effort lists.

## Local gaps, not architecture gaps

1. Claude keeps adapter-version alias candidates and selectable-model fallbacks. They
   are preflight or boundary aids. Current switching tries the canonical id first and
   accepts no alias without live readback. Keep them adapter-local and delete any path
   that treats them as proof of the applied model.
2. Clawline web and iOS retain legacy picker fallbacks when `modelCatalog` or provider
   capability options are absent. They do not run on the current Tightbeam payload.
   Treat them as compatibility cleanup, not a reason to add a second resolver.
3. The live-tune work must extend the existing pipeline. It must not introduce a new
   catalog, alias table, or selection service.

## Product consequence

Keep the existing architecture. Validate changes at its seams. Reclassify any remaining
picker or fallback failures as local conformance bugs with evidence. Do not fund a broad
unification rewrite under this work item.
