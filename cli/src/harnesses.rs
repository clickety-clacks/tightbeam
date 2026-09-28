use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::attempt_diagnostic::FailurePresentation;
use crate::attempt_diagnostic::command_context::{CatalogOrigin, CommandContext};
use crate::dispatch;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessProjection {
    pub wire_name: String,
    pub install_package: String,
    /// The vendor CLI this harness invokes directly, which the operator installs.
    pub cli_binary: String,
    pub process_markers: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessCatalog {
    pub harnesses: Vec<HarnessProjection>,
}

impl HarnessCatalog {
    pub fn names(&self) -> Vec<String> {
        self.harnesses
            .iter()
            .map(|harness| harness.wire_name.clone())
            .collect()
    }

    pub fn contains(&self, name: &str) -> bool {
        self.harnesses
            .iter()
            .any(|harness| harness.wire_name == name)
    }
}

// The projection cache lives in the org, so it must resolve the org the same way
// the gateway does: this read TIGHTBEAM_HOME only and ignored TIGHTBEAM_BASE_DIR.
fn home_dir() -> PathBuf {
    crate::base_dir::resolve()
}

fn parse(encoded: &str) -> Result<HarnessCatalog, String> {
    let rows: Vec<Value> = serde_json::from_str(encoded).map_err(|error| error.to_string())?;
    let harnesses = rows
        .into_iter()
        .filter(|row| row.get("enabled").and_then(Value::as_bool) != Some(false))
        .map(|row| {
            let string = |key: &str| {
                row.get(key)
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .ok_or_else(|| format!("harness projection missing {key}"))
            };
            let process_markers = row
                .get("process_markers")
                .and_then(Value::as_array)
                .ok_or_else(|| "harness projection missing process_markers".to_owned())?
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| "harness process marker is not a string".to_owned())
                })
                .collect::<Result<Vec<_>, _>>()?;
            string("id")?;
            Ok(HarnessProjection {
                wire_name: string("wire_name")?,
                install_package: string("install_package")?,
                cli_binary: string("cli_binary")?,
                process_markers,
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok(HarnessCatalog { harnesses })
}

pub fn local_registry() -> Result<HarnessCatalog, String> {
    parse(include_str!("../../priv/harness_registry.json"))
}

pub(crate) enum DoctorCatalog {
    Live(HarnessCatalog),
    Offline {
        catalog: HarnessCatalog,
        reason: String,
    },
    GatewayError(String),
}

pub(crate) fn load_for_doctor(base_dir: &Path) -> DoctorCatalog {
    let cached = cached_catalog(base_dir);
    let endpoint = match dispatch::discover_from(base_dir) {
        Ok(endpoint) => endpoint,
        Err(reason) => {
            return offline_doctor_catalog(cached, doctor_unavailable(&reason));
        }
    };

    match load_endpoint_for_doctor(&endpoint, base_dir) {
        Ok(live) => DoctorCatalog::Live(cached.unwrap_or(live)),
        Err(DoctorLoadError::Offline(reason)) => offline_doctor_catalog(cached, reason),
        Err(DoctorLoadError::Gateway(_reason)) if cached.is_some() => {
            DoctorCatalog::Live(cached.expect("checked above"))
        }
        Err(DoctorLoadError::Gateway(reason)) => DoctorCatalog::GatewayError(reason),
    }
}

fn cached_catalog(base_dir: &Path) -> Option<HarnessCatalog> {
    fs::read_to_string(base_dir.join("harnesses.json"))
        .ok()
        .and_then(|encoded| parse(&encoded).ok())
}

fn offline_doctor_catalog(cached: Option<HarnessCatalog>, reason: String) -> DoctorCatalog {
    match cached.map(Ok).unwrap_or_else(local_registry) {
        Ok(catalog) => DoctorCatalog::Offline { catalog, reason },
        Err(local_reason) => DoctorCatalog::GatewayError(format!(
            "{reason}; local harness registry is invalid: {local_reason}"
        )),
    }
}

enum DoctorLoadError {
    Offline(String),
    Gateway(String),
}

fn load_endpoint_for_doctor(
    endpoint: &dispatch::Endpoint,
    base_dir: &Path,
) -> Result<HarnessCatalog, DoctorLoadError> {
    let context = Some(CommandContext::catalog(CatalogOrigin::Doctor));
    match request_catalog(endpoint, context, base_dir, None) {
        Ok(catalog) => Ok(catalog),
        Err(CatalogRequestFailure::Transport(reason)) => Err(DoctorLoadError::Offline(
            gateway_failure(reason, doctor_unavailable),
        )),
        Err(CatalogRequestFailure::Gateway(reason)) => Err(DoctorLoadError::Gateway(
            gateway_failure(reason, doctor_unavailable),
        )),
        Err(CatalogRequestFailure::Projection(reason)) => {
            Err(DoctorLoadError::Gateway(doctor_unavailable(&reason)))
        }
    }
}

pub fn load() -> Result<HarnessCatalog, String> {
    load_from_with(&home_dir(), load_from_default_route)
}

#[cfg(test)]
pub fn load_from(base_dir: &Path) -> Result<HarnessCatalog, String> {
    load_from_with(base_dir, || load_from_route(base_dir))
}

fn load_from_with(
    base_dir: &Path,
    fallback: impl FnOnce() -> Result<HarnessCatalog, String>,
) -> Result<HarnessCatalog, String> {
    let path = base_dir.join("harnesses.json");
    match fs::read_to_string(&path) {
        Ok(encoded) => match parse(&encoded) {
            Ok(catalog) => return Ok(catalog),
            Err(_) => {}
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.to_string()),
    }

    fallback()
}

#[cfg(test)]
fn load_from_route(base_dir: &Path) -> Result<HarnessCatalog, String> {
    let endpoint = dispatch::discover_from(base_dir).map_err(|reason| unavailable(&reason))?;
    load_endpoint(&endpoint)
}

fn load_from_default_route() -> Result<HarnessCatalog, String> {
    let endpoint = dispatch::discover().map_err(|reason| unavailable(&reason))?;
    load_endpoint(&endpoint)
}

fn load_endpoint(endpoint: &dispatch::Endpoint) -> Result<HarnessCatalog, String> {
    load_endpoint_with_deadline(endpoint, None)
}

fn load_endpoint_with_deadline(
    endpoint: &dispatch::Endpoint,
    deadline: Option<Instant>,
) -> Result<HarnessCatalog, String> {
    let receipt_base = home_dir();
    load_endpoint_with_context_and_deadline(endpoint, None, &receipt_base, deadline)
}

fn load_endpoint_with_context_and_deadline(
    endpoint: &dispatch::Endpoint,
    context: Option<CommandContext>,
    receipt_base: &Path,
    deadline: Option<Instant>,
) -> Result<HarnessCatalog, String> {
    if let Some(deadline) = deadline {
        let endpoint = endpoint.clone();
        let receipt_base = receipt_base.to_path_buf();
        return crate::lease::until(deadline, move |remaining| {
            load_endpoint_with_timeout(&endpoint, context, &receipt_base, Some(remaining))
        })
        .map_err(|()| harness_lease_expired())?;
    }

    load_endpoint_with_timeout(endpoint, context, receipt_base, None)
}

fn load_endpoint_with_timeout(
    endpoint: &dispatch::Endpoint,
    context: Option<CommandContext>,
    receipt_base: &Path,
    timeout: Option<Duration>,
) -> Result<HarnessCatalog, String> {
    match request_catalog(endpoint, context, receipt_base, timeout) {
        Ok(catalog) => Ok(catalog),
        Err(CatalogRequestFailure::Transport(reason) | CatalogRequestFailure::Gateway(reason)) => {
            Err(gateway_failure(reason, unavailable))
        }
        Err(CatalogRequestFailure::Projection(reason)) => Err(unavailable(&reason)),
    }
}

enum CatalogRequestFailure {
    Transport(String),
    Gateway(String),
    Projection(String),
}

/// Perform one catalog GET and retain only typed attempt evidence. Catalog
/// projection errors remain distinct from transport and gateway failures.
fn request_catalog(
    endpoint: &dispatch::Endpoint,
    context: Option<CommandContext>,
    receipt_base: &Path,
    timeout: Option<Duration>,
) -> Result<HarnessCatalog, CatalogRequestFailure> {
    let request = dispatch::gateway_request("GET", endpoint, "/harnesses", timeout);
    let mut attempt = crate::attempt_diagnostic::observation::begin_gateway_attempt(
        context,
        "GET",
        "/harnesses",
        timeout,
    );
    let request =
        crate::attempt_diagnostic::observation::attach_request_id(request, attempt.as_ref());
    let (status, response) = match request.call() {
        Ok(response) => (response.status(), response),
        Err(ureq::Error::Status(status, response)) => (status, response),
        Err(ureq::Error::Transport(error)) => {
            let reason = match attempt.take() {
                Some(attempt) => {
                    let completed = attempt.fail_transport(&error, receipt_base);
                    dispatch::transport_failure_with_attempt(
                        &error,
                        Some(completed.render()),
                        FailurePresentation::Ordinary,
                    )
                }
                None => dispatch::transport_failure(&error),
            };
            return Err(CatalogRequestFailure::Transport(reason));
        }
    };
    if let Some(attempt) = attempt.as_mut() {
        attempt.observe_response(&response);
    }
    let encoded = match response.into_string() {
        Ok(encoded) => encoded,
        Err(error) => {
            let reason = match attempt.take() {
                Some(attempt) => {
                    let completed = attempt.fail_body(&error, receipt_base);
                    dispatch::unreadable_response_with_attempt(
                        status,
                        &error,
                        Some(completed.render()),
                        FailurePresentation::Ordinary,
                    )
                }
                None => dispatch::unreadable_response(status, &error),
            };
            return Err(CatalogRequestFailure::Gateway(reason));
        }
    };
    let completed = attempt
        .take()
        .map(|attempt| attempt.complete_response(status, &encoded));
    let attempt_render = completed.as_ref().map(|completed| completed.render());
    if !(200..300).contains(&status) {
        return Err(CatalogRequestFailure::Gateway(
            dispatch::status_failure_with_attempt(status, &encoded, attempt_render),
        ));
    }

    if let Err(error) = serde_json::from_str::<Value>(&encoded) {
        return Err(CatalogRequestFailure::Gateway(match attempt_render {
            Some(attempt) => dispatch::undecodable_response_with_attempt(
                status,
                &encoded,
                &error,
                Some(attempt),
                FailurePresentation::Ordinary,
            ),
            None => dispatch::undecodable_response_with_attempt(
                status,
                &encoded,
                &error,
                None,
                FailurePresentation::Ordinary,
            ),
        }));
    }
    parse(&encoded).map_err(CatalogRequestFailure::Projection)
}

fn load_with_context(context: Option<CommandContext>) -> Result<HarnessCatalog, String> {
    let receipt_base = home_dir();
    load_from_with(&receipt_base, || {
        let endpoint = dispatch::discover().map_err(|reason| unavailable(&reason))?;
        load_endpoint_with_context_and_deadline(&endpoint, context, &receipt_base, None)
    })
}

pub(crate) fn load_optional(context: Option<CommandContext>) -> Option<HarnessCatalog> {
    load_with_context(context).ok()
}

pub(crate) fn catalog_for(context: Option<CommandContext>) -> Result<HarnessCatalog, String> {
    #[cfg(test)]
    {
        let _ = context;
        catalog()
    }
    #[cfg(not(test))]
    {
        load_with_context(context)
    }
}

pub(crate) fn load_optional_from(
    endpoint: &dispatch::Endpoint,
    deadline: Instant,
) -> Result<Option<HarnessCatalog>, String> {
    let receipt_base = home_dir();
    let context = Some(CommandContext::catalog(CatalogOrigin::Onboard));
    match load_from_with(&receipt_base, || {
        load_endpoint_with_context_and_deadline(endpoint, context, &receipt_base, Some(deadline))
    }) {
        Ok(catalog) => Ok(Some(catalog)),
        Err(reason) if reason == harness_lease_expired() => Err(reason),
        Err(_) => Ok(None),
    }
}

fn harness_lease_expired() -> String {
    "harness catalog lookup refused because the onboarding lease expired".to_owned()
}

#[cfg(not(test))]
pub fn catalog() -> Result<HarnessCatalog, String> {
    load()
}

#[cfg(test)]
pub fn catalog() -> Result<HarnessCatalog, String> {
    Ok(HarnessCatalog {
        harnesses: [
            ("claude", "claude-agent-acp"),
            ("codex", "codex-acp"),
            ("fixture", "fixture-acp"),
        ]
        .into_iter()
        .map(|(name, marker)| HarnessProjection {
            wire_name: name.to_owned(),
            install_package: format!("{name}-package"),
            cli_binary: name.to_owned(),
            process_markers: vec![marker.to_owned()],
        })
        .collect(),
    })
}

/// Dispatch's two readings with this module's wording on the sentence. The JSON line
/// stays whole on its own line after it, so nothing is appended to that line.
fn gateway_failure(failure: String, wrap: fn(&str) -> String) -> String {
    match failure.split_once('\n') {
        Some((human, machine)) => format!("{}\n{machine}", wrap(human)),
        None => wrap(&failure),
    }
}

fn unavailable(reason: &str) -> String {
    format!("harness checks unavailable: {reason}; run tightbeam doctor")
}

fn doctor_unavailable(reason: &str) -> String {
    format!("harness checks unavailable: {reason}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn round_trips_every_consumed_field() {
        let catalog = parse(
            r#"[{"id":"third","wire_name":"third","install_package":"pkg","cli_binary":"third-cli","process_markers":["marker"]}]"#,
        )
        .unwrap();
        assert_eq!(catalog.names(), vec!["third"]);
        assert_eq!(catalog.harnesses[0].install_package, "pkg");
        assert_eq!(catalog.harnesses[0].cli_binary, "third-cli");
        assert_eq!(catalog.harnesses[0].process_markers, vec!["marker"]);
    }

    #[test]
    fn shipped_local_registry_is_available_before_any_gateway_boot() {
        let catalog = local_registry().unwrap();
        assert_eq!(catalog.names(), vec!["claude", "codex", "pi"]);
        assert_eq!(catalog.harnesses[0].cli_binary, "claude");
        assert_eq!(catalog.harnesses[1].cli_binary, "codex");
        assert_eq!(catalog.harnesses[2].cli_binary, "pi");
    }

    #[test]
    fn doctor_uses_the_local_registry_when_no_gateway_has_ever_run() {
        let root = std::env::temp_dir().join(format!(
            "tightbeam-doctor-no-gateway-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));

        match load_for_doctor(&root) {
            DoctorCatalog::Offline { catalog, .. } => {
                assert_eq!(catalog.names(), vec!["claude", "codex", "pi"]);
            }
            _ => panic!("an absent gateway must use the shipped local registry"),
        }

        assert!(!root.exists());
    }

    #[test]
    fn only_non_doctor_unavailability_points_to_doctor() {
        assert_eq!(
            doctor_unavailable("auth failed"),
            "harness checks unavailable: auth failed"
        );
        assert_eq!(
            unavailable("auth failed"),
            "harness checks unavailable: auth failed; run tightbeam doctor"
        );
    }

    /// A projection with no `cli_binary` is rejected rather than treated as a harness
    /// with no CLI prerequisite. Skipping the check for a harness whose projection is
    /// old is precisely the fail-open that let a satellite assimilate cleanly and then
    /// die on `claude: command not found` (#76).
    #[test]
    fn a_projection_without_a_cli_binary_is_rejected_rather_than_probed_loosely() {
        assert!(
            parse(
                r#"[{"id":"third","wire_name":"third","install_package":"pkg","process_markers":[]}]"#
            )
            .unwrap_err()
            .contains("missing cli_binary")
        );
    }

    #[test]
    fn a_cached_projection_without_an_id_uses_the_live_route() {
        let root = std::env::temp_dir().join(format!(
            "tightbeam-missing-harness-id-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        fs::write(
            root.join("harnesses.json"),
            r#"[{"wire_name":"cached","install_package":"pkg","cli_binary":"cached-cli","process_markers":[]}]"#,
        )
        .unwrap();

        let live = r#"[{"id":"live","wire_name":"live","install_package":"live-pkg","cli_binary":"live-cli","process_markers":[]}]"#;
        let catalog = load_from_with(&root, || parse(live)).unwrap();

        assert_eq!(catalog.names(), vec!["live"]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn explicit_base_dir_projection_is_authoritative() {
        let root = std::env::temp_dir().join(format!(
            "tightbeam-harnesses-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        fs::write(
            root.join("harnesses.json"),
            r#"[{"id":"third","wire_name":"third","install_package":"pkg","cli_binary":"third-cli","process_markers":["third-marker"]}]"#,
        )
        .unwrap();
        let catalog = load_from(&root).unwrap();
        assert_eq!(catalog.names(), vec!["third"]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_file_uses_the_route_loader_contract() {
        let encoded = r#"[{"id":"route","wire_name":"route","install_package":"route-pkg","cli_binary":"route-cli","process_markers":["route-marker"]}]"#;
        let root = std::env::temp_dir().join("tightbeam-missing-harness-projection");
        let catalog = load_from_with(&root, || parse(encoded)).unwrap();
        assert_eq!(catalog.names(), vec!["route"]);
        assert_eq!(catalog.harnesses[0].install_package, "route-pkg");
    }

    #[test]
    fn malformed_file_uses_the_live_route_loader_contract() {
        let root = std::env::temp_dir().join(format!(
            "tightbeam-malformed-harnesses-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("harnesses.json"), r#"[{"id":"truncated""#).unwrap();

        let encoded = r#"[{"id":"route","wire_name":"route","install_package":"route-pkg","cli_binary":"route-cli","process_markers":["route-marker"]}]"#;
        let catalog = load_from_with(&root, || parse(encoded)).unwrap();

        assert_eq!(catalog.names(), vec!["route"]);
        assert_eq!(catalog.harnesses[0].install_package, "route-pkg");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn malformed_projection_is_rejected_instead_of_inventing_a_catalog() {
        assert!(
            parse(r#"[{"id":"broken"}]"#)
                .unwrap_err()
                .contains("missing process_markers")
        );
    }

    #[test]
    fn expired_ceremony_harness_lookup_refuses_before_network_io() {
        let endpoint = dispatch::Endpoint {
            base: "http://127.0.0.1:1".to_owned(),
            token: "tbc_test".to_owned(),
            origin: crate::dispatch::Origin::Provisioned,
        };
        let error =
            load_endpoint_with_deadline(&endpoint, Some(Instant::now() - Duration::from_millis(1)))
                .unwrap_err();

        assert!(error.contains("onboarding lease expired"), "{error}");
    }

    #[test]
    fn a_refused_catalog_lookup_keeps_the_status_and_whole_error() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let body = r#"{"error":{"code":"forbidden","message":"not yours","requestId":"req-9","diagnostic":{"kind":"denial"},"apiToken":"tbc_leaked","extra":7}}"#;
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 4096];
            let _ = stream.read(&mut request);
            write!(stream, "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
        });
        let endpoint = dispatch::Endpoint {
            base: format!("http://{address}"),
            token: "tbc_test".to_owned(),
            origin: crate::dispatch::Origin::Provisioned,
        };

        let error = load_endpoint(&endpoint).unwrap_err();
        server.join().unwrap();

        let (human, machine) = error.split_once('\n').expect("two readings");
        assert_eq!(
            human,
            "harness checks unavailable: forbidden: not yours (req-9); run tightbeam doctor"
        );
        let machine: Value = serde_json::from_str(machine).unwrap();
        assert_eq!(
            machine,
            serde_json::json!({
                "ok": false,
                "httpStatus": 403,
                "error": {
                    "code": "forbidden",
                    "message": "not yours",
                    "requestId": "req-9",
                    "diagnostic": {"kind": "denial"},
                    "apiToken": "[REDACTED:secret_field]",
                    "extra": 7
                }
            })
        );
    }

    #[test]
    fn a_no_attempt_catalog_decode_failure_keeps_status_and_redacts_body() {
        use std::io::{Read, Write};

        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let body = "not JSON; Authorization: Bearer fixtureSENTINEL";
        let body_bytes = body.len();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 4096];
            let _ = stream.read(&mut request);
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(), body
            )
            .unwrap();
        });
        let endpoint = dispatch::Endpoint {
            base: format!("http://{address}"),
            token: "tbc_test".to_owned(),
            origin: crate::dispatch::Origin::Provisioned,
        };

        let error = match request_catalog(&endpoint, None, &std::env::temp_dir(), None) {
            Err(CatalogRequestFailure::Gateway(error)) => error,
            _ => panic!("expected malformed catalog response"),
        };
        server.join().unwrap();

        assert!(!error.contains("fixtureSENTINEL"), "{error}");
        let (human, machine) = error.split_once('\n').expect("two readings");
        assert!(human.contains("HTTP 200"), "{human}");
        let machine: Value = serde_json::from_str(machine).unwrap();
        assert_eq!(machine["ok"], false);
        assert_eq!(machine["httpStatus"], 200);
        assert_eq!(machine["error"]["code"], "response_undecodable");
        assert_eq!(machine["error"]["bodyBytes"], body_bytes);
        assert_eq!(
            machine["error"]["body"],
            "not JSON; Authorization: Bearer [REDACTED:secret_field]"
        );
    }
}
