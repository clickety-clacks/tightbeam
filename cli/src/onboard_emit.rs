//! Machine-readable emission of onboarding sign-in deliverables (wi_0535922b).
//!
//! Interactive onboarding is INCOMPLETE until the operator holds the sign-in URL and, for
//! the device-code providers, the one-time code (ceremony-lifecycle-v1.md, "The definition
//! of interactive onboarding"). When the ceremony runs inside a session the operator cannot
//! see -- an agent-run install over a private pty -- printing the URL+code to that terminal
//! delivers them to no one. This module turns the deliverable into three things a relay CAN
//! read: a structured stdout line, and the material for a durable substrate row plus an
//! operator wake (both driven by `ceremonies`, which holds the wire).
//!
//! The functions here are PURE -- extraction, ansi stripping, and json/prose shaping -- so
//! they are unit-tested against a REAL captured `codex login --device-auth` response
//! (`tests/fixtures/codex-device-auth-0.146.0.txt`), never a hand-idealized one. The I/O
//! (teeing the child, sending the wire requests) lives in `ceremonies`.

use serde_json::json;

/// What an onboarding ceremony surfaces for the operator to act on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Deliverable {
    /// codex / OpenAI RFC-8628 device code: a verification URL AND a one-time code, both
    /// extracted from the teed vendor stream.
    DeviceCode { url: String, code: String },
    /// claude / Anthropic carry-back: a sign-in URL we minted in-process. There is no code
    /// on our side -- the operator pastes `code#state` BACK from the callback page.
    SignInUrl { url: String },
    /// Extraction missed (vendor output changed shape): the raw, ansi-stripped tail of the
    /// teed stream, so the deliverable is recorded and pointed at rather than lost. The
    /// mechanism never silently degrades to invisible.
    RawTail { tail: String },
}

impl Deliverable {
    /// The `kind` token that names this deliverable on the wire and in the structured line.
    /// Mirrors the ruled step shapes (rails-and-guidance-roadmap.md: codex device_code,
    /// claude paste_back).
    pub(crate) fn kind(&self) -> &'static str {
        match self {
            Deliverable::DeviceCode { .. } => "device_code",
            Deliverable::SignInUrl { .. } => "paste_back",
            Deliverable::RawTail { .. } => "raw_tail",
        }
    }
}

/// The single machine-readable line an onboard ceremony prints to stdout for a relay to
/// parse. One JSON object on its own line, under a stable top-level key so it is
/// unmistakable amid the vendor's human passthrough text.
///
/// `wake_id` is the operator-wake identity -- the wake row IS the durable record of this
/// delivery (wi_0535922b). `delivery_file` is the path to the local 0600 copy. Both are
/// threaded through so the machine-readable line points a relay at where the delivery landed.
pub(crate) fn structured_line(
    provider: &str,
    machine: &str,
    deliverable: &Deliverable,
    wake_id: Option<&str>,
    delivery_file: Option<&str>,
) -> String {
    let mut body = json!({
        "provider": provider,
        "machine": machine,
        "kind": deliverable.kind(),
    });
    let object = body.as_object_mut().expect("json object");
    match deliverable {
        Deliverable::DeviceCode { url, code } => {
            object.insert("url".to_owned(), json!(url));
            object.insert("code".to_owned(), json!(code));
        }
        Deliverable::SignInUrl { url } => {
            object.insert("url".to_owned(), json!(url));
        }
        Deliverable::RawTail { tail } => {
            object.insert("rawTail".to_owned(), json!(tail));
        }
    }
    if let Some(wake_id) = wake_id {
        object.insert("operatorWake".to_owned(), json!(wake_id));
    }
    if let Some(delivery_file) = delivery_file {
        object.insert("deliveryFile".to_owned(), json!(delivery_file));
    }
    json!({ "onboardingDelivery": body }).to_string()
}

