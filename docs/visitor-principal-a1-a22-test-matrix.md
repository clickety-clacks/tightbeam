# Visitor principal A1–A22 automated-test matrix

Use this matrix to prevent a partial implementation from being reported as the
visitor-principal product. Treat every row as required before product
completion.

The authority is `visitor-principal-v3.md` at tightbeam-specs commit
`9fed0adef203904ef44e9252cd0c5b4b8f6c6a70`, content SHA-256
`03fe3dd000a920be82c17e1a4246ef9e0482edfd7b8cffda125a94ab4ec1c32c`.

| Acceptance case | Exact title | Automated status on Card 1 | Test location |
|---|---|---|---|
| A1 | Checked current-main attribution | Required; not implemented | — |
| A2 | External intermediary attribution | Required; not implemented | — |
| A3 | One-target capability matrix | Required; not implemented | — |
| A4 | Consent and lost-response retry | Required; not implemented | — |
| A5 | Atomic visitor post | Required; not implemented | — |
| A6 | Audit-before-read | Required; not implemented | — |
| A7 | Replay-only proof | Required; not implemented | — |
| A8 | Revocation/post race | Required; not implemented | — |
| A9 | Expiry and target retirement | Required; not implemented | — |
| A10 | Unknown-bearer bound | Required; not implemented | — |
| A11 | Quota and duplicate operation | Required; not implemented | — |
| A12 | No agent anatomy | Required; not implemented | — |
| A13 | Origin round trip | Required; not implemented | — |
| A14 | Compatibility and feature gate | Required; not implemented | — |
| A15 | Broker authority and pending limit | Required; not implemented | — |
| A16 | Known-denial audit and public absence | Required; not implemented | — |
| A17 | Wire, discovery, and secret input | Required; not implemented | — |
| A18 | Keyring restart, backup, and missing-key refusal | Automated for Card 1 keyring initialization, pre-migration loading across the current lawful schema predecessor chain, post-migration locking, typed database-key references, restart, pair restore, deterministic retry/authentication, missing-half refusal, filesystem safety, and secret non-disclosure. Visitor routes remain absent until later cards. | `cli/src/visitor.rs`, `cli/tests/visitor_keyring.rs`, `test/visitor_keyring_test.exs` |
| A19 | Scoped operation collisions | Required; not implemented | — |
| A20 | Terminal transition closure | Required; not implemented | — |
| A21 | Realized intermediary collision cannot recur | Required; not implemented | — |
| A22 | Known-scope admission and audit-growth bound | Required; not implemented | — |

Card 1 does not add visitor tables, migration stamps, routes, admission,
origin, domain, or audit behavior. Do not change a non-A18 row to automated
until a test executes that exact acceptance case. Do not report product
completion until every row is automated and green.
