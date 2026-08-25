//! Read-only deployment status projection.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::fs::{DeploymentFs, FsError};
use super::model::{
    DeployStatus, ExpectedActive, Pointer, RestartLoadable, RunningService, ServiceStatus,
    TransactionStatus,
};

pub fn default_root() -> PathBuf {
    std::env::var_os("TIGHTBEAM_DEPLOY_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/opt/tightbeam"))
}

pub fn run(json_output: bool) -> Result<(), String> {
    let status = read(&default_root()).map_err(|error| error.to_string())?;
    if json_output {
        println!(
            "{}",
            serde_json::to_string_pretty(&to_json(&status)).expect("status JSON serializes")
        );
    } else {
        println!(
            "restart_loadable = {}",
            restart_loadable_text(&status.restart_loadable)
        );
        println!("transaction      = {}", status.transaction.as_str());
        println!("audit            = {}", status.audit);
        println!("lock             = {}", status.lock);
        println!("observation      = {}", status.observation);
        println!("gc_hold          = {}", status.gc_hold);
    }
    Ok(())
}

pub fn read(root: &Path) -> Result<DeployStatus, FsError> {
    let fs = DeploymentFs::open(root)?;
    let (active, pointer_error) = match fs.read_active() {
        Ok(active) => (active, None),
        Err(error) => (None, Some(error.to_string())),
    };
    let intents = fs.read_intents()?;
    let audits = fs.read_audit()?;
    let staged = fs.list_staging()?;
    let intent_error = intent_conflict(active.as_ref(), &intents);
    let state_error = pointer_error.or(intent_error);
    let transaction = match state_error.as_deref() {
        Some(reason) => TransactionStatus::Indeterminate {
            reason: reason.to_owned(),
        },
        None => match (&active, intents.is_empty()) {
            (None, true) => TransactionStatus::VirginReady,
            (None, false) => TransactionStatus::NotCommitted,
            (Some(_), true) => TransactionStatus::CommittedRecovered,
            (Some(_), false) => TransactionStatus::Committed,
        },
    };
    let audit = if state_error.is_some() {
        "contradictory"
    } else if audits.is_empty() {
        if active.is_some() && !intents.is_empty() {
            "recovered-missing-row"
        } else {
            "none"
        }
    } else {
        "complete"
    };
    let restart_loadable = match (active, state_error.as_deref()) {
        (Some(pointer), None) => RestartLoadable::Managed {
            generation: pointer.generation,
            release: pointer.release,
        },
        (Some(pointer), Some(reason)) => RestartLoadable::Unavailable {
            reason: format!(
                "active pointer validation changed while reading generation {}: {reason}",
                pointer.generation
            ),
        },
        (None, Some(reason)) => RestartLoadable::Unavailable {
            reason: format!("active pointer invalid: {reason}"),
        },
        (None, None) => RestartLoadable::Unavailable {
            reason: "virgin deployment root has no managed active pointer".to_owned(),
        },
    };
    let service_set = read_service_set(&fs);
    let services = service_set
        .units
        .iter()
        .map(|unit| ServiceStatus {
            unit: unit.clone(),
            running_release: None,
            unit_state: "unknown".to_owned(),
            version: None,
            readiness: None,
            result: "pending".to_owned(),
        })
        .collect::<Vec<_>>();
    Ok(DeployStatus {
        restart_loadable,
        restart_loadable_verification:
            "unverified: no legacy verification evidence in status slice".to_owned(),
        transaction,
        audit: audit.to_owned(),
        running: services
            .iter()
            .map(|service| RunningService {
                unit: service.unit.clone(),
                root: None,
                release: None,
                state: "unknown".to_owned(),
            })
            .collect(),
        service_set: service_set.description,
        services,
        observation: if state_error.is_some() {
            "held"
        } else {
            "pending"
        }
        .to_owned(),
        prior_known_good: "unavailable: no complete machine observation".to_owned(),
        staged,
        lock: fs.lock_status()?.to_owned(),
        unit_disk: Vec::new(),
        unit_effective: Vec::new(),
        unit_transaction: Vec::new(),
        next_authority: if state_error.is_some() {
            "adjudicate"
        } else if intents.is_empty() {
            "none"
        } else {
            "resume-activation"
        }
        .to_owned(),
        gc_hold: state_error.is_some() || !intents.is_empty(),
        gc_hold_transactions: if state_error.is_some() {
            vec!["invalid active pointer".to_owned()]
        } else if intents.is_empty() {
            Vec::new()
        } else {
            vec!["unresolved activation intent".to_owned()]
        },
        last_results: Vec::new(),
    })
}

