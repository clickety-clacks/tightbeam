use std::os::raw::{c_char, c_int};

use rusqlite::ffi;
use rusqlite::functions::{Context, FunctionFlags};
use rusqlite::types::ValueRef;
use rusqlite::{Connection, Result};
use unicode_normalization::UnicodeNormalization;

fn canonical_title(context: &Context<'_>) -> Result<Option<String>> {
    match context.get_raw(0) {
        ValueRef::Text(bytes) => match std::str::from_utf8(bytes) {
            Ok(text) => Ok(Some(text.trim_matches(is_white_space).nfc().collect())),
            Err(_) => Ok(None),
        },
        _ => Ok(None),
    }
}

fn unicode_scalar_length(context: &Context<'_>) -> Result<Option<i64>> {
    match context.get_raw(0) {
        ValueRef::Text(bytes) => match std::str::from_utf8(bytes) {
            Ok(text) => Ok(Some(text.chars().count() as i64)),
            Err(_) => Ok(None),
        },
        _ => Ok(None),
    }
}

fn is_white_space(value: char) -> bool {
    matches!(
        value,
        '\u{0009}'..='\u{000d}'
            | '\u{0020}'
            | '\u{0085}'
            | '\u{00a0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200a}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202f}'
            | '\u{205f}'
            | '\u{3000}'
    )
}

/// SQLite loadable-extension entrypoint.
///
/// # Safety
///
/// SQLite calls this function with its live connection and API table.
#[no_mangle]
pub unsafe extern "C" fn sqlite3_topline_unicode_init(
    db: *mut ffi::sqlite3,
    error: *mut *mut c_char,
    api: *mut ffi::sqlite3_api_routines,
) -> c_int {
    Connection::extension_init2(db, error, api, register)
}

fn register(db: Connection) -> Result<bool> {
    assert_eq!(unicode_normalization::UNICODE_VERSION, (15, 1, 0));
    let flags = FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC;
    db.create_scalar_function("tightbeam_canonical_title", 1, flags, canonical_title)?;
    db.create_scalar_function(
        "tightbeam_unicode_scalar_length",
        1,
        flags,
        unicode_scalar_length,
    )?;
    Ok(false)
}
