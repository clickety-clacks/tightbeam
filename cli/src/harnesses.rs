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
    parse_rows(rows)
}

fn parse_doctor_response(encoded: &str) -> Result<(HarnessCatalog, Option<Value>), String> {
    let value: Value = serde_json::from_str(encoded).map_err(|error| error.to_string())?;
    let Value::Object(mut object) = value else {
        return Err("doctor harness response must be an object".to_owned());
    };
    let rows = object
        .remove("harnesses")
        .and_then(|value| value.as_array().cloned())
        .ok_or_else(|| "doctor harness response missing harnesses".to_owned())?;
    Ok((parse_rows(rows)?, object.remove("binary_diagnostics")))
}

fn parse_rows(rows: Vec<Value>) -> Result<HarnessCatalog, String> {
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
    Live {
        catalog: HarnessCatalog,
        binary_diagnostics: Option<Value>,
    },
    Offline {
        catalog: HarnessCatalog,
        reason: String,
    },
    Unavailable {
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
        Ok((live, binary_diagnostics)) => DoctorCatalog::Live {
            catalog: cached.unwrap_or(live),
            binary_diagnostics,
        },
        Err(DoctorLoadError::Offline(reason)) => offline_doctor_catalog(cached, reason),
        Err(DoctorLoadError::Gateway(reason)) if cached.is_some() => DoctorCatalog::Unavailable {
            catalog: cached.expect("checked above"),
            reason,
        },
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
) -> Result<(HarnessCatalog, Option<Value>), DoctorLoadError> {
    let response =
        match dispatch::gateway_request("GET", endpoint, "/harnesses?doctor=1", None).call() {
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
    parse_doctor_response(&encoded)
        .map_err(|reason| DoctorLoadError::Gateway(doctor_unavailable(&reason)))
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

pub(crate) fn binary_diagnostics_human(value: &Value) -> Vec<String> {
    const BOUNDARY: &str =
        "A failed gateway read cannot establish which binary a running adapter selected.";
    if value.get("status").and_then(Value::as_str) == Some("unavailable") {
        let reason = value
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or("unknown reason");
        let boundary = value
            .get("boundary")
            .and_then(Value::as_str)
            .unwrap_or(BOUNDARY);
        return vec![format!(
            "harness binary diagnostics unavailable: {reason}; {boundary}"
        )];
    }

    let Some(rows) = value.get("rows").and_then(Value::as_array) else {
        return vec![format!("harness binary diagnostics unknown; {BOUNDARY}")];
    };

    rows.iter()
        .flat_map(|row| {
            let host = row.get("host").and_then(Value::as_str).unwrap_or("?");
            let harness = row.get("harness").and_then(Value::as_str).unwrap_or("?");
            let prefix = format!("harness binary {harness} on {host}");
            let adapter = row.get("adapter");
            let package = adapter
                .and_then(|value| value.get("package"))
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let version = adapter
                .and_then(|value| value.get("version"))
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let next = row
                .get("next_launch")
                .map(render_selection)
                .unwrap_or_else(|| "unknown".to_owned());
            let mut lines = vec![
                format!("{prefix}: adapter {package} {version}"),
                format!("{prefix}: next launch {next}"),
            ];
            let running_observation = row.get("running_observation");
            let launches = row
                .get("running")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let running_status = running_observation
                .and_then(|value| value.get("status"))
                .and_then(Value::as_str)
                .unwrap_or("observed");
            if running_status == "unavailable" {
                let reason = running_observation
                    .and_then(|value| value.get("reason"))
                    .and_then(Value::as_str)
                    .unwrap_or("unknown reason");
                let boundary = running_observation
                    .and_then(|value| value.get("boundary"))
                    .and_then(Value::as_str)
                    .unwrap_or("the ready-generation query did not complete");
                lines.push(format!(
                    "{prefix}: running generation query unavailable ({reason}); {boundary}"
                ));
            } else if launches.is_empty() {
                lines.push(format!("{prefix}: running adapter not observed"));
            } else {
                for launch in launches {
                    let generation = launch
                        .get("generation")
                        .and_then(Value::as_u64)
                        .map(|n| n.to_string())
                        .unwrap_or_else(|| "?".to_owned());
                    let selection = launch
                        .get("selection_observation")
                        .map(render_selection)
                        .unwrap_or_else(|| "unknown".to_owned());
                    let child = launch
                        .get("vendor_cli_child")
                        .map(render_selection)
                        .unwrap_or_else(|| "unknown".to_owned());
                    let adapter = launch.get("adapter");
                    let running_package = adapter
                        .and_then(|value| value.get("package"))
                        .and_then(Value::as_str)
                        .unwrap_or("unknown");
                    let running_version = adapter
                        .and_then(|value| value.get("version"))
                        .and_then(Value::as_str)
                        .unwrap_or("unknown");
                    let started = launch
                        .get("selection_observation_started_at_ms")
                        .and_then(Value::as_u64)
                        .map(|value| format!("{value}ms since Unix epoch"))
                        .unwrap_or_else(|| "unknown time".to_owned());
                    let completed = launch
                        .get("selection_observation_completed_at_ms")
                        .and_then(Value::as_u64)
                        .map(|value| format!("{value}ms since Unix epoch"))
                        .unwrap_or_else(|| "unknown time".to_owned());
                    let generation_started = launch
                        .get("adapter_generation_started_at_ms")
                        .and_then(Value::as_u64)
                        .map(|value| format!("{value}ms since Unix epoch"))
                        .unwrap_or_else(|| "unknown time".to_owned());
                    let child_started = launch
                        .get("vendor_cli_child")
                        .and_then(|value| value.get("started_at_ms"))
                        .and_then(Value::as_u64)
                        .map(|value| format!("{value}ms since Unix epoch"))
                        .unwrap_or_else(|| "unknown time".to_owned());
                    let boundary = launch
                        .get("evidence_boundary")
                        .and_then(Value::as_str)
                        .unwrap_or("launch selection probe; vendor child identity is not established");
                    lines.push(format!(
                        "{prefix}: running generation {generation}: adapter {running_package} {running_version}; vendor CLI child {child} (start time {child_started}); adapter generation started at {generation_started}; launch selection probe observed {selection} from {started} to {completed}; {boundary}"
                    ));
                }
            }
            if let Some(warnings) = row.get("warnings").and_then(Value::as_array) {
                lines.extend(
                    warnings
                        .iter()
                        .filter_map(Value::as_str)
                        .map(|warning| format!("{prefix}: warning: {warning}")),
                );
            }
            lines
        })
        .collect()
}

fn render_selection(value: &Value) -> String {
    let status = value
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let source = value
        .get("source")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    if status == "observed" {
        let path = value.get("path").and_then(Value::as_str).unwrap_or("?");
        let version = value.get("version").and_then(Value::as_str).unwrap_or("?");
        format!("{source} {path} version {version}")
    } else {
        let reason = value
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or("no evidence");
        format!("{status} ({source}; {reason})")
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
    fn doctor_response_keeps_diagnostics_and_catalog_together() {
        let (catalog, diagnostics) = parse_doctor_response(
            r#"{"harnesses":[{"id":"codex","wire_name":"codex","install_package":"codex-acp","cli_binary":"codex","process_markers":["codex-acp"]}],"binary_diagnostics":{"status":"observed","rows":[]}}"#,
        )
        .unwrap();

        assert_eq!(catalog.names(), vec!["codex"]);
        assert_eq!(diagnostics.unwrap()["status"], "observed");
    }

    #[test]
    fn doctor_binary_human_output_matches_running_and_next_launch_json_fields() {
        let diagnostics = serde_json::json!({
            "status": "observed",
            "rows": [{
                "host": "example-host",
                "harness": "codex",
                "adapter": {"package": "codex-acp", "version": "1.12.0"},
                "running_observation": {"status": "observed", "boundary": "coordinator ready-generation list"},
                "running": [{
                    "generation": 3,
                    "adapter_generation_started_at_ms": 1789999999000u64,
                    "adapter": {"package": "codex-acp", "version": "1.12.0"},
                    "selection_observation_started_at_ms": 1790000000000u64,
                    "selection_observation_completed_at_ms": 1790000001000u64,
                    "evidence_boundary": "separate probe; does not inspect or fingerprint the vendor child",
                    "vendor_cli_child": {"status": "unknown", "source": "unknown", "started_at_ms": null, "reason": "independent probe does not inspect child"},
                    "selection_observation": {"status": "observed", "source": "pinned_override", "path": "/usr/local/bin/codex", "version": "codex 9.1"}
                }],
                "next_launch": {"status": "observed", "source": "bundled_fallback", "path": "/srv/tb/codex", "version": "codex 8.0"},
                "warnings": ["versions differ"]
            }]
        });

        let lines = binary_diagnostics_human(&diagnostics).join("\n");
        assert!(lines.contains(
            "selection probe observed pinned_override /usr/local/bin/codex version codex 9.1"
        ));
        assert!(lines.contains(
            "vendor CLI child unknown (unknown; independent probe does not inspect child)"
        ));
        assert!(lines.contains("vendor CLI child unknown (unknown; independent probe does not inspect child) (start time unknown time)"));
        assert!(lines.contains("adapter generation started at 1789999999000ms since Unix epoch"));
        assert!(lines.contains("does not inspect or fingerprint the vendor child"));
        assert!(!lines.contains(
            "running pinned_override /usr/local/bin/codex version codex 9.1 (generation"
        ));
        assert!(lines.contains("next launch bundled_fallback /srv/tb/codex version codex 8.0"));
        assert!(lines.contains("warning: versions differ"));
        assert_eq!(
            diagnostics["rows"][0]["running"][0]["selection_observation"]["path"],
            "/usr/local/bin/codex"
        );
        assert_eq!(
            diagnostics["rows"][0]["next_launch"]["version"],
            "codex 8.0"
        );
    }

    #[test]
    fn doctor_human_output_keeps_coordinator_failure_distinct_from_empty_running_state() {
        let diagnostics = serde_json::json!({
            "status": "observed",
            "rows": [{
                "host": "example-host",
                "harness": "codex",
                "adapter": {"package": "codex-acp", "version": "1.12.0"},
                "running_observation": {
                    "status": "unavailable",
                    "reason": "coordinator timed out",
                    "boundary": "ready-generation query did not complete"
                },
                "running": [],
                "next_launch": {"status": "observed", "source": "pinned_override", "path": "/opt/codex", "version": "codex 9"},
                "warnings": []
            }]
        });

        let lines = binary_diagnostics_human(&diagnostics).join("\n");
        assert!(lines.contains("running generation query unavailable (coordinator timed out)"));
        assert!(lines.contains("next launch pinned_override /opt/codex version codex 9"));
        assert!(!lines.contains("running adapter not observed"));
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
        assert!(parse(
            r#"[{"id":"third","wire_name":"third","install_package":"pkg","process_markers":[]}]"#
        )
        .unwrap_err()
        .contains("missing cli_binary"));
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
}
