//! Fetch a provider's model list on the host that holds the credential.
//!
//! WHY THIS IS A CLI VERB and not a shell fragment the gateway sends. The credential file
//! is JSON for a subscription and a bare secret for an api key, so something has to know
//! the shape. Three separate readers grew before this existed -- Elixir in the gateway,
//! JavaScript in the liveness probe, and `python3` shelled onto satellites -- which is one
//! fact with three homes and, in the python case, a runtime dependency added to every
//! satellite to do a job this binary was already installed to do.
//!
//! The CLI is the right home for two reasons beyond deduplication. It is ALREADY on every
//! host assimilate touches, and the gateway already execs it there for `harness-group`, so
//! this adds no dependency and no new transport. And it WRITES this file during onboarding,
//! so the writer of the shape is the reader of the shape.
//!
//! The secret never leaves this process. It goes from a file read into an HTTPS header
//! without passing through a shell variable, an interpreter's argv, or a `$(...)` capture.
//! What comes back on stdout is the provider's model list, which is not secret.

use std::os::unix::fs::OpenOptionsExt;
use std::time::Duration;

use crate::anthropic_oauth;

/// Long enough for a slow model-list response, bounded because the gateway runs this inside
/// a refresh task: an unbounded probe leaves that entry refreshing forever, which is a
/// liveness hole rather than a slow answer.
const TIMEOUT: Duration = Duration::from_secs(30);

/// `catalog-probe <provider> <kind> <credential-path> <url>`
///
/// Internal plumbing, like `harness-group`: the gateway calls it, operators do not.
///
/// Output is the body followed by a newline and the HTTP status, which is exactly what the
/// `curl -w "\n%{http_code}"` this replaces emitted. Keeping the wire shape means the
/// gateway's existing splitter is unchanged -- the credential reader moved, the protocol
/// between the hosts did not.
pub(crate) fn probe(args: &[String]) -> Result<i32, String> {
    let [provider, kind, credential_path, url] = args else {
        return Err(
            "usage: tightbeam catalog-probe <provider> <kind> <credential-path> <url>".to_owned(),
        );
    };

    let raw = std::fs::read_to_string(credential_path)
        .map_err(|error| format!("could not read the credential at {credential_path}: {error}"))?;

    // RENEW BEFORE ASKING, not after being refused. An expired subscription token answers
    // 401, the catalog records "degraded", and the gateway offers zero models -- with
    // nothing placeable, no turn ever runs to renew the token, so the install cannot
    // recover on its own. Renewing here is what breaks that: this verb is the reader that
    // would take the 401, and it is also the writer of this file's shape.
    //
    // Best-effort by construction. A renewal that fails must not fail the probe: the stored
    // token may still be good (a clock skew, a provider hiccup), and the honest outcome of
    // asking with it is the provider's own answer rather than ours.
    let raw = match renewed(provider, kind, &raw, credential_path) {
        Ok(Some(fresh)) => fresh,
        Ok(None) => raw,
        Err(Renewal { fresh, reason }) => {
            // A renewal that could not be SAVED still produced a live token, and using it
            // is strictly better than authenticating with one known to be spent. Falling
            // back to `raw` here would guarantee the 401 this whole path exists to avoid.
            // The failure goes to stderr rather than stdout, which carries the catalog.
            eprintln!("tightbeam: {reason}");
            fresh.unwrap_or(raw)
        }
    };

    let header = authorization(provider, kind, &raw)?;

    let agent = ureq::AgentBuilder::new()
        .timeout(TIMEOUT)
        .timeout_connect(TIMEOUT)
        .build();

    let mut request = agent.get(url);
    for (name, value) in header {
        request = request.set(&name, &value);
    }

    match request.call() {
        Ok(response) => {
            let status = response.status();
            let body = response
                .into_string()
                .map_err(|error| format!("catalog response was unreadable: {error}"))?;
            print!("{}", rendered(&body, status));
            Ok(0)
        }
        Err(ureq::Error::Status(status, response)) => {
            // A refusal still exits ZERO and reports its status in the trailer: the caller
            // distinguishes a 401 from an unreachable host by the trailer, and a nonzero
            // exit would collapse those into one unhelpful failure.
            let body = response.into_string().unwrap_or_default();
            print!("{}", rendered(&body, status));
            Ok(0)
        }
        Err(error) => Err(format!("catalog request failed: {error}")),
    }
}