fn intent_conflict(active: Option<&Pointer>, records: &[Vec<u8>]) -> Option<String> {
    if records.len() > 1 {
        return Some("multiple unresolved activation intents".to_owned());
    }
    let Some(record) = records.first() else {
        return None;
    };
    let value: Value = match serde_json::from_slice(record) {
        Ok(value) => value,
        Err(error) => return Some(format!("invalid activation intent: {error}")),
    };
    let expected = match value.get("expectedActive").and_then(Value::as_str) {
        Some(value) => match ExpectedActive::parse(value) {
            Ok(expected) => expected,
            Err(error) => {
                return Some(format!("invalid activation intent expectedActive: {error}"));
            }
        },
        None => return Some("activation intent has no expectedActive".to_owned()),
    };
    let target = match super::parse_pointer(value.get("target")) {
        Ok(target) => target,
        Err(error) => return Some(error.to_string()),
    };
    let expected_matches = match &expected {
        ExpectedActive::Virgin { .. } => active.is_none(),
        ExpectedActive::Generation {
            generation,
            release,
        } => active.is_some_and(|pointer| {
            pointer.generation == *generation && pointer.release == *release
        }),
    };
    if !expected_matches {
        return Some(format!(
            "activation intent expected {} but observed {}",
            expected.as_wire(),
            active
                .map(|pointer| format!("generation:{}:{}", pointer.generation, pointer.release))
                .unwrap_or_else(|| "virgin".to_owned())
        ));
    }
    if let Some(pointer) = active
        && pointer != &target
    {
        return Some(format!(
            "activation intent targets generation:{}:{} but observed generation:{}:{}",
            target.generation, target.release, pointer.generation, pointer.release
        ));
    }
    None
}

struct ServiceSet {
    description: String,
    units: Vec<String>,
}

fn read_service_set(fs: &DeploymentFs) -> ServiceSet {
    let path = Path::new("deploy-services.json");
    let Ok(bytes) = fs.read_confined(path) else {
        return ServiceSet {
            description: "invalid: service registry unavailable".to_owned(),
            units: Vec::new(),
        };
    };
    let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
        return ServiceSet {
            description: "invalid: malformed service registry".to_owned(),
            units: Vec::new(),
        };
    };
    let Some(entries) = value.get("services").and_then(Value::as_array) else {
        return ServiceSet {
            description: "invalid: service registry has no services".to_owned(),
            units: Vec::new(),
        };
    };
    let mut units = Vec::new();
    for entry in entries {
        let Some(unit) = entry.get("unit").and_then(Value::as_str) else {
            return ServiceSet {
                description: "invalid: service registry entry has no unit".to_owned(),
                units: Vec::new(),
            };
        };
        if units.iter().any(|known| known == unit) {
            return ServiceSet {
                description: format!("invalid: duplicate service unit {unit}"),
                units: Vec::new(),
            };
        }
        units.push(unit.to_owned());
    }
    if units.is_empty() {
        return ServiceSet {
            description: "invalid: service registry is empty".to_owned(),
            units: Vec::new(),
        };
    }
    ServiceSet {
        description: format!("valid: {} ordered units", units.len()),
        units,
    }
}

fn restart_loadable_text(value: &RestartLoadable) -> String {
    match value {
        RestartLoadable::Managed {
            generation,
            release,
        } => {
            format!("generation:{generation} release:{release}")
        }
        RestartLoadable::Legacy { root, release, .. } => format!("legacy:{root} release:{release}"),
        RestartLoadable::Unavailable { reason } => reason.clone(),
    }
}

