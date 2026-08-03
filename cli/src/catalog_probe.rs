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

    const RECORD: &str = r#"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"MUST-NOT-LEAK"}}"#;

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
        assert_eq!(rendered("{\"error\":\"nope\"}", 401), "{\"error\":\"nope\"}\n401\n");
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
