# Model-resolution architecture audit

Status: revised after independent review `att_509f6e28` for
`wi_4e1d39f7-0425-4607-bebb-7f81b2f30eb9`.

## Ruling

The unification architecture already exists. Do not open a model-resolution rewrite.

The design has two ordered authorities with different jobs:

1. The per-host, per-harness `ModelCatalog` decides whether Tightbeam has enough
   inventory evidence to attempt a selection. It carries freshness and permits a
   populated stale inventory to degrade without lying.
2. The harness adapter is the intended authority for the runtime that was actually
   applied. Matching readback is enforced for resident model and effort changes, but
   it is not yet enforced at every creation, fallback, and harness-change seam.

The catalog and adapter are not competing resolvers. The shared architecture is
present, but five local contract gaps prevent a claim of complete conformance.

## Seam matrix

| Consumer | Existing shared path | Current applied-runtime truth |
| --- | --- | --- |
| Spawn and host placement | `spawn_model_selection` uses `resolve_selection`, `compose_model_selection`, then `ModelCatalog.route` for the selected host | Gap F1: `session/new` accepts readable non-matching model readback and accepts missing readback as the request |
| Default and archetype model | Defaults enter the same spawn selection and route path | Gap F1 applies on first engine creation |
| Turn fallback after lost engine context | Reuses the stored `%Model{}` and calls `session/load` or `session/new` | Gap F1: a different readable model can be accepted and stored |
| Live model change | `set_model` uses shared resolution, catalog validation, and the turn-boundary mutation path | Verified resident switch or fork readback |
| Live effort change | `set_reasoning` changes the effort field and uses the model-change apply path | Verified effort readback |
| Live harness change | Resolves and composes against the destination catalog, projects the destination, then restarts residency | Gap F2: the command reports success before a destination adapter exists to read back applied state |
| Session status and in-session picker catalog | Projects `ModelCatalog` through the same `wire_model` identity used for inbound resolution | Catalog choices are shared; Gap F3 hides catalog health, and F1 can leave the current stored runtime unverified |
| Clawline web in-session picker | Uses `sessionStatus.modelCatalog.models[].ref` | Tightbeam session-status payload |
| Clawline web harness control | Server publishes `setHarness` capability | Gap F5: the web client has no capability field, request action, or footer control for harness change |
| Clawline iOS in-session picker | Uses the same model rows and provider effort capabilities | Tightbeam session-status payload |
| Clawline iOS spawn picker | Receives `/api/org-options.models` | Gap F4: Tightbeam emits host-first data while iOS decodes harness-first data |
| Future `tightbeam tune` CLI | Calls the existing gateway `tune` verb | Must preserve these seams and must not add a second resolver |
| `/model` and similar slash text | Tightbeam sends ordinary user text | The harness, if it interprets the text |

## Evidence for the existing architecture

- `Tightbeam.Model` is the single internal field shape. Family, context, and effort
  stay separate. See `lib/tightbeam/model.ex:1-36` and `:107-168`.
- `ModelCatalog` is keyed by `{host, harness}`, carries
  `fresh | stale | unavailable`, and names `route` as the routability answer. See
  `lib/tightbeam/model_catalog.ex:1-29` and `:103-190`.
- Picker output comes from `ModelCatalog` through `wire_model`. See
  `lib/tightbeam/gateway.ex:1238-1269` and `:1271-1416`.
- Inbound selection resolves an issued row, completes omitted fields, and rejects a
  catalog miss. See `lib/tightbeam/gateway.ex:1433-1534`.
- Spawn and live tune both call that shared selection pipeline. See
  `lib/tightbeam/gateway.ex:3559-3685` and `:3730-3902`.
- Resident model and effort switching verifies adapter readback. See
  `lib/tightbeam/acp/adapter.ex:573-602` and `:724-798`.
- The real client journey selects a catalog ref, applies it, checks stored and reported
  state, then runs the next turn. It also states that `/model` is ordinary text. See
  `lib/tightbeam/client_e2e/journeys.ex:168-182` and `:1236-1379`.