pub fn to_json(status: &DeployStatus) -> Value {
    let restart_loadable = match &status.restart_loadable {
        RestartLoadable::Managed {
            generation,
            release,
        } => json!({
            "kind": "generation",
            "generation": generation.as_str(),
            "releaseDigest": release.as_str(),
        }),
        RestartLoadable::Legacy {
            root,
            release,
            verified,
            reason,
        } => json!({
            "kind": "legacy",
            "root": root,
            "releaseDigest": release.as_str(),
            "verification": if *verified { "verified" } else { "unverified" },
            "reason": reason,
        }),
        RestartLoadable::Unavailable { reason } => json!({
            "kind": "unavailable",
            "reason": reason,
        }),
    };
    json!({
        "restartLoadable": restart_loadable,
        "restartLoadableVerification": status.restart_loadable_verification,
        "transaction": status.transaction.as_str(),
        "transactionReason": match &status.transaction {
            TransactionStatus::Indeterminate { reason } => Some(reason),
            _ => None,
        },
        "audit": status.audit,
        "running": status.running.iter().map(|service| json!({
            "unit": service.unit,
            "root": service.root,
            "releaseDigest": service.release.as_ref().map(|digest| digest.as_str()),
            "state": service.state,
        })).collect::<Vec<_>>(),
        "serviceSet": status.service_set,
        "services": status.services.iter().map(|service| json!({
            "unit": service.unit,
            "runningDigest": service.running_release.as_ref().map(|digest| digest.as_str()),
            "unitState": service.unit_state,
            "version": service.version,
            "readiness": service.readiness,
            "result": service.result,
        })).collect::<Vec<_>>(),
        "observation": status.observation,
        "priorKnownGood": status.prior_known_good,
        "staged": status.staged,
        "lock": status.lock,
        "unitDisk": status.unit_disk,
        "unitEffective": status.unit_effective,
        "unitTransaction": status.unit_transaction,
        "nextAuthority": status.next_authority,
        "gcHold": status.gc_hold,
        "gcHoldTransactions": status.gc_hold_transactions,
        "lastResults": status.last_results,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    struct TempDir(PathBuf);

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn tempdir() -> TempDir {
        let path = std::env::temp_dir().join(format!(
            "tightbeam-deploy-status-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&path).unwrap();
        TempDir(path)
    }

    #[test]
    fn status_reads_active_pointer_as_restart_loadable_truth() {
        let directory = tempdir();
        fs::create_dir_all(directory.0.join("generations/g1")).unwrap();
        let digest = "a".repeat(64);
        fs::create_dir_all(
            directory
                .0
                .join(format!("releases/sha256-{digest}/tightbeam")),
        )
        .unwrap();
        fs::write(
            directory.0.join("generations/g1/manifest.json"),
            format!(r#"{{"releaseDigest":"{digest}"}}"#),
        )
        .unwrap();
        std::os::unix::fs::symlink(
            format!("../../releases/sha256-{digest}/tightbeam"),
            directory.0.join("generations/g1/root"),
        )
        .unwrap();
        std::os::unix::fs::symlink("generations/g1", directory.0.join("active")).unwrap();
        let status = read(&directory.0).unwrap();
        assert!(matches!(
            status.restart_loadable,
            RestartLoadable::Managed { .. }
        ));
        assert_eq!(status.transaction.as_str(), "committed-recovered");
        assert_eq!(status.audit, "none");
    }

    #[test]
    fn status_keeps_invalid_pointer_truth_readable_and_held() {
        let directory = tempdir();
        fs::create_dir_all(directory.0.join("generations/g1")).unwrap();
        std::os::unix::fs::symlink("generations/g1", directory.0.join("active")).unwrap();
        let status = read(&directory.0).unwrap();
        assert_eq!(status.transaction.as_str(), "indeterminate");
        assert_eq!(status.audit, "contradictory");
        assert_eq!(status.observation, "held");
        assert_eq!(status.next_authority, "adjudicate");
        assert!(status.gc_hold);
    }
}
