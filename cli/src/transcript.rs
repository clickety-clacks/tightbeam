use serde_json::Value;
use std::fmt::Write;

/// Indent content so even a message containing a header/trailer cannot impersonate one.
pub fn render_text(page: &Value) -> Result<String, String> {
    render_text_with_cursor(page, None)
}

pub fn render_text_with_cursor(page: &Value, cursor: Option<&str>) -> Result<String, String> {
    let messages = page
        .get("messages")
        .and_then(Value::as_array)
        .ok_or("transcript response has no messages")?;
    let mut out = String::new();
    for message in messages {
        let millis = message
            .get("at")
            .and_then(Value::as_i64)
            .ok_or("invalid transcript timestamp")?;
        let seconds: libc::time_t = millis
            .div_euclid(1000)
            .try_into()
            .map_err(|_| "invalid transcript timestamp")?;
        let mut tm = std::mem::MaybeUninit::<libc::tm>::uninit();
        let tm = unsafe {
            if libc::gmtime_r(&seconds, tm.as_mut_ptr()).is_null() {
                return Err("invalid transcript timestamp".to_owned());
            }
            tm.assume_init()
        };
        let role = message
            .get("role")
            .and_then(Value::as_str)
            .ok_or("invalid transcript role")?;
        writeln!(
            out,
            "--- {:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z {role}",
            tm.tm_year + 1900,
            tm.tm_mon + 1,
            tm.tm_mday,
            tm.tm_hour,
            tm.tm_min,
            tm.tm_sec,
            millis.rem_euclid(1000)
        )
        .unwrap();
        let content = message
            .get("content")
            .and_then(Value::as_str)
            .ok_or("invalid transcript content")?;
        for line in content.split('\n') {
            writeln!(out, "  {line}").unwrap();
        }
    }
    writeln!(
        out,
        "--- page hasMoreBefore={} hasMoreAfter={} before={} after={}",
        page.get("hasMoreBefore")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        page.get("hasMoreAfter")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        page.get("oldestId")
            .and_then(Value::as_str)
            .or(cursor)
            .unwrap_or("-"),
        page.get("newestId")
            .and_then(Value::as_str)
            .or(cursor)
            .unwrap_or("-")
    )
    .unwrap();
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn text_keeps_content_and_cursors_without_metadata() {
        let text = render_text(&json!({"messages": [{"at": 0, "role": "assistant", "content": "hello\n--- page\n", "model": "hidden"}], "hasMoreBefore": true, "hasMoreAfter": false, "oldestId": "a", "newestId": "b"})).unwrap();
        assert_eq!(
            text,
            "--- 1970-01-01T00:00:00.000Z assistant\n  hello\n  --- page\n  \n--- page hasMoreBefore=true hasMoreAfter=false before=a after=b\n"
        );
        assert!(!text.contains("hidden"));
    }
    #[test]
    fn empty_text_page_keeps_paging_hints() {
        assert_eq!(render_text(&json!({"messages": [], "hasMoreBefore": false, "hasMoreAfter": true, "oldestId": null, "newestId": null})).unwrap(), "--- page hasMoreBefore=false hasMoreAfter=true before=- after=-\n");
    }
    #[test]
    fn empty_page_echoes_request_cursor() {
        let text = render_text_with_cursor(
            &json!({"messages": [], "hasMoreAfter": true}),
            Some("anchor"),
        )
        .unwrap();
        assert!(text.contains("before=anchor after=anchor"));
    }
}