/// The prose an operator reads in the wake mailbox. Written for a HUMAN who is elsewhere and
/// must act: one instruction per line, the URL and code verbatim and unwrapped.
pub(crate) fn operator_prompt(provider: &str, machine: &str, deliverable: &Deliverable) -> String {
    match deliverable {
        Deliverable::DeviceCode { url, code } => format!(
            "Onboarding {provider} on {machine} needs you to sign in.\n\
             Open this link and sign in:\n    {url}\n\
             Then enter this one-time code:\n    {code}\n\
             The code expires in about 15 minutes."
        ),
        Deliverable::SignInUrl { url } => format!(
            "Onboarding {provider} on {machine} needs you to sign in.\n\
             Open this link and sign in:\n    {url}\n\
             The page then shows a code (code#state); carry it back to the ceremony."
        ),
        Deliverable::RawTail { tail } => format!(
            "Onboarding {provider} on {machine} surfaced a sign-in prompt this build could \
             not parse into a URL+code. Read it and act on it directly:\n\n{tail}"
        ),
    }
}

/// Whether the operator was actually notified, and if not, WHY -- recorded verbatim so a
/// delivery whose wake could not be sent is loud, not silent (the whole point of the fix).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Notified {
    /// The owner was woken; the wake row is the durable notification.
    Waked {
        user_id: String,
        wake_id: Option<String>,
    },
    /// No wake was sent. The reason is carried so the gap is visible in the file and stdout.
    NotNotified { reason: String },
}

/// The full JSON written to the 0600 delivery file -- the LOCAL durable copy of the
/// deliverable (the substrate's durable row is the operator wake itself). Pretty-printed and
/// self-describing: provider, machine, the URL/code, when it was minted and expires, and
/// whether the operator was notified.
pub(crate) fn delivery_file_json(
    provider: &str,
    machine: &str,
    deliverable: &Deliverable,
    minted_at_ms: i64,
    expires_at_ms: Option<i64>,
    notified: &Notified,
) -> String {
    let mut body = json!({
        "provider": provider,
        "machine": machine,
        "kind": deliverable.kind(),
        "mintedAtMs": minted_at_ms,
    });
    let object = body.as_object_mut().expect("json object");
    match deliverable {
        Deliverable::DeviceCode { url, code } => {
            object.insert("url".to_owned(), json!(url));
            object.insert("code".to_owned(), json!(code));
        }
        Deliverable::SignInUrl { url } => {
            object.insert("url".to_owned(), json!(url));
        }
        Deliverable::RawTail { tail } => {
            object.insert("rawTail".to_owned(), json!(tail));
        }
    }
    if let Some(expires_at_ms) = expires_at_ms {
        object.insert("expiresAtMs".to_owned(), json!(expires_at_ms));
    }
    object.insert("notification".to_owned(), notification_json(notified));
    serde_json::to_string_pretty(&json!({ "onboardingDelivery": body })).expect("json serializes")
}

fn notification_json(notified: &Notified) -> serde_json::Value {
    match notified {
        Notified::Waked { user_id, wake_id } => json!({
            "notified": true,
            "userId": user_id,
            "wakeId": wake_id,
        }),
        Notified::NotNotified { reason } => json!({
            "notified": false,
            "reason": reason,
        }),
    }
}

/// Strip ANSI CSI escape sequences (colour/SGR and any other `ESC [ ... final`) from a
/// vendor stream so extraction and the recorded tail read as plain text.
///
/// codex colours the URL and code with SGR (`\x1b[94m ... \x1b[0m`) even to a pipe; nothing
/// in its device-auth output uses cursor motion or an alternate screen, so removing CSI
/// sequences is enough. A lone ESC not starting a CSI is dropped with its next byte rather
/// than left to corrupt a match.
pub(crate) fn strip_ansi(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars();
    while let Some(ch) = chars.next() {
        if ch != '\x1b' {
            out.push(ch);
            continue;
        }
        match chars.next() {
            // CSI: ESC [ params/intermediates (0x20..=0x3f) then a final byte (0x40..=0x7e).
            Some('[') => {
                for follow in chars.by_ref() {
                    if ('\u{40}'..='\u{7e}').contains(&follow) {
                        break;
                    }
                }
            }
            // Any other escape (or a trailing ESC): drop it and the byte it introduced.
            _ => {}
        }
    }
    out
}

