//! Mint an Anthropic subscription credential by running the OAuth ourselves.
//!
//! WHY NOT `claude setup-token`, which is the vendor's own command: it requests a single
//! scope, `user:inference`, and the credential it returns is entitled to LESS than the
//! operator's own login. Measured against the same adapter, same version, minutes apart:
//!
//!   setup-token credential : default, sonnet, opus, haiku
//!   operator's own login   : default, opus[1m], claude-fable-5[1m], sonnet, haiku
//!
//! `fable` and `claude-fable-5` are refused outright under the setup-token credential and
//! accepted under the operator's. So onboarding a host through the vendor's supported
//! command silently downgrades it, and nothing in the flow says so. That is the defect this
//! module exists to fix, and it cannot be fixed by asking `setup-token` more nicely --
//! it takes no flags.
//!
//! The scopes here are the set the operator's working login actually carries, read off a
//! live credential rather than guessed.
//!
//! WHAT THIS IS AND IS NOT. Tightbeam does not do inference. The credential minted here is
//! written where Claude Code reads it and Claude Code does the work, over ACP. That is the
//! whole difference from a harness that takes a subscription credential and calls the API
//! itself: we provision the client, we do not replace it.
//!
//! The redirect is the CODE-DISPLAY callback, not a localhost server. An operator running
//! this over ssh has no browser on the box, and the code-display page works from anywhere --
//! which is also why the paste is `code#state` rather than a URL.

use std::collections::BTreeMap;
use std::time::Duration;

use sha2::{Digest, Sha256};

const AUTHORIZE_URL: &str = "https://claude.ai/oauth/authorize";
const TOKEN_URL: &str = "https://platform.claude.com/v1/oauth/token";

/// Claude Code's own OAuth client. The credential minted with it is consumed by Claude Code.
const CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";

/// Shows the code on a page instead of redirecting to a local server, so the browser does
/// not have to be on this machine.
const REDIRECT_URI: &str = "https://platform.claude.com/oauth/code/callback";

/// Read off a working login, not chosen. `user:sessions:claude_code` is what the narrow
/// setup-token credential lacks, and the model picker is what it costs.
const SCOPES: &str = "org:create_api_key user:profile user:inference \
                      user:sessions:claude_code user:mcp_servers user:file_upload";

/// Debug is implemented rather than derived, and it REDACTS.
///
/// A derived `Debug` puts a live year-long credential into every panic message, assertion
/// failure and stray `dbg!` -- which is how this branch's original defect reached a real
/// operator's log. The struct is unprintable by construction instead of by discipline.
pub(crate) struct Credential {
    pub(crate) access_token: String,
    pub(crate) refresh_token: String,
    pub(crate) expires_at_ms: i64,
    pub(crate) scopes: Vec<String>,
    pub(crate) subscription_type: Option<String>,
}

impl std::fmt::Debug for Credential {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Credential")
            .field("access_token", &"<redacted>")
            .field("refresh_token", &"<redacted>")
            .field("expires_at_ms", &self.expires_at_ms)
            .field("scopes", &self.scopes)
            .field("subscription_type", &self.subscription_type)
            .finish()
    }
}

pub(crate) struct Challenge {
    verifier: String,
    state: String,
    pub(crate) url: String,
}

/// Build the sign-in URL and the secret that proves we are the one who asked for it.
pub(crate) fn begin() -> Challenge {
    let verifier = random_urlsafe(32);
    let challenge = base64url(&Sha256::digest(verifier.as_bytes()));
    let state = random_urlsafe(32);

    let query = [
        ("code", "true"),
        ("client_id", CLIENT_ID),
        ("response_type", "code"),
        ("redirect_uri", REDIRECT_URI),
        ("scope", SCOPES),
        ("code_challenge", &challenge),
        ("code_challenge_method", "S256"),
        ("state", &state),
    ]
    .iter()
    .map(|(key, value)| format!("{key}={}", urlencode(value)))
    .collect::<Vec<_>>()
    .join("&");

    Challenge {
        verifier,
        state,
        url: format!("{AUTHORIZE_URL}?{query}"),
    }
}

/// Exchange what the operator pasted for a credential.
///
/// The paste is `code#state`, which is what the callback page shows. The state is CHECKED
/// rather than merely forwarded: it is the only thing tying the code the operator pasted to
/// the challenge this process generated, and accepting a mismatched one would let a code
/// from some other sign-in be banked as this host's credential.
pub(crate) fn complete(challenge: &Challenge, pasted: &str) -> Result<Credential, String> {
    let pasted = pasted.trim();
    let (code, state) = pasted.split_once('#').ok_or_else(|| {
        "expected the code as `code#state`, exactly as the page shows it".to_owned()
    })?;

    if state != challenge.state {
        return Err(
            "that code was issued for a different sign-in: its state does not match the one \
             this ceremony generated. Start the ceremony again and use the link it prints."
                .to_owned(),
        );
    }

    let mut body = BTreeMap::new();
    body.insert("grant_type", "authorization_code");
    body.insert("client_id", CLIENT_ID);
    body.insert("code", code);
    body.insert("state", state);
    body.insert("redirect_uri", REDIRECT_URI);
    body.insert("code_verifier", challenge.verifier.as_str());

    let payload = serde_json::to_string(&body).map_err(|error| error.to_string())?;
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(30))
        .timeout_connect(Duration::from_secs(30))
        .build();

    let response = agent
        .post(TOKEN_URL)
        .set("content-type", "application/json")
        .set("accept", "application/json")
        .send_string(&payload);

    let body = match response {
        Ok(response) => response
            .into_string()
            .map_err(|error| format!("token exchange returned an unreadable body: {error}"))?,
        Err(ureq::Error::Status(status, response)) => {
            let detail = response.into_string().unwrap_or_default();
            return Err(format!(
                "token exchange refused: HTTP {status} {}",
                detail.trim()
            ));
        }
        Err(error) => return Err(format!("could not reach the token endpoint: {error}")),
    };

    parse_credential(&body)
}

