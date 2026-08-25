//! Read-only deployment status projection.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::fs::{DeploymentFs, FsError};
use super::model::{
    AuditFactRecord, DeployStatus, DeploymentRootIdentity, Digest, ExpectedActive, GenerationId,
    NamespaceIdentity, Pointer, RestartLoadable, RunningService, ServiceSetDigest,
    ServiceSetStatus, ServiceStatus, TransactionId, TransactionState, TransactionStatus,
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
    let (audit_records, audit_error) = parse_audit_records(&audits);
    let staged = fs.list_staging()?;
    let intent = assess_intent(active.as_ref(), &intents, &fs.root_identity_digest());
    let state_error = pointer_error.or(intent.error.clone()).or(audit_error);
    let transaction = match state_error.as_deref() {
        Some(reason) => TransactionStatus::Indeterminate {
            reason: reason.to_owned(),
        },
        None => match intent.state {
            IntentState::NotCommitted => TransactionStatus::NotCommitted,
            IntentState::CommittedRecovered => TransactionStatus::CommittedRecovered,
            IntentState::None => match active {
                None => TransactionStatus::VirginReady,
                Some(_) => TransactionStatus::CommittedRecovered,
            },
        },
    };
    let audit = if state_error.is_some() {
        "contradictory"
    } else if audit_records.is_empty() {
        if intent.state == IntentState::CommittedRecovered {
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
        service_set: service_set.status,
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
        } else if intent.state == IntentState::NotCommitted {
            "resume-activation"
        } else if intent.state == IntentState::CommittedRecovered {
            "restart-or-observe"
        } else {
            "none"
        }
        .to_owned(),
        gc_hold: state_error.is_some() || intent.state != IntentState::None,
        gc_hold_transactions: if state_error.is_some() {
            vec!["invalid active pointer".to_owned()]
        } else if intent.state == IntentState::None {
            Vec::new()
        } else {
            vec!["unresolved activation intent".to_owned()]
        },
        last_results: Vec::new(),
    })
}

fn parse_audit_records(records: &[Vec<u8>]) -> (Vec<AuditFactRecord>, Option<String>) {
    let mut parsed = Vec::new();
    for record in records {
        match parse_audit_record(record) {
            Ok(record) => parsed.push(record),
            Err(error) => return (Vec::new(), Some(error)),
        }
    }
    (parsed, None)
}

