use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::Value;

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

    match load_endpoint_for_doctor(&endpoint) {
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
) -> Result<HarnessCatalog, DoctorLoadError> {
    let response = match dispatch::gateway_request("GET", endpoint, "/harnesses", None).call() {
        Ok(response) => response,
        Err(ureq::Error::Transport(error)) => {
            return Err(DoctorLoadError::Offline(doctor_unavailable(
                &error.to_string(),
            )));
        }
        Err(ureq::Error::Status(status, response)) => {
            let encoded = response
                .into_string()
                .unwrap_or_else(|_| format!("HTTP {status}"));
            return Err(DoctorLoadError::Gateway(doctor_unavailable(&encoded)));
        }
    };
    let encoded = response
        .into_string()
        .map_err(|error| DoctorLoadError::Gateway(doctor_unavailable(&error.to_string())))?;
    parse(&encoded).map_err(|reason| DoctorLoadError::Gateway(doctor_unavailable(&reason)))
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
    if let Some(deadline) = deadline {
        let endpoint = endpoint.clone();
        return crate::lease::until(deadline, move |remaining| {
            load_endpoint_with_timeout(&endpoint, Some(remaining))
        })
        .map_err(|()| harness_lease_expired())?;
    }

    load_endpoint_with_timeout(endpoint, None)
}

fn load_endpoint_with_timeout(
    endpoint: &dispatch::Endpoint,
    timeout: Option<Duration>,
) -> Result<HarnessCatalog, String> {
    let response = match dispatch::gateway_request("GET", endpoint, "/harnesses", timeout).call() {
        Ok(response) => response,
        Err(ureq::Error::Status(status, response)) => {
            let encoded = response
                .into_string()
                .unwrap_or_else(|_| format!("HTTP {status}"));
            let detail = serde_json::from_str::<Value>(&encoded)
                .ok()
                .and_then(|json| {
                    let code = json.pointer("/error/code")?.as_str()?;
                    let message = json.pointer("/error/message").and_then(Value::as_str);
                    Some(match message {
                        Some(message) if !message.is_empty() => format!("{code}: {message}"),
                        _ => code.to_owned(),
                    })
                })
                .unwrap_or(encoded);
            return Err(unavailable(&detail));
        }
        Err(ureq::Error::Transport(error)) => return Err(unavailable(&error.to_string())),
    };
    let encoded = response
        .into_string()
        .map_err(|error| unavailable(&error.to_string()))?;
    parse(&encoded).map_err(|reason| unavailable(&reason))
}

pub fn load_optional() -> Option<HarnessCatalog> {
    load().ok()
}

pub(crate) fn load_optional_from(
    endpoint: &dispatch::Endpoint,
    deadline: Instant,
) -> Result<Option<HarnessCatalog>, String> {
    match load_from_with(&home_dir(), || {
        load_endpoint_with_deadline(endpoint, Some(deadline))
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
        assert_eq!(catalog.names(), vec!["claude", "codex"]);
        assert_eq!(catalog.harnesses[0].cli_binary, "claude");
        assert_eq!(catalog.harnesses[1].cli_binary, "codex");
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
                assert_eq!(catalog.names(), vec!["claude", "codex"]);
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
            session_file: None,
        };
        let error =
            load_endpoint_with_deadline(&endpoint, Some(Instant::now() - Duration::from_millis(1)))
                .unwrap_err();

        assert!(error.contains("onboarding lease expired"), "{error}");
    }
}