/// The token response, read strictly.
///
/// A missing refresh token or expiry is a REFUSAL, not a default. A credential banked
/// without them looks healthy and dies silently when the access token lapses, which is the
/// failure shape this whole area keeps producing.
/// The ONE place a bearer token is taken out of the stored record.
///
/// Everything that authenticates with a subscription credential comes through here -- the
/// catalog probe, and anything added later. Three separate extractions grew before this
/// existed, in three languages, and two of them were wrong at different times.
pub(crate) fn access_token(raw: &str) -> Result<String, String> {
    match serde_json::from_str::<serde_json::Value>(raw) {
        Ok(json) => json
            .get("claudeAiOauth")
            .and_then(|oauth| oauth.get("accessToken"))
            .and_then(serde_json::Value::as_str)
            .map(|token| token.trim().to_owned())
            .filter(|token| !token.is_empty())
            .ok_or_else(|| "credential has no claudeAiOauth.accessToken".to_owned()),
        Err(error) => Err(format!("credential is not a JSON OAuth record: {error}")),
    }
}

fn parse_credential(body: &str) -> Result<Credential, String> {
    let json: serde_json::Value = serde_json::from_str(body)
        .map_err(|error| format!("token exchange returned invalid JSON: {error}"))?;

    let text = |key: &str| {
        json.get(key)
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
    };

    let access_token =
        text("access_token").ok_or_else(|| "token exchange returned no access_token".to_owned())?;
    let refresh_token = text("refresh_token")
        .ok_or_else(|| "token exchange returned no refresh_token".to_owned())?;
    let expires_in = json
        .get("expires_in")
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| "token exchange returned no expires_in".to_owned())?;

    let scopes = match json.get("scope").and_then(serde_json::Value::as_str) {
        Some(scope) => scope.split_whitespace().map(str::to_owned).collect(),
        None => Vec::new(),
    };
    const REQUIRED_SCOPE: &str = "user:sessions:claude_code";
    if !scopes.iter().any(|scope| scope == REQUIRED_SCOPE) {
        return Err(format!(
            "token exchange did not grant required scope {REQUIRED_SCOPE}; credential was NOT banked"
        ));
    }

    Ok(Credential {
        access_token,
        refresh_token,
        expires_at_ms: now_ms() + expires_in * 1000,
        scopes,
        subscription_type: text("subscription_type"),
    })
}

/// The file Claude Code reads, in the shape it reads it.
///
/// Written by us rather than by the vendor, which is the one real cost of this approach: the
/// shape is theirs and they can change it. Kept to exactly the fields observed on a working
/// login, so a change shows up as Claude Code ignoring the file rather than as us inventing
/// structure it never had.
pub(crate) fn credentials_json(credential: &Credential) -> String {
    let mut oauth = serde_json::Map::new();
    oauth.insert("accessToken".into(), credential.access_token.clone().into());
    oauth.insert(
        "refreshToken".into(),
        credential.refresh_token.clone().into(),
    );
    oauth.insert("expiresAt".into(), credential.expires_at_ms.into());
    oauth.insert("scopes".into(), credential.scopes.clone().into());
    if let Some(subscription) = &credential.subscription_type {
        oauth.insert("subscriptionType".into(), subscription.clone().into());
    }

    serde_json::json!({ "claudeAiOauth": oauth }).to_string()
}

/// Entropy from the kernel rather than a crate: this needs unpredictable bytes, which
/// `/dev/urandom` is exactly for, and one fewer dependency in a credential path is worth
/// more than the convenience.
fn random_urlsafe(bytes: usize) -> String {
    let mut buffer = vec![0u8; bytes];
    let mut file = std::fs::File::open("/dev/urandom").expect("/dev/urandom is unavailable");
    std::io::Read::read_exact(&mut file, &mut buffer).expect("/dev/urandom is unreadable");
    base64url(&buffer)
}