fn parse_audit_record(record: &[u8]) -> Result<AuditFactRecord, String> {
    let value: Value =
        serde_json::from_slice(record).map_err(|error| format!("invalid audit fact: {error}"))?;
    let transaction_id = TransactionId::new(
        value
            .get("transactionId")
            .and_then(Value::as_str)
            .ok_or_else(|| "audit fact has no transactionId".to_owned())?,
    )?;
    let state = match value
        .get("state")
        .and_then(Value::as_str)
        .ok_or_else(|| "audit fact has no state".to_owned())?
    {
        "received" => TransactionState::Received,
        "staged" => TransactionState::Staged,
        "verified" => TransactionState::Verified,
        "authorized" => TransactionState::Authorized,
        "activated" => TransactionState::Activated,
        "restarted" => TransactionState::Restarted,
        "observed" => TransactionState::Observed,
        other => return Err(format!("audit fact has unsupported state: {other}")),
    };
    let observed_value = value
        .get("observed")
        .ok_or_else(|| "audit fact has no observed namespace".to_owned())?;
    let observed = match observed_value.get("kind").and_then(Value::as_str) {
        Some("virgin") => {
            NamespaceIdentity::Virgin(DeploymentRootIdentity::from_digest(Digest::parse(
                observed_value
                    .get("deploymentRoot")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "virgin audit fact has no deploymentRoot".to_owned())?,
            )?))
        }
        Some("generation") => NamespaceIdentity::Generation {
            generation: GenerationId::new(
                observed_value
                    .get("generation")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "generation audit fact has no generation".to_owned())?,
            )?,
            release: Digest::parse(
                observed_value
                    .get("releaseDigest")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "generation audit fact has no releaseDigest".to_owned())?,
            )?,
        },
        Some(other) => return Err(format!("audit fact has unsupported namespace: {other}")),
        None => return Err("audit fact has no namespace kind".to_owned()),
    };
    let fact_digest = Digest::parse(
        value
            .get("factDigest")
            .and_then(Value::as_str)
            .ok_or_else(|| "audit fact has no factDigest".to_owned())?,
    )?;
    Ok(AuditFactRecord {
        transaction_id,
        state,
        observed,
        fact_digest,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum IntentState {
    None,
    NotCommitted,
    CommittedRecovered,
}

struct IntentAssessment {
    state: IntentState,
    error: Option<String>,
}

fn assess_intent(
    active: Option<&Pointer>,
    records: &[Vec<u8>],
    root_identity: &DeploymentRootIdentity,
) -> IntentAssessment {
    if records.len() > 1 {
        return IntentAssessment {
            state: IntentState::None,
            error: Some("multiple unresolved activation intents".to_owned()),
        };
    }
    let Some(record) = records.first() else {
        return IntentAssessment {
            state: IntentState::None,
            error: None,
        };
    };
    let value: Value = match serde_json::from_slice(record) {
        Ok(value) => value,
        Err(error) => {
            return IntentAssessment {
                state: IntentState::None,
                error: Some(format!("invalid activation intent: {error}")),
            };
        }
    };
    let expected = match value.get("expectedActive").and_then(Value::as_str) {
        Some(value) => match ExpectedActive::parse(value) {
            Ok(expected) => expected,
            Err(error) => {
                return IntentAssessment {
                    state: IntentState::None,
                    error: Some(format!("invalid activation intent expectedActive: {error}")),
                };
            }
        },
        None => {
            return IntentAssessment {
                state: IntentState::None,
                error: Some("activation intent has no expectedActive".to_owned()),
            };
        }
    };
    let target = match super::parse_pointer(value.get("target")) {
        Ok(target) => target,
        Err(error) => {
            return IntentAssessment {
                state: IntentState::None,
                error: Some(error.to_string()),
            };
        }
    };
    if let ExpectedActive::Virgin { deployment_root } = &expected
        && deployment_root != root_identity
    {
        return IntentAssessment {
            state: IntentState::None,
            error: Some(format!(
                "activation intent names deployment root {}, observed {}",
                deployment_root.as_str(),
                root_identity.as_str()
            )),
        };
    }
    let expected_matches = match &expected {
        ExpectedActive::Virgin { .. } => active.is_none(),
        ExpectedActive::Generation {
            generation,
            release,
        } => active.is_some_and(|pointer| {
            pointer.generation == *generation && pointer.release == *release
        }),
    };
    if active.is_some_and(|pointer| pointer == &target) {
        return IntentAssessment {
            state: IntentState::CommittedRecovered,
            error: None,
        };
    }
    if expected_matches {
        return IntentAssessment {
            state: IntentState::NotCommitted,
            error: None,
        };
    }
    IntentAssessment {
        state: IntentState::None,
        error: Some(format!(
            "activation intent expected {} and targets generation:{}:{} but observed {}",
            expected.as_wire(),
            target.generation,
            target.release,
            active
                .map(|pointer| format!("generation:{}:{}", pointer.generation, pointer.release))
                .unwrap_or_else(|| "virgin".to_owned())
        )),
    }
}

struct ServiceSet {
    status: ServiceSetStatus,
    units: Vec<String>,
}

fn read_service_set(fs: &DeploymentFs) -> ServiceSet {
    let bytes = if fs.root() == Path::new("/opt/tightbeam") {
        std::fs::read("/etc/tightbeam/deploy-services.json").ok()
    } else {
        fs.read_confined(Path::new("deploy-services.json")).ok()
    };
    let Some(bytes) = bytes else {
        return ServiceSet {
            status: ServiceSetStatus {
                digest: None,
                units: Vec::new(),
                description: "invalid: service registry unavailable".to_owned(),
            },
            units: Vec::new(),
        };
    };
    let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
        return ServiceSet {
            status: ServiceSetStatus {
                digest: Some(ServiceSetDigest::from_bytes(&bytes)),
                units: Vec::new(),
                description: "invalid: malformed service registry".to_owned(),
            },
            units: Vec::new(),
        };
    };
    let Some(entries) = value.get("services").and_then(Value::as_array) else {
        return ServiceSet {
            status: ServiceSetStatus {
                digest: Some(ServiceSetDigest::from_bytes(&bytes)),
                units: Vec::new(),
                description: "invalid: service registry has no services".to_owned(),
            },
            units: Vec::new(),
        };
    };
    let mut units = Vec::new();
    for entry in entries {
        let Some(unit) = entry.get("unit").and_then(Value::as_str) else {
            return ServiceSet {
                status: ServiceSetStatus {
                    digest: Some(ServiceSetDigest::from_bytes(&bytes)),
                    units: Vec::new(),
                    description: "invalid: service registry entry has no unit".to_owned(),
                },
                units: Vec::new(),
            };
        };
        if units.iter().any(|known| known == unit) {
            return ServiceSet {
                status: ServiceSetStatus {
                    digest: Some(ServiceSetDigest::from_bytes(&bytes)),
                    units: Vec::new(),
                    description: format!("invalid: duplicate service unit {unit}"),
                },
                units: Vec::new(),
            };
        }
        units.push(unit.to_owned());
    }
    if units.is_empty() {
        return ServiceSet {
            status: ServiceSetStatus {
                digest: Some(ServiceSetDigest::from_bytes(&bytes)),
                units: Vec::new(),
                description: "invalid: service registry is empty".to_owned(),
            },
            units: Vec::new(),
        };
    }
    ServiceSet {
        status: ServiceSetStatus {
            digest: Some(ServiceSetDigest::from_bytes(&bytes)),
            units: units.clone(),
            description: format!("valid: {} ordered units", units.len()),
        },
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
        "serviceSet": {
            "digest": status.service_set.digest.as_ref().map(|digest| digest.as_str()),
            "units": &status.service_set.units,
            "status": &status.service_set.description,
        },
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
    use crate::deploy::model::Digest;
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
        let payload = b"payload";
        let payload_digest = Digest::from_bytes(payload);
        let release_manifest = format!(
            r#"{{"payload":[{{"path":"bin","type":"file","mode":420,"size":{},"sha256":"{}"}}]}}"#,
            payload.len(),
            payload_digest
        );
        let digest = Digest::from_bytes(release_manifest.as_bytes()).to_string();
        fs::create_dir_all(
            directory
                .0
                .join(format!("releases/sha256-{digest}/tightbeam")),
        )
        .unwrap();
        fs::write(
            directory
                .0
                .join(format!("releases/sha256-{digest}/release-manifest.json")),
            release_manifest,
        )
        .unwrap();
        fs::write(
            directory
                .0
                .join(format!("releases/sha256-{digest}/tightbeam/bin")),
            payload,
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
    fn status_uses_target_pointer_truth_after_active_rename() {
        let directory = tempdir();
        let payload = b"payload";
        let payload_digest = Digest::from_bytes(payload);
        let release_manifest = format!(
            r#"{{"payload":[{{"path":"bin","type":"file","mode":420,"size":{},"sha256":"{}"}}]}}"#,
            payload.len(),
            payload_digest
        );
        let digest = Digest::from_bytes(release_manifest.as_bytes()).to_string();
        let release_root = directory.0.join(format!("releases/sha256-{digest}"));
        fs::create_dir_all(release_root.join("tightbeam")).unwrap();
        fs::write(release_root.join("release-manifest.json"), release_manifest).unwrap();
        fs::write(release_root.join("tightbeam/bin"), payload).unwrap();
        for generation in ["g1", "g2"] {
            let generation_root = directory.0.join(format!("generations/{generation}"));
            fs::create_dir_all(&generation_root).unwrap();
            fs::write(
                generation_root.join("manifest.json"),
                format!(r#"{{"releaseDigest":"{digest}"}}"#),
            )
            .unwrap();
            std::os::unix::fs::symlink(
                format!("../../releases/sha256-{digest}/tightbeam"),
                generation_root.join("root"),
            )
            .unwrap();
        }
        fs::create_dir_all(directory.0.join("intents")).unwrap();
        fs::write(
            directory.0.join("intents/tx.json"),
            format!(
                r#"{{"expectedActive":"generation:g1:{digest}","target":{{"generation":"g2","releaseDigest":"{digest}"}}}}"#
            ),
        )
        .unwrap();
        std::os::unix::fs::symlink("generations/g2", directory.0.join("active")).unwrap();

        let status = read(&directory.0).unwrap();
        assert_eq!(status.transaction.as_str(), "committed-recovered");
        assert_eq!(status.audit, "recovered-missing-row");
        assert_eq!(status.observation, "pending");
        assert!(status.gc_hold);
    }

    #[test]
    fn status_holds_an_empty_release_tree_instead_of_claiming_restart_loadable() {
        let directory = tempdir();
        let digest = "a".repeat(64);
        fs::create_dir_all(
            directory
                .0
                .join(format!("releases/sha256-{digest}/tightbeam")),
        )
        .unwrap();
        fs::create_dir_all(directory.0.join("generations/g1")).unwrap();
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
        assert_eq!(status.transaction.as_str(), "indeterminate");
        assert!(matches!(
            status.restart_loadable,
            RestartLoadable::Unavailable { .. }
        ));
        assert_eq!(status.observation, "held");
        assert!(status.gc_hold);
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

    #[test]
    fn status_parses_typed_nested_audit_facts_and_holds_malformed_facts() {
        let directory = tempdir();
        fs::create_dir_all(directory.0.join("audit/tx-1")).unwrap();
        let root_digest = Digest::from_bytes(directory.0.to_string_lossy().as_bytes());
        let fact_digest = Digest::from_bytes(b"fact");
        fs::write(
            directory.0.join("audit/tx-1/fact.json"),
            format!(
                r#"{{"transactionId":"tx-1","state":"activated","observed":{{"kind":"virgin","deploymentRoot":"{}"}},"factDigest":"{}"}}"#,
                root_digest, fact_digest
            ),
        )
        .unwrap();
        let status = read(&directory.0).unwrap();
        assert_eq!(status.audit, "complete");
        assert_eq!(status.transaction.as_str(), "virgin-ready");

        fs::write(
            directory.0.join("audit/tx-1/fact.json"),
            br#"{"state":"broken"}"#,
        )
        .unwrap();
        let status = read(&directory.0).unwrap();
        assert_eq!(status.audit, "contradictory");
        assert_eq!(status.transaction.as_str(), "indeterminate");
        assert_eq!(status.observation, "held");
    }
}