/// Pull the verification URL and one-time code out of a teed `codex login --device-auth`
/// stream. Best-effort and ansi-tolerant: strips ANSI first, then reads the URL as the first
/// `https://` token and the code as the first `XXXX-XXXX` group AFTER the "one-time code"
/// marker, so neither the version string nor the trailing warning line is mistaken for it.
///
/// Returns `None` when either piece is absent -- the caller then records the raw tail rather
/// than emitting a half deliverable.
pub(crate) fn extract_codex_device(raw: &str) -> Option<Deliverable> {
    let text = strip_ansi(raw);
    let url = first_https(&text)?;
    let code = first_code_after(&text, "one-time code")?;
    Some(Deliverable::DeviceCode { url, code })
}

/// The first `https://...` token, ended by ASCII whitespace or control.
fn first_https(text: &str) -> Option<String> {
    let start = text.find("https://")?;
    let rest = &text[start..];
    let end = rest
        .find(|c: char| c.is_whitespace() || c.is_control())
        .unwrap_or(rest.len());
    Some(rest[..end].to_owned())
}

/// The first dash-joined group of upper-case-alnum runs appearing AFTER `marker`.
/// e.g. `VG6S-L35ON`. Each run must be >= 3 chars so ordinary hyphenation is not matched.
fn first_code_after(text: &str, marker: &str) -> Option<String> {
    let from = text.find(marker)? + marker.len();
    let tail = &text[from..];

    let bytes = tail.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        // A candidate token is a maximal run of [A-Z0-9-].
        if is_code_byte(bytes[i]) {
            let start = i;
            while i < bytes.len() && is_code_byte(bytes[i]) {
                i += 1;
            }
            if let Some(code) = valid_code(&tail[start..i]) {
                return Some(code);
            }
        } else {
            i += 1;
        }
    }
    None
}

fn is_code_byte(b: u8) -> bool {
    b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'-'
}

/// A well-formed device code: at least two groups, each >= 3 chars, joined by single dashes.
fn valid_code(token: &str) -> Option<String> {
    let groups: Vec<&str> = token.split('-').collect();
    if groups.len() < 2 {
        return None;
    }
    if groups.iter().any(|g| g.len() < 3) {
        return None;
    }
    Some(token.to_owned())
}