/// `Some(fresh_json)` when the stored credential was spent and has been renewed on disk.
///
/// Only a SUBSCRIPTION can be renewed: an api key is a bare secret with no expiry and no
/// grant behind it, so it is never touched here.
fn renewed(
    provider: &str,
    kind: &str,
    raw: &str,
    credential_path: &str,
) -> Result<Option<String>, Renewal> {
    if (provider, kind) != ("anthropic", "subscription") {
        return Ok(None);
    }

    if !anthropic_oauth::needs_renewal(raw, now_ms()) {
        return Ok(None);
    }

    let credential = anthropic_oauth::refresh(raw).map_err(|reason| Renewal {
        fresh: None,
        reason: format!("could not renew the anthropic credential: {reason}"),
    })?;

    let json = anthropic_oauth::credentials_json(&credential);

    // THE GRANT ALREADY HAPPENED. If the provider rotated the refresh token, the stored
    // record is now the one that cannot renew again — so a failed write must not throw the
    // fresh credential away and report success at using the old one. It is handed back for
    // this process to use, with the persistence failure named.
    match write_credential(credential_path, &json) {
        Ok(()) => Ok(Some(json)),
        Err(reason) => Err(Renewal {
            fresh: Some(json),
            reason: format!(
                "renewed the anthropic credential but could not save it to \
                 {credential_path}: {reason}. This process will use the new token; if the \
                 provider rotated the refresh token, the stored record may no longer renew \
                 and re-onboarding will be required."
            ),
        }),
    }
}

/// A renewal that failed, carrying whatever it still managed to produce.
///
/// Two unlike failures used to share one shape (`Err(_)`): "the grant was refused" and "the
/// grant succeeded but the file would not save". The first means the stored token is all we
/// have; the second means we hold a BETTER token than the stored one. Collapsing them threw
/// away a live credential.
struct Renewal {
    fresh: Option<String>,
    reason: String,
}

/// Replace the credential without ever leaving a partial or shared one behind.
///
/// Write-then-rename because the alternative is truncating the only copy of a credential and
/// then failing to fill it: Claude Code reads this same file, and a half-written record is
/// not a degraded login but a destroyed one.
///
/// The staging path is UNIQUE PER WRITER and created `O_EXCL`. A fixed name was a race with
/// two teeth: two probes renewing at once could hold the same inode, one renaming it into
/// place while the other wrote through its descriptor — modifying the live credential
/// non-atomically — and `.mode(0o600)` is ignored for a file that already exists, so a
/// pre-existing permissive staging file would have received the secret.
fn write_credential(credential_path: &str, json: &str) -> Result<(), String> {
    let path = std::path::Path::new(credential_path);
    let directory = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "credentials".to_owned());
    let temporary = directory.join(format!(
        ".{name}.renewing.{}.{}",
        std::process::id(),
        now_ms()
    ));

    let staged = (|| -> Result<(), String> {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(|error| format!("could not stage the renewed credential: {error}"))?;
        file.write_all(json.as_bytes())
            .map_err(|error| format!("could not write the renewed credential: {error}"))?;
        file.sync_all()
            .map_err(|error| format!("could not flush the renewed credential: {error}"))
    })();

    // Every failure path removes the staging file, including the ones that fail BEFORE the
    // rename. A leftover holding a live token is a secret lying around under a predictable
    // name, and the next writer would collide with it.
    if let Err(reason) = staged {
        let _ = std::fs::remove_file(&temporary);
        return Err(reason);
    }

    if let Err(error) = std::fs::rename(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!("could not install the renewed credential: {error}"));
    }

    // Durability of the REPLACEMENT, not just of the bytes: without this the rename can be
    // lost across a crash and the file reverts to the spent token it just replaced.
    if let Ok(handle) = std::fs::File::open(directory) {
        let _ = handle.sync_all();
    }

    Ok(())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

