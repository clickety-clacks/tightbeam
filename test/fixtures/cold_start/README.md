# Captured v5 cold-start fixtures

These database sets are captured cold-start gateway fixtures, not idealized
schemas. Each gateway stopped cleanly before the set was copied.

The stopped sets contain `state.db`; `state.db-wal` and `state.db-shm` are
absent. The manifest records nonidentifying version and schema information.

The capture command is not published. The five base fixtures were produced
through the real HTTP/WebSocket gateway without direct database edits.

`v5-missing-main-parent` starts from the stopped, captured `v5-healthy` set.
The versioned `scripts/derive_cold_start_fixtures_v1.sh` script creates this
impossible-by-real-flow broken-parent state.
