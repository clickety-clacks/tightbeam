//! Private PreToolUse JSON decode used by Bash statutes.
//!
//! The hook uses this entry's exit status only; successful decoding writes
//! nothing to stdout.

use std::io::{self, Read};

pub(crate) fn run() -> Result<(), String> {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|error| format!("hook-command could not read stdin: {error}"))?;

    let _ = crate::github_auth::decode_hook_json(&input)
        .map_err(|error| format!("hook-command received malformed hook JSON: {error}"))?;

    Ok(())
}