/// Body, newline, status -- the shape the gateway's splitter reads.
///
/// This is a CROSS-LANGUAGE CONTRACT and it has no compiler to enforce it: the Elixir side
/// takes the last line as the status and everything before it as the body. Emitting the
/// status on its own line is therefore load-bearing, and it is what `curl -w "\n%{http_code}"`
/// produced before this verb existed. A body that does not end in a newline would otherwise
/// run into the status and both would be unparseable.
fn rendered(body: &str, status: u16) -> String {
    let separator = if body.ends_with('\n') { "" } else { "\n" };
    format!("{body}{separator}{status}\n")
}

/// The header this credential authenticates with, chosen by KIND rather than by sniffing.
///
/// The variable names the kind: anthropic rejects a subscription token sent as `x-api-key`
/// and an api key sent as `Authorization: Bearer`, and each refusal blames the credential
/// rather than the header. Passing the kind in explicitly is what keeps a wrong pairing a
/// programming error instead of a mysterious 401.
fn authorization(provider: &str, kind: &str, raw: &str) -> Result<Vec<(String, String)>, String> {
    match (provider, kind) {
        ("anthropic", "subscription") => {
            let token = anthropic_oauth::access_token(raw)?;
            Ok(vec![
                ("authorization".to_owned(), format!("Bearer {token}")),
                ("anthropic-version".to_owned(), "2023-06-01".to_owned()),
            ])
        }
        ("anthropic", "api_key") => Ok(vec![
            ("x-api-key".to_owned(), raw.trim().to_owned()),
            ("anthropic-version".to_owned(), "2023-06-01".to_owned()),
        ]),
        ("openai", _) => Ok(vec![(
            "authorization".to_owned(),
            format!("Bearer {}", raw.trim()),
        )]),
        _ => Err(format!("unsupported provider/kind: {provider}/{kind}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RECORD: &str =
        r#"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"MUST-NOT-LEAK"}}"#;

    /// The whole point: a subscription sends the access token, and the refresh token stays
    /// on disk. Sending the record whole is what a naive reader does, and it both fails
    /// authentication and discloses the refresh token to the provider.
    #[test]
    fn a_subscription_sends_only_its_access_token() {
        let header = authorization("anthropic", "subscription", RECORD).unwrap();
        let rendered = format!("{header:?}");
        assert!(rendered.contains("Bearer tok"), "{rendered}");
        assert!(!rendered.contains("MUST-NOT-LEAK"), "{rendered}");
        assert!(!rendered.contains("claudeAiOauth"), "{rendered}");
    }

    /// An api key is the file, and it authenticates on a DIFFERENT header. Sent as a bearer
    /// it is refused with a message blaming the key.
    #[test]
    fn an_api_key_goes_on_x_api_key_not_bearer() {
        let header = authorization("anthropic", "api_key", "sk-ant-api03-x\n").unwrap();
        assert!(header.contains(&("x-api-key".to_owned(), "sk-ant-api03-x".to_owned())));
        assert!(header.iter().all(|(name, _)| name != "authorization"));
    }

    /// A subscription record that is not one must refuse rather than send something
    /// plausible: a header built from garbage earns a 401 that reads as a dead credential.
    #[test]
    fn a_malformed_subscription_record_refuses() {
        assert!(authorization("anthropic", "subscription", "not json").is_err());
        assert!(authorization("anthropic", "subscription", "{}").is_err());
    }

    #[test]
    fn an_unknown_provider_refuses_rather_than_guessing_a_header() {
        assert!(authorization("gemini", "api_key", "x").is_err());
    }

    /// The trailer contract, asserted against the ELIXIR SIDE'S OWN SOURCE.
    ///
    /// Nothing else can enforce this: two languages agree on a wire shape by convention,
    /// which is exactly how a staged filename came to disagree with the reader that wanted
    /// it. If the gateway stops splitting on the last line, this fails here rather than as
    /// an unparseable catalog in production.
    #[test]
    fn the_trailer_is_the_shape_the_gateway_splits_on() {
        assert_eq!(rendered("{\"data\":[]}", 200), "{\"data\":[]}\n200\n");
        // A body that already ends in a newline must not gain a blank line, or the status
        // stops being the last line.
        assert_eq!(rendered("{}\n", 401), "{}\n401\n");

        let gateway = include_str!("../../lib/tightbeam/harness/support.ex");
        assert!(
            gateway.contains("split_trailing_line"),
            "the gateway no longer splits a trailing status line; this verb's output shape \
             is stale"
        );
    }

    /// A refusal is reported in the TRAILER, not the exit code: the caller must be able to
    /// tell a 401 from a host it could not reach, and a nonzero exit collapses those.
    #[test]
    fn an_http_refusal_still_renders_a_parseable_trailer() {
        assert_eq!(
            rendered("{\"error\":\"nope\"}", 401),
            "{\"error\":\"nope\"}\n401\n"
        );
    }

    /// An api key has no expiry and no grant behind it, so renewal must never touch it.
    /// Reaching the refresh path with one would send a bare secret to a token endpoint.
    #[test]
    fn an_api_key_is_never_renewed() {
        let temporary = std::env::temp_dir().join("tb-renew-apikey");
        assert!(matches!(
            renewed(
                "anthropic",
                "api_key",
                "sk-ant-x",
                temporary.to_str().unwrap()
            ),
            Ok(None)
        ));
        assert!(!temporary.exists(), "an api key path must not be written");
    }

    /// A LIVE subscription is left alone. Renewing a good token on every probe would
    /// rotate the credential constantly and turn a read into a write.
    #[test]
    fn a_live_subscription_is_left_alone() {
        let live = format!(
            r#"{{"claudeAiOauth":{{"accessToken":"a","refreshToken":"r","expiresAt":{}}}}}"#,
            now_ms() + 3_600_000
        );
        let temporary = std::env::temp_dir().join("tb-renew-live");
        assert!(matches!(
            renewed(
                "anthropic",
                "subscription",
                &live,
                temporary.to_str().unwrap()
            ),
            Ok(None)
        ));
    }

    /// The expiry question, both sides of the boundary. A token inside the skew window is
    /// already spent: it can expire between this check and the request it authorizes, and
    /// the caller cannot tell that from a revoked credential.
    #[test]
    fn renewal_is_judged_with_a_skew_so_a_token_cannot_lapse_mid_request() {
        let at = |expires_at: i64| {
            format!(r#"{{"claudeAiOauth":{{"accessToken":"a","expiresAt":{expires_at}}}}}"#)
        };
        let now = 1_000_000_000_000;

        assert!(
            anthropic_oauth::needs_renewal(&at(now - 1), now),
            "past expiry"
        );
        assert!(
            anthropic_oauth::needs_renewal(&at(now + 30_000), now),
            "inside the skew window is spent, not live"
        );
        assert!(!anthropic_oauth::needs_renewal(&at(now + 3_600_000), now));
    }

    /// A record we cannot DATE must be renewed, not trusted. Nothing else refuses it —
    /// `access_token` validates only `accessToken` — so answering "live" here would leave
    /// an undateable record 401ing on every probe and never renewing, which is exactly the
    /// deadlock this path exists to end. Renewing is self-healing: what we write back has
    /// an expiry, so the unknown state resolves instead of recurring.
    #[test]
    fn a_record_with_no_readable_expiry_is_renewed_rather_than_trusted_forever() {
        assert!(anthropic_oauth::needs_renewal(
            r#"{"claudeAiOauth":{"accessToken":"a"}}"#,
            0
        ));
        assert!(anthropic_oauth::needs_renewal("not json", 0));
    }

    /// The renewed credential must land whole or not at all. Claude Code reads this same
    /// file: a half-written record is not a degraded login, it is a destroyed one.
    #[test]
    fn a_renewed_credential_is_installed_whole_and_private() {
        use std::os::unix::fs::PermissionsExt;

        let directory = std::env::temp_dir().join("tb-renew-write");
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join(".credentials.json");
        std::fs::write(&path, "OLD").unwrap();

        write_credential(
            path.to_str().unwrap(),
            r#"{"claudeAiOauth":{"accessToken":"new"}}"#,
        )
        .unwrap();

        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            r#"{"claudeAiOauth":{"accessToken":"new"}}"#
        );
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600,
            "a credential must never sit at the default umask"
        );
        assert!(
            std::fs::read_dir(&directory).unwrap().count() == 1,
            "the staging file must not survive the rename"
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    /// A PRE-EXISTING staging file must never be written through.
    ///
    /// This is the deterministic half of the fixed-name hazard, and the half with teeth:
    /// `.mode(0o600)` is ignored for a file that already exists, so with a fixed name a
    /// planted world-readable staging file would have received the live token. `create_new`
    /// plus a per-writer name makes that unreachable. (The other half — two probes racing on
    /// one inode — is a genuine concurrency property that a sequential test cannot establish,
    /// so it is not claimed here.)
    #[test]
    fn a_planted_staging_file_never_receives_the_secret() {
        use std::os::unix::fs::PermissionsExt;

        let directory = std::env::temp_dir().join("tb-renew-planted");
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join(".credentials.json");

        // EXACTLY the name the fixed-path version builds: `.{file_name}.renewing`, and the
        // file name already begins with a dot, so it is doubled. Getting this wrong makes
        // the test green for the wrong reason — it did, the first time.
        let planted = directory.join("..credentials.json.renewing");
        std::fs::write(&planted, "").unwrap();
        std::fs::set_permissions(&planted, std::fs::Permissions::from_mode(0o666)).unwrap();

        write_credential(path.to_str().unwrap(), r#"{"secret":"live-token"}"#).unwrap();

        assert_eq!(
            std::fs::read_to_string(&planted).unwrap(),
            "",
            "the planted permissive file must not have received the credential"
        );
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            r#"{"secret":"live-token"}"#
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    /// A write that cannot even be staged must leave the EXISTING credential exactly as it
    /// was. The failure mode this guards is the one that costs a login: truncating the only
    /// copy and then failing to fill it.
    #[test]
    fn a_failed_write_leaves_the_existing_credential_untouched() {
        let directory = std::env::temp_dir().join("tb-renew-failed");
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join(".credentials.json");
        std::fs::write(&path, "ORIGINAL").unwrap();

        // The parent of this path is a FILE, so staging cannot succeed.
        let unwritable = path.join("nested").join(".credentials.json");
        assert!(write_credential(unwritable.to_str().unwrap(), r#"{"a":1}"#).is_err());

        assert_eq!(std::fs::read_to_string(&path).unwrap(), "ORIGINAL");
        let _ = std::fs::remove_dir_all(&directory);
    }

    /// Every spelling of "the provider sent no new refresh token" must inherit the stored
    /// one. `""` used to be ACCEPTED and written, which stores a token that cannot renew and
    /// disables the next renewal silently and permanently.
    #[test]
    fn absent_null_and_blank_refresh_tokens_all_inherit_the_stored_one() {
        let base = |extra: &str| {
            format!(
                r#"{{"access_token":"new","expires_in":3600,{extra}"scope":"user:sessions:claude_code"}}"#
            )
        };

        for body in [
            base(""),
            base(r#""refresh_token":null,"#),
            base(r#""refresh_token":"","#),
            base(r#""refresh_token":"   ","#),
        ] {
            let credential = anthropic_oauth::renewed_credential_for_test(&body, "STORED")
                .unwrap_or_else(|error| panic!("{body} -> {error}"));
            assert_eq!(credential.refresh_token, "STORED", "{body}");
        }

        // A real rotation is kept, not overwritten by the stored one.
        let rotated = anthropic_oauth::renewed_credential_for_test(
            &base(r#""refresh_token":"ROTATED","#),
            "STORED",
        )
        .unwrap();
        assert_eq!(rotated.refresh_token, "ROTATED");
    }

    #[test]
    fn wrong_arity_names_the_usage_rather_than_panicking() {
        let error = probe(&["anthropic".to_owned()]).unwrap_err();
        assert!(error.contains("usage: tightbeam catalog-probe"), "{error}");
    }

    /// A missing credential names the PATH. The gateway runs this over ssh and reads one
    /// stream, so a reason that does not say which file is a support ticket.
    #[test]
    fn a_missing_credential_names_the_path_it_looked_for() {
        let missing = "/nonexistent/tightbeam-probe-fixture/.credentials.json";
        let error = probe(&[
            "anthropic".to_owned(),
            "subscription".to_owned(),
            missing.to_owned(),
            "https://example.invalid/v1/models".to_owned(),
        ])
        .unwrap_err();
        assert!(error.contains(missing), "{error}");
    }
}