/// The last `max` bytes of a teed stream, ansi-stripped and trimmed, for the miss path.
pub(crate) fn raw_tail(raw: &str, max: usize) -> String {
    let text = strip_ansi(raw);
    let trimmed = text.trim();
    if trimmed.len() <= max {
        return trimmed.to_owned();
    }
    // Keep the TAIL: the code, if present at all, is near the end of the block.
    let start = trimmed.len() - max;
    // Do not split a UTF-8 char.
    let start = (start..trimmed.len())
        .find(|&i| trimmed.is_char_boundary(i))
        .unwrap_or(trimmed.len());
    trimmed[start..].to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Real capture: `codex login --device-auth` (codex-cli 0.146.0), stdout piped to a
    /// file, base64-round-tripped. NOT hand-authored -- the fixture is the wire truth.
    const CODEX_REAL: &str = include_str!("../tests/fixtures/codex-device-auth-0.146.0.txt");

    #[test]
    fn extracts_url_and_code_from_the_real_codex_stream() {
        let deliverable = extract_codex_device(CODEX_REAL).expect("extracts from real output");
        assert_eq!(
            deliverable,
            Deliverable::DeviceCode {
                url: "https://auth.openai.com/codex/device".to_owned(),
                code: "VG6S-L35ON".to_owned(),
            }
        );
    }

    #[test]
    fn strip_ansi_removes_sgr_but_keeps_text() {
        let stripped = strip_ansi("a\x1b[94mURL\x1b[0mb");
        assert_eq!(stripped, "aURLb");
    }

    #[test]
    fn version_string_and_warning_are_not_read_as_the_code() {
        // The code must come from AFTER the "one-time code" marker: the version `0.146.0`
        // and the word `Codex.` in the trailing warning must not win.
        let deliverable = extract_codex_device(CODEX_REAL).expect("extracts");
        match deliverable {
            Deliverable::DeviceCode { code, .. } => assert_eq!(code, "VG6S-L35ON"),
            other => panic!("expected device code, got {other:?}"),
        }
    }

    #[test]
    fn missing_code_yields_none_so_the_caller_records_the_tail() {
        let only_url = "Open this link\n   https://auth.openai.com/codex/device\n";
        assert!(extract_codex_device(only_url).is_none());
    }

    #[test]
    fn missing_url_yields_none() {
        let only_code = "Enter this one-time code\n   VG6S-L35ON\n";
        assert!(extract_codex_device(only_code).is_none());
    }

    #[test]
    fn structured_line_is_one_json_object_under_a_stable_key() {
        let deliverable = Deliverable::DeviceCode {
            url: "https://auth.openai.com/codex/device".to_owned(),
            code: "VG6S-L35ON".to_owned(),
        };
        let line = structured_line(
            "openai",
            "shrdlu",
            &deliverable,
            Some("w_1"),
            Some("/w/onboard-delivery-openai-1.json"),
        );
        assert!(!line.contains('\n'), "structured line must be single-line");
        let parsed: serde_json::Value = serde_json::from_str(&line).expect("valid json");
        let d = &parsed["onboardingDelivery"];
        assert_eq!(d["provider"], "openai");
        assert_eq!(d["machine"], "shrdlu");
        assert_eq!(d["kind"], "device_code");
        assert_eq!(d["url"], "https://auth.openai.com/codex/device");
        assert_eq!(d["code"], "VG6S-L35ON");
        assert_eq!(d["operatorWake"], "w_1");
        assert_eq!(d["deliveryFile"], "/w/onboard-delivery-openai-1.json");
    }

    #[test]
    fn sign_in_url_deliverable_carries_no_code() {
        let deliverable = Deliverable::SignInUrl {
            url: "https://claude.ai/oauth/authorize?x=1".to_owned(),
        };
        let line = structured_line("anthropic", "shrdlu", &deliverable, None, None);
        let parsed: serde_json::Value = serde_json::from_str(&line).expect("valid json");
        let d = &parsed["onboardingDelivery"];
        assert_eq!(d["kind"], "paste_back");
        assert_eq!(d["url"], "https://claude.ai/oauth/authorize?x=1");
        assert!(d.get("code").is_none(), "paste_back has no code our side");
    }

    #[test]
    fn delivery_file_carries_deliverable_minting_and_notification() {
        let deliverable = Deliverable::DeviceCode {
            url: "https://auth.openai.com/codex/device".to_owned(),
            code: "VG6S-L35ON".to_owned(),
        };
        let notified = Notified::Waked {
            user_id: "mike".to_owned(),
            wake_id: Some("w_1".to_owned()),
        };
        let file = delivery_file_json(
            "openai",
            "shrdlu",
            &deliverable,
            1000,
            Some(901_000),
            &notified,
        );
        let parsed: serde_json::Value = serde_json::from_str(&file).expect("valid json");
        let d = &parsed["onboardingDelivery"];
        assert_eq!(d["code"], "VG6S-L35ON");
        assert_eq!(d["mintedAtMs"], 1000);
        assert_eq!(d["expiresAtMs"], 901_000);
        assert_eq!(d["notification"]["notified"], true);
        assert_eq!(d["notification"]["userId"], "mike");
        assert_eq!(d["notification"]["wakeId"], "w_1");
    }

    #[test]
    fn delivery_file_records_a_missing_notification_loudly() {
        let deliverable = Deliverable::SignInUrl {
            url: "https://claude.ai/oauth/authorize".to_owned(),
        };
        let notified = Notified::NotNotified {
            reason: "gateway did not supply ownerUserId".to_owned(),
        };
        let file = delivery_file_json("anthropic", "shrdlu", &deliverable, 5, None, &notified);
        let parsed: serde_json::Value = serde_json::from_str(&file).expect("valid json");
        let n = &parsed["onboardingDelivery"]["notification"];
        assert_eq!(n["notified"], false);
        assert_eq!(n["reason"], "gateway did not supply ownerUserId");
        assert!(parsed["onboardingDelivery"].get("expiresAtMs").is_none());
    }

    #[test]
    fn raw_tail_keeps_the_end_and_strips_ansi() {
        let tail = raw_tail(CODEX_REAL, 80);
        assert!(tail.len() <= 80);
        assert!(!tail.contains('\x1b'));
        // The end of the block is the warning line; the tail must include its close.
        assert!(tail.contains("cancel."));
    }
}
