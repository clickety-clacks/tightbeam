# Captured v5 cold-start fixtures

These database sets came from the production release at source commit
`d00e06aea578d711e608637d38a97872487df15e`. They are not idealized schemas.
The release performed every boot, pair, auth, and local-user write named in
`manifest.json`. Each gateway stopped cleanly before the set was copied.

The stopped sets contain `state.db`. `state.db-wal` and `state.db-shm` are
recorded as absent. The manifest binds every present member by byte length and
SHA-256 and records the deterministic table census.

Run `scripts/capture_v5_cold_start.sh <current-clone> <output-dir>` to repeat
the capture on unused local ports. The script checks out the exact source
commit in a disposable clone, builds both release artifacts, and uses the real
HTTP/WebSocket gateway. It does not edit a database to produce these five
base fixtures.

`v5-missing-main-parent` starts from the stopped, captured `v5-healthy` set.
The versioned `scripts/derive_cold_start_fixtures_v1.sh` script creates this
impossible-by-real-flow broken-parent state. The manifest binds the source and
script digests, exact invocation, foreign-key setting, output hash, and census.
