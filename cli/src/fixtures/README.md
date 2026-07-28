# Test fixtures for `screen.rs`

## `claude-setup-token-2.1.220-80col.log`

**This file contains no credential. Do not delete it in a security sweep.**

It is a recording of `claude setup-token` (claude 2.1.220) running on a 24x80 pty,
captured on eezo on 2026-07-27. The flow was **deliberately aborted**: `open`,
`xdg-open` and the browsers were stubbed so nothing launched, and the process was
killed after 12 seconds, before the paste prompt could accept an authorization code.
No code was entered, no token was ever issued, and `grep -c sk-ant` over the file
returns **0**. `the_recorded_aborted_flow_yields_no_token` asserts that about the
fixture itself, so it cannot silently acquire one later.

What it does contain, and why it is worth keeping:

* An OAuth **authorize** URL — not a token. Its `client_id` is public, and its PKCE
  `code_challenge` is single-use and belongs to a handshake that was never completed,
  so it is spent and unusable.
* The rendering that defect #80 is about: prose whose spaces were never emitted
  (the TUI jumps the cursor over them instead of writing them), and a long line the
  TUI hard-wrapped into 80-column rows.

The URL appears **twice** in the file: once whole inside an OSC 8 hyperlink, and once
as visible text broken across rows. That is what makes this a recorded-reality fixture
rather than a mock — the tests reconstruct the visible copy and check it against the
hyperlink copy, so the file attests to its own expected value. A fixture that asserted
only what a test author told it to would have proven nothing here.

The explanation lives in this README rather than as a header inside the file because
the file is a byte-exact pty recording. A comment line prepended to it would be
replayed as screen content, become row 0, and could change the width inference the
reconstruction depends on.