/// base64url without padding, per RFC 4648 §5 -- what PKCE requires.
///
/// Hand-rolled rather than pulled in: it is fifteen lines, it is exercised by every
/// challenge this module builds, and the round-trip is pinned by a test against a known
/// vector. A dependency would be more code, not less.
fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let packed = chunk.iter().enumerate().fold(0u32, |acc, (index, byte)| {
            acc | (u32::from(*byte) << (16 - 8 * index))
        });
        for index in 0..=chunk.len() {
            out.push(ALPHABET[((packed >> (18 - 6 * index)) & 0x3f) as usize] as char);
        }
    }
    out
}

fn urlencode(value: &str) -> String {
    value
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The scopes are the point of this module existing. `user:sessions:claude_code` is the
    /// one the narrow setup-token credential lacks, and losing it costs the model picker.
    #[test]
    fn the_request_asks_for_the_scopes_a_working_login_carries() {
        let challenge = begin();
        for scope in [
            "user%3Ainference",
            "user%3Asessions%3Aclaude_code",
            "user%3Amcp_servers",
            "user%3Aprofile",
        ] {
            assert!(
                challenge.url.contains(scope),
                "missing {scope}: {}",
                challenge.url
            );
        }
    }

    /// A localhost callback cannot work for an operator signing in from another machine,
    /// which is the ordinary case for a remote install.
    #[test]
    fn the_redirect_shows_the_code_rather_than_needing_a_local_browser() {
        assert!(
            begin()
                .url
                .contains("platform.claude.com%2Foauth%2Fcode%2Fcallback")
        );
    }

    /// Two ceremonies must not be able to complete each other.
    #[test]
    fn a_code_from_a_different_sign_in_is_refused() {
        let challenge = begin();
        let error = complete(&challenge, "somecode#notmystate").unwrap_err();
        assert!(error.contains("different sign-in"), "{error}");
    }

    #[test]
    fn a_paste_that_is_not_code_hash_state_says_so() {
        let error = complete(&begin(), "justacode").unwrap_err();
        assert!(error.contains("code#state"), "{error}");
    }

    /// Each ceremony gets its own verifier and state, or one could replay another.
    /// A known vector, so a subtle encoding bug shows up here rather than as an OAuth
    /// refusal nobody can explain.
    #[test]
    fn base64url_matches_the_rfc_vectors() {
        assert_eq!(base64url(b""), "");
        assert_eq!(base64url(b"f"), "Zg");
        assert_eq!(base64url(b"fo"), "Zm8");
        assert_eq!(base64url(b"foo"), "Zm9v");
        assert_eq!(base64url(b"foob"), "Zm9vYg");
        assert_eq!(base64url(b"fooba"), "Zm9vYmE");
        assert_eq!(base64url(b"foobar"), "Zm9vYmFy");
        // url-safe alphabet: no + or /, no padding
        assert_eq!(base64url(&[0xfb, 0xff, 0xfe]), "-__-");
    }

    #[test]
    fn every_challenge_is_unique() {
        let (first, second) = (begin(), begin());
        assert_ne!(first.state, second.state);
        assert_ne!(first.verifier, second.verifier);
    }

    /// A credential missing its refresh token or expiry is refused, not defaulted: banked
    /// without them it looks healthy and dies silently when the access token lapses.
    #[test]
    fn an_incomplete_token_response_is_refused_rather_than_defaulted() {
        let missing_refresh = r#"{"access_token":"a","expires_in":3600}"#;
        assert!(
            parse_credential(missing_refresh)
                .unwrap_err()
                .contains("refresh_token")
        );

        let missing_expiry = r#"{"access_token":"a","refresh_token":"r"}"#;
        assert!(
            parse_credential(missing_expiry)
                .unwrap_err()
                .contains("expires_in")
        );
    }

    #[test]
    fn a_token_response_must_grant_the_claude_code_session_scope() {
        let missing = parse_credential(
            r#"{"access_token":"at","refresh_token":"rt","expires_in":60,
                "scope":"user:file_upload user:inference user:profile"}"#,
        )
        .unwrap_err();
        assert!(missing.contains("user:sessions:claude_code"), "{missing}");
        assert!(missing.contains("NOT banked"), "{missing}");

        let complete = parse_credential(
            r#"{"access_token":"at","refresh_token":"rt","expires_in":60,
                "scope":"user:file_upload user:inference user:mcp_servers user:profile user:sessions:claude_code"}"#,
        )
        .unwrap();
        assert!(
            complete
                .scopes
                .iter()
                .any(|scope| scope == "user:sessions:claude_code")
        );
    }

    #[test]
    fn the_credential_file_has_the_shape_claude_code_reads() {
        let credential = parse_credential(
            r#"{"access_token":"at","refresh_token":"rt","expires_in":60,
                "scope":"user:inference user:sessions:claude_code",
                "subscription_type":"max"}"#,
        )
        .unwrap();
        let written: serde_json::Value =
            serde_json::from_str(&credentials_json(&credential)).unwrap();
        let oauth = &written["claudeAiOauth"];
        assert_eq!(oauth["accessToken"], "at");
        assert_eq!(oauth["refreshToken"], "rt");
        assert_eq!(oauth["subscriptionType"], "max");
        assert_eq!(oauth["scopes"][1], "user:sessions:claude_code");
        assert!(oauth["expiresAt"].as_i64().unwrap() > now_ms());
    }
}