- Clawline web consumes the session catalog at
  `src/features/chat/SessionStatusFooter.tsx:148-186` in Clawline commit
  `159097742b7c4faa81da9d75d2b6a39304ae8f51`.
- Clawline iOS consumes the in-session catalog at
  `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:8555-8611`
  and provider effort capabilities at `:8613-8640` in the same commit.

## Open local gaps

### F1 — New and load do not require matching readback

`Adapter.apply_initial_config` returns any readable model from
`session/current_mode` without comparing it with the request. If config is unreadable,
it returns the requested model as success. New/load cache that result, and Gateway can
accept the pointer without a second readback. See
`lib/tightbeam/acp/adapter.ex:605-667`, `:1116-1140`, and
`lib/tightbeam/gateway.ex:2110-2198`, `:2274-2296`.

The independent review reproduced a request for `gpt-new/high` that created and loaded
successfully while `Adapter.current_model/2` returned `haiku/high`. This is a local
conformance bug at the existing adapter boundary, not evidence for a new resolver.

### F2 — Harness tune succeeds before destination readback

`set_harness` validates through the destination catalog, projects the destination
selection, commits the residency barrier, and returns success before the destination
adapter starts. The next turn creates that adapter. See
`lib/tightbeam/gateway.ex:3730-3796`, `:3961-4057`, and
`test/gateway_test.exs:4617-4693`.

Deferred verification is current behavior. It must not be described as already-applied
runtime truth. The live-tune slice may either make deferred verification explicit or
change this seam under its own reviewed authority.

### F3 — Catalog health does not reach clients

`ModelCatalog` carries fresh, stale, and unavailable health, but Gateway discards the
health value and emits `modelCatalog.available: true` without health, stale, unavailable,
or reason fields. See `lib/tightbeam/model_catalog.ex:103-190`, `:577-597`, and
`lib/tightbeam/gateway.ex:1300`, `:1397-1409`.

Routing is freshness-aware internally. Client projection is not. This is a missing
status field at the existing catalog boundary.

### F4 — The iOS spawn picker decodes the wrong catalog shape

Tightbeam emits `/api/org-options.models` as host first:
`%{host => %{harness => [model]}}`. Clawline iOS decodes it as harness first and indexes
it by selected harness. See `lib/tightbeam/gateway.ex:1211-1268` and Clawline
`ios/Clawline/Clawline/Models/OrgOptions.swift:15-46`,
`ios/Clawline/Clawline/Views/Chat/StreamCreationSheet.swift:74-77` at commit
`159097742b7c4faa81da9d75d2b6a39304ae8f51`.

This is a local wire-contract mismatch in one consumer. It does not justify another
catalog or resolver.

### F5 — Clawline web omits live harness control

Tightbeam publishes `setHarness` in the session capability payload, but Clawline web
does not decode that capability, define the matching request action, or render a harness
control in the session footer. See `lib/tightbeam/gateway.ex:1381-1388` and Clawline
`src/features/chat/stream-api.ts:69-117`,
`src/features/chat/SessionStatusFooter.tsx:85-127` at commit
`159097742b7c4faa81da9d75d2b6a39304ae8f51`.

The model picker already consumes the shared session catalog. The missing harness action
is a local client integration gap, not evidence for another resolver or catalog.

## Test evidence and limitation

After removing the active session's `TIGHTBEAM_LOCAL_HOST_NAME=gibson` override so the
repository test config could supply `testhost`, the seven cited Gateway cases passed.
They prove the catalog and gateway seams they cover. They do not prove matching
new/load readback or destination harness application.

The independent F1 reproduction failed as expected against the current tree: the
adapter accepted non-matching applied model state. Full commands and results are in
review artifact `art_a0fc4221`.

## Product consequence

Keep the existing catalog, selection pipeline, and adapter boundary. Do not fund a
broad unification rewrite. Track F1-F5 as local conformance gaps with their own scope
and authority. Until they close, do not claim that every model-resolution consumer is
freshness-aware or that every successful spawn, fallback, or harness change has matching
live readback.
