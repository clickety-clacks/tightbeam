use std::fs;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::dispatch;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessProjection {
    pub id: String,
    pub wire_name: String,
    pub install_package: String,
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
            Ok(HarnessProjection {
                id: string("id")?,
                wire_name: string("wire_name")?,
                install_package: string("install_package")?,
                process_markers,
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok(HarnessCatalog { harnesses })
}

pub fn load() -> Result<HarnessCatalog, String> {
    load_from_with(&home_dir(), load_from_default_route)
}

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

fn load_from_route(base_dir: &Path) -> Result<HarnessCatalog, String> {
    let endpoint = dispatch::discover_from(base_dir).map_err(|reason| unavailable(&reason))?;
    load_endpoint(&endpoint)
}

fn load_from_default_route() -> Result<HarnessCatalog, String> {
    let endpoint = dispatch::discover().map_err(|reason| unavailable(&reason))?;
    load_endpoint(&endpoint)
}

fn load_endpoint(endpoint: &dispatch::Endpoint) -> Result<HarnessCatalog, String> {
    let url = format!("{}/harnesses", endpoint.base);
    let response = ureq::get(&url)
        .set("authorization", &format!("Bearer {}", endpoint.token))
        .call()
        .map_err(|error| unavailable(&error.to_string()))?;
    let encoded = response
        .into_string()
        .map_err(|error| unavailable(&error.to_string()))?;
    parse(&encoded).map_err(|reason| unavailable(&reason))
}

pub fn load_optional() -> Option<HarnessCatalog> {
    load().ok()
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
            id: name.to_owned(),
            wire_name: name.to_owned(),
            install_package: format!("{name}-package"),
            process_markers: vec![marker.to_owned()],
        })
        .collect(),
    })
}

fn unavailable(reason: &str) -> String {
    format!("harness checks unavailable: {reason}; run tightbeam doctor")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn round_trips_every_consumed_field() {
        let catalog = parse(
            r#"[{"id":"third","wire_name":"third","install_package":"pkg","process_markers":["marker"]}]"#,
        )
        .unwrap();
        assert_eq!(catalog.names(), vec!["third"]);
        assert_eq!(catalog.harnesses[0].id, "third");
        assert_eq!(catalog.harnesses[0].install_package, "pkg");
        assert_eq!(catalog.harnesses[0].process_markers, vec!["marker"]);
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
            r#"[{"id":"third","wire_name":"third","install_package":"pkg","process_markers":["third-marker"]}]"#,
        )
        .unwrap();
        let catalog = load_from(&root).unwrap();
        assert_eq!(catalog.names(), vec!["third"]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_file_uses_the_route_loader_contract() {
        let encoded = r#"[{"id":"route","wire_name":"route","install_package":"route-pkg","process_markers":["route-marker"]}]"#;
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

        let encoded = r#"[{"id":"route","wire_name":"route","install_package":"route-pkg","process_markers":["route-marker"]}]"#;
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
}
